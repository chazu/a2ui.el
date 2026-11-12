;;; demo-gif.el --- Record the README demo's frames -*- lexical-binding: t; -*-

;;; Commentary:

;; Replays examples/code-review.jsonl into the real renderer and drives
;; it as a user would: a blocked Merge, unfolding Context, picking a
;; reviewer, then the Merge that sends the action.  Each step's buffer
;; text, a face class per character, the cursor and the echo area are
;; written as JSON for scripts/demo-gif.py, which draws the GIF.
;; Load this file in batch Emacs through Eldev and call
;; `a2ui-demo-gif-frames', then run the Python script; the README's
;; Development section has the commands.  scripts/example-gifs.el uses
;; the same recorder for the examples' GIFs.

;;; Code:

(require 'a2ui)

(defconst a2ui-demo-gif--classes
  '(("diff-indicator-added\\|diff-added\\|diff-refine-added" . "added")
    ("diff-indicator-removed\\|diff-removed\\|diff-refine-removed" . "removed")
    ("diff-hunk-header" . "hunk")
    ("diff-header\\|diff-file-header\\|a2ui-emacs-file" . "file")
    ("a2ui-heading\\|org-level\\|a2ui-emacs-section" . "heading")
    ("a2ui-button-primary" . "primary")
    ("a2ui-tone-success\\|\\`success" . "success")
    ("a2ui-tone-warning\\|\\`warning" . "warning")
    ;; Before shadow: Org's code faces inherit from it.
    ("org-code\\|org-verbatim" . "code")
    ("a2ui-button-inactive\\|a2ui-placeholder\\|a2ui-caption\\|shadow" . "shadow")
    ("font-lock-keyword\\|font-lock-builtin" . "keyword")
    ("font-lock-string\\|font-lock-doc" . "string")
    ("font-lock-comment" . "comment")
    ("font-lock-function\\|font-lock-variable\\|font-lock-constant" . "function")
    ("a2ui-error\\|\\`error" . "error")
    ("a2ui-link\\|org-link\\|\\`link" . "link")
    ("a2ui-rule" . "rule")
    ("widget-field\\|a2ui-field" . "field")
    ("italic" . "italic")
    ("bold" . "bold")
    ("button" . "button"))
  "Face name patterns and the class each draws with, first match wins.")

(defun a2ui-demo-gif--faces (pos)
  "Return the face symbols at POS, with those they inherit from."
  (let (out)
    (cl-labels ((walk (f)
                  (cond ((and (symbolp f) f (facep f) (not (memq f out)))
                         (push f out)
                         (let ((inherit (face-attribute f :inherit nil)))
                           (dolist (i (ensure-list inherit)) (walk i))))
                        ((and (consp f) (keywordp (car f)))
                         (dolist (i (ensure-list (plist-get f :inherit))) (walk i)))
                        ((consp f) (mapc #'walk f)))))
      (walk (get-text-property pos 'face))
      (walk (get-text-property pos 'font-lock-face))
      ;; Editable fields get their face from an overlay.
      (dolist (o (overlays-at pos)) (walk (overlay-get o 'face))))
    (nreverse out)))

(defun a2ui-demo-gif--class (pos)
  "Return the drawing class of the text at POS."
  (let ((names (mapcar #'symbol-name (a2ui-demo-gif--faces pos))))
    (or (cdr (seq-find (lambda (rule) (seq-some (lambda (n) (string-match-p (car rule) n)) names))
                       a2ui-demo-gif--classes))
        "default")))

(defvar a2ui-demo-gif--echo ""
  "The last message, shown in the echo area.")

(defun a2ui-demo-gif--frame (buffer caption &optional top rows delay)
  "Return a frame of BUFFER now, under CAPTION.
TOP and ROWS show only ROWS lines from line TOP (from 0), as a window
scrolled there would.  DELAY is how long the frame stays, in 1/100 s."
  (with-current-buffer buffer
    (let ((root (vui-get-instance buffer)))
      (while (and root (vui-instance-render-timer root)) (sleep-for 0.01)))
    ;; Line ends would otherwise stop at the edge of an editable field.
    (let ((inhibit-field-text-motion t) (lines nil) (cursor nil))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((spans nil) (end (line-end-position)))
            (while (< (point) end)
              (let* ((class (a2ui-demo-gif--class (point)))
                     (next (min end (next-single-char-property-change (point) 'face nil end)
                                (next-single-char-property-change (point) 'font-lock-face nil end))))
                (push (vector class (buffer-substring-no-properties (point) next)) spans)
                (goto-char next)))
            (push (nreverse spans) lines)
            (forward-line 1))))
      (setq lines (nreverse lines)
            cursor (list (- (line-number-at-pos) 1 (or top 0)) (current-column)))
      (when top (setq lines (nthcdr top lines)))
      (when rows (setq lines (seq-take lines rows)))
      (list :caption caption
            :header (a2ui-vui--header-line)
            :lines (vconcat (mapcar #'vconcat lines))
            :cursor (and (<= 0 (car cursor)) (< (car cursor) (length lines)) (vconcat cursor))
            :echo a2ui-demo-gif--echo
            :delay delay))))

(defun a2ui-demo-gif--write (name meta frames)
  "Write FRAMES, oldest first, and META for the GIF NAME to docs/.
The file is docs/NAME-frames.json.
META is a plist: :title of the window, :cols, :rows, :output (the
GIF's path) and :still (where to put the last frame as a PNG)."
  (make-directory "docs" t)
  (let ((coding-system-for-write 'utf-8-unix)
        (file (format "docs/%s-frames.json" name)))
    (with-temp-file file
      (insert (a2ui-json-encode
               (a2ui-obj "title" (plist-get meta :title)
                         "cols" (plist-get meta :cols)
                         "rows" (plist-get meta :rows)
                         "output" (plist-get meta :output)
                         "still" (plist-get meta :still)
                         "frames" (vconcat
                                   (mapcar (lambda (f)
                                             (a2ui-obj "caption" (plist-get f :caption)
                                                       "header" (plist-get f :header)
                                                       "lines" (plist-get f :lines)
                                                       "cursor" (plist-get f :cursor)
                                                       "echo" (plist-get f :echo)
                                                       "delay" (plist-get f :delay)))
                                           frames))))))
    (princ (format "wrote %s\n" file))))

(defun a2ui-demo-gif-frames ()
  "Drive the review surface and write the frames to docs/demo-frames.json."
  (let* ((a2ui-log-messages nil)
         (sent nil)
         (session (a2ui-session-create
                   :name "claude"
                   :send-action-fn (lambda (m _) (push m sent))))
         (frames nil))
    (advice-add 'message :around
                (lambda (orig fmt &rest args)
                  (when fmt (setq a2ui-demo-gif--echo (apply #'format-message fmt args)))
                  (apply orig fmt args)))
    (a2ui-vui-attach session)
    (dolist (m (a2ui-read-jsonl (expand-file-name "examples/code-review.jsonl")))
      (a2ui-apply-message session m))
    (let ((buffer (car (a2ui-vui--view session "review")))
          (shot (lambda (buffer caption) (push (a2ui-demo-gif--frame buffer caption) frames))))
      (with-current-buffer buffer
        (setq a2ui-demo-gif--echo "")
        (goto-char (point-min))
        (funcall shot buffer "An agent asks for a review: Section, Table, Diff, Picker and OrgText")
        (vui-goto-key "go@")
        (funcall shot buffer "Merge is blocked until its checks pass")
        (vui-activate)
        (funcall shot buffer "Merge is blocked until its checks pass")
        (setq a2ui-demo-gif--echo "")
        (vui-goto-key "why@")
        (funcall shot buffer "RET folds and unfolds a Section")
        (vui-activate)
        (funcall shot buffer "Code is fontified by its major mode; FileRef visits the file")
        (vui-goto-key "decision@")
        (funcall shot buffer "The Picker reads a value with completing-read")
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (setq a2ui-demo-gif--echo (concat prompt "grace"))
                     "grace")))
          (vui-activate))
        (funcall shot buffer "The Picker reads a value with completing-read")
        (setq a2ui-demo-gif--echo "")
        (vui-goto-key "go@")
        (funcall shot buffer "The choice is in the data model; Merge is ready")
        (vui-activate)
        (let ((action (gethash "action" (car sent))))
          (setq a2ui-demo-gif--echo
                (format "→ agent: %s"
                        (a2ui-json-encode (a2ui-obj "name" (gethash "name" action)
                                                    "context" (gethash "context" action)))))
          (funcall shot buffer "The press goes to the agent with the resolved context"))))
    (a2ui-demo-gif--write "demo" (list :title "*a2ui: review*" :cols 74
                                       :output "docs/demo.gif" :still "docs/demo.png")
                          (nreverse frames))))

(provide 'demo-gif)
;;; demo-gif.el ends here
