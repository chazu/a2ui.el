;;; a2ui-tools.el --- A2UI as tools for LLM hosts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/a2ui.el
;; Keywords: tools, comm
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The tools a model uses to draw A2UI surfaces, defined once for every
;; host: gptel (`a2ui-gptel'), MCP clients such as Claude Code, Codex
;; and agent-shell (`a2ui-mcp', `a2ui-agent-shell').
;;
;; - render_a2ui: show or replace a surface
;; - update_a2ui: change some components or data of a surface
;; - a2ui_catalog: the component list (a compact digest) or the
;;   schema of named components
;; - a2ui_await_action: wait for the user's next button press
;;
;; A host is one conversation's A2UI session plus how actions reach
;; the model.  A host with a DELIVER function hands each action to it
;; (agent-shell submits it as a prompt); otherwise actions wait for
;; a2ui_await_action.  A pending a2ui_await_action always takes the
;; action first.
;;
;; Results are compact JSON, and the catalog is sent only when the
;; model asks for it, to keep each turn small.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'a2ui-core)

(defcustom a2ui-tools-catalog-in-description nil
  "When non-nil, put the catalog digest in render_a2ui's description.
The model then never needs to call a2ui_catalog, at the cost of the
digest (~900 tokens) in every request, UI or not."
  :type 'boolean
  :group 'a2ui)

(defcustom a2ui-tools-await-timeout 120
  "Default seconds a2ui_await_action waits before giving up."
  :type 'natnum
  :group 'a2ui)

(defvar a2ui-tools-host-functions nil
  "Abnormal hook run with each new host's A2UI session.
A renderer adds itself here, e.g. `a2ui-vui-attach'.")

;;;; Hosts

(cl-defstruct (a2ui-tools-host (:constructor a2ui-tools--make-host) (:copier nil))
  "One conversation's A2UI session and how its actions reach the model."
  name session deliver
  (queue nil)                           ; undelivered action texts, oldest first
  (waiters nil)                         ; (SURFACE-ID . CALLBACK) of awaits
  (failed nil))                         ; (SURFACE-ID . ERRORS) of rejected renders

(defvar a2ui-tools--errors t
  "Errors collected while a tool call applies messages, or t when not.")

(cl-defun a2ui-tools-host-create (&key name directory deliver)
  "Return a new host NAME whose relative paths start at DIRECTORY.
DELIVER, when non-nil, is called with each action as text when no
a2ui_await_action is waiting for it."
  (let* ((host (a2ui-tools--make-host :name name :deliver deliver))
         (session (a2ui-session-create
                   :name name :directory directory
                   :send-action-fn (lambda (message _metadata)
                                     (a2ui-tools--outbound host message)))))
    (setf (a2ui-tools-host-session host) session
          (a2ui-session-on-change-fn session)
          (lambda (surface-id)
            (unless (a2ui-session-surface session surface-id)
              (a2ui-tools--closed host surface-id))))
    (run-hook-with-args 'a2ui-tools-host-functions session)
    host))

(defun a2ui-tools--error-text (error)
  "Describe the A2UI ERROR object in one line."
  (format "%s%s: %s" (gethash "code" error)
          (if (gethash "path" error) (concat " " (gethash "path" error)) "")
          (gethash "message" error)))

(defun a2ui-tools-action-text (action)
  "Describe ACTION for the model, as the AG-UI A2UI middleware does."
  (format "User performed action %S on surface %S (component: %s). Context: %s"
          (gethash "name" action) (gethash "surfaceId" action)
          (gethash "sourceComponentId" action)
          (a2ui-json-encode (or (gethash "context" action) (a2ui-obj)))))

(defun a2ui-tools--outbound (host message)
  "Handle MESSAGE, an outbound A2UI envelope of HOST."
  (cond
   ((gethash "error" message)
    (if (listp a2ui-tools--errors)
        (push (a2ui-tools--error-text (gethash "error" message)) a2ui-tools--errors)
      (message "a2ui: %s" (a2ui-tools--error-text (gethash "error" message)))))
   ((gethash "action" message)
    (a2ui-tools--deliver host (gethash "surfaceId" (gethash "action" message))
                         (a2ui-tools-action-text (gethash "action" message))))))

(defun a2ui-tools--closed (host surface-id)
  "End HOST's a2ui_await_action calls on SURFACE-ID, which was deleted."
  (dolist (waiter (a2ui-tools-host-waiters host))
    (when (equal (car waiter) surface-id)
      (setf (a2ui-tools-host-waiters host) (delq waiter (a2ui-tools-host-waiters host)))
      (funcall (cdr waiter) (a2ui-tools--result "closed" "surfaceId" surface-id
                                                "note" "The user closed this surface.")))))

(defun a2ui-tools--deliver (host surface-id text)
  "Give the action TEXT from SURFACE-ID to HOST's model.
A waiting a2ui_await_action for that surface (or any surface) gets it
first, then the host's DELIVER function; otherwise it is queued."
  (if-let* ((waiter (seq-find (lambda (w) (or (null (car w)) (equal (car w) surface-id)))
                              (a2ui-tools-host-waiters host))))
      (progn (setf (a2ui-tools-host-waiters host) (delq waiter (a2ui-tools-host-waiters host)))
             (funcall (cdr waiter) text))
    (if (a2ui-tools-host-deliver host)
        (funcall (a2ui-tools-host-deliver host) text)
      (setf (a2ui-tools-host-queue host) (append (a2ui-tools-host-queue host) (list text)))
      (message "a2ui: action saved for the agent; it receives it when it calls a2ui_await_action"))))

;;;; Tool definitions

(defconst a2ui-tools--render-description
  "Show the user an interactive surface in their Emacs: forms, tables, diffs, pickers and more, instead of asking in prose.  components is a flat array of A2UI v0.9 components {\"id\", \"component\": Type, ...props}; one has id \"root\"; containers name children by id; a Button's child is a Text id.  Bind values to data with {\"path\": \"/x\"}, in props and action contexts alike.  Rendering a surfaceId again replaces it; use update_a2ui for small changes.  Call a2ui_catalog first for the components.  When the user presses a button you receive \"User performed action ...\" with the resolved context."
  "Description of render_a2ui.")

(defun a2ui-tools--schema (properties required)
  "Return an object JSON Schema with PROPERTIES (a plist) and REQUIRED."
  (let ((props (make-hash-table :test 'equal)))
    (cl-loop for (k v) on properties by #'cddr
             do (puthash (substring (symbol-name k) 1) v props))
    (a2ui-obj "type" "object" "properties" props "required" (vconcat required))))

(defun a2ui-tools--top-catalog (host)
  "Return HOST's most capable catalog, or the default one without HOST."
  (car (a2ui-session-top-catalogs (if host
                                      (a2ui-tools-host-session host)
                                    (a2ui-session-create)))))

(defun a2ui-tools-specs (host &optional names)
  "Return the tool definitions for HOST as plists.
Each has :name, :description and :parameters (a JSON Schema object).
NAMES, a list of tool names, limits the result."
  (let ((specs
         (list
          (list :name "render_a2ui"
                :description (concat a2ui-tools--render-description
                                     (when a2ui-tools-catalog-in-description
                                       (concat "\n\n" (a2ui-catalog-digest (a2ui-tools--top-catalog host)))))
                :parameters (a2ui-tools--schema
                             (list :surfaceId (a2ui-obj "type" "string" "description" "A stable id; reuse it to replace the surface.")
                                   :components (a2ui-obj "type" "array" "items" (a2ui-obj "type" "object")
                                                         "description" "Flat A2UI v0.9 components; one has id \"root\".")
                                   :data (a2ui-obj "type" "object" "description" "The initial data model."))
                             '("surfaceId" "components")))
          (list :name "update_a2ui"
                :description "Change part of a surface shown with render_a2ui: components upserts components by id; data sets values at JSON Pointer paths (leave value out to remove).  Cheaper than rendering again."
                :parameters (a2ui-tools--schema
                             (list :surfaceId (a2ui-obj "type" "string")
                                   :components (a2ui-obj "type" "array" "items" (a2ui-obj "type" "object"))
                                   :data (a2ui-obj "type" "array"
                                                   "items" (a2ui-obj "type" "object"
                                                                     "properties" (a2ui-obj "path" (a2ui-obj "type" "string")
                                                                                            "value" (a2ui-obj))
                                                                     "required" ["path"])))
                             '("surfaceId")))
          (list :name "a2ui_catalog"
                :description "List the components and functions render_a2ui accepts, one per line.  Name components to get their full JSON Schema instead."
                :parameters (a2ui-tools--schema
                             (list :components (a2ui-obj "type" "array" "items" (a2ui-obj "type" "string")))
                             nil))
          (list :name "a2ui_await_action"
                :description "Wait for the user's next button press on a surface (or any, without surfaceId) and return it.  Returns at once if one is already waiting; gives up after timeoutSeconds."
                :parameters (a2ui-tools--schema
                             (list :surfaceId (a2ui-obj "type" "string")
                                   :timeoutSeconds (a2ui-obj "type" "number"))
                             nil)))))
    (if names
        (seq-filter (lambda (s) (member (plist-get s :name) names)) specs)
      specs)))

;;;; Tool implementations

(defun a2ui-tools-normalize-components (components)
  "Return COMPONENTS, a vector, with two common model mistakes repaired.
Properties wrapped in a \"props\" object are moved up, and components
written inline in children (or child) are hoisted into the flat list
and referred to by id.  Valid components pass through unchanged."
  (let (out)
    (cl-labels
        ((visit (c)
           (when (hash-table-p c)
             (let ((props (gethash "props" c)))
               (when (hash-table-p props)
                 (remhash "props" c)
                 (maphash (lambda (k v) (unless (gethash k c) (puthash k v c))) props)))
             (let ((children (gethash "children" c)))
               (when (vectorp children)
                 (puthash "children"
                          (vconcat (mapcar (lambda (child)
                                             (if (and (hash-table-p child) (stringp (gethash "id" child)))
                                                 (progn (visit child) (gethash "id" child))
                                               child))
                                           children))
                          c)))
             (let ((child (gethash "child" c)))
               (when (and (hash-table-p child) (stringp (gethash "id" child)))
                 (visit child)
                 (puthash "child" (gethash "id" child) c)))
             (push c out))))
      (seq-doseq (c components) (visit c)))
    (vconcat (nreverse out))))

(defun a2ui-tools-render-operations (session args default-catalog-id)
  "Return the A2UI operations that render_a2ui ARGS stand for in SESSION.
A new surface is created in DEFAULT-CATALOG-ID unless ARGS name a
catalogId.  Args holding a2ui_operations or messages arrays of A2UI
messages are accepted as they are."
  (let ((id (gethash "surfaceId" args)))
    (cond
     ((vectorp (gethash "a2ui_operations" args)) (gethash "a2ui_operations" args))
     ((vectorp (gethash "messages" args)) (gethash "messages" args))
     ((not (stringp id))
      (signal 'a2ui-error (list "render_a2ui needs a surfaceId string")))
     (t
      (delq nil
            (list (unless (a2ui-session-surface session id)
                    (a2ui-obj "version" "v0.9"
                              "createSurface" (a2ui-obj "surfaceId" id
                                                        "catalogId" (or (gethash "catalogId" args)
                                                                        default-catalog-id))))
                  (a2ui-obj "version" "v0.9"
                            "updateComponents" (a2ui-obj "surfaceId" id
                                                         "components" (a2ui-tools-normalize-components
                                                                       (or (gethash "components" args) []))))
                  (when (gethash "data" args)
                    (a2ui-obj "version" "v0.9"
                              "updateDataModel" (a2ui-obj "surfaceId" id "path" "/"
                                                          "value" (gethash "data" args))))))))))

(defun a2ui-tools--apply (host operations)
  "Apply OPERATIONS to HOST's session; return the errors they caused."
  (let ((a2ui-tools--errors nil)
        (session (a2ui-tools-host-session host)))
    (seq-doseq (op operations)
      (let ((create (and (hash-table-p op) (gethash "createSurface" op))))
        ;; Rendering a surface again is a replacement, not an error.
        (unless (and (hash-table-p create) (a2ui-session-surface session (gethash "surfaceId" create)))
          (a2ui-apply-message session op))))
    (nreverse a2ui-tools--errors)))

(defun a2ui-tools--result (status &rest pairs)
  "Return a compact JSON result with STATUS and the key/value PAIRS."
  (a2ui-json-encode (apply #'a2ui-obj "status" status pairs)))

(defun a2ui-tools--outcome (host errors surface-id)
  "Return the result of HOST's render or update of SURFACE-ID with ERRORS.
A failure is remembered, so a2ui_await_action on the surface returns
at once instead of waiting for a press that cannot come."
  (setf (alist-get surface-id (a2ui-tools-host-failed host) nil 'remove #'equal) errors)
  (if errors
      (a2ui-tools--result "invalid" "surfaceId" surface-id
                          "errors" (vconcat errors)
                          "hint" "Fix these and call again; a2ui_catalog lists the components.")
    (a2ui-tools--result "shown" "surfaceId" surface-id)))

(defun a2ui-tools--render (host args)
  "Run render_a2ui with ARGS for HOST."
  (let* ((session (a2ui-tools-host-session host))
         (id (gethash "surfaceId" args))
         (catalog (a2ui-catalog-id (a2ui-tools--top-catalog host))))
    ;; A new render replaces the surface, so old components do not linger.
    (when (and (stringp id) (a2ui-session-surface session id))
      (clrhash (a2ui-surface-components (a2ui-session-surface session id))))
    (a2ui-tools--outcome
     host (a2ui-tools--apply host (a2ui-tools-render-operations session args catalog))
     id)))

(defun a2ui-tools--update (host args)
  "Run update_a2ui with ARGS for HOST."
  (let ((id (gethash "surfaceId" args)))
    (if (not (a2ui-session-surface (a2ui-tools-host-session host) id))
        (a2ui-tools--result "invalid" "errors" (vector (format "No surface %s; call render_a2ui first" id)))
      (a2ui-tools--outcome
       host
       (a2ui-tools--apply
        host
        (append
         (when (vectorp (gethash "components" args))
           (list (a2ui-obj "version" "v0.9"
                           "updateComponents" (a2ui-obj "surfaceId" id "components"
                                                        (a2ui-tools-normalize-components (gethash "components" args))))))
         (cl-loop for entry across (let ((d (gethash "data" args))) (if (vectorp d) d []))
                  when (hash-table-p entry)
                  collect (let ((body (a2ui-obj "surfaceId" id "path" (or (gethash "path" entry) "/"))))
                            (unless (eq (gethash "value" entry 'absent) 'absent)
                              (puthash "value" (gethash "value" entry) body))
                            (a2ui-obj "version" "v0.9" "updateDataModel" body)))))
       id))))

(defun a2ui-tools--catalog (host args)
  "Run a2ui_catalog with ARGS for HOST."
  (let* ((catalog (a2ui-tools--top-catalog host))
         (names (append (gethash "components" args) nil)))
    (if (null names)
        (a2ui-catalog-digest catalog)
      (let ((components (gethash "components" (a2ui-catalog-schema catalog)))
            (out (a2ui-obj)))
        (dolist (n names)
          (puthash n (or (gethash n components) "unknown component") out))
        (a2ui-json-encode out)))))

(defun a2ui-tools--await (host args callback)
  "Run a2ui_await_action with ARGS for HOST; call CALLBACK with the result."
  (let* ((surface-id (gethash "surfaceId" args))
         (queued (seq-find (lambda (text) (or (null surface-id)
                                              (string-search (format "on surface %S" surface-id) text)))
                           (a2ui-tools-host-queue host))))
    (cond
     (queued
      (setf (a2ui-tools-host-queue host) (delete queued (a2ui-tools-host-queue host)))
      (funcall callback queued))
     ((and surface-id (not (a2ui-session-surface (a2ui-tools-host-session host) surface-id)))
      (funcall callback (a2ui-tools--result "invalid" "errors"
                                            (vector (format "No surface %s; show it with render_a2ui first" surface-id)))))
     ((and surface-id (alist-get surface-id (a2ui-tools-host-failed host) nil nil #'equal))
      (funcall callback (a2ui-tools--result "invalid" "surfaceId" surface-id
                                            "errors" (vconcat (alist-get surface-id (a2ui-tools-host-failed host)
                                                                         nil nil #'equal))
                                            "hint" "The last render of this surface failed; fix it before waiting.")))
     (t
      (let* ((done nil)
             (waiter (cons surface-id (lambda (text)
                                        (unless done (setq done t) (funcall callback text)))))
             (timeout (min 600 (or (a2ui-number (gethash "timeoutSeconds" args))
                                   a2ui-tools-await-timeout))))
        (push waiter (a2ui-tools-host-waiters host))
        (run-at-time timeout nil
                     (lambda ()
                       (unless done
                         (setf (a2ui-tools-host-waiters host) (delq waiter (a2ui-tools-host-waiters host)))
                         (funcall (cdr waiter)
                                  (a2ui-tools--result "waiting" "note" "No action yet; the user may still be filling in the surface."))))))))))

(defun a2ui-tools-call (host name args callback)
  "Run tool NAME of HOST with ARGS, a JSON object; CALLBACK gets the result.
The result is a string.  Every tool but a2ui_await_action calls
CALLBACK before returning."
  (condition-case err
      (pcase name
        ("render_a2ui" (funcall callback (a2ui-tools--render host args)))
        ("update_a2ui" (funcall callback (a2ui-tools--update host args)))
        ("a2ui_catalog" (funcall callback (a2ui-tools--catalog host args)))
        ("a2ui_await_action" (a2ui-tools--await host args callback))
        (_ (funcall callback (a2ui-tools--result "error" "error" (format "Unknown tool %s" name)))))
    (error (funcall callback (a2ui-tools--result "error" "error" (error-message-string err))))))

;;;; Arguments from Lisp

(defun a2ui-tools-from-lisp (value)
  "Return VALUE, JSON decoded as plists or alists, as A2UI JSON.
Keyword plists and alists become hash tables, `:json-false' and
`:false' become `:false', and `:null' becomes nil."
  (cond
   ((memq value '(:json-false :false)) :false)
   ((eq value :null) nil)
   ((hash-table-p value) value)
   ((vectorp value) (vconcat (mapcar #'a2ui-tools-from-lisp value)))
   ((and (consp value) (keywordp (car value)))
    (let ((obj (a2ui-obj)))
      (cl-loop for (k v) on value by #'cddr
               do (puthash (substring (symbol-name k) 1) (a2ui-tools-from-lisp v) obj))
      obj))
   ((and (consp value) (consp (car value)) (or (symbolp (caar value)) (stringp (caar value))))
    (let ((obj (a2ui-obj)))
      (dolist (pair value)
        (puthash (format "%s" (car pair)) (a2ui-tools-from-lisp (cdr pair)) obj))
      obj))
   ((consp value) (vconcat (mapcar #'a2ui-tools-from-lisp value)))
   (t value)))

(provide 'a2ui-tools)
;;; a2ui-tools.el ends here
