;;; example-gifs.el --- Record the examples' GIF frames -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives each example in examples/ through the real renderer, as a
;; user would, and records frames with scripts/demo-gif.el's recorder:
;; the Kubernetes rollout to its decision and on to the end, the intake
;; form from guesses to the action, and the release checklist from
;; recall to Tag and push.  scripts/demo-gif.py then draws the GIFs into
;; examples/images/.  The README's Development section has the commands.

;;; Code:

(require 'a2ui)
(eval-and-compile
  (let ((here (file-name-directory (macroexp-file-name))))
    (load (expand-file-name "demo-gif.el" here) nil t)
    (load (expand-file-name "../examples/k8s-rollout.el" here) nil t)))

(defvar a2ui-example-gifs--frames nil
  "Frames recorded so far, newest first.")

(defun a2ui-example-gifs--settle (buffer)
  "Wait until BUFFER has no render pending."
  (let ((root (vui-get-instance buffer)))
    (while (and root (vui-instance-render-timer root)) (sleep-for 0.01))))

(defun a2ui-example-gifs--line (buffer regexp)
  "Return the line, from 0, of BUFFER where REGEXP first matches."
  (a2ui-example-gifs--settle buffer)
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp)
      (1- (line-number-at-pos)))))

(defun a2ui-example-gifs--shot (buffer caption &optional delay top)
  "Record BUFFER under CAPTION for DELAY, scrolled to line TOP."
  (a2ui-example-gifs--settle buffer)
  (push (a2ui-demo-gif--frame buffer caption top nil delay) a2ui-example-gifs--frames))

(defun a2ui-example-gifs--goto (buffer key)
  "Move point in BUFFER to the widget with KEY."
  (a2ui-example-gifs--settle buffer)
  (with-current-buffer buffer
    (unless (vui-goto-key key) (error "No widget %s" key))
    (set-window-point (or (get-buffer-window buffer) (selected-window)) (point))))

(defun a2ui-example-gifs--press (buffer key)
  "Press the widget with KEY in BUFFER."
  (a2ui-example-gifs--goto buffer key)
  (with-current-buffer buffer (vui-activate))
  (a2ui-example-gifs--settle buffer))

(defun a2ui-example-gifs--sent (message)
  "Show outbound MESSAGE in the echo area as the agent receives it."
  (when-let* ((action (gethash "action" message)))
    (setq a2ui-demo-gif--echo
          (format "→ agent: %s %s" (gethash "name" action)
                  (a2ui-json-encode (gethash "context" action))))))

(defmacro a2ui-example-gifs--recording (&rest body)
  "Run BODY with the echo area recorded and no protocol log."
  (declare (indent 0) (debug t))
  `(let ((a2ui-log-messages nil)
         (a2ui-example-gifs--frames nil)
         (echo (lambda (orig fmt &rest args)
                 (when fmt (setq a2ui-demo-gif--echo (apply #'format-message fmt args)))
                 (apply orig fmt args))))
     (setq a2ui-demo-gif--echo "")
     (advice-add 'message :around echo)
     (unwind-protect (progn ,@body)
       (advice-remove 'message echo))))

;;;; The Kubernetes rollout

(defun a2ui-example-gifs-rollout ()
  "Record the rollout: plan, rolling, the decision, the fix, the end."
  (a2ui-example-gifs--recording
    (let* ((a2ui-k8s-tick-seconds nil)
           (a2ui-k8s--defer #'funcall)
           (session (a2ui-session-create :name "rollout-agent"))
           (_ (a2ui-vui-attach session))
           (run (a2ui-k8s-start session))
           (handler (a2ui-session-send-action-fn session))
           (buffer (car (a2ui-vui--view session a2ui-k8s--surface)))
           (tick (lambda (n caption delay &optional every)
                   (dotimes (i n)
                     (a2ui-k8s--tick run)
                     (when (zerop (mod (1+ i) (or every 1)))
                       (a2ui-example-gifs--shot buffer caption delay 0))))))
      (setf (a2ui-session-send-action-fn session)
            (lambda (message metadata)
              (a2ui-example-gifs--sent message)
              (funcall handler message metadata)))
      (a2ui-example-gifs--goto buffer "start@")
      (a2ui-example-gifs--shot buffer "A scripted agent proposes a rollout: plan, manifest diff, options" 400 0)
      (a2ui-example-gifs--press buffer "start@")
      ;; Events are folded to fit the frame; the PDB row tells the drain's story.
      (a2ui-example-gifs--press buffer "events_sec@")
      (with-current-buffer buffer (goto-char (point-min)))
      (a2ui-example-gifs--shot buffer "Start rollout: the options go to the agent" 160 0)
      (setq a2ui-demo-gif--echo "")
      (while (eq (a2ui-k8s-run-phase run) 'rolling)
        (funcall tick 1 "Every second the agent updates the ReplicaSets, pods, telemetry and PDB" 55))
      (pop a2ui-example-gifs--frames)
      (a2ui-example-gifs--shot buffer "2.14.0 runs out of memory: the agent pauses and adds a decision card" 650 0)
      (let ((pods (a2ui-example-gifs--line buffer "^▾ Pods")))
        (a2ui-example-gifs--shot buffer "Too few pods are healthy, so the PDB blocks the autoscaler's node drain" 550
                                 (a2ui-example-gifs--line buffer "^▾ Plan"))
        (let ((name (a2ui-k8s-pod-name (a2ui-k8s--crashing-pod run))))
          (with-current-buffer buffer
            (goto-char (point-min))
            (re-search-forward "^▾ Pods")
            (search-forward name)
            (goto-char (match-beginning 0)))
          (a2ui-example-gifs--shot buffer "RET on a pod asks the agent to describe it" 220 pods)
          (with-current-buffer buffer (vui-activate))
          (a2ui-example-gifs--shot buffer "RET on a pod asks the agent to describe it" 450 pods)))
      (a2ui-example-gifs--press buffer "hide_detail@")
      (setq a2ui-demo-gif--echo "")
      (a2ui-example-gifs--goto buffer "fix@/accept")
      (a2ui-example-gifs--shot buffer "Accept the agent's patch: memory limit 512Mi → 768Mi" 300 0)
      (a2ui-example-gifs--press buffer "fix@/accept")
      (with-current-buffer buffer (goto-char (point-min)))
      (a2ui-example-gifs--shot buffer "Accept the agent's patch: memory limit 512Mi → 768Mi" 160 0)
      (setq a2ui-demo-gif--echo "")
      (while (not (eq (a2ui-k8s-run-phase run) 'done))
        (funcall tick 3 "Revision 9 replaces the 2.13.4 pods and the crashing ones" 60 3))
      (a2ui-example-gifs--shot buffer "Done: the agent sums up and lists follow-ups" 800 0)
      (a2ui-demo-gif--write "k8s-rollout"
                            (list :title "*a2ui: k8s-rollout*" :cols 104 :rows 42
                                  :output "examples/images/k8s-rollout.gif")
                            (reverse a2ui-example-gifs--frames))
      (kill-buffer buffer))))

;;;; The intake form

(defun a2ui-example-gifs-intake ()
  "Record the intake form: guesses, a blocked Start, edits, the action."
  (a2ui-example-gifs--recording
    (let* ((session (a2ui-session-create :name "claude" :send-action-fn
                                         (lambda (m _) (a2ui-example-gifs--sent m))))
           (_ (a2ui-vui-attach session))
           (_ (dolist (m (a2ui-read-jsonl "examples/intake-form.jsonl")) (a2ui-apply-message session m)))
           (buffer (car (a2ui-vui--view session "intake"))))
      (with-current-buffer buffer (goto-char (point-min)))
      (a2ui-example-gifs--shot buffer "Instead of asking in prose, the agent shows what it found and would do" 500)
      (a2ui-example-gifs--press buffer "start@")
      (a2ui-example-gifs--shot buffer "Start is disabled until the form is complete" 300)
      (setq a2ui-demo-gif--echo "")
      (a2ui-example-gifs--press buffer "budget@+")
      (a2ui-example-gifs--shot buffer "Change any guess: a bigger memory budget..." 200)
      (a2ui-example-gifs--press buffer "sites@/select/1")
      (a2ui-example-gifs--shot buffer "...or fewer call sites" 200)
      (a2ui-example-gifs--goto buffer "reviewer@")
      (with-current-buffer buffer
        (unless (widget-field-at (point)) (forward-char 1))
        (goto-char (widget-field-start (widget-field-at (point))))
        (dolist (c (string-to-list "@ada"))
          (insert c)
          (a2ui-example-gifs--shot buffer "Fill in what it couldn't guess" 30)))
      (a2ui-example-gifs--goto buffer "start@")
      (a2ui-example-gifs--shot buffer "Now Start is ready" 200)
      (a2ui-example-gifs--press buffer "start@")
      (a2ui-example-gifs--shot buffer "One press sends the whole spec to the agent as one action" 700)
      (a2ui-demo-gif--write "intake-form"
                            (list :title "*a2ui: intake*" :cols 92
                                  :output "examples/images/intake-form.gif")
                            (reverse a2ui-example-gifs--frames))
      (kill-buffer buffer))))

;;;; The release checklist

(defun a2ui-example-gifs-release ()
  "Record the release checklist: recall, fill in, checks, Tag and push."
  (a2ui-example-gifs--recording
    (let* ((a2ui-library-directory ".a2ui")
           (session (a2ui-session-create :name "release-agent" :directory default-directory
                                         :send-action-fn (lambda (m _) (a2ui-example-gifs--sent m))))
           (_ (a2ui-vui-attach session))
           (_ (a2ui-library-recall session "release"))
           (buffer (car (a2ui-vui--view session "release")))
           (update (lambda (path value)
                     (a2ui-apply-message session (a2ui-obj "version" "v0.9" "updateDataModel"
                                                           (a2ui-obj "surfaceId" "release" "path" path "value" value)))))
           (filled (gethash "value" (gethash "updateDataModel"
                                             (car (last (a2ui-read-jsonl "examples/release-checklist.jsonl")))))))
      (with-current-buffer buffer (goto-char (point-min)))
      (setq a2ui-demo-gif--echo "← agent: recall_a2ui {\"name\":\"release\"}")
      (a2ui-example-gifs--shot buffer "\"Bring back the release checklist\": the agent recalls the saved form" 450)
      (maphash (lambda (k v) (unless (equal k "checks") (funcall update (concat "/" k) v))) filled)
      (setq a2ui-demo-gif--echo "← agent: update_a2ui /version /bump /date /commits /changelog /intro")
      (a2ui-example-gifs--shot buffer "...and fills it in from git log" 500)
      (setq a2ui-demo-gif--echo "")
      (a2ui-example-gifs--press buffer "release_btn@")
      (a2ui-example-gifs--shot buffer "Tag and push stays disabled until every check passes" 300)
      (a2ui-example-gifs--press buffer "run_checks@")
      (a2ui-example-gifs--shot buffer "Run checks for me" 200)
      (dolist (check '("tests" "lint" "header" "changelog_file" "readme" "tree"))
        (funcall update (concat "/checks/" check) t)
        (setq a2ui-demo-gif--echo (format "← agent: update_a2ui /checks/%s true" check))
        (a2ui-example-gifs--shot buffer "The agent runs each check and ticks what passes" 60))
      (setq a2ui-demo-gif--echo "")
      (a2ui-example-gifs--goto buffer "release_btn@")
      (a2ui-example-gifs--shot buffer "Every check passed" 200)
      (a2ui-example-gifs--press buffer "release_btn@")
      (a2ui-example-gifs--shot buffer "Tag and push: the agent gets the version, date and changelog" 700)
      (a2ui-demo-gif--write "release-checklist"
                            (list :title "*a2ui: release*" :cols 92
                                  :output "examples/images/release-checklist.gif")
                            (reverse a2ui-example-gifs--frames))
      (kill-buffer buffer))))

(defun a2ui-example-gifs ()
  "Record every example's frames into docs/."
  (a2ui-example-gifs-rollout)
  (a2ui-example-gifs-intake)
  (a2ui-example-gifs-release))

(provide 'example-gifs)
;;; example-gifs.el ends here
