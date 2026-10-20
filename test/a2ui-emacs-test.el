;;; a2ui-emacs-test.el --- Tests for the Emacs catalog -*- lexical-binding: t; -*-

;;; Commentary:

;; Interaction tests for the Emacs catalog's components.  Their render
;; snapshots are in a2ui-vui-test.el (fixtures/catalog/).

;;; Code:

(require 'ert)
(require 'a2ui)
(require 'a2ui-vui-test)

(defun a2ui-emacs-test--face-at (text face)
  "Return non-nil when FACE is on the first occurrence of TEXT in the buffer."
  (goto-char (point-min))
  (and (search-forward text nil t)
       (memq face (flatten-tree (get-text-property (match-beginning 0) 'face)))))

(ert-deftest a2ui-emacs-section-folds ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Section"))
    (let ((surface (a2ui-session-surface session "s")))
      (should-not (string-search "Hidden" (a2ui-vui-test--text buffer)))
      (a2ui-vui-test--press "shut@")
      (a2ui-vui-test--settle buffer)
      (should (string-search "▾ Advanced\n  Hidden" (a2ui-vui-test--text buffer)))
      ;; TAB on a heading folds too.
      (should (vui-goto-key "open@"))
      (call-interactively (key-binding (kbd "TAB")))
      (a2ui-vui-test--settle buffer)
      (should-not (string-search "Shown by default" (a2ui-vui-test--text buffer)))
      ;; A bound section writes its state.
      (a2ui-vui-test--press "bound@")
      (should (eq (a2ui-get surface "/folded") t)))))

(ert-deftest a2ui-emacs-table-select-and-act ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Table"))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--press "pick@/select/0")
      (should (equal (a2ui-get surface "/chosen") ["search" "billing"]))
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "pick@/select/1")
      (should (equal (a2ui-get surface "/chosen") ["billing"]))
      (a2ui-vui-test--settle buffer)
      ;; RET on a row: paths in the action resolve against that row.
      (a2ui-vui-test--press "pick@/row/1")
      (let ((action (car (a2ui-vui-test--actions))))
        (should (equal (gethash "name" action) "open"))
        (should (equal (gethash "sourceComponentId" action) "pick"))
        (should (equal (gethash "service" (gethash "context" action)) "search"))))))

(ert-deftest a2ui-emacs-table-single-selection ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Table\",\"columns\":[{\"label\":\"N\",\"key\":\"n\"}],\"rows\":{\"path\":\"/r\"},\"selectable\":\"single\",\"selection\":{\"path\":\"/sel\"}}]"
                                                "{\"r\":[{\"n\":\"a\"},{\"n\":\"b\"}]}"
                                                a2ui-emacs-catalog-id))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--press "root@/select/1")
      (should (equal (a2ui-get surface "/sel") 1))
      (a2ui-vui-test--settle buffer)
      (should (string-search "(•) b" (a2ui-vui-test--text buffer))))))

(ert-deftest a2ui-emacs-diff ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Diff"))
    (should (a2ui-emacs-test--face-at "replicas: 5" 'diff-added))
    (should (a2ui-emacs-test--face-at "replicas: 3" 'diff-removed))
    (a2ui-vui-test--press "root@/accept")
    (a2ui-vui-test--press "root@/reject")
    (should (equal (mapcar (lambda (a) (list (gethash "name" a) (gethash "sourceComponentId" a)))
                           (a2ui-vui-test--actions))
                   '(("apply" "root") ("discard" "root"))))))

(ert-deftest a2ui-emacs-code ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Code"))
    (should (a2ui-emacs-test--face-at "def" 'font-lock-keyword-face))
    (should (a2ui-emacs-test--face-at "defun" 'font-lock-keyword-face))
    (goto-char (point-min))
    (search-forward "plain text")
    (should-not (get-text-property (match-beginning 0) 'face))))

(ert-deftest a2ui-emacs-code-only-trusts-major-modes ()
  (should (eq (a2ui-emacs--mode-for "python") 'python-mode))
  (should (eq (a2ui-emacs--mode-for "elisp") 'emacs-lisp-mode))
  ;; LANGUAGE-mode is only used when it is a major mode.
  (should (eq (a2ui-emacs--mode-for "css") 'css-mode))
  (should-not (a2ui-emacs--mode-for "server"))
  (should-not (a2ui-emacs--mode-for "auto-fill"))
  (should-not (a2ui-emacs--mode-for "no-such-language")))

(ert-deftest a2ui-emacs-picker ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Picker"))
    (let ((surface (a2ui-session-surface session "s")) (offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (push (cons prompt (all-completions "" collection)) offered)
                   (if (string-prefix-p "Environment" prompt) "prod" "US"))))
        (a2ui-vui-test--press "env@")
        (a2ui-vui-test--press "none@"))
      (should (equal (reverse offered) '(("Environment: " "staging" "prod") ("Region: " "Europe" "US"))))
      (should (equal (a2ui-get surface "/env") "prod"))
      (should (equal (a2ui-get surface "/region") "us")))))

(ert-deftest a2ui-emacs-file-ref ()
  (let ((dir (make-temp-file "a2ui-emacs" t)))
    (unwind-protect
        (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "FileRef"))
          (setf (a2ui-session-directory session) dir)
          (with-temp-file (expand-file-name "a2ui-core.el" dir)
            (dotimes (i 50) (insert (format "line %d\n" (1+ i)))))
          (a2ui-vui-test--press "line@")
          (let ((visited (get-file-buffer (expand-file-name "a2ui-core.el" dir))))
            (should visited)
            (with-current-buffer visited
              (should (= (line-number-at-pos) 42))
              (should (looking-at "line 42")))
            (kill-buffer visited)))
      (delete-directory dir t))))

(ert-deftest a2ui-emacs-org-text ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "OrgText"))
    (should (a2ui-emacs-test--face-at "Release notes" 'org-level-1))
    (should (a2ui-emacs-test--face-at "three" 'bold))
    (should (a2ui-emacs-test--face-at "Project page" 'org-link))))

;;;; Catalog

(ert-deftest a2ui-emacs-catalog-is-a-superset ()
  (let* ((session (a2ui-session-create :catalogs '(emacs)))
         (sent nil))
    (setf (a2ui-session-send-action-fn session) (lambda (m _) (push m sent)))
    (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S}}"
                                        a2ui-emacs-catalog-id))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"root\",\"component\":\"Text\",\"text\":{\"call\":\"formatString\",\"args\":{\"value\":\"n=${/n}\"}}},{\"id\":\"t\",\"component\":\"Tabs\",\"tabs\":[]},{\"id\":\"d\",\"component\":\"Diff\",\"diff\":\"\"}]}}")
    (let ((surface (a2ui-session-surface session "s")))
      ;; Basic components and functions work; Tabs is not offered.
      (a2ui-set surface "/n" 3)
      (should (equal (a2ui-resolve-prop (a2ui-surface-component surface "root") "text" surface) "n=3"))
      (should (a2ui-surface-component surface "d"))
      (should-not (a2ui-surface-component surface "t"))
      (should (string-match-p "Unknown component type Tabs"
                              (gethash "message" (gethash "error" (car sent))))))))

(ert-deftest a2ui-emacs-digest ()
  (let ((basic (a2ui-catalog-digest (a2ui-catalog 'basic)))
        (emacs (a2ui-catalog-digest (a2ui-catalog 'emacs))))
    (should (string-match-p "^Table: columns:" emacs))
    (should (string-match-p "^TextField: label:str" emacs))
    (should-not (string-match-p "^Tabs:" emacs))
    (should (string-match-p "^Functions: required(value:any)" emacs))
    ;; A digest is several times smaller than the schema it describes.
    (dolist (c '(basic emacs))
      (should (< (* 5 (length (a2ui-catalog-digest (a2ui-catalog c))))
                 (length (a2ui-json-encode (gethash "components" (a2ui-catalog-schema (a2ui-catalog c))))))))
    (should (< (length basic) (length emacs)))))

(ert-deftest a2ui-emacs-top-catalogs ()
  (let ((session (a2ui-session-create :catalogs '(basic emacs))))
    (should (equal (mapcar #'a2ui-catalog-name (a2ui-session-top-catalogs session)) '(emacs)))))

(provide 'a2ui-emacs-test)
;;; a2ui-emacs-test.el ends here
