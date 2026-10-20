;;; drive-gptel.el --- Try a2ui through gptel with a real model -*- lexical-binding: t; -*-

;;; Commentary:

;; Opens a gptel chat buffer with the A2UI tools enabled, asks for a
;; surface, presses its Approve button, and checks that the press is
;; sent to the model as the next chat message.  The backend is a local
;; Ollama model by default (A2UI_GPTEL_MODEL, default qwen2.5-coder).
;; Load this file through Eldev and call `a2ui-drive-gptel'.

;;; Code:

(require 'a2ui)
(require 'a2ui-gptel)
(require 'gptel)
(require 'gptel-ollama)

(defconst a2ui-drive-gptel--prompt
  "Call the render_a2ui tool to show me a surface with surfaceId \"confirm\": a Column (id \"root\") holding a Text that says \"Deploy billing to prod?\" and a Row of two Buttons, Approve and Reject, each with a Text child and an action event named \"decide\" whose context is {\"choice\": \"approve\"} or {\"choice\": \"reject\"}. After rendering, stop and wait for my button press. When it arrives, tell me in one sentence what I chose."
  "The request sent to the model.")

(defun a2ui-drive-gptel--wait (pred seconds)
  "Wait up to SECONDS for PRED; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    value))

(defun a2ui-drive-gptel ()
  "Run the gptel check; exit non-zero on failure."
  (let* ((model (intern (or (getenv "A2UI_GPTEL_MODEL") "qwen2.5-coder:latest")))
         (gptel-backend (gptel-make-ollama "Ollama" :host "localhost:11434" :stream t :models (list model)))
         (gptel-model model)
         (gptel-use-tools t)
         (gptel-confirm-tool-calls nil)
         (a2ui-log-messages nil)
         ;; Small local models rarely call a2ui_catalog on their own.
         (a2ui-tools-catalog-in-description t)
         (buffer (get-buffer-create "*gptel a2ui*")))
    (a2ui-gptel-enable)
    (with-current-buffer buffer
      (text-mode)
      (gptel-mode 1)
      (insert a2ui-drive-gptel--prompt)
      (gptel-send))
    (let ((host (a2ui-drive-gptel--wait
                 (lambda ()
                   (let ((host (buffer-local-value 'a2ui-gptel--host buffer)))
                     (and host (a2ui-session-surface-ids (a2ui-tools-host-session host))
                          (not (a2ui-gptel--busy-p buffer))
                          host)))
                 300)))
      (unless host
        (princ (format "FAIL: no surface\n%s\n" (with-current-buffer buffer (buffer-string))))
        (kill-emacs 1))
      (let* ((session (a2ui-tools-host-session host))
             (surface (a2ui-session-surface session (car (a2ui-session-surface-ids session))))
             (sbuffer (car (a2ui-vui--view session (a2ui-surface-id surface))))
             (button (seq-find (lambda (c) (and (equal (gethash "component" c) "Button")
                                                (string-match-p "approve" (downcase (concat (gethash "id" c) " "
                                                                                             (a2ui-vui-label surface (gethash "child" c) nil))))))
                               (hash-table-values (a2ui-surface-components surface)))))
        (sleep-for 0.3)
        (princ (format "--- surface %s\n%s\n" (a2ui-surface-id surface)
                       (with-current-buffer sbuffer (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))))
        (unless button
          (princ (format "FAIL: no Approve button\n--- chat buffer\n%s\n" (with-current-buffer buffer (buffer-string))))
          (kill-emacs 1))
        (with-current-buffer sbuffer
          (vui-goto-key (concat (gethash "id" button) "@"))
          (vui-activate))
        (a2ui-drive-gptel--wait (lambda () (a2ui-gptel--busy-p buffer)) 20)
        (a2ui-drive-gptel--wait (lambda () (not (a2ui-gptel--busy-p buffer))) 300)
        (let ((text (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max)))))
          (princ (format "\n--- chat buffer\n%s\n" text))
          (if (string-search "User performed action" text)
              (princ "\nPASS: the press went to the model as a chat message\n")
            (princ "\nFAIL: the press never reached the chat\n")
            (kill-emacs 1)))))))

(provide 'drive-gptel)
;;; drive-gptel.el ends here
