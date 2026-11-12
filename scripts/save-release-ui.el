;;; save-release-ui.el --- Rebuild .a2ui/release.json -*- lexical-binding: t; -*-

;;; Commentary:

;; Saves examples/release-checklist.jsonl, with its data cleared, as the
;; saved UI .a2ui/release.json, through the same code as save_a2ui.  An
;; agent working in this repository can then recall it as "release".
;; Run it after changing the example's components; a test checks that
;; the two agree.  The README's Development section has the command.

;;; Code:

(require 'a2ui)

(defconst a2ui-save-release-ui--description
  "a2ui.el release checklist.  After recall, fill /version, /bump ([\"patch\"|\"minor\"|\"major\"]), /date (YYYY-MM-DD), /commits ([{sha, subject}] from git log since the last tag), /changelog (a drafted CHANGELOG.md entry) and /intro (one line on what changed); leave /checks/* false until each is verified.  Actions: run_checks (run eldev test and eldev lint, check the Version: header, CHANGELOG.md, README and git status, then set the /checks that pass), show_commit {sha}, release {version, bump, date, changelog} (commit, tag vVERSION and push, after confirming with the user)."
  "What the saved UI tells an agent that lists or recalls it.")

(defun a2ui-save-release-ui ()
  "Write .a2ui/release.json from the release checklist example."
  (let* ((a2ui-library-directory ".a2ui")
         (session (a2ui-session-create :name "save" :directory default-directory))
         (no :false))
    (dolist (m (a2ui-read-jsonl "examples/release-checklist.jsonl"))
      (a2ui-apply-message session m))
    (a2ui-apply-message
     session
     (a2ui-obj "version" "v0.9"
               "updateDataModel"
               (a2ui-obj "surfaceId" "release"
                         "value" (a2ui-obj "intro" "/Recalled from =.a2ui/release.json=.  Fill in the commits and a CHANGELOG draft, then tick the checks as they pass./"
                                           "bump" ["patch"] "version" "" "date" "" "commits" [] "changelog" ""
                                           "checks" (a2ui-obj "tests" no "lint" no "header" no
                                                              "changelog_file" no "readme" no "tree" no)))))
    (princ (format "%s\n" (a2ui-library-save session "release" "release"
                                             a2ui-save-release-ui--description t)))))

(provide 'save-release-ui)
;;; save-release-ui.el ends here
