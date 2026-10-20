;;; drive-agent-shell.el --- Try a2ui through a real agent-shell -*- lexical-binding: t; -*-

;;; Commentary:

;; Starts an agent-shell running Claude Code (claude-agent-acp) with the
;; a2ui MCP server, asks for a review surface, presses its Approve
;; button, and checks that the press reaches Claude as the shell's next
;; prompt.  It runs in an empty temporary project; a2ui's tools are
;; approved by `a2ui-agent-shell-allow-a2ui', so no permission prompt
;; blocks it.
;;
;; Load this file through Eldev, with agent-shell and its dependencies
;; on the load path, and call `a2ui-drive-agent-shell'.

;;; Code:

(require 'a2ui)
(require 'a2ui-agent-shell)

(defvar agent-shell-session-strategy)
(declare-function agent-shell-start "agent-shell" (&rest args))
(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic" ())
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell-insert "agent-shell" (&rest args))
(declare-function shell-maker-busy "shell-maker" ())

(defconst a2ui-drive-agent-shell--prompt
  "Show me a review surface (with the a2ui tools) for this change to the billing service: values.yaml bumps replicas from 3 to 5. Include the diff and Approve/Reject buttons, then end your turn without waiting; my button press will reach you as my next message. When it does, reply in one sentence saying what I chose."
  "The request sent through the shell.")

(defun a2ui-drive-agent-shell--wait (pred seconds)
  "Wait up to SECONDS for PRED to return non-nil; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    value))

(defun a2ui-drive-agent-shell ()
  "Run the agent-shell check; exit non-zero on failure."
  (require 'agent-shell)
  (let* ((project (file-name-as-directory (make-temp-file "a2ui-agent-shell" t)))
         (default-directory project)
         (a2ui-log-messages nil)
         (agent-shell-session-strategy 'new)
         ready buffer host)
    (a2ui-agent-shell-setup)
    (setq buffer (agent-shell-start :config (agent-shell-anthropic-make-claude-code-config)))
    (agent-shell-subscribe-to :shell-buffer buffer :event 'prompt-ready
                              :on-event (lambda (_) (setq ready t)))
    (unless (a2ui-drive-agent-shell--wait (lambda () ready) 120)
      (princ "FAIL: the shell never became ready\n") (kill-emacs 1))
    (princ (format "shell %s ready in %s\n" (buffer-name buffer) project))
    (with-current-buffer buffer
      (agent-shell-insert :text a2ui-drive-agent-shell--prompt :submit t :shell-buffer buffer))
    ;; Wait for the surface and for the turn to end.
    (unless (a2ui-drive-agent-shell--wait
             (lambda ()
               (setq host (and (buffer-local-value 'a2ui-agent-shell--url buffer)
                               (gethash (car (last (split-string (buffer-local-value 'a2ui-agent-shell--url buffer) "/")))
                                        a2ui-mcp--hosts)))
               (and host (a2ui-session-surface-ids (a2ui-tools-host-session host))
                    (not (with-current-buffer buffer (shell-maker-busy)))))
             300)
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
      (princ (format "\n--- surface %s\n%s\n" (a2ui-surface-id surface)
                     (with-current-buffer sbuffer (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))))
      (unless button (princ "FAIL: no Approve button\n") (kill-emacs 1))
      (with-current-buffer sbuffer
        (vui-goto-key (concat (gethash "id" button) "@"))
        (vui-activate))
      (princ "\n=== pressed Approve; the shell gets it as a prompt\n")
      (a2ui-drive-agent-shell--wait (lambda () (with-current-buffer buffer (shell-maker-busy))) 30)
      (a2ui-drive-agent-shell--wait (lambda () (not (with-current-buffer buffer (shell-maker-busy)))) 300)
      (let ((text (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max)))))
        (princ (format "\n--- shell transcript (last part)\n%s\n"
                       (substring text (max 0 (- (length text) 1500)))))
        (if (string-search "User performed action" text)
            (princ "\nPASS: the action reached Claude through agent-shell\n")
          (princ "\nFAIL: the action never reached the shell\n")
          (kill-emacs 1))))))

(provide 'drive-agent-shell)
;;; drive-agent-shell.el ends here
