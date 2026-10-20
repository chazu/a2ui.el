;;; drive-deploy.el --- Play the deploy example against a live agent -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the whole loop of DESIGN.md's deploy example in batch Emacs,
;; acting as the user through the rendered buffers.  Load this file in
;; batch through Eldev and call `a2ui-drive-deploy' with the arguments
;; URL [RECORD-DIR] left on the command line.
;;
;; URL is an AG-UI endpoint (deploy_agent.py or llm_agent.py).  With
;; RECORD-DIR, each run's raw SSE stream is saved there as
;; deploy-N.sse.  Exits non-zero if a step fails.

;;; Code:

(require 'a2ui)

(defvar a2ui-drive--record-dir nil)
(defvar a2ui-drive--run 0)

(defun a2ui-drive--record (agent chunk)
  "Append CHUNK of AGENT's current run to its recording."
  (ignore agent)
  (when a2ui-drive--record-dir
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region chunk nil (expand-file-name (format "deploy-%d.sse" a2ui-drive--run)
                                              a2ui-drive--record-dir)
                    t 'silent))))

(defun a2ui-drive--wait (agent)
  "Wait for AGENT's run, and the renders it causes, to finish."
  (let ((deadline (+ (float-time) 120)))
    (while (and (a2ui-agui-running-p agent) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (when (a2ui-agui-running-p agent)
      (error "Run timed out"))
    (sleep-for 0.2)))

(defun a2ui-drive--buffer (agent surface-id)
  "Return the buffer showing SURFACE-ID of AGENT, or fail."
  (or (car (a2ui-vui--view (a2ui-agui-agent-session agent) surface-id))
      (error "Surface %s was not shown; surfaces: %S" surface-id
             (a2ui-session-surface-ids (a2ui-agui-agent-session agent)))))

(defun a2ui-drive--show (label buffer)
  "Print BUFFER's text under LABEL."
  (princ (format "\n--- %s\n%s\n" label
                 (with-current-buffer buffer
                   (buffer-substring-no-properties (point-min) (point-max))))))

(defun a2ui-drive--step (title)
  "Announce the step TITLE and count a new run."
  (cl-incf a2ui-drive--run)
  (princ (format "\n=== %d. %s\n" a2ui-drive--run title)))

(defun a2ui-drive--first-key (pred)
  "Move to the first vui element whose key satisfies PRED; return the key."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (let ((key (vui-key-at)))
        (if (and key (funcall pred key))
            (setq found key)
          (goto-char (or (next-single-property-change (point) 'vui-key) (point-max))))))
    found))

(defun a2ui-drive-deploy ()
  "Run the deploy example against the endpoint in `command-line-args-left'."
  (let* ((url (pop command-line-args-left))
         (a2ui-drive--record-dir (pop command-line-args-left))
         (a2ui-agui-agents `(("deploy" :url ,url)))
         (agent (a2ui-agui-connect "deploy")))
    (when a2ui-drive--record-dir
      (make-directory a2ui-drive--record-dir t)
      (dolist (f (directory-files a2ui-drive--record-dir t "\\`\\(deploy-[0-9]+\\.sse\\|input-[0-9]+\\.json\\)\\'"))
        (delete-file f)))
    (advice-add 'a2ui-agui-receive :before #'a2ui-drive--record)
    (add-hook 'a2ui-agui-event-functions
              (lambda (_agent direction object)
                (when (and a2ui-drive--record-dir (eq direction 'out))
                  (let ((coding-system-for-write 'utf-8-unix))
                    (with-temp-file (expand-file-name (format "input-%d.json" a2ui-drive--run)
                                                      a2ui-drive--record-dir)
                      (insert (a2ui-json-encode object)))))))

    (a2ui-drive--step "user asks for a deploy")
    (a2ui-agui-send-message agent "deploy the billing service")
    (a2ui-drive--wait agent)
    (let* ((surface-id (or (car (seq-remove (lambda (id) (string-prefix-p "a2ui-agui-" id))
                                            (a2ui-session-surface-ids (a2ui-agui-agent-session agent))))
                           (error "No surface was rendered")))
           (buffer (a2ui-drive--buffer agent surface-id))
           (surface (a2ui-session-surface (a2ui-agui-agent-session agent) surface-id)))
      (a2ui-drive--show (format "surface %s" surface-id) buffer)

      (a2ui-drive--step "user picks prod, 5 replicas, presses the button")
      (with-current-buffer buffer
        ;; Fill whatever the agent drew: pickers get "prod"-like
        ;; choices, fields get 5, then the first enabled button.
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (let ((choices (all-completions "" collection)))
                       (or (seq-find (lambda (c) (string-match-p "prod" (downcase c))) choices)
                           (car choices))))))
          (dolist (c (hash-table-values (a2ui-surface-components surface)))
            (pcase (gethash "component" c)
              ("ChoicePicker" (when (vui-goto-key (concat (gethash "id" c) "@")) (vui-activate)))
              ("TextField"
               (when-let* ((path (a2ui-binding-path c "value")))
                 (when (string-match-p "replica" (downcase (concat path (gethash "id" c))))
                   (a2ui-set surface path "5")))))))
        (a2ui-vui-test-settle buffer)
        (a2ui-drive--show "filled in" buffer)
        (let ((button (seq-find (lambda (c) (equal (gethash "component" c) "Button"))
                                (hash-table-values (a2ui-surface-components surface)))))
          (unless (vui-goto-key (concat (gethash "id" button) "@"))
            (error "No button"))
          (vui-activate)))
      (a2ui-drive--wait agent)
      (with-current-buffer (a2ui-agui-transcript agent)
        (princ (format "\n--- transcript\n%s\n" (buffer-string))))

      (when-let* ((interrupt (seq-find (lambda (id) (string-prefix-p "a2ui-agui-interrupt-" id))
                                       (a2ui-session-surface-ids (a2ui-agui-agent-session agent)))))
        (let ((ibuffer (a2ui-drive--buffer agent interrupt)))
          (a2ui-vui-test-settle ibuffer)
          (a2ui-drive--show "interrupt" ibuffer)
          (a2ui-drive--step "user approves")
          (with-current-buffer ibuffer
            (vui-goto-key "approve@")
            (vui-activate))
          (a2ui-drive--wait agent)))

      (a2ui-vui-test-settle buffer)
      (a2ui-drive--show (format "final surface %s" surface-id) buffer)
      (with-current-buffer (a2ui-agui-transcript agent)
        (princ (format "\n--- final transcript\n%s\n" (buffer-string))))
      (princ (format "\nagent status: %s, %d messages in history\n"
                     (a2ui-agui-agent-status agent) (length (a2ui-agui-agent-messages agent))))
      (unless (member (a2ui-agui-agent-status agent) '("idle"))
        (kill-emacs 1)))))

(defun a2ui-vui-test-settle (buffer)
  "Wait until the vui root in BUFFER has no render pending."
  (let ((root (vui-get-instance buffer))
        (deadline (+ (float-time) 5)))
    (while (and root (vui-instance-render-timer root) (< (float-time) deadline))
      (sleep-for 0.01))))

(provide 'drive-deploy)
;;; drive-deploy.el ends here
