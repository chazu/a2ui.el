;;; a2ui-gptel.el --- A2UI surfaces for gptel -*- lexical-binding: t; -*-

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

;; The `a2ui-tools' as native gptel tools, so any model gptel talks to
;; can draw A2UI surfaces.  `a2ui-gptel-enable' registers them and adds
;; them to `gptel-tools'.  Each gptel buffer has its own session.
;;
;; A button press reaches the model one of two ways: if the model is
;; waiting in a2ui_await_action, as that tool's result, in the same
;; turn; otherwise it is typed into the chat buffer and sent, like a
;; message from you (`a2ui-gptel-send-actions').
;;
;; gptel is not required to load this file; it is used once the tools
;; are enabled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'a2ui-tools)
(require 'a2ui-vui)

(defcustom a2ui-gptel-send-actions t
  "When non-nil, send button presses to the model as chat messages.
They go to the end of the gptel chat buffer and are sent at once (or
when the current request finishes).  When nil, or outside a chat
buffer, they wait for the model to call a2ui_await_action."
  :type 'boolean
  :group 'a2ui)

(defcustom a2ui-gptel-inline-surfaces nil
  "When non-nil, draw surfaces in the gptel chat buffer itself.
Each new surface appears below the response that drew it, once that
response is done, and gptel leaves it out of what it sends.  If the
model waits for a press in a2ui_await_action instead of ending its
response, the surface opens in its own buffer.  When nil, or outside
a chat buffer, each surface gets a buffer of its own."
  :type 'boolean
  :group 'a2ui)

(defvar gptel-tools)
(defvar gptel-mode)
(defvar gptel--request-alist)
(defvar gptel-post-response-functions)
(declare-function gptel-make-tool "gptel-request" (&rest slots))
(declare-function gptel-send "gptel" (&optional arg))
(declare-function gptel-prompt-prefix-string "gptel" ())
(declare-function gptel-fsm-info "gptel-request" (fsm))
(declare-function gptel-tool-name "gptel-request" (tool))
(declare-function gptel--fsm-live-p "gptel" (&optional fsm))

(defvar-local a2ui-gptel--host nil
  "This buffer's A2UI host.")

(defvar-local a2ui-gptel--pending nil
  "Ids of surfaces to draw inline when the current response ends.")

(defun a2ui-gptel--show-inline (buffer surface-id)
  "Draw SURFACE-ID in chat BUFFER once the response in progress ends."
  (with-current-buffer buffer
    (unless (member surface-id a2ui-gptel--pending)
      (setq a2ui-gptel--pending (append a2ui-gptel--pending (list surface-id))))
    (add-hook 'gptel-post-response-functions #'a2ui-gptel--insert-pending nil t)
    (unless (a2ui-gptel--busy-p buffer)
      (a2ui-gptel--insert-pending nil (point-max)))))

(defun a2ui-gptel--show-pending-apart ()
  "Show the surfaces waiting for the response's end in their own buffers.
A model waiting in a2ui_await_action does not end its response, and
gptel is still writing to the chat, so they cannot wait for it."
  (when-let* ((host a2ui-gptel--host))
    (dolist (id (prog1 a2ui-gptel--pending (setq a2ui-gptel--pending nil)))
      (when (a2ui-session-surface (a2ui-tools-host-session host) id)
        (a2ui-show-surface (a2ui-tools-host-session host) id)))))

(defun a2ui-gptel--insert-pending (_beg end)
  "Draw the surfaces waiting to be shown, below the response ending at END."
  (let ((pos (min (or end (point-max)) (point-max)))
        (session (a2ui-tools-host-session a2ui-gptel--host)))
    (dolist (id (prog1 a2ui-gptel--pending (setq a2ui-gptel--pending nil)))
      (when (a2ui-session-surface session id)
        (let ((instance (a2ui-vui-insert-surface session id pos '(gptel ignore))))
          (setq pos (or (cdr (vui--inline-bounds instance)) pos)))))))

(defun a2ui-gptel--busy-p (buffer)
  "Return non-nil while a gptel request for BUFFER is in flight.
That includes the time its tools run, when no HTTP request is open."
  (or (and (fboundp 'gptel--fsm-live-p) (buffer-live-p buffer)
           (with-current-buffer buffer
             (and (bound-and-true-p gptel--fsm-last) (gptel--fsm-live-p))))
      (and (boundp 'gptel--request-alist)
           (seq-some (lambda (entry)
                       (ignore-errors
                         (eq buffer (plist-get (gptel-fsm-info (cadr entry)) :buffer))))
                     gptel--request-alist))))

(defun a2ui-gptel--send (buffer text)
  "Type TEXT at the end of chat BUFFER and send it to the model.
While a request is in flight, wait for it to finish."
  (if (a2ui-gptel--busy-p buffer)
      (letrec ((retry (lambda (&rest _)
                        (remove-hook 'gptel-post-response-functions retry)
                        (run-at-time 0.1 nil #'a2ui-gptel--send buffer text))))
        (add-hook 'gptel-post-response-functions retry))
    (with-current-buffer buffer
      (goto-char (point-max))
      ;; Beside gptel's prompt prefix, or on a line of its own.
      (unless (or (bolp)
                  (and (fboundp 'gptel-prompt-prefix-string)
                       (looking-back (regexp-quote (gptel-prompt-prefix-string)) (line-beginning-position))))
        (insert "\n"))
      (insert text)
      (gptel-send))))

(defun a2ui-gptel-host ()
  "Return the current buffer's A2UI host, making it on first use."
  (or a2ui-gptel--host
      (let* ((buffer (current-buffer))
             (host (a2ui-tools-host-create
                    :name (buffer-name buffer)
                    :directory default-directory
                    :deliver (and a2ui-gptel-send-actions (bound-and-true-p gptel-mode)
                                  (lambda (text) (a2ui-gptel--send buffer text))))))
        (when (and a2ui-gptel-inline-surfaces (bound-and-true-p gptel-mode))
          (setf (a2ui-session-display-fn (a2ui-tools-host-session host))
                (lambda (id) (a2ui-gptel--show-inline buffer id))))
        (setq a2ui-gptel--host host))))

(defun a2ui-gptel--plist (value)
  "Return the JSON VALUE as a plist with keyword keys, for gptel."
  (cond ((hash-table-p value)
         (let (out)
           (maphash (lambda (k v) (setq out (append out (list (intern (concat ":" k)) (a2ui-gptel--plist v)))))
                    value)
           out))
        ((vectorp value) (vconcat (mapcar #'a2ui-gptel--plist value)))
        (t value)))

(defun a2ui-gptel--free-object-p (prop)
  "Return non-nil if PROP is an object schema without listed properties.
gptel declares every object argument closed (additionalProperties
false), which would forbid any key, so these are passed as JSON text."
  (and (equal (gethash "type" prop) "object") (not (gethash "properties" prop))))

(defun a2ui-gptel--args (schema)
  "Return gptel :args for the object JSON SCHEMA of a tool's parameters."
  (let ((required (append (gethash "required" schema) nil))
        args)
    (maphash
     (lambda (name prop)
       (push (append (list :name name
                           :type (if (a2ui-gptel--free-object-p prop) 'string (intern (gethash "type" prop)))
                           :description (concat (or (gethash "description" prop) name)
                                                (when (a2ui-gptel--free-object-p prop) "  A JSON object, as text.")))
                     (unless (member name required) (list :optional t))
                     (when (gethash "items" prop)
                       (list :items (a2ui-gptel--plist (gethash "items" prop)))))
             args))
     (gethash "properties" schema))
    (nreverse args)))

(defun a2ui-gptel-tools ()
  "Return the A2UI tools as gptel tools, registering them with gptel."
  (require 'gptel)
  (mapcar
   (lambda (spec)
     (let* ((name (plist-get spec :name))
            (args (a2ui-gptel--args (plist-get spec :parameters)))
            (names (mapcar (lambda (a) (plist-get a :name)) args))
            (texts (seq-filter (lambda (n) (a2ui-gptel--free-object-p
                                            (gethash n (gethash "properties" (plist-get spec :parameters)))))
                               names)))
       (gptel-make-tool
        :name name
        :description (plist-get spec :description)
        :category "a2ui"
        :async t
        :args args
        :function (lambda (callback &rest values)
                    (let ((obj (a2ui-obj)))
                      (cl-mapc (lambda (n v)
                                 (when (and (stringp v) (member n texts))
                                   (setq v (condition-case nil (a2ui-json-parse v) (error v))))
                                 (when v (puthash n (a2ui-tools-from-lisp v) obj)))
                               names values)
                      (when (equal name "a2ui_await_action")
                        (a2ui-gptel--show-pending-apart))
                      (a2ui-tools-call (a2ui-gptel-host) name obj callback))))))
   (a2ui-tools-specs nil)))

;;;###autoload
(defun a2ui-gptel-enable ()
  "Let gptel models draw A2UI surfaces: add the A2UI tools to `gptel-tools'."
  (interactive)
  (let ((tools (a2ui-gptel-tools)))
    (setq-default gptel-tools
                  (append (seq-remove (lambda (tool)
                                        (member (gptel-tool-name tool)
                                                '("render_a2ui" "update_a2ui" "a2ui_catalog" "a2ui_await_action")))
                                      (default-value 'gptel-tools))
                          tools))
    (message "a2ui: %d tools added to gptel-tools" (length tools))))

(provide 'a2ui-gptel)
;;; a2ui-gptel.el ends here
