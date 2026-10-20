;;; a2ui-core-test.el --- Tests for a2ui-core -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the protocol core: pointers, messages, functions,
;; validation and outbound actions.

;;; Code:

(require 'ert)
(require 'a2ui-core)

(defconst a2ui-test--fixtures
  (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))

(defun a2ui-test--json (string)
  "Parse STRING as A2UI JSON."
  (a2ui-json-parse string))

(defvar a2ui-test--outbox (make-hash-table :test 'eq :weakness 'key)
  "Session -> outbound (MESSAGE . METADATA) pairs, newest first.")

(defun a2ui-test--session ()
  "Return a session whose outbound messages are collected."
  (let (session)
    (setq session (a2ui-session-create
                   :name "test"
                   :send-action-fn (lambda (msg meta)
                                     (push (cons msg meta) (gethash session a2ui-test--outbox)))))
    session))

(defun a2ui-test--sent (session)
  "Return the (MESSAGE . METADATA) pairs SESSION sent, oldest first."
  (reverse (gethash session a2ui-test--outbox)))

(defun a2ui-test--errors (session)
  "Return the error objects SESSION sent."
  (delq nil (mapcar (lambda (m) (gethash "error" (car m))) (a2ui-test--sent session))))

(defun a2ui-test--surface (&optional components data)
  "Return a basic-catalog surface with COMPONENTS and DATA (JSON strings)."
  (let ((session (a2ui-test--session)))
    (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S}}"
                                        a2ui-basic-catalog-id))
    (when components
      (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":%s}}"
                                          components)))
    (when data
      (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"value\":%s}}"
                                          data)))
    (a2ui-session-surface session "s")))

(defun a2ui-test--call (surface json &optional scope)
  "Evaluate the FunctionCall JSON against SURFACE in SCOPE."
  (a2ui-resolve (a2ui-test--json json) surface scope))

;;;; JSON

(ert-deftest a2ui-core-json-roundtrip ()
  (let ((v (a2ui-test--json "{\"a\":null,\"b\":false,\"c\":[1,null,true]}")))
    (should (equal (a2ui-json-encode v) "{\"a\":null,\"b\":false,\"c\":[1,null,true]}"))))

(ert-deftest a2ui-core-stringify ()
  (should (equal (a2ui-stringify nil) ""))
  (should (equal (a2ui-stringify t) "true"))
  (should (equal (a2ui-stringify :false) "false"))
  (should (equal (a2ui-stringify 3) "3"))
  (should (equal (a2ui-stringify 3.0) "3"))
  (should (equal (a2ui-stringify 3.5) "3.5"))
  (should (equal (a2ui-stringify [1 "a"]) "[1,\"a\"]")))

;;;; JSON Pointer

(ert-deftest a2ui-core-pointer-get ()
  (let ((data (a2ui-test--json "{\"a\":{\"b\":[10,{\"c\":\"x\"}]},\"s/l\":1,\"t~d\":2}")))
    (should (equal (a2ui-pointer-get data "/a/b/0") 10))
    (should (equal (a2ui-pointer-get data "/a/b/1/c") "x"))
    (should (equal (a2ui-pointer-get data "/s~1l") 1))
    (should (equal (a2ui-pointer-get data "/t~0d") 2))
    (should (eq (a2ui-pointer-get data "/") data))
    (should (null (a2ui-pointer-get data "/missing/deep")))
    (should (null (a2ui-pointer-get data "/a/b/9")))
    (should (null (a2ui-pointer-get data "/a/b/x")))))

(ert-deftest a2ui-core-pointer-relative ()
  (let ((data (a2ui-test--json "{\"employees\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}],\"company\":\"Acme\"}")))
    (should (equal (a2ui-pointer-get data "name" "/employees/1") "Bob"))
    (should (equal (a2ui-pointer-get data "/company" "/employees/1") "Acme"))
    (should (equal (a2ui-pointer-resolve "name" nil) "/name"))
    (should (equal (a2ui-pointer-resolve "" "/employees/0") "/employees/0"))))

(ert-deftest a2ui-core-pointer-set-creates-intermediates ()
  (let ((data (a2ui-pointer-set (make-hash-table :test 'equal) "/a/b/c" 1)))
    (should (equal (a2ui-pointer-get data "/a/b/c") 1))))

(ert-deftest a2ui-core-pointer-set-arrays ()
  (let ((data (a2ui-test--json "{\"xs\":[1,2]}")))
    (setq data (a2ui-pointer-set data "/xs/0" 9))
    (should (equal (a2ui-pointer-get data "/xs") [9 2]))
    (setq data (a2ui-pointer-set data "/xs/-" 3))
    (should (equal (a2ui-pointer-get data "/xs") [9 2 3]))
    (setq data (a2ui-pointer-set data "/xs/5" 6))
    (should (equal (a2ui-pointer-get data "/xs") [9 2 3 nil nil 6]))
    (should-error (a2ui-pointer-set data "/xs/foo" 1) :type 'a2ui-error)))

(ert-deftest a2ui-core-pointer-remove ()
  (let ((data (a2ui-test--json "{\"a\":1,\"xs\":[1,2,3]}")))
    (setq data (a2ui-pointer-remove data "/a"))
    (should (eq (gethash "a" data 'absent) 'absent))
    (setq data (a2ui-pointer-remove data "/xs/1"))
    (should (equal (a2ui-pointer-get data "/xs") [1 nil 3]))
    (setq data (a2ui-pointer-remove data "/nope/deeper"))
    (should (eq (gethash "nope" data 'absent) 'absent))))

;;;; Messages

(ert-deftest a2ui-core-create-surface ()
  (let ((session (a2ui-test--session)))
    (should (equal (a2ui-apply-message
                    session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"x\",\"catalogId\":%S,\"sendDataModel\":true,\"theme\":{\"agentDisplayName\":\"Bot\"}}}"
                                    a2ui-basic-catalog-id))
                   '("x")))
    (let ((surface (a2ui-session-surface session "x")))
      (should (a2ui-surface-send-data-model surface))
      (should (equal (gethash "agentDisplayName" (a2ui-surface-theme surface)) "Bot")))))

(ert-deftest a2ui-core-create-surface-errors ()
  (let ((session (a2ui-test--session))
        (msg (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"x\",\"catalogId\":%S}}"
                     a2ui-basic-catalog-id)))
    (a2ui-apply-message session msg)
    (should-not (a2ui-apply-message session msg))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"y\",\"catalogId\":\"urn:nope\"}}")
    (should-not (a2ui-session-surface session "y"))
    (should (equal (mapcar (lambda (e) (gethash "code" e)) (a2ui-test--errors session))
                   '("SURFACE_EXISTS" "UNSUPPORTED_CATALOG")))))

(ert-deftest a2ui-core-version-dispatch ()
  (let ((session (a2ui-test--session)))
    (should (a2ui-apply-message session (format "{\"version\":\"v0.9.1\",\"createSurface\":{\"surfaceId\":\"a\",\"catalogId\":%S}}"
                                                a2ui-basic-catalog-id)))
    (should-not (a2ui-apply-message session "{\"version\":\"v7\",\"deleteSurface\":{\"surfaceId\":\"a\"}}"))
    (should (equal (gethash "code" (car (a2ui-test--errors session))) "UNSUPPORTED_VERSION"))))

(ert-deftest a2ui-core-update-components-upserts ()
  (let ((surface (a2ui-test--surface "[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"a\"}]")))
    (a2ui-apply-message (a2ui-surface-session surface)
                        "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"b\"},{\"id\":\"other\",\"component\":\"Divider\"}]}}")
    (should (equal (gethash "text" (a2ui-surface-component surface "root")) "b"))
    (should (a2ui-surface-component surface "other"))))

(ert-deftest a2ui-core-update-components-validation ()
  (let* ((surface (a2ui-test--surface
                   (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\",3]},"
                           "{\"id\":\"b\",\"component\":\"Blink\"},"
                           "{\"id\":\"c\",\"component\":\"Button\",\"child\":\"l\"},"
                           "{\"id\":\"d\",\"component\":\"Text\",\"text\":\"ok\"}]")))
         (errors (a2ui-test--errors (a2ui-surface-session surface))))
    (should-not (a2ui-surface-component surface "root"))
    (should-not (a2ui-surface-component surface "b"))
    (should-not (a2ui-surface-component surface "c"))
    (should (a2ui-surface-component surface "d"))
    (should (equal (mapcar (lambda (e) (list (gethash "code" e) (gethash "path" e))) errors)
                   '(("VALIDATION_FAILED" "/components/0/children/1")
                     ("VALIDATION_FAILED" "/components/1/component")
                     ("VALIDATION_FAILED" "/components/2/action"))))
    (should (equal (gethash "surfaceId" (car errors)) "s"))))

(ert-deftest a2ui-core-validation-template-and-tabs ()
  (let* ((surface (a2ui-test--surface
                   (concat "[{\"id\":\"l\",\"component\":\"List\",\"children\":{\"path\":\"/xs\"}},"
                           "{\"id\":\"t\",\"component\":\"Tabs\",\"tabs\":[{\"title\":\"A\",\"child\":7}]}]")))
         (paths (mapcar (lambda (e) (gethash "path" e))
                        (a2ui-test--errors (a2ui-surface-session surface)))))
    (should (equal paths '("/components/0/children/componentId" "/components/1/tabs/0/child")))))

(ert-deftest a2ui-core-update-data-model ()
  (let* ((surface (a2ui-test--surface nil "{\"user\":{\"name\":\"A\",\"tmp\":1},\"xs\":[1,2]}"))
         (session (a2ui-surface-session surface)))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/user/name\",\"value\":\"B\"}}")
    (should (equal (a2ui-get surface "/user/name") "B"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/user/tmp\"}}")
    (should (eq (gethash "tmp" (a2ui-get surface "/user") 'absent) 'absent))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/xs/0\"}}")
    (should (equal (a2ui-get surface "/xs") [nil 2]))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"value\":{\"z\":1}}}")
    (should (equal (a2ui-json-encode (a2ui-surface-data surface)) "{\"z\":1}"))))

(ert-deftest a2ui-core-delete-surface ()
  (let* ((surface (a2ui-test--surface))
         (session (a2ui-surface-session surface)))
    (should (equal (a2ui-apply-message session "{\"version\":\"v0.9\",\"deleteSurface\":{\"surfaceId\":\"s\"}}")
                   '("s")))
    (should-not (a2ui-session-surface session "s"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"value\":{}}}")
    (should (equal (gethash "code" (car (a2ui-test--errors session))) "SURFACE_NOT_FOUND"))))

(ert-deftest a2ui-core-on-change-notifies ()
  (let* ((changed nil)
         (session (a2ui-session-create :on-change-fn (lambda (id) (push id changed)))))
    (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S}}"
                                        a2ui-basic-catalog-id))
    (a2ui-set (a2ui-session-surface session "s") "/x" 1)
    (should (equal changed '("s" "s")))))

;;;; Functions

(ert-deftest a2ui-core-required ()
  (let ((s (a2ui-test--surface nil "{\"e\":\"\",\"f\":\"x\",\"a\":[],\"b\":false}")))
    (should (eq (a2ui-test--call s "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/e\"}}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/missing\"}}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/a\"}}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/f\"}}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/b\"}}}") t))))

(ert-deftest a2ui-core-regex-translation ()
  (should (string-match-p (a2ui-js-regex-to-emacs "^\\d{10}$") "1234567890"))
  (should-not (string-match-p (a2ui-js-regex-to-emacs "^\\d{10}$") "123456789"))
  (should-not (string-match-p (a2ui-js-regex-to-emacs "^\\d{10}$") "1234567890\n1"))
  (should (string-match-p (a2ui-js-regex-to-emacs "^[0-9]{5}(-[0-9]{4})?$") "12345-6789"))
  (should (string-match-p (a2ui-js-regex-to-emacs "^(?:a|b)+$") "abba"))
  (should (string-match-p (a2ui-js-regex-to-emacs "^[\\w.\\-]+$") "a.b-c_d"))
  (should-not (string-match-p (a2ui-js-regex-to-emacs "^[\\w.\\-]+$") "a b"))
  (should (string-match-p (a2ui-js-regex-to-emacs "^\\(\\d+\\)$") "(12)"))
  (should-error (a2ui-js-regex-to-emacs "a(?=b)") :type 'a2ui-error))

(ert-deftest a2ui-core-validators ()
  (let ((s (a2ui-test--surface nil "{\"p\":\"1234567890\",\"m\":\"a@b.co\",\"n\":\"7\"}")))
    (should (eq (a2ui-test--call s "{\"call\":\"regex\",\"args\":{\"value\":{\"path\":\"/p\"},\"pattern\":\"^\\\\d{10}$\"}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"email\",\"args\":{\"value\":{\"path\":\"/m\"}}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"email\",\"args\":{\"value\":\"nope@x\"}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"length\",\"args\":{\"value\":\"abc\",\"min\":2,\"max\":3}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"length\",\"args\":{\"value\":\"abcd\",\"max\":3}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"numeric\",\"args\":{\"value\":{\"path\":\"/n\"},\"min\":1,\"max\":20}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"numeric\",\"args\":{\"value\":\"x\"}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"numeric\",\"args\":{\"value\":30,\"max\":20}}") :false))))

(ert-deftest a2ui-core-logic ()
  (let ((s (a2ui-test--surface nil "{\"t\":\"x\",\"e\":\"\"}")))
    (should (eq (a2ui-test--call s "{\"call\":\"and\",\"args\":{\"values\":[true,{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/t\"}}}]}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"and\",\"args\":{\"values\":[true,{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/e\"}}}]}}") :false))
    (should (eq (a2ui-test--call s "{\"call\":\"or\",\"args\":{\"values\":[false,{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/t\"}}}]}}") t))
    (should (eq (a2ui-test--call s "{\"call\":\"not\",\"args\":{\"value\":false}}") t))))

(ert-deftest a2ui-core-format-string ()
  (let ((s (a2ui-test--surface nil "{\"user\":{\"firstName\":\"Ada\"},\"appName\":\"Emacs\",\"n\":3,\"xs\":[{\"name\":\"row\"}]}")))
    (should (equal (a2ui-format-string "Hello, ${/user/firstName}! Welcome to ${/appName}." s)
                   "Hello, Ada! Welcome to Emacs."))
    (should (equal (a2ui-format-string "n=${/n} missing=[${/nope}]" s) "n=3 missing=[]"))
    (should (equal (a2ui-format-string "lit \\${/n} ${'q'}" s) "lit ${/n} q"))
    (should (equal (a2ui-format-string "${name}" s "/xs/0") "row"))
    (should (equal (a2ui-format-string "${formatNumber(value:${/n}, decimals:2)}" s) "3.00"))
    (should (equal (a2ui-format-string "${formatNumber(value: 1234567, grouping: true)}" s) "1,234,567"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatString\",\"args\":{\"value\":\"Hi ${/user/firstName}\"}}")
                   "Hi Ada"))))

(ert-deftest a2ui-core-format-string-errors-are-reported ()
  (let* ((s (a2ui-test--surface))
         (result (a2ui-test--call s "{\"call\":\"formatString\",\"args\":{\"value\":\"${unterminated\"}}")))
    (should (null result))
    (should (equal (gethash "code" (car (a2ui-test--errors (a2ui-surface-session s))))
                   "FUNCTION_FAILED"))))

(ert-deftest a2ui-core-format-number-and-currency ()
  (let ((s (a2ui-test--surface)))
    (should (equal (a2ui-test--call s "{\"call\":\"formatNumber\",\"args\":{\"value\":1234.5678}}") "1,234.568"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatNumber\",\"args\":{\"value\":1234.5,\"decimals\":0,\"grouping\":false}}") "1235"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatNumber\",\"args\":{\"value\":-0.0001}}") "0"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatCurrency\",\"args\":{\"value\":-1234.5,\"currency\":\"USD\"}}") "-$1,234.50"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatCurrency\",\"args\":{\"value\":500,\"currency\":\"JPY\"}}") "¥500"))
    (should (equal (a2ui-test--call s "{\"call\":\"formatCurrency\",\"args\":{\"value\":5,\"currency\":\"CHF\"}}") "CHF 5.00"))))

(ert-deftest a2ui-core-format-date ()
  (let ((a2ui-time-zone t))
    (should (equal (a2ui-format-date "2026-02-02T15:17:00Z" "E MMM d, YYYY h:mm a")
                   "Mon Feb 2, 2026 3:17 PM"))
    (should (equal (a2ui-format-date "2026-01-16T14:30:05Z" "yyyy-MM-dd HH:mm:ss") "2026-01-16 14:30:05"))
    (should (equal (a2ui-format-date "2026-01-16T00:05:00Z" "EEEE, d MMMM 'at' hh:mm a")
                   "Friday, 16 January at 12:05 AM"))
    (should (equal (a2ui-format-date 0 "yy/M/d") "70/1/1"))))

(ert-deftest a2ui-core-pluralize ()
  (let ((s (a2ui-test--surface)))
    (should (equal (a2ui-test--call s "{\"call\":\"pluralize\",\"args\":{\"value\":1,\"one\":\"item\",\"other\":\"items\"}}") "item"))
    (should (equal (a2ui-test--call s "{\"call\":\"pluralize\",\"args\":{\"value\":0,\"zero\":\"none\",\"one\":\"item\",\"other\":\"items\"}}") "items"))))

(ert-deftest a2ui-core-open-url-allowlist ()
  (let* ((s (a2ui-test--surface))
         (opened nil)
         (a2ui-confirm-open-url nil)
         (browse-url-browser-function (lambda (url &rest _) (setq opened url))))
    (a2ui-test--call s "{\"call\":\"openUrl\",\"args\":{\"url\":\"javascript:alert(1)\"}}")
    (should-not opened)
    (a2ui-test--call s "{\"call\":\"openUrl\",\"args\":{\"url\":\"https://example.com\"}}")
    (should (equal opened "https://example.com"))))

(ert-deftest a2ui-core-unknown-function ()
  (let ((s (a2ui-test--surface)))
    (should (null (a2ui-test--call s "{\"call\":\"frobnicate\"}")))
    (should (equal (gethash "code" (car (a2ui-test--errors (a2ui-surface-session s))))
                   "UNKNOWN_FUNCTION"))
    ;; Reported once, however often it is evaluated.
    (a2ui-test--call s "{\"call\":\"frobnicate\"}")
    (should (= 1 (length (a2ui-test--errors (a2ui-surface-session s)))))))

;;;; Checks and actions

(ert-deftest a2ui-core-checks-both-shapes ()
  (let* ((s (a2ui-test--surface nil "{\"email\":\"\"}"))
         (wrapped (a2ui-test--json "{\"checks\":[{\"condition\":{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/email\"}}},\"message\":\"Required.\"}]}"))
         (bare (a2ui-test--json "{\"checks\":[{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/email\"}},\"message\":\"Required.\"}]}")))
    (should (equal (a2ui-check-failures wrapped s) '("Required.")))
    (should (equal (a2ui-check-failures bare s) '("Required.")))
    (a2ui-set s "/email" "a@b.co")
    (should-not (a2ui-check-failures wrapped s))
    (should-not (a2ui-check-failures bare s))))

(ert-deftest a2ui-core-dispatch-action ()
  (let* ((s (a2ui-test--surface nil "{\"form\":{\"env\":\"prod\"},\"rows\":[{\"id\":7}]}"))
         (button (a2ui-test--json "{\"id\":\"go\",\"component\":\"Button\",\"action\":{\"event\":{\"name\":\"deploy\",\"context\":{\"env\":{\"path\":\"/form/env\"},\"row\":{\"path\":\"id\"},\"fixed\":\"x\"}}}}"))
         (msg (a2ui-dispatch-action s button "/rows/0"))
         (action (gethash "action" msg))
         (context (gethash "context" action)))
    (should (equal (gethash "version" msg) "v0.9"))
    (should (equal (gethash "name" action) "deploy"))
    (should (equal (gethash "surfaceId" action) "s"))
    (should (equal (gethash "sourceComponentId" action) "go"))
    (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T.*Z\\'" (gethash "timestamp" action)))
    (should (equal (gethash "env" context) "prod"))
    (should (equal (gethash "row" context) 7))
    (should (equal (gethash "fixed" context) "x"))
    (should (eq (car (car (a2ui-test--sent (a2ui-surface-session s)))) msg))))

(ert-deftest a2ui-core-dispatch-sends-data-model ()
  (let ((session (a2ui-test--session)))
    (a2ui-apply-message session (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S,\"sendDataModel\":true}}"
                                        a2ui-basic-catalog-id))
    (let ((s (a2ui-session-surface session "s")))
      (a2ui-set s "/x" 1)
      (a2ui-dispatch-action s (a2ui-test--json "{\"id\":\"b\",\"action\":{\"event\":{\"name\":\"go\"}}}"))
      (let ((meta (cdr (car (a2ui-test--sent session)))))
        (should (equal (a2ui-json-encode meta)
                       "{\"a2uiClientDataModel\":{\"version\":\"v0.9\",\"surfaces\":{\"s\":{\"x\":1}}}}"))))))

(ert-deftest a2ui-core-message-hook ()
  (let* ((log nil)
         (a2ui-message-functions (list (lambda (dir _s msg _m) (push (cons dir msg) log))))
         (s (a2ui-test--surface)))
    (a2ui-dispatch-action s (a2ui-test--json "{\"id\":\"b\",\"action\":{\"event\":{\"name\":\"go\"}}}"))
    (should (equal (mapcar #'car (reverse log)) '(in out)))))

;;;; Spec fixtures

(defun a2ui-test--replay (file &optional drop-last)
  "Replay fixture FILE into a new session; DROP-LAST skips the final message."
  (let ((session (a2ui-test--session))
        (messages (a2ui-read-jsonl (expand-file-name file a2ui-test--fixtures))))
    (dolist (m (if drop-last (butlast messages) messages))
      (a2ui-apply-message session m))
    session))

(ert-deftest a2ui-core-contact-form-fixture ()
  (dolist (file '("contact_form_example.jsonl" "contact_form_doc.jsonl"))
    (let* ((session (a2ui-test--replay file t))
           (s (a2ui-session-surface session "contact_form_1")))
      (should-not (a2ui-test--errors session))
      (should (= 25 (hash-table-count (a2ui-surface-components s))))
      (should (equal (a2ui-get s "/contact/email") "john.doe@example.com"))
      (should (equal (a2ui-get s "/contact/preference") ["email"]))
      (should-not (a2ui-check-failures (a2ui-surface-component s "email_field") s))
      (a2ui-set s "/contact/email" "nope")
      (should (equal (a2ui-check-failures (a2ui-surface-component s "email_field") s)
                     '("Please enter a valid email address.")))
      (let* ((a2ui-time-zone t)
             (msg (a2ui-dispatch-action s (a2ui-surface-component s "submit_button")))
             (context (gethash "context" (gethash "action" msg))))
        (should (equal (gethash "formId" context) "contact_form_1"))
        (should (equal (gethash "clientTime" context) "Mon Feb 2, 2026 3:17 PM"))
        (should (eq (gethash "isNewsletterSubscribed" context) t))))
    (let ((session (a2ui-test--replay file)))
      (should-not (a2ui-session-surface session "contact_form_1")))))

(provide 'a2ui-core-test)
;;; a2ui-core-test.el ends here
