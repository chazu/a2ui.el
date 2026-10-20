;;; a2ui-vui.el --- Render A2UI surfaces with vui.el -*- lexical-binding: t; -*-

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

;; Turns an `a2ui-core' surface into a vui.el component tree.  Each
;; surface is one `a2ui-vui-surface-view' mounted in its own buffer;
;; it re-renders from `root' whenever the core reports a change.  The
;; renderer holds no protocol state: inputs write through `a2ui-set'
;; and buttons through `a2ui-dispatch-action'.
;;
;; Component renderers are registered per catalog with
;; `a2ui-define-component'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'a2ui-core)

(defcustom a2ui-vui-width 60
  "Width in characters of rules drawn by Card and Divider."
  :type 'natnum
  :group 'a2ui)

(defcustom a2ui-vui-field-width 30
  "Width in characters of single-line text fields."
  :type 'natnum
  :group 'a2ui)

(defcustom a2ui-vui-auto-show t
  "When non-nil, display a surface's buffer as soon as it is created."
  :type 'boolean
  :group 'a2ui)

(defcustom a2ui-trust-agent-display-name nil
  "When non-nil, show the surface theme's `agentDisplayName'.
By default the header line names the agent from the session, which
the user configured, so a surface cannot claim to come from another
agent."
  :type 'boolean
  :group 'a2ui)

(defface a2ui-heading-1 '((t :inherit (outline-1 bold) :height 1.3))
  "Face for h1 Text." :group 'a2ui)
(defface a2ui-heading-2 '((t :inherit (outline-2 bold) :height 1.2))
  "Face for h2 Text." :group 'a2ui)
(defface a2ui-heading-3 '((t :inherit (outline-3 bold) :height 1.1))
  "Face for h3 Text." :group 'a2ui)
(defface a2ui-heading-4 '((t :inherit (outline-4 bold)))
  "Face for h4 Text." :group 'a2ui)
(defface a2ui-heading-5 '((t :inherit (outline-5 bold)))
  "Face for h5 Text." :group 'a2ui)
(defface a2ui-caption '((t :inherit shadow))
  "Face for caption Text." :group 'a2ui)
(defface a2ui-code '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face for inline code in Text." :group 'a2ui)
(defface a2ui-link '((t :inherit link))
  "Face for links in Text." :group 'a2ui)
(defface a2ui-button-primary '((t :inherit (custom-button bold)))
  "Face for primary buttons." :group 'a2ui)
(defface a2ui-button-inactive '((t :inherit shadow))
  "Face for buttons whose checks fail." :group 'a2ui)
(defface a2ui-error '((t :inherit error))
  "Face for failing check messages." :group 'a2ui)
(defface a2ui-rule '((t :inherit shadow))
  "Face for Card and Divider rules." :group 'a2ui)
(defface a2ui-placeholder '((t :inherit shadow :slant italic))
  "Face for components that have not arrived or cannot be shown." :group 'a2ui)

;;;; Component registry

(defvar a2ui-vui--renderers (make-hash-table :test 'eq)
  "Catalog symbol -> hash table of component type -> render function.")

(defun a2ui-vui--register (catalog type fn)
  "Register FN to render component TYPE of CATALOG."
  (let ((table (or (gethash catalog a2ui-vui--renderers)
                   (puthash catalog (make-hash-table :test 'equal) a2ui-vui--renderers))))
    (puthash type fn table)))

(defmacro a2ui-define-component (catalog type arglist &rest body)
  "Define how component TYPE of CATALOG renders.
ARGLIST names three arguments: the component object, the surface and
the scope (the item path inside a list template, or nil).  BODY
returns a vui vnode."
  (declare (indent 3) (debug (symbolp stringp sexp body)))
  `(a2ui-vui--register ',catalog ,type (lambda ,arglist ,@body)))

(defun a2ui-vui--renderer (surface type)
  "Return the render function for TYPE in SURFACE's catalog, or nil.
A catalog that extends another falls back to its renderers."
  (seq-some (lambda (catalog)
              (when-let* ((table (gethash (a2ui-catalog-name catalog) a2ui-vui--renderers)))
                (gethash type table)))
            (a2ui-catalog-ancestors (a2ui-surface-catalog surface))))

;;;; Rendering

(defvar a2ui-vui--rendering nil
  "The (ID . SCOPE) pairs being rendered, innermost first.")

(defvar a2ui-vui--indent 0
  "Columns of indentation the component being rendered sits at.")

(defun a2ui-vui--placeholder (text)
  "Return a dim placeholder vnode showing TEXT."
  (vui-text text :face 'a2ui-placeholder))

(defun a2ui-vui-key (component scope)
  "Return a reconciliation key for COMPONENT rendered in SCOPE."
  (concat (gethash "id" component) "@" (or scope "")))

(defun a2ui-vui-render (surface id &optional scope)
  "Return the vnode for component ID of SURFACE rendered in SCOPE.
A component that has not arrived yet renders as a placeholder, as
does one whose type has no renderer."
  (let ((c (and (stringp id) (a2ui-surface-component surface id))))
    (cond
     ((null c) (a2ui-vui--placeholder "…"))
     ((member (cons id scope) a2ui-vui--rendering)
      (a2ui-report-validation-error surface (format "/components/%s" id)
                                    (format "Component %s contains itself" id))
      (a2ui-vui--placeholder (format "[cycle: %s]" id)))
     (t
      (let ((type (gethash "component" c))
            (a2ui-vui--rendering (cons (cons id scope) a2ui-vui--rendering)))
        (if-let* ((fn (a2ui-vui--renderer surface type)))
            (condition-case err
                (funcall fn c surface scope)
              (error
               (message "a2ui: rendering %s failed: %s" id (error-message-string err))
               (a2ui-vui--placeholder (format "[error in %s: %s]" type
                                              (error-message-string err)))))
          (a2ui-vui--placeholder (format "[unsupported: %s]" type))))))))

(defun a2ui-vui--template-scopes (surface template scope)
  "Return the item paths of SURFACE's list that TEMPLATE binds to, in SCOPE."
  (let* ((path (a2ui-pointer-resolve (gethash "path" template) scope))
         (items (a2ui-get surface path))
         (base (string-remove-suffix "/" path)))
    (cond ((vectorp items)
           (cl-loop for i below (length items) collect (format "%s/%d" base i)))
          ((hash-table-p items)
           (mapcar (lambda (k)
                     (concat base "/" (string-replace "/" "~1" (string-replace "~" "~0" k))))
                   (hash-table-keys items))))))

(defun a2ui-vui-children (component surface scope &optional prop)
  "Return vnodes for ChildList PROP of COMPONENT on SURFACE in SCOPE.
PROP defaults to `children'.
A static array renders each id in order; a template renders its
component once per item of the bound list, each in the item's scope."
  (let ((children (gethash (or prop "children") component)))
    (cond ((vectorp children)
           (mapcar (lambda (id) (a2ui-vui-render surface id scope)) children))
          ((hash-table-p children)
           (let ((tid (gethash "componentId" children)))
             (mapcar (lambda (item) (a2ui-vui-render surface tid item))
                     (a2ui-vui--template-scopes surface children scope)))))))

(defun a2ui-vui-child-ids (component surface scope)
  "Return (ID . SCOPE) for each child COMPONENT renders on SURFACE in SCOPE."
  (let ((children (gethash "children" component)))
    (cond ((vectorp children)
           (mapcar (lambda (id) (cons id scope)) children))
          ((hash-table-p children)
           (let ((tid (gethash "componentId" children)))
             (mapcar (lambda (item) (cons tid item))
                     (a2ui-vui--template-scopes surface children scope)))))))

(defun a2ui-vui--string (component prop surface scope)
  "Resolve PROP of COMPONENT to a display string."
  (a2ui-stringify (a2ui-resolve-prop component prop surface scope)))

;;;; Text and Markdown

(defconst a2ui-vui--markdown-inline
  '(("`\\([^`]+\\)`" . a2ui-code)
    ("\\*\\*\\(.+?\\)\\*\\*" . bold)
    ("__\\(.+?\\)__" . bold)
    ("\\*\\([^*\n]+\\)\\*" . italic))
  "Inline Markdown patterns and the face for group 1 of each.")

(defun a2ui-vui-markdown (text &optional face)
  "Render the simple Markdown in TEXT as a propertized string.
Headings, bullets, emphasis, inline code and links are understood;
everything else stays as it is.  FACE applies beneath the result."
  (let ((lines
         (mapcar
          (lambda (line)
            (cond
             ((string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)\\'" line)
              (let ((level (min 5 (length (match-string 1 line)))))
                (propertize (match-string 2 line) 'face
                            (or face (intern (format "a2ui-heading-%d" level))))))
             ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\(.*\\)\\'" line)
              (concat (match-string 1 line) "• " (match-string 2 line)))
             (t line)))
          (split-string text "\n"))))
    (let ((result (string-join lines "\n")))
      (pcase-dolist (`(,re . ,f) a2ui-vui--markdown-inline)
        (setq result
              (replace-regexp-in-string
               re (lambda (m)
                    (let ((inner (match-string 1 m)))
                      (add-face-text-property 0 (length inner) f t inner)
                      inner))
               result t t)))
      (setq result
            (replace-regexp-in-string
             "\\[\\([^]]+\\)\\](\\([^)]+\\))"
             (lambda (m)
               (let ((label (match-string 1 m)))
                 (add-face-text-property 0 (length label) 'a2ui-link t label)
                 (propertize label 'help-echo (match-string 2 m))))
             result t t))
      (when face
        (add-face-text-property 0 (length result) face t result))
      result)))

(defun a2ui-vui--plain (text)
  "Strip common Markdown markers from TEXT."
  (substring-no-properties (a2ui-vui-markdown text)))

(defun a2ui-vui--variant-face (variant)
  "Return the face for Text VARIANT, or nil for body text."
  (pcase variant
    ("h1" 'a2ui-heading-1) ("h2" 'a2ui-heading-2) ("h3" 'a2ui-heading-3)
    ("h4" 'a2ui-heading-4) ("h5" 'a2ui-heading-5)
    ("caption" 'a2ui-caption)))

(defconst a2ui-vui-icons
  '(("accountCircle" . "◉") ("add" . "+") ("arrowBack" . "←") ("arrowForward" . "→")
    ("attachFile" . "⎘") ("calendarToday" . "▦") ("call" . "☎") ("camera" . "◎")
    ("check" . "✓") ("close" . "✕") ("delete" . "⌫") ("download" . "↓")
    ("edit" . "✎") ("event" . "▦") ("error" . "⊗") ("fastForward" . "⏩")
    ("favorite" . "♥") ("favoriteOff" . "♡") ("folder" . "▤") ("help" . "?")
    ("home" . "⌂") ("info" . "ℹ") ("locationOn" . "⌖") ("lock" . "🔒")
    ("lockOpen" . "🔓") ("mail" . "✉") ("menu" . "≡") ("moreVert" . "⋮")
    ("moreHoriz" . "⋯") ("notifications" . "🔔") ("notificationsOff" . "🔕")
    ("pause" . "⏸") ("payment" . "$") ("person" . "☺") ("phone" . "☎")
    ("photo" . "▣") ("play" . "▶") ("print" . "⎙") ("refresh" . "↻")
    ("rewind" . "⏪") ("search" . "⌕") ("send" . "➤") ("settings" . "⚙")
    ("share" . "⇪") ("shoppingCart" . "🛒") ("skipNext" . "⏭") ("skipPrevious" . "⏮")
    ("star" . "★") ("starHalf" . "⯪") ("starOff" . "☆") ("stop" . "■")
    ("upload" . "↑") ("visibility" . "◉") ("visibilityOff" . "○")
    ("volumeDown" . "🔉") ("volumeMute" . "🔈") ("volumeOff" . "🔇") ("volumeUp" . "🔊")
    ("warning" . "⚠"))
  "Glyphs for the basic catalog's icon names.")

(defun a2ui-vui--icon (component surface scope)
  "Return the glyph string for Icon COMPONENT on SURFACE in SCOPE."
  (let ((name (a2ui-resolve-prop component "name" surface scope)))
    (cond ((stringp name) (or (cdr (assoc name a2ui-vui-icons)) (format "[%s]" name)))
          (t "◆"))))

(defun a2ui-vui-label (surface id scope)
  "Return a plain label for component ID of SURFACE in SCOPE, for a Button."
  (let ((c (and (stringp id) (a2ui-surface-component surface id))))
    (pcase (and c (gethash "component" c))
      ('nil "…")
      ("Text" (a2ui-vui--plain (a2ui-vui--string c "text" surface scope)))
      ("Icon" (a2ui-vui--icon c surface scope))
      ((or "Row" "Column")
       (mapconcat (pcase-lambda (`(,cid . ,cscope)) (a2ui-vui-label surface cid cscope))
                  (a2ui-vui-child-ids c surface scope) " "))
      (type (format "[%s]" type)))))

(defun a2ui-vui--rule ()
  "Return a horizontal rule vnode that fits the current indentation."
  (vui-text (make-string (max 8 (- a2ui-vui-width a2ui-vui--indent)) ?─)
            :face 'a2ui-rule))

(defun a2ui-vui--failures (messages)
  "Return a vnode listing failing check MESSAGES, or nil."
  (when messages
    (vui-text (string-join messages "; ") :face 'a2ui-error)))

;;;;; Touched inputs

(defvar a2ui-vui--touched (make-hash-table :test 'eq :weakness 'key)
  "Surface -> hash table of data paths the user has edited.
The key `:all' means a submit was attempted, so every failing check
is shown.")

(defun a2ui-vui--touch (surface key)
  "Record that the user touched KEY, a path or `:all', on SURFACE."
  (puthash key t (or (gethash surface a2ui-vui--touched)
                     (puthash surface (make-hash-table :test 'equal) a2ui-vui--touched))))

(defun a2ui-vui--touched-p (surface path)
  "Return non-nil when failures at PATH on SURFACE should be shown."
  (when-let* ((table (gethash surface a2ui-vui--touched)))
    (or (gethash :all table) (and path (gethash path table)))))

(defun a2ui-vui--write (surface path value)
  "Store VALUE at PATH of SURFACE on behalf of the user."
  (when path
    (a2ui-vui--touch surface path)
    (a2ui-set surface path value)))

(defun a2ui-vui--shown-failures (c surface scope &optional failures)
  "Return the failing checks of input C to show on SURFACE in SCOPE.
FAILURES defaults to C's failing checks.  An input's failures stay
hidden until the user edits it or a submit is blocked, so a fresh
form does not open covered in errors."
  (when (a2ui-vui--touched-p surface (a2ui-binding-path c "value" scope))
    (or failures (a2ui-check-failures c surface scope))))

;;;; Basic catalog

(defun a2ui-vui--lines (text &optional face)
  "Return a vnode showing TEXT, a line per element so indentation holds.
vui indents only the first line of a multi-line text.  FACE, when
non-nil, applies to every line."
  (let ((lines (mapcar (lambda (line) (vui-text line :face face))
                       (split-string text "\n"))))
    (if (cdr lines) (apply #'vui-vstack lines) (car lines))))

(a2ui-define-component basic "Text" (c surface scope)
  (a2ui-vui--lines (a2ui-vui-markdown (a2ui-vui--string c "text" surface scope)
                                      (a2ui-vui--variant-face (gethash "variant" c)))))

(a2ui-define-component basic "Icon" (c surface scope)
  (vui-text (a2ui-vui--icon c surface scope)))

(a2ui-define-component basic "Divider" (c _surface _scope)
  (if (equal (gethash "axis" c) "vertical")
      (vui-text "│" :face 'a2ui-rule)
    (a2ui-vui--rule)))

(a2ui-define-component basic "Column" (c surface scope)
  (apply #'vui-vstack (a2ui-vui-children c surface scope)))

(defconst a2ui-vui--field-types '("TextField" "CheckBox" "ChoicePicker")
  "Component types that render editable widgets.
vui composes a wrapped row with multi-line children as plain text,
which keeps buttons working but drops widgets, so a Row holding any
of these stacks instead.")

(defun a2ui-vui--descendants (component surface scope)
  "Return the components under COMPONENT on SURFACE in SCOPE, deepest last."
  (let (seen out (queue (list (cons component scope))))
    (while queue
      (pcase-let ((`(,c . ,sc) (pop queue)))
        (dolist (ref (append (a2ui-vui-child-ids c surface sc)
                             (mapcar (lambda (prop) (cons (gethash prop c) sc))
                                     '("child" "trigger" "content"))
                             (cl-loop for tab across (let ((tabs (gethash "tabs" c)))
                                                       (if (vectorp tabs) tabs []))
                                      when (hash-table-p tab)
                                      collect (cons (gethash "child" tab) sc))))
          (let ((child (and (stringp (car ref)) (a2ui-surface-component surface (car ref)))))
            (when (and child (not (member ref seen)))
              (push ref seen)
              (push child out)
              (setq queue (append queue (list (cons child (cdr ref))))))))))
    (nreverse out)))

(defun a2ui-vui--widget-free-p (component surface scope)
  "Return non-nil when nothing under COMPONENT renders an editable widget.
SURFACE and SCOPE are where COMPONENT renders.  A longText field
renders as text and an Edit button, so it counts as widget-free."
  (cl-notany (lambda (c)
               (and (member (gethash "component" c) a2ui-vui--field-types)
                    (not (equal (gethash "variant" c) "longText"))))
             (a2ui-vui--descendants component surface scope)))

(defconst a2ui-vui--single-line-types
  '("Text" "Icon" "Button" "CheckBox" "Image" "Video" "AudioPlayer"
    "Slider" "DateTimeInput")
  "Component types that usually render on one line.")

(defun a2ui-vui--single-line-p (component surface scope)
  "Return non-nil when each child of COMPONENT on SURFACE takes one line.
SCOPE is the item path the children render in."
  (cl-every (pcase-lambda (`(,id . ,_))
              (let ((child (a2ui-surface-component surface id)))
                (or (null child)
                    (member (gethash "component" child) a2ui-vui--single-line-types))))
            (a2ui-vui-child-ids component surface scope)))

(defun a2ui-vui--row (c surface scope)
  "Render Row-like C of SURFACE in SCOPE with its children side by side.
Children wrap onto further lines when they do not fit.  A Row holding
editable widgets stacks as a column instead; see
`a2ui-vui--field-types'."
  (let ((children (a2ui-vui-children c surface scope)))
    (let ((justify (pcase (gethash "justify" c)
                     ("center" :center) ("end" :end)
                     ((or "spaceBetween" "spaceAround" "spaceEvenly") :space-between)
                     (_ :start)))
          (width (max 20 (- a2ui-vui-width a2ui-vui--indent))))
      (cond
       ;; vui ignores :justify when wrapping, so a justified row of
       ;; one-line children is laid out unwrapped.
       ((and (not (eq justify :start)) (a2ui-vui--single-line-p c surface scope))
        (apply #'vui-flex :spacing 2 :width width :justify justify children))
       ((a2ui-vui--widget-free-p c surface scope)
        (apply #'vui-flex :wrap t :spacing 2 :width width children))
       (t (apply #'vui-vstack children))))))

(a2ui-define-component basic "Row" (c surface scope)
  (a2ui-vui--row c surface scope))

(a2ui-define-component basic "List" (c surface scope)
  (if (equal (gethash "direction" c) "horizontal")
      (a2ui-vui--row c surface scope)
    (apply #'vui-vstack (a2ui-vui-children c surface scope))))

(a2ui-define-component basic "Card" (c surface scope)
  (vui-vstack
   (a2ui-vui--rule)
   (vui-vstack :indent 2 (let ((a2ui-vui--indent (+ a2ui-vui--indent 2)))
                           (a2ui-vui-render surface (gethash "child" c) scope)))
   (a2ui-vui--rule)))

(a2ui-define-component basic "Button" (c surface scope)
  (let* ((variant (gethash "variant" c))
         (failures (a2ui-check-failures c surface scope)))
    (vui-button (a2ui-vui-label surface (gethash "child" c) scope)
      :key (a2ui-vui-key c scope)
      :face (cond (failures 'a2ui-button-inactive)
                  ((equal variant "primary") 'a2ui-button-primary))
      :no-decoration (equal variant "borderless")
      :help-echo (and failures (string-join failures "\n"))
      :on-click (lambda ()
                  ;; Checks are re-run: the data may have changed
                  ;; since this render.
                  (if-let* ((now (a2ui-check-failures c surface scope)))
                      (progn
                        ;; Reveal every input's failures, to show why.
                        (a2ui-vui--touch surface :all)
                        (a2ui-vui-refresh surface)
                        (message "%s" (string-join now " ")))
                    (a2ui-dispatch-action surface c scope))))))

(a2ui-define-component basic "TextField" (c surface scope)
  (let* ((path (a2ui-binding-path c "value" scope))
         (regexp (gethash "validationRegexp" c))
         (value (a2ui-vui--string c "value" surface scope))
         (failures (append (a2ui-check-failures c surface scope)
                           (and (stringp regexp)
                                (not (string-match-p (a2ui-js-regex-to-emacs regexp) value))
                                (list "Invalid format.")))))
    (vui-vstack
     (if (equal (gethash "variant" c) "longText")
         (a2ui-vui--long-text c surface scope path value)
       (vui-hstack
        (a2ui-vui--label-prefix c surface scope)
        (vui-field :key (a2ui-vui-key c scope)
                   :value value
                   :size a2ui-vui-field-width
                   :secret (equal (gethash "variant" c) "obscured")
                   :on-change (lambda (v) (a2ui-vui--write surface path v)))))
     (a2ui-vui--failures (a2ui-vui--shown-failures c surface scope failures)))))

(a2ui-define-component basic "CheckBox" (c surface scope)
  (let ((path (a2ui-binding-path c "value" scope)))
    (a2ui-vui--input
     c surface scope
     (vui-checkbox :key (a2ui-vui-key c scope)
                   :checked (a2ui-true-p (a2ui-resolve-prop c "value" surface scope))
                   :label (a2ui-vui--string c "label" surface scope)
                   :on-change (lambda (v) (a2ui-vui--write surface path (a2ui-bool v)))))))

(defun a2ui-vui--label-prefix (c surface scope)
  "Return a \"Label:\" text vnode for C on SURFACE in SCOPE, or nil."
  (let ((label (a2ui-vui--string c "label" surface scope)))
    (unless (string-empty-p label)
      (vui-text (if (string-match-p "[:?]\\'" label) label (concat label ":"))))))

(defun a2ui-vui--input (c surface scope control)
  "Return CONTROL for input C, with its failing checks shown beneath.
SURFACE and SCOPE are where C's checks are evaluated."
  (if-let* ((failures (a2ui-vui--failures (a2ui-vui--shown-failures c surface scope))))
      (vui-vstack control failures)
    control))

(defun a2ui-vui--selection (value)
  "Return the selected option values in the StringList VALUE."
  (cond ((vectorp value) (mapcar #'a2ui-stringify value))
        ((stringp value) (list value))))

(a2ui-define-component basic "ChoicePicker" (c surface scope)
  (let* ((path (a2ui-binding-path c "value" scope))
         (selected (a2ui-vui--selection (a2ui-resolve-prop c "value" surface scope)))
         (options (cl-loop for o across (or (gethash "options" c) [])
                           when (hash-table-p o)
                           collect (cons (a2ui-stringify (gethash "value" o))
                                         (a2ui-vui--string o "label" surface scope))))
         (label (a2ui-vui--string c "label" surface scope))
         (key (a2ui-vui-key c scope))
         (write (lambda (values) (a2ui-vui--write surface path (vconcat values)))))
    (a2ui-vui--input
     c surface scope
     (if (equal (gethash "variant" c) "multipleSelection")
         (let ((boxes
                (mapcar
                 (pcase-lambda (`(,value . ,text))
                   (vui-checkbox
                    :key (concat key "/" value)
                    :checked (member value selected)
                    :label text
                    :on-change
                    (lambda (on)
                      ;; Keep the options' order, whatever the click order.
                      (funcall write
                               (cl-loop for (v . _) in options
                                        when (if (equal v value) on (member v selected))
                                        collect v)))))
                 options)))
           (vui-vstack
            (a2ui-vui--label-prefix c surface scope)
            (if (equal (gethash "displayStyle" c) "chips")
                (apply #'vui-hstack :spacing 2 boxes)
              (apply #'vui-vstack :indent 2 boxes))))
       (vui-hstack
        (a2ui-vui--label-prefix c surface scope)
        (vui-select :key key
                    :value (car selected)
                    :options options
                    :prompt (format "%s: " (if (string-empty-p label) "Choose" label))
                    :on-change (lambda (v) (funcall write (list v)))))))))

(defun a2ui-vui--slider-step (lo hi value)
  "Return a step for a slider from LO to HI at VALUE.
Whole-number sliders spanning at least ten step by whole numbers,
about a twentieth of the range; others by a twentieth."
  (if (and (integerp lo) (integerp hi) (integerp value) (>= (- hi lo) 10))
      (max 1 (/ (- hi lo) 20))
    (/ (- hi lo) 20.0)))

(defun a2ui-vui--tidy-number (n)
  "Return N with floating-point noise such as 0.30000000000000004 removed."
  (if (floatp n) (/ (fround (* n 1e10)) 1e10) n))

(defun a2ui-vui--gauge (value lo hi)
  "Return a bar showing where VALUE lies between LO and HI."
  (let* ((width 20)
         (filled (if (> hi lo)
                     (round (* width (/ (float (- (min hi (max lo value)) lo)) (- hi lo))))
                   0)))
    (concat "▕" (make-string filled ?█) (make-string (- width filled) ?░) "▏")))

(a2ui-define-component basic "Slider" (c surface scope)
  (let* ((path (a2ui-binding-path c "value" scope))
         (lo (or (a2ui-number (gethash "min" c)) 0))
         (hi (or (a2ui-number (gethash "max" c)) 100))
         (value (or (a2ui-number (a2ui-resolve-prop c "value" surface scope)) lo))
         (step (a2ui-vui--slider-step lo hi value))
         (key (a2ui-vui-key c scope))
         (set (lambda (v) (a2ui-vui--write surface path
                                            (a2ui-vui--tidy-number (min hi (max lo v))))))
         (down (lambda () (interactive) (funcall set (- value step))))
         (up (lambda () (interactive) (funcall set (+ value step)))))
    (a2ui-vui--input
     c surface scope
     (vui-hstack
      (a2ui-vui--label-prefix c surface scope)
      (vui-button "-" :key (concat key "-") :on-click down)
      (vui-button (a2ui-stringify value)
        :key key
        :keymap (define-keymap "-" down "+" up "<left>" down "<right>" up)
        :help-echo (format "%s to %s; - and + step by %s, RET to type a value" lo hi step)
        :on-click (lambda ()
                    (funcall set (read-number (format "Value (%s–%s): " lo hi) value))))
      (vui-button "+" :key (concat key "+") :on-click up)
      (vui-text (a2ui-vui--gauge value lo hi) :face 'a2ui-rule)
      (vui-text (format "%s–%s" lo hi) :face 'shadow)))))

(defun a2ui-vui--datetime-kind (c)
  "Return `date', `time' or `datetime' for DateTimeInput C."
  (let ((date (a2ui-true-p (gethash "enableDate" c)))
        (time (a2ui-true-p (gethash "enableTime" c))))
    (cond ((and date time) 'datetime) (time 'time) (t 'date))))

(defun a2ui-vui--parse-datetime (value)
  "Return the time in ISO 8601 VALUE, or nil if it does not parse."
  (ignore-errors
    (let ((decoded (if (string-match-p "\\`[0-9]\\{2\\}:" value)
                       (iso8601-parse-time value)
                     (iso8601-parse value)))
          (now (decode-time)))
      (dolist (slot '(0 1 2))
        (unless (nth slot decoded) (setf (nth slot decoded) 0)))
      (dolist (slot '(3 4 5))
        (unless (nth slot decoded) (setf (nth slot decoded) (nth slot now))))
      (encode-time decoded))))

(defconst a2ui-vui--datetime-formats
  '((date "%Y-%m-%d" "%a %b %-d, %Y")
    (time "%H:%M:%S" "%H:%M")
    (datetime "%Y-%m-%dT%H:%M:%S" "%a %b %-d, %Y %H:%M"))
  "Per kind: the ISO 8601 format written, then the format displayed.")

(declare-function org-read-date "org"
                  (&optional with-time to-time from-string prompt default-time
                             default-input inactive))

(defun a2ui-vui-read-datetime (prompt kind default)
  "Read a date and/or time with PROMPT and return its ISO 8601 string.
KIND is `date', `time' or `datetime'; DEFAULT is a time or nil."
  (require 'org)
  (let ((time (org-read-date (not (eq kind 'date)) t nil prompt default)))
    (format-time-string (nth 1 (assq kind a2ui-vui--datetime-formats)) time)))

(a2ui-define-component basic "DateTimeInput" (c surface scope)
  (let* ((path (a2ui-binding-path c "value" scope))
         (kind (a2ui-vui--datetime-kind c))
         (value (a2ui-vui--string c "value" surface scope))
         (time (and (not (string-empty-p value)) (a2ui-vui--parse-datetime value)))
         (lo (a2ui-stringify (a2ui-resolve-prop c "min" surface scope)))
         (hi (a2ui-stringify (a2ui-resolve-prop c "max" surface scope)))
         (label (a2ui-vui--string c "label" surface scope)))
    (a2ui-vui--input
     c surface scope
     (vui-hstack
      (a2ui-vui--label-prefix c surface scope)
      (vui-button (cond (time (format-time-string
                               (nth 2 (assq kind a2ui-vui--datetime-formats)) time))
                        ((string-empty-p value) "Pick…")
                        (t value))
        :key (a2ui-vui-key c scope)
        :on-click
        (lambda ()
          (let ((iso (a2ui-vui-read-datetime
                      (format "%s: " (if (string-empty-p label) "Date" label)) kind time)))
            ;; ISO 8601 strings of one kind sort as their times do.
            (cond ((and (not (string-empty-p lo)) (string< iso lo))
                   (message "Choose %s or later" lo))
                  ((and (not (string-empty-p hi)) (string< hi iso))
                   (message "Choose %s or earlier" hi))
                  (t (a2ui-vui--write surface path iso))))))))))

;;;;; Media

(defun a2ui-vui--link (label url &optional key)
  "Return a button showing LABEL that opens URL after asking.
KEY is its reconciliation key."
  (vui-button label
    :key key
    :no-decoration t
    :face 'a2ui-link
    :help-echo url
    :on-click (lambda ()
                (condition-case err
                    (a2ui-open-url url)
                  (a2ui-error (message "%s" (error-message-string err)))))))

(defun a2ui-vui--media (c surface scope glyph kind)
  "Render media component C of SURFACE in SCOPE as a link.
GLYPH marks the link, labelled KIND when C has no description."
  (let ((url (a2ui-vui--string c "url" surface scope))
        (description (a2ui-vui--string c "description" surface scope)))
    (if (string-empty-p url)
        (a2ui-vui--placeholder (format "[%s]" kind))
      (a2ui-vui--link (format "%s %s" glyph (if (string-empty-p description) kind description))
                      url (a2ui-vui-key c scope)))))

(a2ui-define-component basic "Image" (c surface scope)
  (a2ui-vui--media c surface scope "▣" "Image"))

(a2ui-define-component basic "Video" (c surface scope)
  (a2ui-vui--media c surface scope "▶" "Video"))

(a2ui-define-component basic "AudioPlayer" (c surface scope)
  (a2ui-vui--media c surface scope "♪" "Audio"))

;;;; Long text editing

(defvar-local a2ui-vui--edit-commit nil
  "Function called with the text when this edit buffer is committed.")

(defun a2ui-edit-commit ()
  "Save the text of this edit buffer back to its field and close it."
  (interactive)
  (let ((commit a2ui-vui--edit-commit)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (quit-window t)
    (funcall commit text)))

(defun a2ui-edit-abort ()
  "Close this edit buffer without saving."
  (interactive)
  (quit-window t))

(defvar-keymap a2ui-edit-mode-map
  :doc "Keymap for buffers editing a long A2UI text field."
  "C-c C-c" #'a2ui-edit-commit
  "C-c C-k" #'a2ui-edit-abort)

(define-minor-mode a2ui-edit-mode
  "Minor mode for editing a long A2UI text field in its own buffer.

\\{a2ui-edit-mode-map}"
  :lighter " A2UI-Edit")

(defun a2ui-vui-edit-text (title text commit)
  "Pop up a buffer named after TITLE to edit TEXT.
COMMIT is called with the new text on \\[a2ui-edit-commit]."
  (let ((buffer (generate-new-buffer (format "*a2ui-edit: %s*" title))))
    (with-current-buffer buffer
      (insert text)
      (text-mode)
      (a2ui-edit-mode 1)
      (setq a2ui-vui--edit-commit commit)
      (setq header-line-format
            (substitute-command-keys
             " Edit, then \\[a2ui-edit-commit] to save or \\[a2ui-edit-abort] to cancel"))
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

(defun a2ui-vui--long-text (c surface scope path value)
  "Render longText field C of SURFACE at PATH: VALUE and an Edit button.
SCOPE is the item path C renders in."
  (let ((label (a2ui-vui--string c "label" surface scope)))
    (vui-vstack
     (a2ui-vui--label-prefix c surface scope)
     (vui-vstack :indent 2
                 (if (string-empty-p value)
                     (vui-text "(empty)" :face 'shadow)
                   (a2ui-vui--lines value))
                 (vui-button "Edit"
                   :key (a2ui-vui-key c scope)
                   :on-click (lambda ()
                               (a2ui-vui-edit-text
                                (if (string-empty-p label) (gethash "id" c) label)
                                value
                                (lambda (text)
                                  ;; The surface may have been deleted meanwhile.
                                  (when (eq surface (a2ui-session-surface
                                                     (a2ui-surface-session surface)
                                                     (a2ui-surface-id surface)))
                                    (a2ui-vui--write surface path text))))))))))

;;;; Surface views

(defvar a2ui-vui--views (make-hash-table :test 'eq :weakness 'key)
  "Session -> hash table of surface id -> (BUFFER . BUMP-FN).")

(defun a2ui-vui--view (session surface-id)
  "Return the (BUFFER . BUMP-FN) view of SURFACE-ID in SESSION, or nil."
  (when-let* ((views (gethash session a2ui-vui--views)))
    (gethash surface-id views)))

(defun a2ui-vui--on-change (session surface-id)
  "Re-render the view of SURFACE-ID in SESSION, showing new surfaces."
  (if-let* ((view (a2ui-vui--view session surface-id)))
      (funcall (cdr view))
    (when (and a2ui-vui-auto-show (a2ui-session-surface session surface-id))
      (a2ui-show-surface session surface-id))))

(defun a2ui-vui-attach (session)
  "Make this renderer SESSION's change listener.
An existing `on-change-fn' keeps being called."
  (unless (gethash session a2ui-vui--views)
    (puthash session (make-hash-table :test 'equal) a2ui-vui--views)
    (let ((previous (a2ui-session-on-change-fn session)))
      (setf (a2ui-session-on-change-fn session)
            (lambda (surface-id)
              (when previous (funcall previous surface-id))
              (a2ui-vui--on-change session surface-id)))))
  session)

(vui-defcomponent a2ui-vui-surface-view (session surface-id)
  :state ((tick 0))
  :on-mount
  (progn
    (puthash surface-id
             (cons (current-buffer) (vui-with-async-context (vui-set-state :tick #'1+)))
             (gethash session a2ui-vui--views))
    (lambda ()
      (when-let* ((views (gethash session a2ui-vui--views)))
        (remhash surface-id views))))
  :render
  (let ((surface (a2ui-session-surface session surface-id)))
    (ignore tick)
    (cond ((null surface)
           (vui-text (format "Surface %s was deleted." surface-id) :face 'shadow))
          ((a2ui-surface-component surface "root")
           (a2ui-vui-render surface "root" nil))
          (t (vui-text "Waiting for agent…" :face 'shadow)))))

(defvar-local a2ui-vui-session nil
  "The session whose surface this buffer shows.")
(put 'a2ui-vui-session 'permanent-local t)

(defvar-local a2ui-vui-surface-id nil
  "The id of the surface this buffer shows.")
(put 'a2ui-vui-surface-id 'permanent-local t)

(defun a2ui-vui--header-line ()
  "Return the header line naming the agent and surface of this buffer."
  (let* ((surface (a2ui-session-surface a2ui-vui-session a2ui-vui-surface-id))
         (theme (and surface (a2ui-surface-theme surface)))
         (claimed (and (hash-table-p theme) (gethash "agentDisplayName" theme)))
         (agent (or (and a2ui-trust-agent-display-name claimed)
                    (a2ui-session-name a2ui-vui-session)
                    "agent")))
    (concat " " (propertize (format "%s" agent) 'face 'bold) "  " a2ui-vui-surface-id)))

(defun a2ui-vui-refresh (surface)
  "Re-render the view of SURFACE, if it has one."
  (when-let* ((view (a2ui-vui--view (a2ui-surface-session surface) (a2ui-surface-id surface))))
    (funcall (cdr view))))

(defun a2ui-surface-refresh (&rest _)
  "Re-render the surface in the current buffer."
  (interactive)
  (when-let* ((view (a2ui-vui--view a2ui-vui-session a2ui-vui-surface-id)))
    (funcall (cdr view))))

(defun a2ui-surface-delete ()
  "Delete the surface in the current buffer and kill the buffer."
  (interactive)
  (when (and a2ui-vui-session (yes-or-no-p (format "Delete surface %s? " a2ui-vui-surface-id)))
    (a2ui-delete-surface a2ui-vui-session a2ui-vui-surface-id)
    (kill-buffer)))

(defvar-keymap a2ui-surface-mode-map
  :doc "Keymap for buffers showing an A2UI surface."
  "C-c C-k" #'a2ui-surface-delete)

(define-minor-mode a2ui-surface-mode
  "Minor mode for buffers showing an A2UI surface.
TAB and S-TAB move between controls, RET activates, \\`g' re-renders
and \\`q' buries the buffer.

\\{a2ui-surface-mode-map}"
  :lighter " A2UI"
  (when a2ui-surface-mode
    (setq-local revert-buffer-function #'a2ui-surface-refresh)
    (setq header-line-format '(:eval (a2ui-vui--header-line)))))

(defun a2ui-vui--buffer-name (surface-id)
  "Return a fresh buffer name for SURFACE-ID."
  (generate-new-buffer-name (format "*a2ui: %s*" surface-id)))

(defun a2ui-show-surface (session surface-id)
  "Display SURFACE-ID of SESSION in its buffer, mounting it if needed.
The buffer is shown with `display-buffer', so `display-buffer-alist'
decides where.  Return the buffer."
  (a2ui-vui-attach session)
  (let ((buffer (car (a2ui-vui--view session surface-id))))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create (a2ui-vui--buffer-name surface-id)))
      (with-current-buffer buffer
        (setq a2ui-vui-session session
              a2ui-vui-surface-id surface-id)
        (vui-render (vui-component 'a2ui-vui-surface-view
                                   :session session :surface-id surface-id)
                    buffer)
        (a2ui-surface-mode 1)))
    (display-buffer buffer)
    buffer))

(provide 'a2ui-vui)
;;; a2ui-vui.el ends here
