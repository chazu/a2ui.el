;;; a2ui-library-test.el --- Tests for saved UIs -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise persistence across hosts, discovery, validation and file boundaries.

;;; Code:

(require 'a2ui-hosts-test)
(require 'a2ui-vui-test)

(defmacro a2ui-library-test--with-library (&rest body)
  "Run BODY with an isolated library and host, then remove its files."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "a2ui-library-test-" t))
          (default-directory directory)
          (a2ui-library-directory ".a2ui")
          (host (a2ui-hosts-test--host)))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(ert-deftest a2ui-library-roundtrip-and-action-routing ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "f")))
      (a2ui-set surface "/name" "Zoë")
      (a2ui-set surface "/flags" [t :false nil])
      (setf (a2ui-surface-theme surface) (a2ui-obj "primaryColor" "#123456")
            (a2ui-surface-send-data-model surface) t))
    (should (equal "saved" (gethash "status" (a2ui-json-parse
                                             (a2ui-hosts-test--call
                                              host "save_a2ui"
                                              "{\"surfaceId\":\"f\",\"name\":\"signup\",\"description\":\"Sign up form\"}")))))
    ;; A fresh conversation discovers a file, not an in-memory cache.
    (let* ((fresh (a2ui-hosts-test--host))
           (session (a2ui-tools-host-session fresh))
           (listing (a2ui-json-parse (a2ui-hosts-test--call fresh "list_a2ui" "{}"))))
      (should (equal (gethash "name" (aref (gethash "uis" listing) 0)) "signup"))
      (should (equal (gethash "description" (aref (gethash "uis" listing) 0)) "Sign up form"))
      (should (equal (a2ui-hosts-test--call fresh "recall_a2ui" "{\"name\":\"signup\",\"surfaceId\":\"again\"}")
                     "{\"status\":\"shown\",\"surfaceId\":\"again\"}"))
      (let ((surface (a2ui-session-surface session "again")))
        (should (equal (a2ui-get surface "/name") "Zoë"))
        (should (equal (a2ui-get surface "/flags") [t :false nil]))
        (should (equal (gethash "primaryColor" (a2ui-surface-theme surface)) "#123456"))
        (should (a2ui-surface-send-data-model surface))
        (should (eq (a2ui-surface-catalog surface) (a2ui-catalog 'emacs)))
        (a2ui-set surface "/name" "Grace"))
      (a2ui-hosts-test--press fresh "again" "go")
      (should (string-match-p "Grace" (a2ui-hosts-test--call fresh "a2ui_await_action" "{}")))
      (should-not (a2ui-tools-host-queue host))
      ;; Each recall re-reads the stored values, replacing current state.
      (a2ui-hosts-test--call fresh "recall_a2ui" "{\"name\":\"signup\",\"surfaceId\":\"again\"}")
      (should (equal (a2ui-get (a2ui-session-surface session "again") "/name") "Zoë")))))

(ert-deftest a2ui-library-overwrite-is-explicit ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (a2ui-hosts-test--call host "save_a2ui" "{\"surfaceId\":\"f\",\"name\":\"form\"}")
    (a2ui-set (a2ui-session-surface (a2ui-tools-host-session host) "f") "/name" "Grace")
    (dolist (args '("{\"surfaceId\":\"f\",\"name\":\"form\"}"
                    "{\"surfaceId\":\"f\",\"name\":\"form\",\"overwrite\":false}"))
      (should (string-match-p "already exists" (a2ui-hosts-test--call host "save_a2ui" args))))
    (let ((fresh (a2ui-hosts-test--host)))
      (a2ui-hosts-test--call fresh "recall_a2ui" "{\"name\":\"form\"}")
      (should (equal (a2ui-get (a2ui-session-surface (a2ui-tools-host-session fresh) "f") "/name") "Ada")))
    (should (string-match-p "saved" (a2ui-hosts-test--call host "save_a2ui"
                                                        "{\"surfaceId\":\"f\",\"name\":\"form\",\"overwrite\":true}")))
    (a2ui-hosts-test--call host "recall_a2ui" "{\"name\":\"form\"}")
    (should (equal (a2ui-get (a2ui-session-surface (a2ui-tools-host-session host) "f") "/name") "Grace"))))

(ert-deftest a2ui-library-failed-save-preserves-file ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let* ((session (a2ui-tools-host-session host))
           (file (a2ui-library-save session "f" "form"))
           (before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Write failed"))))
        (should-error (a2ui-library-save session "f" "form" "Changed" t)))
      (should (equal before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (should (equal (directory-files (file-name-directory file) nil directory-files-no-dot-files-regexp)
                     '("form.json"))))))

(ert-deftest a2ui-library-invalid-recall-keeps-live-surface ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let* ((session (a2ui-tools-host-session host))
           (original (a2ui-session-surface session "f"))
           (file (a2ui-library-save session "f" "form"))
           (snapshot (a2ui-library--read file)))
      (dolist (bad '("not json" "{}" "{\"format\":\"a2ui-library\",\"version\":2}"))
        (with-temp-file file (insert bad))
        (should (string-match-p "\"status\":\"error\""
                                (a2ui-hosts-test--call host "recall_a2ui" "{\"name\":\"form\"}")))
        (should (eq original (a2ui-session-surface session "f"))))
      (should (gethash "error" (aref (a2ui-library-list session) 0)))
      ;; Invalid components and unsupported catalogs cannot partially replace a UI.
      (puthash "components" (vector (a2ui-obj "id" "root" "component" "Unknown"))
               (gethash "surface" snapshot))
      (with-temp-file file (insert (a2ui-json-encode snapshot)))
      (should-error (a2ui-library-recall session "form"))
      (should (eq original (a2ui-session-surface session "f")))
      (puthash "catalogId" "unsupported" (gethash "surface" snapshot))
      (with-temp-file file (insert (a2ui-json-encode snapshot)))
      (should-error (a2ui-library-recall session "form"))
      (should (eq original (a2ui-session-surface session "f"))))))

(ert-deftest a2ui-library-empty-missing-and-failed-render ()
  (a2ui-library-test--with-library
    (should (equal (a2ui-library-list (a2ui-tools-host-session host)) []))
    (should-not (file-exists-p (expand-file-name ".a2ui" directory)))
    (should (string-match-p "error" (a2ui-hosts-test--call host "recall_a2ui" "{\"name\":\"absent\"}")))
    (should (string-match-p "No surface" (a2ui-hosts-test--call host "save_a2ui" "{\"surfaceId\":\"f\",\"name\":\"form\"}")))
    (a2ui-hosts-test--call host "render_a2ui" "{\"surfaceId\":\"f\",\"components\":[{\"id\":\"root\",\"component\":\"Unknown\"}]}")
    (should (string-match-p "failed render" (a2ui-hosts-test--call host "save_a2ui" "{\"surfaceId\":\"f\",\"name\":\"form\"}")))
    (should-not (file-exists-p (expand-file-name ".a2ui" directory)))))

(ert-deftest a2ui-library-confines-names-and-rejects-symlinks ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let ((session (a2ui-tools-host-session host)))
      (dolist (name '("../escape" "/tmp/escape" "a/b" "a\\b" "" "." ".."))
        (should-error (a2ui-library-save session "f" name))
        (should-error (a2ui-library-recall session name)))
      (make-directory (expand-file-name ".a2ui" directory))
      (make-symbolic-link (expand-file-name "outside.json" directory)
                         (expand-file-name ".a2ui/link.json" directory))
      (should-error (a2ui-library-save session "f" "link" nil t))
      (should-error (a2ui-library-recall session "link"))
      (delete-directory (expand-file-name ".a2ui" directory) t)
      (make-directory (expand-file-name "outside" directory))
      (make-symbolic-link (expand-file-name "outside" directory) (expand-file-name ".a2ui" directory))
      (should-error (a2ui-library-save session "f" "form"))
      (should-error (a2ui-library-list session)))))

(ert-deftest a2ui-library-project-root-and-shared-directory ()
  (a2ui-library-test--with-library
    (make-directory (expand-file-name ".git" directory))
    (make-directory (expand-file-name "sub" directory))
    (let* ((default-directory (expand-file-name "sub/" directory))
           (session (a2ui-session-create)))
      (should (equal (a2ui-library-directory session) (expand-file-name ".a2ui/" directory)))
      (let ((a2ui-library-directory (expand-file-name "shared" directory)))
        (should (equal (a2ui-library-directory session) (expand-file-name "shared/" directory)))))))

(ert-deftest a2ui-library-gptel-save-and-recall ()
  (a2ui-library-test--with-library
    (let ((a2ui-tools-host-functions nil)
          (tools (a2ui-gptel-tools)))
      (with-temp-buffer
        (a2ui-hosts-test--gptel-call (car tools) a2ui-hosts-test--form)
        (should (string-match-p "saved" (a2ui-hosts-test--gptel-call
                                        (seq-find (lambda (tool) (equal (gptel-tool-name tool) "save_a2ui")) tools)
                                        "{\"surfaceId\":\"f\",\"name\":\"form\"}"))))
      (with-temp-buffer
        (should (string-match-p "shown" (a2ui-hosts-test--gptel-call
                                        (seq-find (lambda (tool) (equal (gptel-tool-name tool) "recall_a2ui")) tools)
                                        "{\"name\":\"form\"}")))))))

(ert-deftest a2ui-library-mcp-save-and-recall ()
  (skip-unless (executable-find "curl"))
  (a2ui-library-test--with-library
    (a2ui-hosts-test--with-mcp (host url)
      (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
      (dolist (call '(("save_a2ui" "{\"surfaceId\":\"f\",\"name\":\"form\"}" "saved")
                      ("list_a2ui" "{}" "ok")
                      ("recall_a2ui" "{\"name\":\"form\",\"surfaceId\":\"recalled\"}" "shown")
                      ("recall_a2ui" "{\"name\":\"missing\"}" "error")))
        (let* ((result (gethash "result" (a2ui-hosts-test--rpc
                                         url "tools/call"
                                         (a2ui-obj "name" (nth 0 call) "arguments" (a2ui-json-parse (nth 1 call))))))
               (text (gethash "text" (aref (gethash "content" result) 0))))
          (should (equal (gethash "status" (a2ui-json-parse text)) (nth 2 call)))
          (should (eq (gethash "isError" result) (if (equal (nth 2 call) "error") t :false))))))))

(ert-deftest a2ui-library-recall-renders-and-replaces ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (a2ui-library-save (a2ui-tools-host-session host) "f" "form")
    (let* ((fresh (a2ui-hosts-test--host))
           (session (a2ui-tools-host-session fresh))
           (a2ui-vui-auto-show t)
           buffer)
      (a2ui-vui-attach session)
      (unwind-protect
          (save-window-excursion
            (a2ui-library-recall session "form")
            (setq buffer (a2ui-vui-test--buffer session "f"))
            (should (string-match-p "Name: Ada" (a2ui-vui-test--text buffer)))
            (a2ui-set (a2ui-session-surface session "f") "/name" "Grace")
            (a2ui-vui-test--settle buffer)
            (should (string-match-p "Name: Grace" (a2ui-vui-test--text buffer)))
            (a2ui-library-recall session "form")
            (a2ui-vui-test--settle buffer)
            (should (string-match-p "Name: Ada" (a2ui-vui-test--text buffer)))
            (with-current-buffer buffer
              (should (vui-goto-key "go@"))
              (vui-activate))
            (should (string-match-p "Ada" (car (a2ui-tools-host-queue fresh)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest a2ui-library-recall-with-data ()
  (a2ui-library-test--with-library
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "f")))
      (a2ui-set surface "/flags" [t t]))
    (a2ui-hosts-test--call host "save_a2ui" "{\"surfaceId\":\"f\",\"name\":\"form\"}")
    (let ((fresh (a2ui-hosts-test--host)))
      ;; One call recalls the UI and fills it in; keys not named keep their saved values.
      (should (equal (a2ui-hosts-test--call fresh "recall_a2ui"
                                            "{\"name\":\"form\",\"data\":{\"name\":\"Grace\",\"flags\":[false]}}")
                     "{\"status\":\"shown\",\"surfaceId\":\"f\"}"))
      (let ((surface (a2ui-session-surface (a2ui-tools-host-session fresh) "f")))
        (should (equal (a2ui-get surface "/name") "Grace"))
        (should (equal (a2ui-get surface "/flags") [:false])))
      ;; The file keeps what was saved.
      (let ((again (a2ui-hosts-test--host)))
        (a2ui-hosts-test--call again "recall_a2ui" "{\"name\":\"form\"}")
        (should (equal (a2ui-get (a2ui-session-surface (a2ui-tools-host-session again) "f") "/name") "Ada")))
      (should (string-match-p "data must be an object"
                              (a2ui-hosts-test--call fresh "recall_a2ui" "{\"name\":\"form\",\"data\":[1]}"))))))

(provide 'a2ui-library-test)
;;; a2ui-library-test.el ends here
