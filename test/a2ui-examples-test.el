;;; a2ui-examples-test.el --- The examples still render and run -*- lexical-binding: t; -*-

;;; Commentary:

;; Each example in examples/ is driven as a user would: the forms are
;; replayed and their gated buttons pressed, the saved release
;; checklist is recalled, and the Kubernetes rollout is played to the
;; end along each of its decisions.  None of them may draw a
;; validation error.

;;; Code:

(require 'ert)
(require 'a2ui)

(eval-and-compile
  (defconst a2ui-examples-test--root
    (expand-file-name ".." (file-name-directory (macroexp-file-name)))
    "The repository root.")
  (load (expand-file-name "examples/k8s-rollout.el" a2ui-examples-test--root) nil t))

(defun a2ui-examples-test--settle (buffer)
  "Wait until BUFFER has no render pending."
  (let ((root (vui-get-instance buffer)))
    (while (and root (vui-instance-render-timer root)) (sleep-for 0.01))))

(defun a2ui-examples-test--press (buffer key)
  "Press the widget at KEY in BUFFER."
  (with-current-buffer buffer
    (a2ui-examples-test--settle buffer)
    (should (vui-goto-key key))
    (vui-activate)
    (a2ui-examples-test--settle buffer)))

(defmacro a2ui-examples-test--with-session (spec &rest body)
  "Run BODY with a session bound as SPEC says: (SESSION SENT ERRORS).
SENT collects outbound actions and ERRORS outbound errors, newest first."
  (declare (indent 1) (debug t))
  (pcase-let ((`(,session ,sent ,errors) spec))
    `(let* ((a2ui-log-messages nil)
            (,sent nil)
            (,errors nil)
            (,session (a2ui-session-create
                       :name "example"
                       :directory a2ui-examples-test--root
                       :send-action-fn (lambda (m _)
                                         (if (gethash "error" m) (push m ,errors) (push m ,sent))))))
       (a2ui-vui-attach ,session)
       (unwind-protect (progn ,@body)
         (dolist (id (a2ui-session-surface-ids ,session))
           (when-let* ((buffer (car (a2ui-vui--view ,session id))))
             (kill-buffer buffer)))))))

(defun a2ui-examples-test--replay (session file)
  "Replay examples/FILE into SESSION."
  (dolist (m (a2ui-read-jsonl (expand-file-name (concat "examples/" file) a2ui-examples-test--root)))
    (a2ui-apply-message session m)))

(ert-deftest a2ui-examples-intake-form ()
  (a2ui-examples-test--with-session (session sent errors)
    (a2ui-examples-test--replay session "intake-form.jsonl")
    (let ((buffer (car (a2ui-vui--view session "intake")))
          (surface (a2ui-session-surface session "intake")))
      ;; The agent couldn't guess the reviewer, so Start waits for one.
      (a2ui-examples-test--press buffer "start@")
      (should-not sent)
      (a2ui-set surface "/cache/reviewer" "@ada")
      (a2ui-examples-test--press buffer "start@")
      (let ((context (gethash "context" (gethash "action" (car sent)))))
        (should (equal (gethash "reviewer" context) "@ada"))
        (should (equal (gethash "strategy" context) ["inproc"]))
        (should (equal (gethash "budget" context) 64))
        (should (= (length (gethash "sites" context)) 3))))
    (should-not errors)))

(ert-deftest a2ui-examples-release-checklist ()
  (a2ui-examples-test--with-session (session sent errors)
    (a2ui-examples-test--replay session "release-checklist.jsonl")
    (let ((buffer (car (a2ui-vui--view session "release")))
          (surface (a2ui-session-surface session "release")))
      (a2ui-examples-test--press buffer "release_btn@")
      (should-not sent)
      (dolist (check '("tests" "lint" "header" "changelog_file" "readme" "tree"))
        (a2ui-set surface (concat "/checks/" check) t))
      (a2ui-examples-test--press buffer "release_btn@")
      (should (equal (gethash "version" (gethash "context" (gethash "action" (car sent)))) "0.2.0")))
    (should-not errors)))

(ert-deftest a2ui-examples-saved-release-checklist ()
  ;; .a2ui/release.json is the release checklist with its data cleared,
  ;; saved by save_a2ui.  Its components must not drift from the example.
  (a2ui-examples-test--with-session (session sent errors)
    (let ((a2ui-library-directory ".a2ui"))
      (should (equal (a2ui-library-recall session "release") "release"))
      (let ((saved (a2ui-session-surface session "release"))
            (example (a2ui-session-create :name "example")))
        (a2ui-examples-test--replay example "release-checklist.jsonl")
        (should (equal (a2ui-json-encode (a2ui-library--snapshot saved nil))
                       (a2ui-json-encode
                        (let ((s (a2ui-library--snapshot (a2ui-session-surface example "release") nil)))
                          (puthash "data" (a2ui-surface-data saved) (gethash "surface" s))
                          s))))
        (should (equal (a2ui-get saved "/commits") []))
        (should (eq (a2ui-get saved "/checks/tests") :false))))
    (should-not sent)
    (should-not errors)))

(defun a2ui-examples-test--rollout (decide)
  "Play the rollout example to its end, choosing with DECIDE at a pause.
DECIDE is called with the run and its surface buffer.  Return the run."
  (let ((run nil))
    (a2ui-examples-test--with-session (session sent errors)
      (let ((a2ui-k8s-tick-seconds nil)
            (a2ui-k8s--defer #'funcall))
        (setq run (a2ui-k8s-start session))
        (let ((buffer (car (a2ui-vui--view session a2ui-k8s--surface))))
          (a2ui-examples-test--press buffer "start@")
          (should (eq (a2ui-k8s-run-phase run) 'rolling))
          (dotimes (_ 200)
            (unless (eq (a2ui-k8s-run-phase run) 'done)
              (a2ui-k8s--tick run)
              (when (eq (a2ui-k8s-run-phase run) 'decision)
                (funcall decide run buffer))))))
      (ignore sent)
      (should-not errors))
    run))

(defun a2ui-examples-test--steps (run)
  "Return the statuses of RUN's plan steps by id."
  (mapcar (lambda (s) (cons (plist-get s :id) (plist-get s :status))) (a2ui-k8s-run-steps run)))

(ert-deftest a2ui-examples-rollout-accept-fix ()
  (let ((run (a2ui-examples-test--rollout
              (lambda (run buffer)
                (let ((w (a2ui-k8s-run-world run)))
                  ;; Let the user think: the drain stays blocked meanwhile.
                  (dotimes (_ 6) (a2ui-k8s--tick run))
                  (should (> (a2ui-k8s-world-blocked w) 0))
                  (should (string-match-p "OOMKilled" (a2ui-k8s-run-pause-reason run)))
                  ;; RET on the crashing pod describes it.
                  (let ((name (a2ui-k8s-pod-name (a2ui-k8s--crashing-pod run))))
                    (with-current-buffer buffer
                      (a2ui-examples-test--settle buffer)
                      (goto-char (point-min))
                      (search-forward name)
                      (goto-char (match-beginning 0)))
                    (with-current-buffer buffer (vui-activate))
                    (should (equal (a2ui-k8s-run-detail-pod run) name)))
                  (a2ui-examples-test--press buffer "fix@/accept"))))))
    (let ((w (a2ui-k8s-run-world run)))
      (should (eq (a2ui-k8s-run-phase run) 'done))
      (should (a2ui-k8s-run-fixed run))
      (should (equal (a2ui-k8s-rs-limit (a2ui-k8s-world-target w)) 768))
      (should (seq-every-p (lambda (p) (eq (a2ui-k8s-pod-rs p) (a2ui-k8s-world-target w)))
                           (a2ui-k8s-world-pods w)))
      (should (a2ui-k8s-world-drained w))
      (should (seq-every-p (lambda (s) (equal (cdr s) "✓")) (a2ui-examples-test--steps run))))))

(ert-deftest a2ui-examples-rollout-roll-back ()
  (let ((run (a2ui-examples-test--rollout
              (lambda (_run buffer) (a2ui-examples-test--press buffer "undo@")))))
    (should (eq (a2ui-k8s-run-phase run) 'done))
    (should (a2ui-k8s-run-rolled-back run))
    (should (equal (a2ui-k8s-rs-image (a2ui-k8s-world-target (a2ui-k8s-run-world run))) "2.13.4"))
    (should (equal (alist-get 'rollback (a2ui-examples-test--steps run)) "✓"))))

(ert-deftest a2ui-examples-rollout-resume-then-roll-back ()
  ;; Resuming as is buys three more restarts; then the agent asks again.
  (let* ((pauses 0)
         (run (a2ui-examples-test--rollout
               (lambda (_run buffer)
                 (cl-incf pauses)
                 (a2ui-examples-test--press buffer (if (= pauses 1) "resume@" "undo@"))))))
    (should (= pauses 2))
    (should (a2ui-k8s-run-rolled-back run))
    (should (eq (a2ui-k8s-run-phase run) 'done))))

(provide 'a2ui-examples-test)
;;; a2ui-examples-test.el ends here
