;;; drive-catalog.el --- Check that an agent uses the Emacs catalog -*- lexical-binding: t; -*-

;;; Commentary:

;; Milestone 4's done-check, in batch Emacs: send a model-backed agent
;; a request that calls for review UI, list the component types of the
;; surface it draws, and succeed when at least three come from the
;; Emacs catalog.  Then act as the user (fill pickers, press Accept or
;; the first button) and show how the agent answers.  Load this file
;; through Eldev and call `a2ui-drive-catalog' with URL [PROMPT] left
;; on the command line.

;;; Code:

(require 'a2ui)

(defconst a2ui-drive-catalog--prompt
  "I'm about to merge a change to the billing service: values.yaml bumps replicas from 3 to 5 and the image from billing:1.8 to billing:1.9, and deploy.sh gains a health check (curl -f localhost:8080/healthz) after the rollout. Show me something to review it with, then let me approve or reject it."
  "A request that calls for review UI without naming components.")

(defconst a2ui-drive-catalog--emacs-types
  '("Section" "Table" "Diff" "Code" "Picker" "FileRef" "OrgText")
  "The component types only the Emacs catalog has.")

(defun a2ui-drive-catalog--wait (agent)
  "Wait for AGENT's run, and any automatic retries, to finish."
  (let ((deadline (+ (float-time) 300)))
    (while (and (a2ui-agui-running-p agent) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (sleep-for 0.3)
    (while (and (a2ui-agui-running-p agent) (< (float-time) deadline))
      (accept-process-output nil 0.1))))

(defun a2ui-drive-catalog--settle (buffer)
  "Wait until BUFFER's vui root has no render pending."
  (when-let* ((root (vui-get-instance buffer)))
    (while (vui-instance-render-timer root) (sleep-for 0.01))))

(defun a2ui-drive-catalog--print (label buffer)
  "Print BUFFER's text under LABEL."
  (a2ui-drive-catalog--settle buffer)
  (princ (format "\n--- %s\n%s\n" label
                 (with-current-buffer buffer
                   (string-trim-right (buffer-substring-no-properties (point-min) (point-max)))))))

(defun a2ui-drive-catalog ()
  "Run the Emacs catalog check against the endpoint on the command line."
  (let* ((url (pop command-line-args-left))
         (prompt (or (pop command-line-args-left) a2ui-drive-catalog--prompt))
         (a2ui-log-messages nil)
         (a2ui-agui-agents `(("claude" :url ,url)))
         (agent (a2ui-agui-connect "claude"))
         (session (a2ui-agui-agent-session agent)))
    (princ (format "prompt: %s\n" prompt))
    (a2ui-agui-send-message agent prompt)
    (a2ui-drive-catalog--wait agent)
    (let* ((ids (seq-remove (lambda (id) (string-prefix-p "a2ui-agui-" id))
                            (a2ui-session-surface-ids session)))
           (surface (and ids (a2ui-session-surface session (car ids)))))
      (with-current-buffer (a2ui-agui-transcript agent)
        (princ (format "\n--- transcript\n%s\n" (buffer-string))))
      (unless surface
        (princ "\nFAIL: no surface was drawn\n")
        (kill-emacs 1))
      (let* ((components (hash-table-values (a2ui-surface-components surface)))
             (types (seq-uniq (mapcar (lambda (c) (gethash "component" c)) components)))
             (emacs (seq-filter (lambda (ty) (member ty a2ui-drive-catalog--emacs-types)) types))
             (buffer (car (a2ui-vui--view session (a2ui-surface-id surface)))))
        (princ (format "\ncatalog: %s\ncomponents: %d, types: %s\nEmacs catalog types: %s\nrender retries: %d\n"
                       (a2ui-catalog-id (a2ui-surface-catalog surface))
                       (length components) (string-join (sort types #'string<) " ")
                       (string-join emacs " ") (a2ui-agui-agent-retries agent)))
        (a2ui-drive-catalog--print (format "surface %s" (a2ui-surface-id surface)) buffer)

        ;; Act as the user: choose the first option of every picker,
        ;; then accept the diff or press the first button.
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _) (car (all-completions "" collection)))))
            (dolist (c components)
              (when (member (gethash "component" c) '("Picker" "ChoicePicker"))
                (when (vui-goto-key (concat (gethash "id" c) "@"))
                  (vui-activate)
                  (a2ui-drive-catalog--settle buffer)))))
          (let* ((diff (seq-find (lambda (c) (and (equal (gethash "component" c) "Diff")
                                                  (gethash "acceptAction" c)))
                                 components))
                 (buttons (seq-filter (lambda (c) (equal (gethash "component" c) "Button")) components))
                 (button (or (seq-find (lambda (c)
                                         (string-match-p "approve\\|accept\\|merge\\|yes"
                                                         (downcase (concat (gethash "id" c) " "
                                                                           (a2ui-vui-label surface (gethash "child" c) nil)))))
                                       buttons)
                             (car buttons)))
                 (key (cond (diff (concat (gethash "id" diff) "@/accept"))
                            (button (concat (gethash "id" button) "@")))))
            (when (and key (vui-goto-key key))
              (princ (format "\n=== pressing %s\n" key))
              (vui-activate))))
        (a2ui-drive-catalog--wait agent)
        (with-current-buffer (a2ui-agui-transcript agent)
          (princ (format "\n--- transcript after the action\n%s\n" (buffer-string))))
        (a2ui-drive-catalog--print "surface after the action" buffer)
        (princ (format "\nagent status: %s\n" (a2ui-agui-agent-status agent)))
        (if (>= (length emacs) 3)
            (princ (format "\nPASS: %d Emacs catalog component types\n" (length emacs)))
          (princ (format "\nFAIL: only %d Emacs catalog component types\n" (length emacs)))
          (kill-emacs 1))))))

(provide 'drive-catalog)
;;; drive-catalog.el ends here
