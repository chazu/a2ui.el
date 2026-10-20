;;; drive-mcp.el --- Try the MCP endpoint with Claude Code or Codex -*- lexical-binding: t; -*-

;;; Commentary:

;; Starts the a2ui MCP endpoint in batch Emacs, runs a terminal agent
;; headless against it, and plays the user: once a surface is shown and
;; the agent waits in a2ui_await_action, press its Approve-like button.
;; Load this file through Eldev and call `a2ui-drive-mcp' with CLIENT
;; (claude or codex) and optionally PROMPT left on the command line.

;;; Code:

(require 'a2ui)

(defconst a2ui-drive-mcp--prompt
  "I'm about to merge a change to the billing service: values.yaml bumps replicas from 3 to 5 and the image from billing:1.8 to billing:1.9. Show me a review surface in Emacs with the diff and Approve/Reject buttons, wait for my decision, then tell me in one sentence what I chose."
  "The request sent to the agent.")

(defun a2ui-drive-mcp--command (client url prompt)
  "Return the command running CLIENT headless on PROMPT with endpoint URL."
  (pcase client
    ("claude"
     (list "claude" "-p" prompt "--output-format" "text"
           "--model" (or (getenv "CLAUDE_MODEL") "sonnet")
           "--tools" "" "--setting-sources" "" "--no-session-persistence"
           "--strict-mcp-config"
           "--mcp-config" (a2ui-json-encode
                           (a2ui-obj "mcpServers" (a2ui-obj "a2ui" (a2ui-obj "type" "http" "url" url))))
           "--allowedTools" "mcp__a2ui"))
    ("codex"
     (list "codex" "exec" "--skip-git-repo-check" "--sandbox" "read-only"
           "-c" (format "mcp_servers.a2ui.url=%S" url)
           "-c" "mcp_servers.a2ui.tool_timeout_sec=300"
           ;; codex exec never asks, so a2ui's tools must be approved up front.
           "-c" "mcp_servers.a2ui.default_tools_approval_mode=\"approve\""
           prompt))
    (_ (error "Unknown client %s" client))))

(defun a2ui-drive-mcp--press (host)
  "Press the Approve-like button of HOST's newest surface; return its key."
  (let* ((session (a2ui-tools-host-session host))
         (surface (a2ui-session-surface session (car (last (a2ui-session-surface-ids session)))))
         (buffer (car (a2ui-vui--view session (a2ui-surface-id surface))))
         (components (hash-table-values (a2ui-surface-components surface)))
         (diff (seq-find (lambda (c) (and (equal (gethash "component" c) "Diff") (gethash "acceptAction" c)))
                         components))
         (buttons (seq-filter (lambda (c) (equal (gethash "component" c) "Button")) components))
         (button (or (seq-find (lambda (c)
                                 (string-match-p "approve\\|accept\\|merge\\|yes"
                                                 (downcase (concat (gethash "id" c) " "
                                                                   (a2ui-vui-label surface (gethash "child" c) nil)))))
                               buttons)
                     (car buttons)))
         (key (cond (button (concat (gethash "id" button) "@"))
                    (diff (concat (gethash "id" diff) "@/accept")))))
    (with-current-buffer buffer
      (let ((root (vui-get-instance buffer)))
        (while (vui-instance-render-timer root) (sleep-for 0.01)))
      (princ (format "\n--- surface %s (%s)\n%s\n" (a2ui-surface-id surface)
                     (string-join (seq-uniq (mapcar (lambda (c) (gethash "component" c)) components)) " ")
                     (string-trim-right (buffer-substring-no-properties (point-min) (point-max)))))
      (when (and key (vui-goto-key key))
        (vui-activate)
        key))))

(defun a2ui-drive-mcp ()
  "Run the agent named on the command line against the a2ui endpoint."
  (let* ((client (pop command-line-args-left))
         (prompt (or (pop command-line-args-left) a2ui-drive-mcp--prompt))
         (a2ui-log-messages nil)
         (url (save-window-excursion (a2ui-mcp-start)))
         (host a2ui-mcp-host)
         (out (generate-new-buffer " *agent*"))
         ;; An empty directory, so the agent has nothing to explore first.
         (default-directory (file-name-as-directory (make-temp-file "a2ui-drive" t)))
         (proc (make-process :name client :buffer out :noquery t :sentinel #'ignore
                             :connection-type 'pipe
                             :command (a2ui-drive-mcp--command client url prompt)))
         (deadline (+ (float-time) 600))
         pressed)
    (process-send-eof proc)
    (princ (format "client: %s\nendpoint: %s\n" client url))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (when (and (not pressed) (a2ui-tools-host-waiters host)
                 (a2ui-session-surface-ids (a2ui-tools-host-session host)))
        (sleep-for 0.3)
        (setq pressed (a2ui-drive-mcp--press host))
        (princ (format "\n=== pressed %s while the agent waited\n" pressed))))
    (princ (format "\n--- agent output\n%s\n" (with-current-buffer out (string-trim (buffer-string)))))
    (if (and pressed (zerop (process-exit-status proc)))
        (princ "\nPASS: surface shown, action delivered through a2ui_await_action\n")
      (princ (format "\nFAIL: pressed=%s exit=%s\n" pressed (process-exit-status proc)))
      (kill-emacs 1))))

(provide 'drive-mcp)
;;; drive-mcp.el ends here
