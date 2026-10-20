;;; a2ui-core.el --- A2UI protocol core: surfaces, data models, functions -*- lexical-binding: t; -*-

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

;; The A2UI protocol (v0.9) as pure data.  A session holds surfaces;
;; `a2ui-apply-message' folds server-to-client messages into them and
;; reports which surfaces changed.  Nothing here touches buffers or the
;; network: a renderer supplies `on-change-fn' and a transport supplies
;; `send-action-fn'.
;;
;; JSON is represented the way `json-parse-string' produces it with
;; hash tables for objects, vectors for arrays, nil for null and
;; `:false' for false.  Use `a2ui-true-p' to test truthiness and
;; `a2ui-json-encode' to serialize, which turns nil back into null.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'iso8601)

(defgroup a2ui nil
  "Render A2UI agent surfaces in Emacs."
  :group 'tools
  :prefix "a2ui-")

(defcustom a2ui-confirm-open-url t
  "When non-nil, ask before `openUrl' opens a URL in a browser."
  :type 'boolean)

(defcustom a2ui-time-zone nil
  "Time zone used by `formatDate'.
nil means local time, t means UTC; any ZONE accepted by
`decode-time' works."
  :type '(choice (const :tag "Local" nil) (const :tag "UTC" t) sexp))

(define-error 'a2ui-error "A2UI error")

(defconst a2ui--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory a2ui was loaded from; catalogs live beneath it.")

(defconst a2ui-basic-catalog-id
  "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"
  "Catalog id of the A2UI v0.9 basic catalog.")

(defvar a2ui-message-functions nil
  "Abnormal hook run for every protocol message in or out.
Each function is called with DIRECTION (`in' or `out'), the SESSION,
the MESSAGE and its METADATA (nil for incoming messages).")

;;;; JSON

(defun a2ui-json-parse (string)
  "Parse STRING as JSON into hash tables, vectors, nil and `:false'."
  (json-parse-string string :object-type 'hash-table :array-type 'array
                     :null-object nil :false-object :false))

(defun a2ui--jsonify (value)
  "Return VALUE with every nil replaced by `:null', ready to serialize."
  (cond ((null value) :null)
        ((hash-table-p value)
         (let ((copy (make-hash-table :test 'equal :size (hash-table-count value))))
           (maphash (lambda (k v) (puthash k (a2ui--jsonify v) copy)) value)
           copy))
        ((vectorp value) (vconcat (mapcar #'a2ui--jsonify value)))
        (t value)))

(defun a2ui-json-encode (value)
  "Serialize VALUE, an A2UI JSON value, to a JSON string."
  (json-serialize (a2ui--jsonify value)))

(defun a2ui-obj (&rest pairs)
  "Return a JSON object built from alternating keys and values in PAIRS."
  (let ((obj (make-hash-table :test 'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) obj))
    obj))

(defun a2ui-true-p (value)
  "Return non-nil when the JSON VALUE is truthy."
  (and value (not (eq value :false))))

(defun a2ui-bool (value)
  "Return the JSON boolean for the Lisp truth of VALUE."
  (if value t :false))

(defun a2ui-stringify (value)
  "Convert the JSON VALUE to a string the way A2UI interpolation does."
  (cond ((or (null value) (eq value :null)) "")
        ((eq value t) "true")
        ((eq value :false) "false")
        ((stringp value) value)
        ((integerp value) (number-to-string value))
        ((floatp value)
         (if (and (not (isnan value)) (< (abs value) 1e15)
                  (= value (ftruncate value)))
             (number-to-string (truncate value))
           (number-to-string value)))
        (t (a2ui-json-encode value))))

;;;; Catalogs

(cl-defstruct (a2ui-catalog (:constructor a2ui--catalog-make) (:copier nil))
  "A component and function catalog, shared by every session using it."
  name id aliases schema-file
  parent                                ; catalog symbol it extends
  (specs 'unloaded)                     ; hash: type -> spec, or nil
  digest-cache                          ; cached `a2ui-catalog-digest'
  (functions (make-hash-table :test 'equal)))

(defvar a2ui--catalogs (make-hash-table :test 'eq)
  "Registered catalogs, keyed by symbol.")

(cl-defun a2ui-register-catalog (name &key id aliases schema parent)
  "Register catalog NAME, a symbol, with catalog ID and SCHEMA file.
ALIASES are other ids agents use for the same catalog.  SCHEMA is a
JSON Schema catalog used to validate components; without it any
component type is accepted.  PARENT names a catalog this one extends:
its functions, and renderers, apply here too.  Re-registering keeps
functions."
  (let ((catalog (gethash name a2ui--catalogs)))
    (if catalog
        (setf (a2ui-catalog-id catalog) id
              (a2ui-catalog-aliases catalog) aliases
              (a2ui-catalog-schema-file catalog) schema
              (a2ui-catalog-parent catalog) parent
              (a2ui-catalog-specs catalog) 'unloaded
              (a2ui-catalog-digest-cache catalog) nil)
      (setq catalog (a2ui--catalog-make :name name :id id :aliases aliases
                                        :schema-file schema :parent parent))
      (puthash name catalog a2ui--catalogs))
    catalog))

(defun a2ui-catalog-ancestors (catalog)
  "Return CATALOG followed by the catalogs it extends, nearest first."
  (let (out)
    (while catalog
      (push catalog out)
      (setq catalog (and (a2ui-catalog-parent catalog)
                         (a2ui-catalog (a2ui-catalog-parent catalog)))))
    (nreverse out)))

(defun a2ui-catalog-function (catalog name)
  "Return function NAME of CATALOG or of a catalog it extends."
  (seq-some (lambda (c) (gethash name (a2ui-catalog-functions c)))
            (a2ui-catalog-ancestors catalog)))

(defun a2ui-catalog (name)
  "Return the registered catalog NAME, or signal an error."
  (or (gethash name a2ui--catalogs)
      (signal 'a2ui-error (list (format "Unknown catalog %s" name)))))

(defun a2ui--ref-shape (schema)
  "Return how SCHEMA references components, or nil if it does not.
The result is `id' for a ComponentId, `children' for a ChildList,
`action' for an Action, `dynamic' for a Dynamic* value, or
\(items . ALIST) for an array of objects
whose properties reference components, ALIST mapping property names
to shapes."
  (when (hash-table-p schema)
    (let ((ref (gethash "$ref" schema)))
      (cond ((and (stringp ref) (string-suffix-p "/ComponentId" ref)) 'id)
            ((and (stringp ref) (string-suffix-p "/ChildList" ref)) 'children)
            ((and (stringp ref) (string-suffix-p "/Action" ref)) 'action)
            ((and (stringp ref) (string-match-p "/Dynamic[A-Za-z]*\\'" ref)) 'dynamic)
            ((equal (gethash "type" schema) "array")
             (when-let* ((items (gethash "items" schema))
                         (props (and (hash-table-p items)
                                     (gethash "properties" items)))
                         (alist (a2ui--property-shapes props)))
               (cons 'items alist)))))))

(defun a2ui--property-shapes (properties)
  "Return an alist of property name to ref shape for PROPERTIES."
  (let (alist)
    (maphash (lambda (k v)
               (when-let* ((shape (a2ui--ref-shape v)))
                 (push (cons k shape) alist)))
             properties)
    (nreverse alist)))

(defun a2ui--component-spec (schema)
  "Summarize a catalog component SCHEMA as a plist.
The plist has :required, a list of property names, and :refs, an
alist of property name to ref shape."
  (let (required refs)
    (dolist (part (cons schema (append (gethash "allOf" schema) nil)))
      (when (hash-table-p part)
        (setq required (append required (append (gethash "required" part) nil)))
        (when-let* ((props (gethash "properties" part)))
          (setq refs (append refs (a2ui--property-shapes props))))))
    (list :required (delete "component" (delete-dups required))
          :refs refs)))

(defun a2ui-catalog-component-specs (catalog)
  "Return CATALOG's component specs, loading its schema on first use.
The result is a hash table from component type to spec, or nil when
the catalog has no schema."
  (when (eq (a2ui-catalog-specs catalog) 'unloaded)
    (setf (a2ui-catalog-specs catalog)
          (when-let* ((schema (a2ui-catalog-schema catalog)))
            (let ((specs (make-hash-table :test 'equal)))
              (maphash (lambda (type s) (puthash type (a2ui--component-spec s) specs))
                       (gethash "components" schema))
              specs))))
  (a2ui-catalog-specs catalog))

;;;;; Digest

(defun a2ui--digest-type (schema)
  "Return a compact type notation for the JSON SCHEMA of a property."
  (let ((ref (and (hash-table-p schema) (gethash "$ref" schema))))
    (cond
     ((not (hash-table-p schema)) "any")
     ((stringp ref)
      (pcase (car (last (split-string ref "/")))
        ("DynamicString" "str") ("DynamicNumber" "num") ("DynamicBoolean" "bool")
        ("DynamicStringList" "strs") ("DynamicValue" "any") ("DataBinding" "path")
        ("ComponentId" "id") ("ChildList" "children") ("Action" "action")
        (other other)))
     ((gethash "enum" schema) (mapconcat #'a2ui-stringify (gethash "enum" schema) "|"))
     ((gethash "oneOf" schema)
      (mapconcat #'a2ui--digest-type (gethash "oneOf" schema) "|"))
     ((equal (gethash "type" schema) "array")
      (format "[%s]" (a2ui--digest-type (gethash "items" schema))))
     ((gethash "properties" schema)
      (format "{%s}" (a2ui--digest-props schema)))
     (t (pcase (gethash "type" schema)
          ("string" "string") ("number" "number") ("integer" "int")
          ("boolean" "boolean") ("object" "object") (_ "any"))))))

(defun a2ui--digest-props (schema &optional skip)
  "Return SCHEMA's properties as \"name:type\" pairs, optional ones marked ?.
Properties named in SKIP are left out."
  (let (required props)
    (dolist (part (cons schema (append (gethash "allOf" schema) nil)))
      (when (hash-table-p part)
        (setq required (append required (append (gethash "required" part) nil)))
        (when-let* ((p (gethash "properties" part)))
          (maphash (lambda (k v) (unless (member k skip) (push (cons k v) props))) p))))
    (mapconcat (pcase-lambda (`(,k . ,v))
                 (format "%s%s:%s" k (if (member k required) "" "?") (a2ui--digest-type v)))
               (nreverse props) " ")))

(defconst a2ui--digest-preamble
  "Types: str/num/bool/strs/any take a literal, {\"path\":\"/json/pointer\"} or a function call {\"call\",\"args\"}; children is [ids] or {\"path\",\"componentId\"} to repeat a template per list item (paths inside it are relative to the item); action is {\"event\":{\"name\",\"context\":{key: value}}}.  Inputs and Button take checks:[{\"condition\":<bool call>,\"message\"}]; a failing check disables a Button."
  "How to read a catalog digest, sent once before its components.")

(defun a2ui--digest-functions (schema)
  "Return the functions of catalog SCHEMA as name(args) words."
  (let (fns)
    (maphash (lambda (name s)
               (let* ((props (and (hash-table-p s) (gethash "properties" s)))
                      (args (and (hash-table-p props) (gethash "args" props))))
                 (push (format "%s(%s)" name (if (hash-table-p args) (a2ui--digest-props args) ""))
                       fns)))
             (or (gethash "functions" schema) (make-hash-table)))
    (string-join (nreverse fns) " ")))

(defun a2ui-catalog-digest (catalog)
  "Return a compact text description of CATALOG for a model's context.
One line per component and a line of functions, a tenth or so of the
size of the JSON Schema.  A component schema's `x-a2ui-digest' string,
when present, replaces its generated line."
  (or (a2ui-catalog-digest-cache catalog)
      (setf (a2ui-catalog-digest-cache catalog)
            (when-let* ((schema (a2ui-catalog-schema catalog)))
              (let (lines)
                (maphash (lambda (name s)
                           (push (or (gethash "x-a2ui-digest" s)
                                     (format "%s: %s" name
                                             (a2ui--digest-props
                                              s '("component" "id" "accessibility" "weight"))))
                                 lines))
                         (gethash "components" schema))
                (concat (format "A2UI v0.9 catalog %s\n" (a2ui-catalog-id catalog))
                        (when-let* ((about (gethash "description" schema)))
                          (concat about "\n"))
                        a2ui--digest-preamble "\n"
                        (string-join (nreverse lines) "\n") "\n"
                        "Functions: " (a2ui--digest-functions schema)))))))

;;;; Functions

(defun a2ui--register-function (catalog name fn)
  "Register FN as function NAME in CATALOG, a catalog symbol."
  (puthash name fn (a2ui-catalog-functions (a2ui-catalog catalog))))

(defmacro a2ui-define-function (catalog name arglist &rest body)
  "Define client-side function NAME in CATALOG.
NAME is a symbol or string matching the `call' name.  ARGLIST names
the arguments, which are bound to their resolved values; an element
\(VAR KEY) binds VAR to argument KEY instead.  ARGLIST may end
with `&context VAR' to bind VAR to the evaluation context, a cons of
surface and scope.  BODY returns the function's JSON result."
  (declare (indent 3) (debug (symbolp sexp sexp body)))
  (let* ((pos (cl-position '&context arglist))
         (params (if pos (cl-subseq arglist 0 pos) arglist))
         (ctx (if pos (nth (1+ pos) arglist) (make-symbol "ctx")))
         (args (make-symbol "args")))
    `(a2ui--register-function
      ',catalog ,(if (symbolp name) (symbol-name name) name)
      (lambda (,args ,ctx)
        (ignore ,args ,ctx)
        (let ,(mapcar (lambda (p)
                        (if (consp p)
                            `(,(car p) (gethash ,(cadr p) ,args))
                          `(,p (gethash ,(symbol-name p) ,args))))
                      params)
          ,@body)))))

;;;; Sessions and surfaces

(cl-defstruct (a2ui-session (:constructor a2ui--session-make) (:copier nil))
  "A set of surfaces fed by one transport."
  name
  directory                                 ; where relative file paths start
  (surfaces (make-hash-table :test 'equal))
  (catalogs (make-hash-table :test 'equal)) ; catalog id -> a2ui-catalog
  send-action-fn                            ; (lambda (message metadata))
  on-change-fn)                             ; (lambda (surface-id))

(cl-defstruct (a2ui-surface (:constructor a2ui--surface-make) (:copier nil))
  "One A2UI surface: a component map plus its data model."
  id session catalog theme send-data-model
  (components (make-hash-table :test 'equal))
  (data (make-hash-table :test 'equal))
  errors)                               ; errors already reported

(defvar a2ui-default-catalogs '(basic)
  "Catalog symbols a session supports unless told otherwise.
Loading a catalog's renderer adds it here, e.g. `a2ui-emacs'.")

(cl-defun a2ui-session-create (&key name send-action-fn on-change-fn
                                    (catalogs a2ui-default-catalogs)
                                    directory)
  "Create a session.
NAME identifies the agent to the user.  SEND-ACTION-FN is called with
each outbound message (an action or error envelope) and its metadata.
ON-CHANGE-FN is called with the id of each surface that changed.
CATALOGS lists the catalog symbols the session supports.  DIRECTORY
is where relative file paths in surfaces start, by default the
current `default-directory'."
  (let ((session (a2ui--session-make :name name
                                     :directory (or directory default-directory)
                                     :send-action-fn send-action-fn
                                     :on-change-fn on-change-fn)))
    (dolist (c catalogs)
      (let ((catalog (a2ui-catalog c)))
        (dolist (id (cons (a2ui-catalog-id catalog) (a2ui-catalog-aliases catalog)))
          (puthash id catalog (a2ui-session-catalogs session)))))
    session))

(defun a2ui-session-catalog-list (session)
  "Return the distinct catalogs SESSION supports."
  (delete-dups (hash-table-values (a2ui-session-catalogs session))))

(defun a2ui-session-top-catalogs (session)
  "Return SESSION's catalogs that no other of its catalogs extends.
These are the ones worth describing to an agent: the rest are
contained in them."
  (let ((all (a2ui-session-catalog-list session)))
    (seq-remove (lambda (c)
                  (seq-some (lambda (other)
                              (and (not (eq other c))
                                   (memq c (a2ui-catalog-ancestors other))))
                            all))
                all)))

(defun a2ui-session-catalog-ids (session)
  "Return SESSION's supported catalog ids, for `supportedCatalogIds'.
Aliases are left out."
  (mapcar #'a2ui-catalog-id (a2ui-session-catalog-list session)))

(defun a2ui-catalog-schema (catalog)
  "Return CATALOG's JSON Schema as parsed JSON, or nil without one."
  (when-let* ((file (a2ui-catalog-schema-file catalog)))
    (with-temp-buffer
      (insert-file-contents file)
      (a2ui-json-parse (buffer-string)))))

(defun a2ui-session-surface (session surface-id)
  "Return SESSION's surface SURFACE-ID, or nil."
  (gethash surface-id (a2ui-session-surfaces session)))

(defun a2ui-session-surface-ids (session)
  "Return the ids of SESSION's live surfaces."
  (hash-table-keys (a2ui-session-surfaces session)))

(defun a2ui-surface-component (surface id)
  "Return SURFACE's component ID, or nil."
  (gethash id (a2ui-surface-components surface)))

;;;; JSON Pointer

(defun a2ui-pointer-resolve (path &optional scope)
  "Return PATH as an absolute pointer, relative paths joined to SCOPE."
  (cond ((string-prefix-p "/" path) path)
        ((string-empty-p path) (or scope "/"))
        (t (concat (string-remove-suffix "/" (or scope "")) "/" path))))

(defun a2ui-pointer-segments (path &optional scope)
  "Return the unescaped segments of PATH resolved against SCOPE.
Empty segments are dropped, so both \"\" and \"/\" name the root."
  (mapcar (lambda (seg)
            (string-replace "~0" "~" (string-replace "~1" "/" seg)))
          (split-string (a2ui-pointer-resolve path scope) "/" t)))

(defun a2ui--index (segment)
  "Return SEGMENT as an array index, or nil if it is not one."
  (and (string-match-p "\\`[0-9]+\\'" segment) (string-to-number segment)))

(defun a2ui-pointer-get (data path &optional scope)
  "Return the value at PATH in DATA, resolving relative PATH in SCOPE.
Missing values are nil."
  (let ((node data))
    (dolist (seg (a2ui-pointer-segments path scope) node)
      (setq node
            (cond ((hash-table-p node) (gethash seg node))
                  ((vectorp node)
                   (let ((i (a2ui--index seg)))
                     (and i (< i (length node)) (aref node i)))))))))

(defun a2ui--pointer-put (node segments value remove)
  "Return NODE with VALUE stored at SEGMENTS, or removed if REMOVE.
Intermediate objects are created as needed; arrays grow to fit."
  (if (null segments)
      value
    (let ((seg (car segments))
          (last (null (cdr segments))))
      (if (vectorp node)
          (let ((i (if (equal seg "-") (length node) (a2ui--index seg))))
            (unless i
              (signal 'a2ui-error
                      (list (format "Non-numeric index %S into an array" seg))))
            (cond ((< i (length node))
                   (aset node i (if (and remove last)
                                    nil
                                  (a2ui--pointer-put (aref node i) (cdr segments)
                                                     value remove)))
                   node)
                  (remove node)
                  (t (let ((grown (vconcat node (make-vector (- (1+ i) (length node)) nil))))
                       (aset grown i (a2ui--pointer-put nil (cdr segments) value nil))
                       grown))))
        (unless (hash-table-p node)
          (setq node (make-hash-table :test 'equal)))
        (cond ((and remove last) (remhash seg node))
              ((and remove (not (gethash seg node))))
              (t (puthash seg (a2ui--pointer-put (gethash seg node) (cdr segments)
                                                 value remove)
                          node)))
        node))))

(defun a2ui-pointer-set (data path value &optional scope)
  "Store VALUE at PATH in DATA and return the new DATA.
DATA is modified in place where possible; callers must still use the
return value, which differs when the root is replaced or an array
grows."
  (a2ui--pointer-put data (a2ui-pointer-segments path scope) value nil))

(defun a2ui-pointer-remove (data path &optional scope)
  "Remove the value at PATH in DATA and return the new DATA.
An object key is deleted; an array slot is set to nil, keeping length."
  (let ((segments (a2ui-pointer-segments path scope)))
    (if segments
        (a2ui--pointer-put data segments nil t)
      (make-hash-table :test 'equal))))

;;;; Data model access

(defun a2ui-get (surface path &optional scope)
  "Return the value at PATH in SURFACE's data model, relative to SCOPE."
  (a2ui-pointer-get (a2ui-surface-data surface) path scope))

(defun a2ui-set (surface path value &optional scope)
  "Set PATH in SURFACE's data model to VALUE, as a local edit.
Nothing is sent to the agent; the session's change hook fires so
bound components re-render."
  (setf (a2ui-surface-data surface)
        (a2ui-pointer-set (a2ui-surface-data surface) path value scope))
  (a2ui--notify (a2ui-surface-session surface) (list (a2ui-surface-id surface))))

(defun a2ui--notify (session surface-ids)
  "Tell SESSION's renderer that SURFACE-IDS changed."
  (when-let* ((fn (a2ui-session-on-change-fn session)))
    (dolist (id surface-ids)
      (funcall fn id))))

;;;; Dynamic values

(defun a2ui-binding-p (value)
  "Return non-nil when VALUE is a data binding object {path}."
  (and (hash-table-p value)
       (= (hash-table-count value) 1)
       (stringp (gethash "path" value))))

(defun a2ui-function-call-p (value)
  "Return non-nil when VALUE is a FunctionCall object."
  (and (hash-table-p value) (stringp (gethash "call" value))))

(defun a2ui-resolve (value surface &optional scope)
  "Resolve the dynamic VALUE against SURFACE in SCOPE.
Literals are returned as they are, bindings are looked up and
function calls evaluated, recursively through arrays."
  (cond ((a2ui-binding-p value) (a2ui-get surface (gethash "path" value) scope))
        ((a2ui-function-call-p value) (a2ui-call value surface scope))
        ((vectorp value) (vconcat (mapcar (lambda (v) (a2ui-resolve v surface scope))
                                          value)))
        (t value)))

(defun a2ui-resolve-prop (component prop surface &optional scope)
  "Resolve property PROP of COMPONENT against SURFACE in SCOPE."
  (a2ui-resolve (gethash prop component) surface scope))

(defun a2ui-binding-path (component prop &optional scope)
  "Return the absolute path PROP of COMPONENT is bound to, or nil."
  (let ((value (gethash prop component)))
    (when (a2ui-binding-p value)
      (a2ui-pointer-resolve (gethash "path" value) scope))))

(defun a2ui-call (call surface &optional scope)
  "Evaluate the FunctionCall object CALL against SURFACE in SCOPE.
Errors are reported to the agent and yield nil."
  (let ((args (make-hash-table :test 'equal)))
    (when-let* ((raw (gethash "args" call)))
      (when (hash-table-p raw)
        (maphash (lambda (k v) (puthash k (a2ui-resolve v surface scope) args)) raw)))
    (a2ui--invoke surface (gethash "call" call) args scope)))

(defun a2ui--invoke (surface name args scope)
  "Run function NAME of SURFACE's catalog with resolved ARGS in SCOPE."
  (let ((fn (a2ui-catalog-function (a2ui-surface-catalog surface) name)))
    (if (not fn)
        (progn (a2ui--report-error surface "UNKNOWN_FUNCTION"
                                   (format "Function %s is not in this catalog" name))
               nil)
      (condition-case err
          (funcall fn args (cons surface scope))
        (error
         (a2ui--report-error surface "FUNCTION_FAILED"
                             (format "%s: %s" name (error-message-string err)))
         nil)))))

(defun a2ui-check-failures (component surface &optional scope)
  "Return the messages of COMPONENT's checks that fail on SURFACE in SCOPE."
  (let (messages)
    (seq-doseq (rule (or (gethash "checks" component) []))
      (when (hash-table-p rule)
        ;; v0.9 wraps the call in `condition'; some agents (and the
        ;; spec's own prose example) put the call on the rule itself.
        (let ((condition (if (eq (gethash "condition" rule 'absent) 'absent)
                             (and (gethash "call" rule) rule)
                           (gethash "condition" rule))))
          (unless (or (null condition)
                      (a2ui-true-p (a2ui-resolve condition surface scope)))
            (push (or (gethash "message" rule) "Invalid value.") messages)))))
    (nreverse messages)))

;;;; Outbound messages

(defun a2ui--metadata (surface)
  "Return transport metadata for messages about SURFACE, or nil."
  (when (and surface (a2ui-surface-send-data-model surface))
    (a2ui-obj "a2uiClientDataModel"
              (a2ui-obj "version" "v0.9"
                        "surfaces" (a2ui-obj (a2ui-surface-id surface)
                                             (a2ui-surface-data surface))))))

(defun a2ui--send (session message &optional surface)
  "Send MESSAGE through SESSION's transport, with SURFACE's metadata."
  (let ((metadata (a2ui--metadata surface)))
    (run-hook-with-args 'a2ui-message-functions 'out session message metadata)
    (when-let* ((fn (a2ui-session-send-action-fn session)))
      (funcall fn message metadata))
    message))

(defun a2ui--send-error (session surface-id code message &optional path)
  "Send SESSION an error envelope with CODE and MESSAGE about SURFACE-ID.
PATH, when given, points at the offending field."
  (let ((err (a2ui-obj "code" code "surfaceId" (or surface-id "") "message" message)))
    (when path (puthash "path" path err))
    (a2ui--send session (a2ui-obj "version" "v0.9" "error" err)
                (and surface-id (a2ui-session-surface session surface-id)))))

(defun a2ui--report-error (surface code message &optional path)
  "Report error CODE with MESSAGE about SURFACE to the agent.
PATH points at the offending field.  Each distinct error is reported
once, however often the surface re-renders."
  (let ((key (list code path message)))
    (unless (member key (a2ui-surface-errors surface))
      (push key (a2ui-surface-errors surface))
      (a2ui--send-error (a2ui-surface-session surface) (a2ui-surface-id surface)
                        code message path))))

(defun a2ui-report-validation-error (surface path message)
  "Report a VALIDATION_FAILED error at PATH about SURFACE."
  (a2ui--report-error surface "VALIDATION_FAILED" message path))

(defun a2ui--timestamp ()
  "Return the current time as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))

(defun a2ui-dispatch-action (surface component &optional scope)
  "Run COMPONENT's action on SURFACE, resolving bindings in SCOPE.
An `event' action is sent to the agent and the message returned; a
`functionCall' action runs locally."
  (let ((action (gethash "action" component)))
    (cond
     ((not (hash-table-p action)) nil)
     ((hash-table-p (gethash "event" action))
      (let* ((event (gethash "event" action))
             (context (make-hash-table :test 'equal)))
        (when (hash-table-p (gethash "context" event))
          (maphash (lambda (k v) (puthash k (a2ui-resolve v surface scope) context))
                   (gethash "context" event)))
        (a2ui--send (a2ui-surface-session surface)
                    (a2ui-obj "version" "v0.9"
                              "action" (a2ui-obj "name" (gethash "name" event)
                                                 "surfaceId" (a2ui-surface-id surface)
                                                 "sourceComponentId" (gethash "id" component)
                                                 "timestamp" (a2ui--timestamp)
                                                 "context" context))
                    surface)))
     ((a2ui-function-call-p (gethash "functionCall" action))
      (a2ui-call (gethash "functionCall" action) surface scope)
      nil))))

;;;; Validation

(defconst a2ui--action-shape
  "{\"event\": {\"name\": \"...\", \"context\": {...}}} or {\"functionCall\": {\"call\": \"...\", \"args\": {...}}}"
  "How an Action is written, for validation messages.")

(defun a2ui--validate-dynamic (value path)
  "Check the Dynamic* VALUE at PATH; return a list of (PATH . MESSAGE).
An object must be a binding {path} or a function call {call, args}."
  (when (and (hash-table-p value)
             (not (stringp (gethash "path" value)))
             (not (stringp (gethash "call" value))))
    (list (cons path "Expected a literal, {\"path\": \"/x\"} or {\"call\": \"...\", \"args\": {...}}"))))

(defun a2ui--validate-action (value path)
  "Check the Action VALUE at PATH; return a list of (PATH . MESSAGE)."
  (let ((event (and (hash-table-p value) (gethash "event" value)))
        (call (and (hash-table-p value) (gethash "functionCall" value))))
    (cond
     ((hash-table-p event)
      (append (unless (stringp (gethash "name" event))
                (list (cons (concat path "/event/name") "An event action needs a name string")))
              (let ((context (gethash "context" event 'absent)))
                (cond ((memq context '(absent nil)) nil)
                      ((not (hash-table-p context))
                       (list (cons (concat path "/event/context") "An event context must be an object")))
                      (t (let (errors)
                           (maphash (lambda (k v)
                                      (setq errors (append errors (a2ui--validate-dynamic
                                                                   v (format "%s/event/context/%s" path k)))))
                                    context)
                           errors))))))
     ((hash-table-p call)
      (unless (stringp (gethash "call" call))
        (list (cons (concat path "/functionCall/call") "A functionCall needs a call string"))))
     (t (list (cons path (concat "Expected an action like " a2ui--action-shape)))))))

(defun a2ui--validate-ref (shape value path)
  "Check VALUE against ref SHAPE; return a list of (PATH . MESSAGE)."
  (pcase shape
    ('action (a2ui--validate-action value path))
    ('dynamic (a2ui--validate-dynamic value path))
    ('id (unless (stringp value)
           (list (cons path "Expected a component id string"))))
    ('children
     (cond ((vectorp value)
            (cl-loop for v across value for i from 0
                     unless (stringp v)
                     collect (cons (format "%s/%d" path i) "Expected a component id string")))
           ((hash-table-p value)
            (append (unless (stringp (gethash "componentId" value))
                      (list (cons (concat path "/componentId") "Expected a component id string")))
                    (unless (stringp (gethash "path" value))
                      (list (cons (concat path "/path") "Expected a data path string")))))
           (t (list (cons path "Expected an array of component ids or a template")))))
    (`(items . ,props)
     (when (vectorp value)
       (cl-loop for item across value for i from 0
                when (hash-table-p item)
                append (cl-loop for (prop . sub) in props
                                for v = (gethash prop item)
                                when v
                                append (a2ui--validate-ref sub v (format "%s/%d/%s" path i prop))))))))

(defun a2ui--validate-component (catalog component path)
  "Check COMPONENT at PATH against CATALOG; return (PATH . MESSAGE) errors."
  (if (not (hash-table-p component))
      (list (cons path "Component must be an object"))
    (let ((id (gethash "id" component))
          (type (gethash "component" component))
          (specs (a2ui-catalog-component-specs catalog)))
      (cond
       ((not (stringp id)) (list (cons (concat path "/id") "Component id must be a string")))
       ((not (stringp type)) (list (cons (concat path "/component") "Component type must be a string")))
       ((null specs) nil)
       ((not (gethash type specs))
        (list (cons (concat path "/component")
                    (format "Unknown component type %s in catalog %s" type (a2ui-catalog-id catalog)))))
       (t
        (let ((spec (gethash type specs)))
          (append
           (cl-loop for prop in (plist-get spec :required)
                    when (eq (gethash prop component 'absent) 'absent)
                    collect (cons (format "%s/%s" path prop)
                                  (format "%s requires property %s" type prop)))
           ;; `gethash' with a sentinel tells a missing prop from null.
           (cl-loop for (prop . shape) in (plist-get spec :refs)
                    for v = (gethash prop component 'absent)
                    unless (eq v 'absent)
                    append (a2ui--validate-ref shape v (format "%s/%s" path prop))))))))))

;;;; Message application

(defvar a2ui-protocol-versions
  '(("v0.9" . a2ui--apply-v0-9)
    ("v0.9.1" . a2ui--apply-v0-9))
  "Alist from protocol version string to message handler.
A handler is called with the session and message and returns the ids
of changed surfaces.  Messages without a version use v0.9.")

(defun a2ui-apply-message (session message)
  "Apply the server-to-client MESSAGE to SESSION.
MESSAGE is a parsed JSON object or a JSON string.  Return the ids of
surfaces that changed, after notifying the session's renderer."
  (when (stringp message)
    (setq message (a2ui-json-parse message)))
  (run-hook-with-args 'a2ui-message-functions 'in session message nil)
  (let* ((version (and (hash-table-p message) (gethash "version" message "v0.9")))
         (handler (cdr (assoc version a2ui-protocol-versions)))
         (changed (cond ((not (hash-table-p message))
                         (a2ui--send-error session nil "INVALID_MESSAGE"
                                           "Message must be a JSON object")
                         nil)
                        ((not handler)
                         (a2ui--send-error session nil "UNSUPPORTED_VERSION"
                                           (format "Protocol version %s is not supported" version))
                         nil)
                        (t (funcall handler session message)))))
    (a2ui--notify session changed)
    changed))

(defun a2ui--apply-v0-9 (session message)
  "Apply v0.9 MESSAGE to SESSION and return the changed surface ids."
  (cl-loop for (key . fn) in '(("createSurface" . a2ui--create-surface)
                               ("updateComponents" . a2ui--update-components)
                               ("updateDataModel" . a2ui--update-data-model)
                               ("deleteSurface" . a2ui--delete-surface))
           for body = (gethash key message)
           when (hash-table-p body)
           return (let ((id (gethash "surfaceId" body)))
                    (if (stringp id)
                        (funcall fn session id body)
                      (a2ui--send-error session nil "VALIDATION_FAILED"
                                        "surfaceId must be a string"
                                        (concat "/" key "/surfaceId"))
                      nil))
           finally (a2ui--send-error session nil "INVALID_MESSAGE"
                                     "Message has no known message type")))

(defun a2ui--create-surface (session id body)
  "Create surface ID in SESSION from createSurface BODY."
  (let* ((catalog-id (gethash "catalogId" body))
         (catalog (gethash catalog-id (a2ui-session-catalogs session))))
    (cond
     ((a2ui-session-surface session id)
      (a2ui--send-error session id "SURFACE_EXISTS"
                        (format "Surface %s already exists; delete it first" id))
      nil)
     ((not catalog)
      (a2ui--send-error session id "UNSUPPORTED_CATALOG"
                        (format "Catalog %s is not supported; use one of %s"
                                catalog-id (string-join (a2ui-session-catalog-ids session) ", ")))
      nil)
     (t
      (puthash id (a2ui--surface-make :id id :session session :catalog catalog
                                      :theme (gethash "theme" body)
                                      :send-data-model (a2ui-true-p (gethash "sendDataModel" body)))
               (a2ui-session-surfaces session))
      (list id)))))

(defun a2ui--require-surface (session id)
  "Return SESSION's surface ID, reporting an error if it is missing."
  (or (a2ui-session-surface session id)
      (progn (a2ui--send-error session id "SURFACE_NOT_FOUND"
                               (format "Surface %s does not exist; send createSurface first" id))
             nil)))

(defun a2ui--update-components (session id body)
  "Upsert the components in updateComponents BODY into SESSION's surface ID."
  (when-let* ((surface (a2ui--require-surface session id)))
    (let ((components (gethash "components" body))
          (table (a2ui-surface-components surface)))
      (if (not (vectorp components))
          (a2ui--send-error session id "VALIDATION_FAILED" "components must be an array" "/components")
        (cl-loop for c across components for i from 0
                 for errors = (a2ui--validate-component (a2ui-surface-catalog surface)
                                                        c (format "/components/%d" i))
                 if errors
                 ;; Sent every time: each message is new, unlike the
                 ;; errors a re-render keeps finding.
                 do (pcase-dolist (`(,path . ,msg) errors)
                      (a2ui--send-error session id "VALIDATION_FAILED" msg path))
                 else do (puthash (gethash "id" c) c table)))
      (list id))))

(defun a2ui--update-data-model (session id body)
  "Apply updateDataModel BODY to SESSION's surface ID."
  (when-let* ((surface (a2ui--require-surface session id)))
    (let ((path (or (gethash "path" body) "/"))
          (value (gethash "value" body 'absent)))
      (condition-case err
          (setf (a2ui-surface-data surface)
                (if (eq value 'absent)
                    (a2ui-pointer-remove (a2ui-surface-data surface) path)
                  (a2ui-pointer-set (a2ui-surface-data surface) path value)))
        (a2ui-error
         (a2ui--send-error session id "VALIDATION_FAILED" (error-message-string err) "/path")))
      (list id))))

(defun a2ui--delete-surface (session id _body)
  "Delete surface ID from SESSION."
  (when (a2ui--require-surface session id)
    (remhash id (a2ui-session-surfaces session))
    (list id)))

(defun a2ui-delete-surface (session surface-id)
  "Delete SESSION's SURFACE-ID locally, as if the agent had sent deleteSurface."
  (when (a2ui-session-surface session surface-id)
    (remhash surface-id (a2ui-session-surfaces session))
    (a2ui--notify session (list surface-id))))

(defun a2ui-read-jsonl (file)
  "Return the messages in FILE, one JSON object per non-blank line."
  (with-temp-buffer
    (insert-file-contents file)
    (cl-loop for line in (split-string (buffer-string) "\n" t "[ \t\r]+")
             collect (a2ui-json-parse line))))

;;;; Basic catalog functions

(defun a2ui-number (value)
  "Return VALUE as a number, parsing numeric strings, or nil."
  (cond ((numberp value) value)
        ((and (stringp value)
              (string-match-p "\\`[ \t]*[-+]?\\([0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\([eE][-+]?[0-9]+\\)?[ \t]*\\'"
                              value))
         (string-to-number (string-trim value)))))

(defun a2ui--js-class-escape (char)
  "Translate the escaped CHAR inside a JS character class."
  (pcase char
    (?d "0-9") (?w "[:alnum:]_") (?s "[:space:]")
    (?n "\n") (?t "\t") (?r "\r")
    ((or ?D ?W ?S) (signal 'a2ui-error (list "Negated class escapes inside [] are not supported")))
    (_ (string char))))

(defun a2ui--js-escape (char)
  "Translate the escaped CHAR outside a JS character class."
  (pcase char
    (?d "[0-9]") (?D "[^0-9]")
    (?w "[[:alnum:]_]") (?W "[^[:alnum:]_]")
    (?s "[[:space:]]") (?S "[^[:space:]]")
    (?b "\\b") (?B "\\B")
    (?n "\n") (?t "\t") (?r "\r") (?f "\f") (?v "\v")
    ((pred (lambda (c) (<= ?1 c ?9))) (string ?\\ char))
    (_ (regexp-quote (string char)))))

(defun a2ui-js-regex-to-emacs (pattern)
  "Translate the JavaScript regular expression PATTERN to Emacs syntax.
Covers the common subset: classes, shorthand escapes, groups,
alternation, quantifiers and anchors.  Lookaround and named groups
signal `a2ui-error'."
  (let ((i 0) (n (length pattern)) out)
    (while (< i n)
      (let ((c (aref pattern i)))
        (cond
         ((eq c ?\\)
          (cl-incf i)
          (when (>= i n) (signal 'a2ui-error (list "Trailing backslash in pattern")))
          (pcase (aref pattern i)
            (?u (push (string (string-to-number (substring pattern (1+ i) (+ i 5)) 16)) out)
                (cl-incf i 4))
            (?x (push (string (string-to-number (substring pattern (1+ i) (+ i 3)) 16)) out)
                (cl-incf i 2))
            (e (push (a2ui--js-escape e) out))))
         ((eq c ?\[)
          ;; Collect the class, then emit it in Emacs order: a literal
          ;; ] first, a literal - last.
          (let ((negate (and (< (1+ i) n) (eq (aref pattern (1+ i)) ?^)))
                members rbracket dash)
            (cl-incf i (if negate 2 1))
            (while (and (< i n) (not (eq (aref pattern i) ?\])))
              (if (eq (aref pattern i) ?\\)
                  (let ((e (aref pattern (cl-incf i))))
                    (pcase e
                      (?\] (setq rbracket t))
                      (?- (setq dash t))
                      (_ (push (a2ui--js-class-escape e) members))))
                (push (string (aref pattern i)) members))
              (cl-incf i))
            (push (concat "[" (and negate "^") (and rbracket "]")
                          (apply #'concat (nreverse members)) (and dash "-") "]")
                  out)))
         ((eq c ?\()
          (cond ((and (< (+ i 2) n) (string= (substring pattern i (+ i 3)) "(?:"))
                 (push "\\(?:" out)
                 (cl-incf i 2))
                ((and (< (1+ i) n) (eq (aref pattern (1+ i)) ??))
                 (signal 'a2ui-error (list "Lookaround and named groups are not supported")))
                (t (push "\\(" out))))
         ((eq c ?\)) (push "\\)" out))
         ((eq c ?|) (push "\\|" out))
         ((eq c ?{) (push "\\{" out))
         ((eq c ?}) (push "\\}" out))
         ((eq c ?^) (push "\\`" out))
         ((eq c ?$) (push "\\'" out))
         (t (push (string c) out))))
      (cl-incf i))
    (apply #'concat (nreverse out))))

(defun a2ui--group-digits (digits)
  "Insert thousands separators into the string of DIGITS."
  (let ((out "") (len (length digits)))
    (dotimes (i len)
      (when (and (> i 0) (zerop (% (- len i) 3)))
        (setq out (concat out ",")))
      (setq out (concat out (string (aref digits i)))))
    out))

(defun a2ui--format-number (number decimals grouping)
  "Format NUMBER with DECIMALS fraction digits and optional GROUPING.
Without DECIMALS, up to three fraction digits are shown, as
`Intl.NumberFormat' does by default."
  (let* ((places (if decimals (truncate decimals) 3))
         (scale (expt 10.0 places))
         ;; Round half away from zero like `Intl'; `format' rounds
         ;; half to even.
         (rounded (/ (* (if (< number 0) -1 1)
                        (ffloor (+ (* (abs number) scale) 0.5)))
                     scale))
         (text (format (format "%%.%df" places) rounded))
         (text (if decimals
                   text
                 (string-trim-right (string-trim-right text "0+") "\\.")))
         (negative (string-prefix-p "-" text))
         (text (string-remove-prefix "-" text))
         (dot (string-search "." text))
         (int (substring text 0 dot))
         (frac (if dot (substring text dot) "")))
    (when (and negative (string-match-p "\\`[0.]*\\'" text))
      (setq negative nil))
    (concat (and negative "-")
            (if grouping (a2ui--group-digits int) int)
            frac)))

(defconst a2ui--month-names
  ["January" "February" "March" "April" "May" "June" "July"
   "August" "September" "October" "November" "December"])

(defconst a2ui--day-names
  ["Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"])

(defun a2ui--parse-time (value)
  "Parse VALUE, an ISO 8601 string or epoch milliseconds, to a time."
  (cond ((numberp value) (seconds-to-time (/ value 1000.0)))
        ((stringp value)
         (let ((decoded (iso8601-parse value)))
           ;; A bare date has no time of day.
           (dolist (slot '(0 1 2))
             (unless (nth slot decoded) (setf (nth slot decoded) 0)))
           (encode-time decoded)))
        (t (signal 'a2ui-error (list "Cannot parse date")))))

(defun a2ui--date-field (letter count time)
  "Format TR35 field LETTER repeated COUNT times for decoded TIME."
  (let ((pad (lambda (n) (format (if (>= count 2) "%02d" "%d") n)))
        (hour (decoded-time-hour time)))
    (pcase letter
      ((or ?y ?Y ?u) (let ((year (decoded-time-year time)))
                       (if (= count 2) (format "%02d" (% year 100)) (format "%d" year))))
      ((or ?M ?L) (let ((month (decoded-time-month time)))
                    (pcase count
                      ((or 1 2) (funcall pad month))
                      (3 (substring (aref a2ui--month-names (1- month)) 0 3))
                      (_ (aref a2ui--month-names (1- month))))))
      (?d (funcall pad (decoded-time-day time)))
      (?E (let ((name (aref a2ui--day-names (decoded-time-weekday time))))
            (if (>= count 4) name (substring name 0 3))))
      (?H (funcall pad hour))
      (?h (funcall pad (let ((h (% hour 12))) (if (zerop h) 12 h))))
      (?m (funcall pad (decoded-time-minute time)))
      (?s (funcall pad (truncate (decoded-time-second time))))
      (?a (if (< hour 12) "AM" "PM"))
      (_ (make-string count letter)))))

(defun a2ui-format-date (value pattern)
  "Format VALUE, a date, with the Unicode TR35 PATTERN."
  (let ((time (decode-time (a2ui--parse-time value) a2ui-time-zone))
        (i 0) (n (length pattern)) out)
    (while (< i n)
      (let ((c (aref pattern i)))
        (cond
         ((eq c ?')
          (let ((end (string-search "'" pattern (1+ i))))
            (push (if (eq end (1+ i)) "'" (substring pattern (1+ i) end)) out)
            (setq i (1+ (or end (1- n))))))
         ((or (<= ?a c ?z) (<= ?A c ?Z))
          (let ((j i))
            (while (and (< j n) (eq (aref pattern j) c)) (cl-incf j))
            (push (a2ui--date-field c (- j i) time) out)
            (setq i j)))
         (t (push (string c) out) (cl-incf i)))))
    (apply #'concat (nreverse out))))

;;;;; formatString

(defun a2ui--at-p (string pos prefix)
  "Return non-nil when STRING has PREFIX at POS."
  (eq t (compare-strings prefix nil nil string pos (min (length string) (+ pos (length prefix))))))

(defun a2ui--fs-skip (s pos)
  "Return the position after any whitespace in S at POS."
  (while (and (< pos (length s)) (memq (aref s pos) '(?\s ?\t ?\n)))
    (cl-incf pos))
  pos)

(defun a2ui--fs-expect (s pos char)
  "Return the position after CHAR in S at POS, or signal an error."
  (setq pos (a2ui--fs-skip s pos))
  (unless (and (< pos (length s)) (eq (aref s pos) char))
    (signal 'a2ui-error (list (format "Expected `%c' at %d in formatString" char pos))))
  (1+ pos))

(defun a2ui--fs-token (s pos)
  "Read a bare token from S at POS; return (TOKEN . END)."
  (let ((start (setq pos (a2ui--fs-skip s pos))))
    (while (and (< pos (length s))
                (not (memq (aref s pos) '(?} ?, ?\( ?\) ?: ?\s ?\t ?\n))))
      (cl-incf pos))
    (when (= start pos)
      (signal 'a2ui-error (list (format "Expected an expression at %d in formatString" pos))))
    (cons (substring s start pos) pos)))

(defun a2ui--fs-parse (s pos)
  "Parse one formatString expression in S at POS; return (EXPR . END).
EXPR is (lit VALUE), (path PATH) or (call NAME ((ARG . EXPR) ...))."
  (setq pos (a2ui--fs-skip s pos))
  (cond
   ((>= pos (length s)) (signal 'a2ui-error (list "Unterminated formatString expression")))
   ((a2ui--at-p s pos "${")
    (pcase-let ((`(,expr . ,end) (a2ui--fs-parse s (+ pos 2))))
      (cons expr (a2ui--fs-expect s end ?}))))
   ((memq (aref s pos) '(?' ?\"))
    (let ((delim (aref s pos)) (end (1+ pos)) chars)
      (while (and (< end (length s)) (not (eq (aref s end) delim)))
        (when (eq (aref s end) ?\\) (cl-incf end))
        (push (aref s end) chars)
        (cl-incf end))
      (cons (list 'lit (concat (nreverse chars))) (1+ end))))
   (t
    (pcase-let* ((`(,token . ,end) (a2ui--fs-token s pos))
                 (next (a2ui--fs-skip s end)))
      (cond
       ((and (< next (length s)) (eq (aref s next) ?\())
        (let ((pos (a2ui--fs-skip s (1+ next))) args)
          (unless (eq (aref s pos) ?\))
            (while (progn
                     (pcase-let* ((`(,name . ,end) (a2ui--fs-token s pos))
                                  (`(,expr . ,end) (a2ui--fs-parse s (a2ui--fs-expect s end ?:))))
                       (push (cons name expr) args)
                       (setq pos (a2ui--fs-skip s end)))
                     (when (eq (aref s pos) ?,)
                       (setq pos (1+ pos))))))
          (cons (list 'call token (nreverse args)) (a2ui--fs-expect s pos ?\)))))
       ((member token '("true" "false" "null"))
        (cons (list 'lit (pcase token ("true" t) ("false" :false) (_ nil))) end))
       ((a2ui-number token) (cons (list 'lit (a2ui-number token)) end))
       (t (cons (list 'path token) end)))))))

(defun a2ui--fs-eval (expr surface scope)
  "Evaluate the parsed formatString EXPR against SURFACE in SCOPE."
  (pcase expr
    (`(lit ,value) value)
    (`(path ,path) (a2ui-get surface path scope))
    (`(call ,name ,args)
     (let ((table (make-hash-table :test 'equal)))
       (pcase-dolist (`(,k . ,v) args)
         (puthash k (a2ui--fs-eval v surface scope) table))
       (a2ui--invoke surface name table scope)))))

(defun a2ui-format-string (template surface &optional scope)
  "Interpolate the ${...} expressions in TEMPLATE against SURFACE in SCOPE."
  (let ((i 0) (n (length template)) out)
    (while (< i n)
      (cond
       ((a2ui--at-p template i "\\${") (push "${" out) (cl-incf i 3))
       ((a2ui--at-p template i "${")
        (pcase-let ((`(,expr . ,end) (a2ui--fs-parse template (+ i 2))))
          (push (a2ui-stringify (a2ui--fs-eval expr surface scope)) out)
          (setq i (a2ui--fs-expect template end ?}))))
       (t (push (string (aref template i)) out) (cl-incf i))))
    (apply #'concat (nreverse out))))

;;;;; Definitions

(a2ui-register-catalog 'basic
                       :id a2ui-basic-catalog-id
                       ;; The id the AG-UI A2UI toolkits default to.
                       :aliases '("https://a2ui.org/specification/v0_9/basic_catalog.json")
                       :schema (expand-file-name "catalogs/basic/catalog.json" a2ui--directory))

(a2ui-define-function basic required (value)
  (a2ui-bool (not (or (null value) (equal value "") (equal value [])))))

(a2ui-define-function basic regex (value pattern)
  (a2ui-bool (string-match-p (a2ui-js-regex-to-emacs pattern) (a2ui-stringify value))))

(a2ui-define-function basic length (value min max)
  (let ((len (length (a2ui-stringify value))))
    (a2ui-bool (and (or (null min) (>= len min)) (or (null max) (<= len max))))))

(a2ui-define-function basic numeric (value min max)
  (let ((number (a2ui-number value)))
    (a2ui-bool (and number
                    (or (null min) (>= number min))
                    (or (null max) (<= number max))))))

(a2ui-define-function basic email (value)
  (a2ui-bool (string-match-p "\\`[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+\\'"
                             (a2ui-stringify value))))

(a2ui-define-function basic and ((vals "values"))
  (a2ui-bool (cl-every #'a2ui-true-p vals)))

(a2ui-define-function basic or ((vals "values"))
  (a2ui-bool (cl-some #'a2ui-true-p vals)))

(a2ui-define-function basic not (value)
  (a2ui-bool (not (a2ui-true-p value))))

(a2ui-define-function basic formatString (value &context ctx)
  (a2ui-format-string (a2ui-stringify value) (car ctx) (cdr ctx)))

(a2ui-define-function basic formatNumber (value decimals grouping)
  (when-let* ((number (a2ui-number value)))
    (a2ui--format-number number decimals (not (eq grouping :false)))))

(defconst a2ui--currency-symbols
  '(("USD" . "$") ("EUR" . "€") ("GBP" . "£") ("JPY" . "¥") ("INR" . "₹")
    ("CNY" . "CN¥") ("KRW" . "₩") ("CAD" . "CA$") ("AUD" . "A$"))
  "Currency codes with a symbol, in the style of `Intl' for en-US.")

(a2ui-define-function basic formatCurrency (value currency decimals grouping)
  (when-let* ((number (a2ui-number value)))
    (let* ((code (upcase (or currency "")))
           (symbol (or (cdr (assoc code a2ui--currency-symbols)) (concat code " ")))
           (text (a2ui--format-number (abs number)
                                      (or decimals (if (member code '("JPY" "KRW")) 0 2))
                                      (not (eq grouping :false)))))
      (concat (and (< number 0) "-") symbol text))))

(a2ui-define-function basic formatDate (value format)
  (when value (a2ui-format-date value (a2ui-stringify format))))

(a2ui-define-function basic pluralize (value one other)
  ;; English plural rules, as `Intl.PluralRules' gives for en: only an
  ;; integer 1 is "one"; every other category falls back to `other'.
  (or (and (eql (a2ui-number value) 1) one)
      other))

(defun a2ui-open-url (url)
  "Open URL in a browser, if it is http(s) and the user agrees.
Other schemes signal `a2ui-error'.  See `a2ui-confirm-open-url'."
  (unless (and (stringp url) (string-match-p "\\`https?://" url))
    (signal 'a2ui-error (list (format "Refusing to open non-http(s) URL %S" url))))
  (when (or (not a2ui-confirm-open-url)
            (y-or-n-p (format "Agent wants to open %s; open it? " url)))
    (browse-url url)))

(a2ui-define-function basic openUrl (url)
  (a2ui-open-url url)
  nil)

(provide 'a2ui-core)
;;; a2ui-core.el ends here
