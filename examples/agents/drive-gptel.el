;;; drive-gptel.el --- Try a2ui through gptel with a real model -*- lexical-binding: t; -*-

;;; Commentary:

;; Opens a gptel chat buffer with the A2UI tools enabled, asks for a
;; surface, presses its Approve button, and checks that the press
;; reaches the model, either through a2ui_await_action or as the next
;; chat message (with A2UI_GPTEL_CHAT set).  A2UI_GPTEL_BACKEND picks
;; the backend: "ollama" (the default, a local model) or "openrouter"
;; (needs OPENROUTER_API_KEY).  A2UI_GPTEL_MODEL picks the model, and
;; A2UI_INLINE draws the surface in the chat buffer.  Load
;; this file through Eldev and call `a2ui-drive-gptel'.

;;; Code:

(require 'a2ui)
(require 'a2ui-gptel)
(require 'gptel)
(require 'gptel-ollama)
(require 'gptel-openai)

(defconst a2ui-drive-gptel--prompt
  "Call the render_a2ui tool to show me a surface with surfaceId \"confirm\": a Column (id \"root\") holding a Text that says \"Deploy billing to prod?\", a TextField labelled Reason bound to /reason, and a Row of two Buttons, Approve and Reject, each with a Text child and an action event named \"decide\" whose context is {\"choice\": \"approve\"} or {\"choice\": \"reject\"} plus the reason bound to /reason.  Start the data model with reason \"routine release\".  "
  "The request sent to the model, before how to wait.")

(defun a2ui-drive-gptel--request ()
  "Return the request; with A2UI_GPTEL_CHAT set, the press comes as chat."
  (concat a2ui-drive-gptel--prompt
          (if (getenv "A2UI_GPTEL_CHAT")
              "Then end your turn without calling a2ui_await_action; my press will arrive as my next message.  When it does,"
            "After rendering, wait for my button press.  When it arrives,")
          " tell me in one sentence what I chose and why."))

(defun a2ui-drive-gptel--wait (pred seconds)
  "Wait up to SECONDS for PRED; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    value))

(defun a2ui-drive-gptel--backend (name model)
  "Return the gptel backend NAME serving MODEL."
  (pcase name
    ("ollama" (gptel-make-ollama "Ollama" :host "localhost:11434" :stream t :models (list model)))
    ("openrouter" (gptel-make-openai "OpenRouter"
                    :host "openrouter.ai" :endpoint "/api/v1/chat/completions" :stream t
                    :key (lambda () (getenv "OPENROUTER_API_KEY")) :models (list model)))
    (_ (error "Unknown backend %s" name))))

(defun a2ui-drive-gptel ()
  "Run the gptel check; exit non-zero on failure."
  (let* ((backend (or (getenv "A2UI_GPTEL_BACKEND") "ollama"))
         (local (equal backend "ollama"))
         (model (intern (or (getenv "A2UI_GPTEL_MODEL")
                            (if local "qwen2.5-coder:latest" "anthropic/claude-haiku-5.5"))))
         (gptel-backend (a2ui-drive-gptel--backend backend model))
         (gptel-model model)
         (gptel-use-tools t)
         (gptel-confirm-tool-calls nil)
         (a2ui-log-messages nil)
         ;; Small local models rarely call a2ui_catalog on their own.
         (a2ui-tools-catalog-in-description local)
         (a2ui-gptel-inline-surfaces (and (getenv "A2UI_INLINE") t))
         (buffer (get-buffer-create "*gptel a2ui*")))
    (princ (format "backend: %s  model: %s\n" backend model))
    (a2ui-gptel-enable)
    (with-current-buffer buffer
      (text-mode)
      (gptel-mode 1)
      (insert (a2ui-drive-gptel--request))
      (gptel-send))
    (let ((host (a2ui-drive-gptel--wait
                 (lambda ()
                   ;; Ready once the model has drawn the surface and either
                   ;; finished its turn or waits in a2ui_await_action.
                   (let ((host (buffer-local-value 'a2ui-gptel--host buffer)))
                     (and host (a2ui-session-surface-ids (a2ui-tools-host-session host))
                          (or (a2ui-tools-host-waiters host) (not (a2ui-gptel--busy-p buffer)))
                          ;; Inline, the surface is drawn when the response ends.
                          (or (not a2ui-gptel-inline-surfaces)
                              (with-current-buffer buffer
                                (save-excursion (goto-char (point-min)) (search-forward "┌─ " nil t))))
                          host)))
                 300)))
      (unless host
        (princ (format "FAIL: no surface\n%s\n" (with-current-buffer buffer (buffer-string))))
        (kill-emacs 1))
      (let* ((session (a2ui-tools-host-session host))
             (surface (a2ui-session-surface session (car (a2ui-session-surface-ids session))))
             (sbuffer (if a2ui-gptel-inline-surfaces
                          buffer
                        (car (a2ui-vui--view session (a2ui-surface-id surface)))))
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
              (princ (format "\nPASS: the press reached the model %s; the bound reason %s\n"
                             (if (string-search "(a2ui_await_action" text)
                                 "through a2ui_await_action"
                               "as a chat message")
                             (if (string-match-p "User performed action .*routine release" text)
                                 "came with it"
                               "did not (the model's context did not bind /reason)")))
            (princ "\nFAIL: the press never reached the chat\n")
            (kill-emacs 1)))))))

(provide 'drive-gptel)
;;; drive-gptel.el ends here
