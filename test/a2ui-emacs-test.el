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

;;;; Tones and gauges

(ert-deftest a2ui-emacs-table-tones-bars-and-sparklines ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Table\",\"rows\":{\"path\":\"/r\"},\"columns\":[{\"label\":\"Pod\",\"key\":\"pod\",\"toneKey\":\"tone\"},{\"label\":\"Mem\",\"key\":\"mem\",\"display\":\"bar\",\"max\":512},{\"label\":\"Trend\",\"key\":\"trend\",\"display\":\"sparkline\",\"min\":0,\"max\":8},{\"label\":\"Note\",\"key\":\"note\",\"display\":\"bar\"}]}]"
                                                "{\"r\":[{\"pod\":\"ok-pod\",\"tone\":\"success\",\"mem\":256,\"trend\":[0,4,8],\"note\":\"n/a\"},{\"pod\":\"bad-pod\",\"tone\":\"nonsense\",\"mem\":600,\"trend\":[8,null,0],\"note\":0.5}]}"
                                                a2ui-emacs-catalog-id))
    (let ((text (a2ui-vui-test--text buffer)))
      ;; A bar is scaled to the column's max and clamped; a sparkline
      ;; to its min and max, with a gap for null.
      (should (string-search "ok-pod  ████░░░░ ▁▅█" text))
      (should (string-search "bad-pod ████████ █ ▁" text))
      ;; A cell that isn't a number shows as text.
      (should (string-search "n/a" text)))
    (should (a2ui-emacs-test--face-at "ok-pod" 'a2ui-tone-success))
    ;; An unknown tone is ignored.
    (goto-char (point-min))
    (search-forward "bad-pod")
    (should-not (get-text-property (match-beginning 0) 'face))))

(ert-deftest a2ui-emacs-gauges ()
  (should (equal (a2ui-emacs-bar 0.5 4) "██░░"))
  (should (equal (a2ui-emacs-bar 2 4) "████"))
  (should (equal (a2ui-emacs-bar -1 4) "░░░░"))
  (should (equal (a2ui-emacs-sparkline [1 2 "x" 3]) "▁▅ █"))
  (should (equal (a2ui-emacs-sparkline [5 5]) "▄▄"))
  (should (equal (a2ui-emacs-sparkline []) ""))
  (should (eq (get-text-property 0 'face (a2ui-emacs-sparkline [1 2] nil nil 'a2ui-tone-error))
              'a2ui-tone-error)))

;;;; Text tone and visibility

(ert-deftest a2ui-emacs-text-tone ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\",\"b\"]},{\"id\":\"a\",\"component\":\"Text\",\"text\":\"Healthy\",\"tone\":\"success\"},{\"id\":\"b\",\"component\":\"Text\",\"variant\":\"h3\",\"text\":\"Status\",\"tone\":{\"path\":\"/tone\"}}]"
                                                "{\"tone\":\"error\"}"
                                                a2ui-emacs-catalog-id))
    (should (a2ui-emacs-test--face-at "Healthy" 'a2ui-tone-success))
    ;; A bound tone keeps the variant's face beneath it.
    (should (a2ui-emacs-test--face-at "Status" 'a2ui-tone-error))
    (should (a2ui-emacs-test--face-at "Status" 'a2ui-heading-3))
    (a2ui-set (a2ui-session-surface session "s") "/tone" "warning")
    (a2ui-vui-refresh (a2ui-session-surface session "s"))
    (a2ui-vui-test--settle buffer)
    (should (a2ui-emacs-test--face-at "Status" 'a2ui-tone-warning))))

(ert-deftest a2ui-emacs-visible ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"top\",\"card\",\"row\"]},{\"id\":\"top\",\"component\":\"Text\",\"text\":\"Always\"},{\"id\":\"card\",\"component\":\"Card\",\"child\":\"inner\",\"visible\":{\"path\":\"/show\"}},{\"id\":\"inner\",\"component\":\"Text\",\"text\":\"Decision\"},{\"id\":\"row\",\"component\":\"Row\",\"children\":[\"x\",\"y\",\"z\"]},{\"id\":\"x\",\"component\":\"Text\",\"text\":\"X\"},{\"id\":\"y\",\"component\":\"Text\",\"text\":\"Y\",\"visible\":false},{\"id\":\"z\",\"component\":\"Text\",\"text\":\"Z\"}]"
                                                "{\"show\":false}"
                                                a2ui-emacs-catalog-id))
    (let ((surface (a2ui-session-surface session "s")))
      ;; A hidden child takes no room, and its children go with it.
      (should (equal (a2ui-vui-test--text buffer) "Always\nX  Z"))
      (a2ui-set surface "/show" t)
      (a2ui-vui-refresh surface)
      (a2ui-vui-test--settle buffer)
      (should (string-search "Decision" (a2ui-vui-test--text buffer)))
      (should-not (a2ui-vui-test--errors)))))

;;;; Diff hunks and Ediff

(defconst a2ui-emacs-test--two-hunks
  "--- a/x.txt\n+++ b/x.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n@@ -8,3 +8,4 @@\n eight\n-nine\n+NINE\n+nine and a half\n ten\n"
  "A diff of `a2ui-emacs-test--ten' with two hunks.")

(defconst a2ui-emacs-test--ten
  "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
  "Ten lines.")

(ert-deftest a2ui-emacs-diff-apply ()
  (should (equal (a2ui-emacs-diff-apply a2ui-emacs-test--ten a2ui-emacs-test--two-hunks)
                 "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nnine and a half\nten\n"))
  (should (equal (a2ui-emacs-diff-apply a2ui-emacs-test--ten a2ui-emacs-test--two-hunks '(1))
                 "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nnine and a half\nten\n"))
  ;; Lines that moved are found nearby, as patch does.
  (should (equal (a2ui-emacs-diff-apply (concat "zero\n" a2ui-emacs-test--ten) a2ui-emacs-test--two-hunks '(0))
                 (concat "zero\none\nTWO\nthree\n" (substring a2ui-emacs-test--ten 14))))
  ;; A pure insertion goes after its line.
  (should (equal (a2ui-emacs-diff-apply "a\nb\n" "@@ -1,0 +2,1 @@\n+inserted\n") "a\ninserted\nb\n"))
  (should-error (a2ui-emacs-diff-apply "nothing like it\n" a2ui-emacs-test--two-hunks) :type 'a2ui-error))

(ert-deftest a2ui-emacs-diff-hunk-selection ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Diff\",\"file\":\"x.txt\",\"diff\":{\"path\":\"/d\"},\"selection\":{\"path\":\"/hunks\"},\"acceptAction\":{\"event\":{\"name\":\"apply\",\"context\":{\"hunks\":{\"path\":\"/hunks\"}}}}}]"
                                                (format "{\"d\":%s}" (a2ui-json-encode a2ui-emacs-test--two-hunks))
                                                a2ui-emacs-catalog-id))
    (let ((surface (a2ui-session-surface session "s")))
      ;; Unset means every hunk.
      (should (string-search "[X] @@ -1,3" (a2ui-vui-test--text buffer)))
      (should (string-search "2 of 2 hunks" (a2ui-vui-test--text buffer)))
      (a2ui-vui-test--press "root@/hunk/0")
      (should (equal (a2ui-get surface "/hunks") [1]))
      (a2ui-vui-test--settle buffer)
      (should (string-search "[ ] @@ -1,3" (a2ui-vui-test--text buffer)))
      (should (string-search "1 of 2 hunks" (a2ui-vui-test--text buffer)))
      ;; The hunk left out is dimmed.
      (should (a2ui-emacs-test--face-at "+TWO" 'a2ui-emacs-hunk-off))
      (should-not (a2ui-emacs-test--face-at "+NINE" 'a2ui-emacs-hunk-off))
      (a2ui-vui-test--press "root@/hunk/0")
      (should (equal (a2ui-get surface "/hunks") [0 1]))
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "root@/accept")
      (should (equal (gethash "hunks" (gethash "context" (car (a2ui-vui-test--actions)))) [0 1]))
      ;; No file on disk, so no Ediff.
      (should-not (vui-goto-key "root@/ediff")))))

(ert-deftest a2ui-emacs-diff-ediff-edits ()
  (let ((dir (make-temp-file "a2ui-emacs" t)))
    (unwind-protect
        (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                      "[{\"id\":\"root\",\"component\":\"Diff\",\"file\":\"x.txt\",\"diff\":{\"path\":\"/d\"},\"edited\":{\"path\":\"/mine\"}}]"
                                                      (format "{\"d\":%s}" (a2ui-json-encode a2ui-emacs-test--two-hunks))
                                                      a2ui-emacs-catalog-id))
          (setf (a2ui-session-directory session) dir)
          (with-temp-file (expand-file-name "x.txt" dir) (insert a2ui-emacs-test--ten))
          (a2ui-vui-refresh (a2ui-session-surface session "s"))
          (a2ui-vui-test--settle buffer)
          ;; The file exists, so Ediff is offered.
          (should (vui-goto-key "root@/ediff"))
          (let* ((surface (a2ui-session-surface session "s"))
                 (proposed (a2ui-emacs-diff-apply a2ui-emacs-test--ten a2ui-emacs-test--two-hunks))
                 (mine (string-replace "TWO" "Two" proposed)))
            ;; What quitting Ediff does with an edit to the proposed copy.
            (a2ui-emacs-diff-edited surface "/mine" a2ui-emacs-test--ten mine "x.txt")
            (a2ui-vui-test--settle buffer)
            (should (string-search "+Two" (a2ui-get surface "/mine")))
            (should (string-search "+++ b/x.txt" (a2ui-get surface "/mine")))
            ;; The Diff now shows the user's edit, and it applies.
            (should (string-search "Edited by you in Ediff" (a2ui-vui-test--text buffer)))
            (should (string-search "+Two" (a2ui-vui-test--text buffer)))
            (should (equal (a2ui-emacs-diff-apply a2ui-emacs-test--ten (a2ui-get surface "/mine")) mine))
            ;; The file itself is untouched.
            (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "x.txt" dir)) (buffer-string))
                           a2ui-emacs-test--ten))))
      (delete-directory dir t))))

(ert-deftest a2ui-emacs-ediff-trusts-only-major-modes ()
  (should (eq (a2ui-emacs--file-mode "a.py") 'python-mode))
  (should-not (a2ui-emacs--file-mode "a.unknown-extension")))

;;;; Catalog

(ert-deftest a2ui-emacs-catalog-is-a-superset ()
  (let* ((session (a2ui-session-create :catalogs '(emacs)))
         (sent nil))
    (setf (a2ui-session-send-action-fn session) (lambda (m _) (push m sent)))
    (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S}}"
                                        a2ui-emacs-catalog-id))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"root\",\"component\":\"Text\",\"text\":{\"call\":\"formatString\",\"args\":{\"value\":\"n=${/n}\"}}},{\"id\":\"t\",\"component\":\"Tabs\",\"tabs\":[{\"title\":\"A\",\"child\":\"d\"}]},{\"id\":\"d\",\"component\":\"Diff\",\"diff\":\"\"},{\"id\":\"b\",\"component\":\"Blink\"}]}}")
    (let ((surface (a2ui-session-surface session "s")))
      ;; Basic components and functions work beside the Emacs ones.
      (a2ui-set surface "/n" 3)
      (should (equal (a2ui-resolve-prop (a2ui-surface-component surface "root") "text" surface) "n=3"))
      (should (a2ui-surface-component surface "d"))
      (should (a2ui-surface-component surface "t"))
      (should-not (a2ui-surface-component surface "b"))
      (should (string-match-p "Unknown component type Blink"
                              (gethash "message" (gethash "error" (car sent))))))))

(ert-deftest a2ui-emacs-digest ()
  (let ((basic (a2ui-catalog-digest (a2ui-catalog 'basic)))
        (emacs (a2ui-catalog-digest (a2ui-catalog 'emacs))))
    (should (string-match-p "^Table: columns:" emacs))
    (should (string-match-p "^TextField: label:str" emacs))
    (should (string-match-p "^Tabs: tabs:\\[{title:str child:id}]  (only the selected" emacs))
    (should (string-match-p "^Modal: trigger:id content:id  (" emacs))
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
