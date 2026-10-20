;;; a2ui-vui-test.el --- Tests for the vui renderer -*- lexical-binding: t; -*-

;;; Commentary:

;; Render snapshots and interaction tests.  Fixtures are replayed into a
;; session, the surface buffer is compared with a golden file, and
;; edits and button presses are driven in the buffer itself.
;;
;; Every file in fixtures/catalog/ (one per basic-catalog component)
;; and fixtures/examples/ (the A2UI spec's basic-catalog examples) gets
;; its own snapshot test.  Set A2UI_UPDATE_GOLDEN=1 to rewrite the
;; golden files.

;;; Code:

(require 'ert)
(require 'org)
(require 'a2ui)

;; DateTimeInput shows instants in local time; snapshots are taken in UTC
;; wherever the tests run.
(set-time-zone-rule t)

(defconst a2ui-vui-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar a2ui-vui-test--sent nil
  "Outbound messages of the current test, newest first.")

(defun a2ui-vui-test--session ()
  "Return a session that collects outbound messages."
  (a2ui-vui-attach
   (a2ui-session-create :name "test-agent"
                        :send-action-fn (lambda (m _meta) (push m a2ui-vui-test--sent)))))

(defun a2ui-vui-test--settle (buffer)
  "Wait until the vui root in BUFFER has no render pending."
  (let ((root (vui-get-instance buffer))
        (deadline (+ (float-time) 5)))
    (while (and root (vui-instance-render-timer root) (< (float-time) deadline))
      (sleep-for 0.01))))

(defun a2ui-vui-test--buffer (session surface-id)
  "Return the settled buffer showing SURFACE-ID of SESSION."
  (let ((buffer (car (a2ui-vui--view session surface-id))))
    (should (buffer-live-p buffer))
    (a2ui-vui-test--settle buffer)
    buffer))

(defun a2ui-vui-test--text (buffer)
  "Return BUFFER's text without properties or trailing whitespace."
  (with-current-buffer buffer
    (mapconcat #'string-trim-right
               (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")
               "\n")))

(defun a2ui-vui-test--faces (buffer)
  "Return lines naming the a2ui faces in BUFFER and the text they cover."
  (with-current-buffer buffer
    (let ((pos (point-min)) lines)
      (while (< pos (point-max))
        (let ((next (next-single-property-change pos 'face nil (point-max)))
              (faces (seq-filter (lambda (f) (and (symbolp f) f
                                                  (string-prefix-p "a2ui-" (symbol-name f))))
                                 (flatten-tree (get-text-property pos 'face)))))
          (when faces
            (push (format "%s: %s" (mapconcat #'symbol-name (delete-dups faces) "+")
                          (string-trim (buffer-substring-no-properties pos next)))
                  lines))
          (setq pos next)))
      (nreverse lines))))

(defun a2ui-vui-test--replay (session messages)
  "Apply MESSAGES, a list of JSON strings or objects, to SESSION."
  (dolist (m messages) (a2ui-apply-message session m)))

(defun a2ui-vui-test--fixture (session file &optional drop-last)
  "Replay fixture FILE into SESSION; DROP-LAST skips its final message."
  (let ((messages (a2ui-read-jsonl (expand-file-name (concat "fixtures/" file) a2ui-vui-test--dir))))
    (a2ui-vui-test--replay session (if drop-last (butlast messages) messages))))

(defun a2ui-vui-test--surface-messages (components &optional data catalog-id)
  "Return messages creating surface \"s\" with COMPONENTS and DATA (JSON).
CATALOG-ID defaults to the basic catalog."
  (delq nil
        (list (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S}}"
                      (or catalog-id a2ui-basic-catalog-id))
              (format "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":%s}}"
                      components)
              (and data (format "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"value\":%s}}"
                                data)))))

(defmacro a2ui-vui-test--with-surface (spec &rest body)
  "Run BODY with a rendered surface.
SPEC is (SESSION BUFFER MESSAGES-FORM [SURFACE-ID]); MESSAGES-FORM
evaluates to the messages to replay, which create SURFACE-ID (default
\"s\").  BODY runs with BUFFER current."
  (declare (indent 1))
  (let ((session (nth 0 spec)) (buffer (nth 1 spec)))
    `(let* ((a2ui-vui-test--sent nil)
            (a2ui-vui-auto-show t)
            (a2ui-log-messages nil)
            (a2ui-time-zone t)
            (,session (a2ui-vui-test--session)))
       (a2ui-vui-test--replay ,session ,(nth 2 spec))
       (let ((,buffer (a2ui-vui-test--buffer ,session ,(or (nth 3 spec) "s"))))
         (unwind-protect (with-current-buffer ,buffer ,@body)
           (kill-buffer ,buffer))))))

(defun a2ui-vui-test--catalog (name)
  "Return the messages of fixture catalog/NAME.jsonl."
  (a2ui-read-jsonl (expand-file-name (format "fixtures/catalog/%s.jsonl" name) a2ui-vui-test--dir)))

(defun a2ui-vui-test--golden (name text)
  "Compare TEXT with golden file NAME, or rewrite it on request."
  (let ((file (expand-file-name (concat "golden/" name) a2ui-vui-test--dir)))
    (if (getenv "A2UI_UPDATE_GOLDEN")
        (progn (make-directory (file-name-directory file) t)
               (with-temp-file file (insert text)))
      (should (equal text (with-temp-buffer
                            (insert-file-contents file)
                            (buffer-string)))))))

(defun a2ui-vui-test--goto-field (key)
  "Move point into the field with vui KEY and return the field widget."
  (should (vui-goto-key key))
  (or (widget-field-at (point))
      (progn (forward-char 1) (widget-field-at (point)))))

(defun a2ui-vui-test--type (key text)
  "Replace the contents of the field with vui KEY by TEXT, as a user would."
  (let ((field (a2ui-vui-test--goto-field key)))
    (should field)
    (delete-region (widget-field-start field)
                   (let ((end (widget-field-end field)))
                     ;; Fields are padded to their size with spaces.
                     (save-excursion
                       (goto-char end)
                       (skip-chars-backward " " (widget-field-start field))
                       (point))))
    (goto-char (widget-field-start field))
    (insert text)))

(defun a2ui-vui-test--press (key)
  "Activate the element with vui KEY in the current buffer."
  (should (vui-goto-key key))
  (vui-activate))

(defun a2ui-vui-test--actions ()
  "Return the action objects sent, oldest first."
  (delq nil (mapcar (lambda (m) (gethash "action" m)) (reverse a2ui-vui-test--sent))))

(defun a2ui-vui-test--errors ()
  "Return the error objects sent, oldest first."
  (delq nil (mapcar (lambda (m) (gethash "error" m)) (reverse a2ui-vui-test--sent))))

;;;; Snapshots

(defconst a2ui-vui-test--expected-errors '("37_native-grid")
  "Fixtures that are expected to report errors: they use custom components.")

(defconst a2ui-vui-test--emoji-width-fixtures '("04_weather-current")
  "Fixtures whose layout pads emoji presentation sequences such as ☀️.
Emacs 32 composes those as one two-column emoji in a displayed buffer,
where Emacs 31 and earlier measure one column, so these fixtures have a
second golden, NAME.emacs32.txt.")

(defun a2ui-vui-test--snapshot (fixture golden)
  "Render FIXTURE and compare every surface it creates with GOLDEN.
The golden file holds each surface's text and the a2ui faces in it."
  (when (and (member (file-name-base fixture) a2ui-vui-test--emoji-width-fixtures)
             (>= emacs-major-version 32))
    (setq golden (concat (file-name-sans-extension golden) ".emacs32.txt")))
  (let ((a2ui-vui-test--sent nil)
        (a2ui-vui-auto-show t)
        (a2ui-log-messages nil)
        (a2ui-time-zone t)
        (session (a2ui-vui-test--session)))
    (a2ui-vui-test--fixture session fixture)
    (let ((ids (sort (a2ui-session-surface-ids session) #'string<))
          (parts nil))
      (should ids)
      (dolist (id ids)
        (let ((buffer (a2ui-vui-test--buffer session id)))
          (unwind-protect
              (let ((text (a2ui-vui-test--text buffer)))
                (should-not (string-match-p "\\[error in" text))
                (push (format "=== %s\n%s\n--- faces\n%s\n" id text
                              (string-join (a2ui-vui-test--faces buffer) "\n"))
                      parts))
            (kill-buffer buffer))))
      (unless (member (file-name-base fixture) a2ui-vui-test--expected-errors)
        (should-not (a2ui-vui-test--errors)))
      (a2ui-vui-test--golden golden (apply #'concat (nreverse parts))))))

(defun a2ui-vui-test--define-snapshots (dir)
  "Define a snapshot test for each JSONL fixture in fixtures/DIR."
  (dolist (file (directory-files (expand-file-name (concat "fixtures/" dir) a2ui-vui-test--dir)
                                 nil "\\.jsonl\\'"))
    (let ((name (file-name-base file)))
      (eval `(ert-deftest ,(intern (format "a2ui-vui-%s/%s" dir name)) ()
               ,(format "Snapshot of fixtures/%s/%s." dir file)
               (a2ui-vui-test--snapshot ,(format "%s/%s" dir file)
                                        ,(format "%s/%s.txt" dir name)))
            t))))

(a2ui-vui-test--define-snapshots "catalog")
(a2ui-vui-test--define-snapshots "examples")

(ert-deftest a2ui-vui-contact-form-snapshot ()
  (let ((a2ui-vui-test--sent nil)
        (a2ui-log-messages nil)
        (session (a2ui-vui-test--session)))
    (a2ui-vui-test--fixture session "contact_form_example.jsonl" t)
    (let ((buffer (a2ui-vui-test--buffer session "contact_form_1")))
      (unwind-protect
          (progn
            (a2ui-vui-test--golden "contact_form.txt" (a2ui-vui-test--text buffer))
            (with-current-buffer buffer
              (should a2ui-surface-mode)
              (should (string-match-p "test-agent" (a2ui-vui--header-line)))
              (goto-char (point-min))
              (search-forward "Contact Us")
              (should (memq 'a2ui-heading-2 (ensure-list (get-text-property (1- (point)) 'face))))))
        (kill-buffer buffer)))))

(ert-deftest a2ui-vui-waits-for-root ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"t\",\"component\":\"Text\",\"text\":\"hi\"}]"))
    (should (equal (a2ui-vui-test--text buffer) "Waiting for agent…"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"t\",\"later\"]}]}}")
    (a2ui-vui-test--settle buffer)
    (should (equal (a2ui-vui-test--text buffer) "hi\n…"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"later\",\"component\":\"Text\",\"text\":\"there\"}]}}")
    (a2ui-vui-test--settle buffer)
    (should (equal (a2ui-vui-test--text buffer) "hi\nthere"))))

(ert-deftest a2ui-vui-missing-data-renders-empty ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Text\",\"text\":{\"path\":\"/greeting\"}}]"))
    (should (equal (a2ui-vui-test--text buffer) ""))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/greeting\",\"value\":\"hello\"}}")
    (a2ui-vui-test--settle buffer)
    (should (equal (a2ui-vui-test--text buffer) "hello"))))

(a2ui-register-catalog 'a2ui-vui-test-open :id "urn:a2ui-vui-test:open" :parent 'basic)

(ert-deftest a2ui-vui-unsupported-and-cycles ()
  ;; A catalog without a schema accepts any type, so one may lack a renderer.
  (let ((a2ui-default-catalogs '(basic a2ui-vui-test-open)))
    (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                  (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"blink\",\"loop\"]},"
                                                          "{\"id\":\"blink\",\"component\":\"Blink\"},"
                                                          "{\"id\":\"loop\",\"component\":\"Column\",\"children\":[\"loop\"]}]")
                                                  nil "urn:a2ui-vui-test:open"))
      (should (equal (a2ui-vui-test--text buffer) "[unsupported: Blink]\n[cycle: loop]"))
      (should (seq-some (lambda (e) (equal (gethash "code" e) "VALIDATION_FAILED"))
                        (a2ui-vui-test--errors))))))

(ert-deftest a2ui-vui-template-relative-scopes ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"row\"}},"
                                                        "{\"id\":\"row\",\"component\":\"Row\",\"children\":[\"name\",\"co\"]},"
                                                        "{\"id\":\"name\",\"component\":\"Text\",\"text\":{\"path\":\"name\"}},"
                                                        "{\"id\":\"co\",\"component\":\"Text\",\"text\":{\"path\":\"/company\"}}]")
                                                "{\"company\":\"Acme\",\"people\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}"))
    (should (equal (a2ui-vui-test--text buffer) "Alice  Acme\nBob  Acme"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/people/-\",\"value\":{\"name\":\"Cy\"}}}")
    (a2ui-vui-test--settle buffer)
    (should (equal (a2ui-vui-test--text buffer) "Alice  Acme\nBob  Acme\nCy  Acme"))))

(ert-deftest a2ui-vui-delete-surface ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"x\"}]"))
    (a2ui-apply-message session "{\"version\":\"v0.9\",\"deleteSurface\":{\"surfaceId\":\"s\"}}")
    (a2ui-vui-test--settle buffer)
    (should (equal (a2ui-vui-test--text buffer) "Surface s was deleted."))))

(ert-deftest a2ui-vui-markdown ()
  (let ((s (a2ui-vui-markdown "# Title\n- **bold** and *it* with `code` and [a link](https://x.y)")))
    (should (equal (substring-no-properties s) "Title\n• bold and it with code and a link"))
    (should (memq 'a2ui-heading-1 (ensure-list (get-text-property 0 'face s))))
    (should (memq 'bold (ensure-list (get-text-property (string-search "bold" s) 'face s))))
    (should (memq 'italic (ensure-list (get-text-property (string-search "it " s) 'face s))))
    (should (memq 'a2ui-code (ensure-list (get-text-property (string-search "code" s) 'face s))))
    (should (equal (get-text-property (string-search "a link" s) 'help-echo s) "https://x.y"))))

;;;; Interaction: the contact form

(ert-deftest a2ui-vui-typing-updates-data-model ()
  (a2ui-vui-test--with-surface (session buffer
                                        (butlast (a2ui-read-jsonl (expand-file-name "fixtures/contact_form_example.jsonl"
                                                                                    a2ui-vui-test--dir)))
                                        "contact_form_1")
    (let ((surface (a2ui-session-surface session "contact_form_1")))
      (a2ui-vui-test--type "email_field@" "not-an-email")
      (should (equal (a2ui-get surface "/contact/email") "not-an-email"))
      (a2ui-vui-test--settle buffer)
      (should (string-match-p "Please enter a valid email address\\." (a2ui-vui-test--text buffer)))
      ;; Point stays in the field across the re-render.
      (should (widget-field-at (point)))
      (a2ui-vui-test--type "email_field@" "ada@example.com")
      (a2ui-vui-test--settle buffer)
      (should-not (string-match-p "valid email" (a2ui-vui-test--text buffer)))
      ;; Typing sends nothing to the agent.
      (should-not (a2ui-vui-test--actions)))))

(ert-deftest a2ui-vui-checkbox-and-submit ()
  (a2ui-vui-test--with-surface (session buffer
                                        (butlast (a2ui-read-jsonl (expand-file-name "fixtures/contact_form_example.jsonl"
                                                                                    a2ui-vui-test--dir)))
                                        "contact_form_1")
    (let ((surface (a2ui-session-surface session "contact_form_1")))
      (a2ui-vui-test--type "first_name_field@" "Grace")
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "newsletter_checkbox@")
      (should (eq (a2ui-get surface "/contact/subscribe") :false))
      (a2ui-vui-test--settle buffer)
      (should (string-match-p "\\[ \\] Subscribe" (a2ui-vui-test--text buffer)))
      (a2ui-vui-test--press "submit_button@")
      (let* ((actions (a2ui-vui-test--actions))
             (action (car actions))
             (context (gethash "context" action)))
        (should (= 1 (length actions)))
        (should (equal (gethash "name" action) "submitContactForm"))
        (should (equal (gethash "sourceComponentId" action) "submit_button"))
        (should (eq (gethash "isNewsletterSubscribed" context) :false))
        (should (equal (gethash "clientTime" context) "Mon Feb 2, 2026 3:17 PM"))
        (should (equal (a2ui-get surface "/contact/firstName") "Grace"))))))

(ert-deftest a2ui-vui-log-records-action ()
  (let ((a2ui-vui-test--sent nil)
        (a2ui-log-messages t)
        (a2ui-log-buffer-name " *a2ui-test-log*")
        (session (a2ui-vui-test--session)))
    (unwind-protect
        (progn
          (a2ui-vui-test--fixture session "contact_form_example.jsonl" t)
          (let ((buffer (a2ui-vui-test--buffer session "contact_form_1")))
            (with-current-buffer buffer
              (a2ui-vui-test--press "submit_button@"))
            (kill-buffer buffer))
          (with-current-buffer a2ui-log-buffer-name
            (goto-char (point-min))
            (should (search-forward "-> out" nil t))
            (should (search-forward "\"submitContactForm\"" nil t))))
      (when (get-buffer a2ui-log-buffer-name)
        (kill-buffer a2ui-log-buffer-name)))))

(ert-deftest a2ui-vui-log-is-trimmed ()
  (let ((a2ui-log-messages t)
        (a2ui-log-max-size 2000)
        (a2ui-log-buffer-name " *a2ui-test-log*")
        (session (a2ui-session-create :name "test-agent")))
    (unwind-protect
        (progn
          (dotimes (i 50)
            (a2ui--log-message 'in session (a2ui-obj "n" i) nil))
          (with-current-buffer a2ui-log-buffer-name
            (should (<= (buffer-size) 2000))
            ;; Whole lines go, and the newest stays.
            (should (string-match-p "\\`[0-9]" (buffer-string)))
            (should (string-match-p "\"n\": 49" (buffer-string)))))
      (when (get-buffer a2ui-log-buffer-name)
        (kill-buffer a2ui-log-buffer-name)))))

(ert-deftest a2ui-vui-replay-file ()
  (let ((a2ui-log-messages nil)
        (session (a2ui-replay-file (expand-file-name "../examples/contact-form.jsonl" a2ui-vui-test--dir))))
    (should (eq session a2ui-replay-session))
    (let ((buffer (a2ui-vui-test--buffer session "contact_form_1")))
      (should (string-match-p "Contact Us" (a2ui-vui-test--text buffer)))
      (kill-buffer buffer))))

(ert-deftest a2ui-vui-list-surfaces ()
  (let* ((a2ui-log-messages nil)
         (session (a2ui-replay-file (expand-file-name "../examples/contact-form.jsonl" a2ui-vui-test--dir)))
         (buffer (a2ui-vui-test--buffer session "contact_form_1")))
    (unwind-protect
        (save-window-excursion
          (a2ui-list-surfaces)
          (with-current-buffer "*a2ui surfaces*"
            ;; Other tests' sessions may be listed too; find this one's row.
            (goto-char (point-min))
            (while (and (not (eobp)) (not (eq (car (tabulated-list-get-id)) session)))
              (forward-line))
            (should (eq (cdr (tabulated-list-get-id))
                        (a2ui-session-surface session "contact_form_1")))
            (should (string-match-p "replay:contact-form.jsonl +contact_form_1"
                                    (buffer-substring (line-beginning-position) (line-end-position))))
            (cl-letf (((symbol-function 'yes-or-no-p) #'always))
              (a2ui-surface-list-delete))
            (should-not (a2ui-session-surface session "contact_form_1"))
            (should-not (buffer-live-p buffer))
            (should-not (seq-find (lambda (e) (eq (car (car e)) session)) (a2ui--surface-list-entries)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (kill-buffer "*a2ui surfaces*"))))

;;;; Interaction: Tabs and Modal

(ert-deftest a2ui-vui-tabs-switch ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Tabs"))
    (should (string-match-p "first tab is selected" (a2ui-vui-test--text buffer)))
    (should-not (string-match-p "Name: Ada" (a2ui-vui-test--text buffer)))
    ;; RET on a title shows its child; the title came from the data.
    (a2ui-vui-test--press "root@/tab/1")
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "Details" (a2ui-vui-test--text buffer)))
    (should (string-match-p "Name: Ada" (a2ui-vui-test--text buffer)))
    (should-not (string-match-p "first tab" (a2ui-vui-test--text buffer)))
    (should (eq (get-text-property (progn (vui-goto-key "root@/tab/1") (point)) 'face) 'a2ui-tab-selected))
    ;; Right arrow moves on, wrapping at the end.
    (vui-goto-key "root@/tab/1")
    (call-interactively (keymap-lookup (get-char-property (point) 'keymap) "<right>"))
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "Only one tab" (a2ui-vui-test--text buffer)))
    (vui-goto-key "root@/tab/2")
    (call-interactively (keymap-lookup (get-char-property (point) 'keymap) "<right>"))
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "first tab" (a2ui-vui-test--text buffer)))
    ;; Switching tabs is view state: nothing goes to the agent.
    (should-not (a2ui-vui-test--actions))))

(ert-deftest a2ui-vui-modal-per-item ()
  ;; A Modal templated over a list shows the item whose trigger was pressed.
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"modal\"}},"
                                                        "{\"id\":\"modal\",\"component\":\"Modal\",\"trigger\":\"open\",\"content\":\"who\"},"
                                                        "{\"id\":\"open_l\",\"component\":\"Text\",\"text\":{\"path\":\"name\"}},"
                                                        "{\"id\":\"open\",\"component\":\"Button\",\"child\":\"open_l\",\"action\":{\"event\":{\"name\":\"open\"}}},"
                                                        "{\"id\":\"who\",\"component\":\"Text\",\"text\":{\"path\":\"name\"}}]")
                                                "{\"people\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}"))
    (save-window-excursion
      (unwind-protect
          (dolist (item '(("/people/0" . "Alice") ("/people/1" . "Bob")))
            (with-current-buffer buffer
              (a2ui-vui-test--press (concat "open@" (car item))))
            (let ((modal (get-buffer "*a2ui: s/modal*")))
              (a2ui-vui-test--settle modal)
              (should (equal (string-trim (a2ui-vui-test--text modal)) (cdr item)))))
        (when-let* ((modal (get-buffer "*a2ui: s/modal*")))
          (kill-buffer modal))))))

(ert-deftest a2ui-vui-modal-opens-and-binds ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Modal"))
    (should-not (string-match-p "Name: Ada" (a2ui-vui-test--text buffer)))
    (save-window-excursion
      (a2ui-vui-test--press "open@")
      ;; The trigger opens the modal and sends nothing.
      (should-not (a2ui-vui-test--actions))
      (let ((modal (get-buffer "*a2ui: s/modal*")))
        (unwind-protect
            (progn
              (should (buffer-live-p modal))
              (should (eq (window-buffer) modal))
              (a2ui-vui-test--settle modal)
              (should (string-match-p "Name: Ada" (a2ui-vui-test--text modal)))
              (with-current-buffer modal
                (should a2ui-modal-mode)
                (a2ui-vui-test--type "name@" "Grace")
                (should (equal (a2ui-get (a2ui-session-surface session "s") "/name") "Grace"))
                (a2ui-vui-test--press "save@"))
              (let ((action (car (a2ui-vui-test--actions))))
                (should (equal (gethash "name" action) "save"))
                (should (equal (gethash "name" (gethash "context" action)) "Grace")))
              ;; An agent's update shows in the open modal.
              (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"save_l\",\"component\":\"Text\",\"text\":\"Saved\"}]}}")
              (a2ui-vui-test--settle modal)
              (should (string-match-p "Saved" (a2ui-vui-test--text modal)))
              ;; So does the surface going away.
              (a2ui-delete-surface session "s")
              (a2ui-vui-test--settle modal)
              (should (string-match-p "Surface s was deleted" (a2ui-vui-test--text modal))))
          (when (buffer-live-p modal) (kill-buffer modal)))))))

(ert-deftest a2ui-vui-modal-other-trigger ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Modal"))
    (save-window-excursion
      (a2ui-vui-test--press "other@/open")
      (let ((modal (get-buffer "*a2ui: s/other*")))
        (unwind-protect
            (progn (a2ui-vui-test--settle modal)
                   (should (string-match-p "not a Button" (a2ui-vui-test--text modal)))
                   (with-current-buffer modal (a2ui-modal-close))
                   (should-not (buffer-live-p modal)))
          (when (buffer-live-p modal) (kill-buffer modal)))))))

;;;; Interaction: checks

(ert-deftest a2ui-vui-button-checks-block-action ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"terms\",\"go\"]},"
                                                        "{\"id\":\"terms\",\"component\":\"CheckBox\",\"label\":\"I agree\",\"value\":{\"path\":\"/terms\"}},"
                                                        "{\"id\":\"go_l\",\"component\":\"Text\",\"text\":\"Go\"},"
                                                        "{\"id\":\"go\",\"component\":\"Button\",\"child\":\"go_l\",\"action\":{\"event\":{\"name\":\"go\"}},"
                                                        "\"checks\":[{\"condition\":{\"path\":\"/terms\"},\"message\":\"Accept the terms first.\"}]}]")
                                                "{\"terms\":false}"))
    (should (vui-goto-key "go@"))
    (should (eq (get-text-property (point) 'face) 'a2ui-button-inactive))
    (vui-activate)
    (should-not (a2ui-vui-test--actions))
    (a2ui-vui-test--press "terms@")
    (a2ui-vui-test--settle buffer)
    (a2ui-vui-test--press "go@")
    (should (equal (mapcar (lambda (a) (gethash "name" a)) (a2ui-vui-test--actions)) '("go")))))

(ert-deftest a2ui-vui-failures-wait-until-touched ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\",\"b\",\"go\"]},"
                                                        "{\"id\":\"a\",\"component\":\"TextField\",\"label\":\"A\",\"value\":{\"path\":\"/a\"},"
                                                        "\"checks\":[{\"condition\":{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/a\"}}},\"message\":\"A is required.\"}]},"
                                                        "{\"id\":\"b\",\"component\":\"TextField\",\"label\":\"B\",\"value\":{\"path\":\"/b\"},"
                                                        "\"checks\":[{\"condition\":{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/b\"}}},\"message\":\"B is required.\"}]},"
                                                        "{\"id\":\"go_l\",\"component\":\"Text\",\"text\":\"Go\"},"
                                                        "{\"id\":\"go\",\"component\":\"Button\",\"child\":\"go_l\",\"action\":{\"event\":{\"name\":\"go\"}},"
                                                        "\"checks\":[{\"condition\":{\"call\":\"and\",\"args\":{\"values\":["
                                                        "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/a\"}}},"
                                                        "{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/b\"}}}]}},\"message\":\"Fill in A and B.\"}]}]")))
    (should-not (string-match-p "required" (a2ui-vui-test--text buffer)))
    ;; Editing A reveals A's failure only.
    (a2ui-vui-test--type "a@" "x")
    (a2ui-vui-test--type "a@" "")
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "A is required" (a2ui-vui-test--text buffer)))
    (should-not (string-match-p "B is required" (a2ui-vui-test--text buffer)))
    ;; A blocked submit reveals everything.
    (a2ui-vui-test--press "go@")
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "B is required" (a2ui-vui-test--text buffer)))
    (should-not (a2ui-vui-test--actions))))

;;;; Interaction: inputs

(ert-deftest a2ui-vui-template-fields-write-their-row ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"name\"}},"
                                                        "{\"id\":\"name\",\"component\":\"TextField\",\"label\":\"Name\",\"value\":{\"path\":\"name\"}}]")
                                                "{\"people\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}"))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--type "name@/people/1" "Robert")
      (should (equal (a2ui-get surface "/people/1/name") "Robert"))
      (should (equal (a2ui-get surface "/people/0/name") "Alice")))))

(defun a2ui-vui-test--count-renders (fn)
  "Call FN and return how many times it rendered a root component."
  (let* ((count 0)
         (counter (lambda (_surface id &optional _scope)
                    (when (equal id "root") (cl-incf count)))))
    (advice-add 'a2ui-vui-render :before counter)
    (unwind-protect (funcall fn)
      (advice-remove 'a2ui-vui-render counter))
    count))

(ert-deftest a2ui-vui-typing-renders-only-what-changes ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\",\"b\",\"mirror\",\"rows\"]},"
                                                        "{\"id\":\"a\",\"component\":\"TextField\",\"label\":\"A\",\"value\":{\"path\":\"/a\"},"
                                                        "\"checks\":[{\"condition\":{\"call\":\"length\",\"args\":{\"value\":{\"path\":\"/a\"},\"max\":3}},\"message\":\"Too long.\"}]},"
                                                        "{\"id\":\"b\",\"component\":\"TextField\",\"label\":\"B\",\"value\":{\"path\":\"/b\"}},"
                                                        "{\"id\":\"mirror\",\"component\":\"Text\",\"text\":{\"path\":\"/b\"}},"
                                                        "{\"id\":\"rows\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"name\"}},"
                                                        "{\"id\":\"name\",\"component\":\"TextField\",\"label\":\"Name\",\"value\":{\"path\":\"name\"}}]")
                                                "{\"a\":\"\",\"b\":\"\",\"people\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}"))
    (let ((surface (a2ui-session-surface session "s"))
          (type (lambda (key text)
                  (a2ui-vui-test--count-renders
                   (lambda ()
                     (a2ui-vui-test--type key text)
                     (a2ui-vui-test--settle buffer))))))
      ;; Nothing else shows /a and its check still passes: no render.
      (should (= 0 (funcall type "a@" "abc")))
      (should (equal (a2ui-get surface "/a") "abc"))
      (should (string-match-p "A: abc" (a2ui-vui-test--text buffer)))
      ;; Its failure appears, and goes again.
      (should (< 0 (funcall type "a@" "abcd")))
      (should (string-match-p "Too long\\." (a2ui-vui-test--text buffer)))
      (should (< 0 (funcall type "a@" "ab")))
      (should-not (string-match-p "Too long\\." (a2ui-vui-test--text buffer)))
      ;; A Text shows /b: typing in B renders it.
      (should (< 0 (funcall type "b@" "hello")))
      (should (string-match-p "^hello$" (a2ui-vui-test--text buffer)))
      ;; A row of a template keeps the list's size: no render.
      (should (= 0 (funcall type "name@/people/1" "Robert")))
      (should (equal (a2ui-get surface "/people/1/name") "Robert"))
      ;; An agent's update renders as before.
      (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateDataModel\":{\"surfaceId\":\"s\",\"path\":\"/a\",\"value\":\"zz\"}}")
      (a2ui-vui-test--settle buffer)
      (should (string-match-p "A: zz" (a2ui-vui-test--text buffer))))))

(ert-deftest a2ui-vui-typing-renders-copies ()
  ;; Two Lists template the same items with the same field: typing in
  ;; one copy shows in the other.
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"l1\",\"l2\"]},"
                                                        "{\"id\":\"l1\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"name\"}},"
                                                        "{\"id\":\"l2\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"name\"}},"
                                                        "{\"id\":\"name\",\"component\":\"TextField\",\"label\":\"N\",\"value\":{\"path\":\"name\"}}]")
                                                "{\"people\":[{\"name\":\"Al\"}]}"))
    (a2ui-vui-test--type "name@/people/0" "Robert")
    (a2ui-vui-test--settle buffer)
    (should-not (string-match-p "N: Al\\b" (a2ui-vui-test--text buffer)))))

(ert-deftest a2ui-vui-text-field-unsupported-regexp ()
  ;; Emacs has no lookahead: the pattern is reported and passes.
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"TextField\",\"label\":\"P\",\"value\":{\"path\":\"/p\"},"
                                                        "\"validationRegexp\":\"^(?=.*\\\\d).{8,}$\"}]")
                                                "{\"p\":\"\"}"))
    (a2ui-vui-test--type "root@" "secret")
    (a2ui-vui-test--settle buffer)
    (should (string-match-p "P: secret" (a2ui-vui-test--text buffer)))
    (should-not (string-match-p "error\\|Invalid" (a2ui-vui-test--text buffer)))
    (should (seq-some (lambda (e) (string-match-p "validationRegexp" (or (gethash "path" e) "")))
                      (a2ui-vui-test--errors)))))

(ert-deftest a2ui-vui-typing-renders-dependents ()
  ;; A Button checking a field's value is rendered as the user types.
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\",\"go\"]},"
                                                        "{\"id\":\"a\",\"component\":\"TextField\",\"label\":\"A\",\"value\":{\"path\":\"/a\"}},"
                                                        "{\"id\":\"go_l\",\"component\":\"Text\",\"text\":\"Go\"},"
                                                        "{\"id\":\"go\",\"component\":\"Button\",\"child\":\"go_l\",\"action\":{\"event\":{\"name\":\"go\"}},"
                                                        "\"checks\":[{\"condition\":{\"call\":\"required\",\"args\":{\"value\":{\"path\":\"/a\"}}},\"message\":\"Need A.\"}]}]")
                                                "{\"a\":\"\"}"))
    (let ((inactive (lambda ()
                      (vui-goto-key "go@")
                      (eq (get-text-property (point) 'face) 'a2ui-button-inactive))))
      (should (funcall inactive))
      (should (< 0 (a2ui-vui-test--count-renders
                    (lambda ()
                      (a2ui-vui-test--type "a@" "x")
                      (a2ui-vui-test--settle buffer)))))
      (should-not (funcall inactive)))))

(ert-deftest a2ui-vui-typing-renders-other-views ()
  ;; The same surface inline elsewhere shows what is typed here.
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                (concat "[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"a\"]},"
                                                        "{\"id\":\"a\",\"component\":\"TextField\",\"label\":\"A\",\"value\":{\"path\":\"/a\"}}]")
                                                "{\"a\":\"\"}"))
    (with-temp-buffer
      (let ((instance (a2ui-vui-insert-surface session "s")))
        (a2ui-vui-test--settle-inline instance)
        (with-current-buffer buffer
          (a2ui-vui-test--type "a@" "typed")
          (a2ui-vui-test--settle buffer))
        (a2ui-vui-test--settle-inline instance)
        (should (string-match-p "A: typed"
                                (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest a2ui-vui-choice-picker-single ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "ChoicePicker"))
    (let ((surface (a2ui-session-surface session "s"))
          (asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (setq asked (list prompt (all-completions "" collection)))
                   "Small")))
        (a2ui-vui-test--press "single@"))
      (should (equal asked '("Size: " ("Small" "Large"))))
      (should (equal (a2ui-get surface "/size") ["s"])))))

(ert-deftest a2ui-vui-choice-picker-multiple ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "ChoicePicker"))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--press "multi@/olives")
      (should (equal (a2ui-get surface "/toppings") ["cheese" "olives" "basil"]))
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "multi@/cheese")
      (should (equal (a2ui-get surface "/toppings") ["olives" "basil"]))
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "chips@/u")
      (should (equal (a2ui-get surface "/tags") ["u" "l"])))))

(ert-deftest a2ui-vui-slider ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Slider"))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--press "int@+")
      (should (equal (a2ui-get surface "/volume") 8))
      (a2ui-vui-test--settle buffer)
      ;; - and + also work with point on the value.
      (should (vui-goto-key "int@"))
      (call-interactively (key-binding "-"))
      (should (equal (a2ui-get surface "/volume") 7))
      (a2ui-vui-test--settle buffer)
      ;; RET on the value asks for one, clamped to the range.
      (cl-letf (((symbol-function 'read-number) (lambda (&rest _) 99)))
        (a2ui-vui-test--press "int@"))
      (should (equal (a2ui-get surface "/volume") 10))
      (a2ui-vui-test--settle buffer)
      (a2ui-vui-test--press "dec@+")
      (should (= (a2ui-get surface "/opacity") 0.3)))))

(ert-deftest a2ui-vui-date-time-input ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "DateTimeInput"))
    (let ((surface (a2ui-session-surface session "s"))
          (picked (encode-time '(0 45 9 3 3 2026 nil -1 nil)))
          (with-time nil))
      (cl-letf (((symbol-function 'org-read-date)
                 (lambda (time-p &rest _) (push time-p with-time) picked)))
        (a2ui-vui-test--press "date@")
        (a2ui-vui-test--settle buffer)
        (a2ui-vui-test--press "time@")
        (a2ui-vui-test--settle buffer)
        (a2ui-vui-test--press "dt@"))
      (should (equal (reverse with-time) '(nil t t)))
      (should (equal (a2ui-get surface "/day") "2026-03-03"))
      (should (equal (a2ui-get surface "/alarm") "09:45:00"))
      (should (equal (a2ui-get surface "/meeting") "2026-03-03T09:45:00")))))

(ert-deftest a2ui-vui-date-time-input-range ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--surface-messages
                                                "[{\"id\":\"root\",\"component\":\"DateTimeInput\",\"enableDate\":true,\"min\":\"2026-01-01\",\"max\":\"2026-12-31\",\"value\":{\"path\":\"/d\"}}]"))
    (let ((surface (a2ui-session-surface session "s")))
      (cl-letf (((symbol-function 'org-read-date)
                 (lambda (&rest _) (encode-time '(0 0 12 1 1 2027 nil -1 nil)))))
        (a2ui-vui-test--press "root@"))
      (should-not (a2ui-get surface "/d")))))

(ert-deftest a2ui-vui-long-text-edit-buffer ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "TextField"))
    (let ((surface (a2ui-session-surface session "s")))
      (a2ui-vui-test--press "long@")
      (let ((edit (get-buffer "*a2ui-edit: Notes*")))
        (should edit)
        (with-current-buffer edit
          (should a2ui-edit-mode)
          (should (equal (buffer-string) "First line\nSecond line"))
          (erase-buffer)
          (insert "Rewritten\nnotes")
          (a2ui-edit-commit))
        (should-not (buffer-live-p edit)))
      (should (equal (a2ui-get surface "/notes") "Rewritten\nnotes"))
      (a2ui-vui-test--settle buffer)
      (should (string-match-p "Rewritten\n *notes" (a2ui-vui-test--text buffer))))))

(ert-deftest a2ui-vui-media-links-ask-first ()
  (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--catalog "Video"))
    (let ((opened nil) (asked nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) t))
                (browse-url-browser-function (lambda (url &rest _) (setq opened url))))
        (a2ui-vui-test--press "v@"))
      (should (string-match-p "example.com/clip.mp4" asked))
      (should (equal opened "https://example.com/clip.mp4")))))

;;;; Inline surfaces

(defun a2ui-vui-test--settle-inline (instance)
  "Wait until inline INSTANCE has no render pending."
  (let ((deadline (+ (float-time) 5)))
    (while (and (vui-instance-render-timer instance) (< (float-time) deadline))
      (sleep-for 0.01))))

(ert-deftest a2ui-vui-inline-surface ()
  (let* ((a2ui-vui-test--sent nil)
         (a2ui-log-messages nil)
         (a2ui-vui-auto-show nil)
         (session (a2ui-vui-test--session)))
    (a2ui-vui-test--replay session (a2ui-vui-test--catalog "Modal"))
    (with-temp-buffer
      (insert "### question\nanswer")
      (let ((instance (a2ui-vui-insert-surface session "s" (point-max) '(gptel ignore))))
        (a2ui-vui-test--settle-inline instance)
        (goto-char (point-max))
        (insert "\n### next")
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          ;; A fresh line, a frame, the surface, then the text after it.
          (should (string-match-p "\\`### question\nanswer\n┌─ s\nSettings\n\\[Edit name]" text))
          (should (string-match-p "└─\n\n### next\\'" text)))
        ;; Its own buffer was not opened.
        (should-not (a2ui-vui--view session "s"))
        ;; Text around it stays editable; its own text is marked.
        (goto-char (point-min))
        (insert "> ")
        (goto-char (point-max))
        (insert "!")
        (should (eq (get-text-property (progn (goto-char (point-min)) (search-forward "Settings") (point)) 'gptel)
                    'ignore))
        (should-not (get-text-property (- (point-max) 1) 'gptel))
        ;; It is live: data updates show, and keep the properties.
        (save-window-excursion
          (save-current-buffer (a2ui-vui-test--press "open@")))
        (should-not (a2ui-vui-test--actions))
        (let ((modal (get-buffer "*a2ui: s/modal*")))
          (unwind-protect
              (progn (a2ui-vui-test--settle modal)
                     (with-current-buffer modal (a2ui-vui-test--press "save@")))
            (kill-buffer modal)))
        (should (equal (gethash "name" (car (a2ui-vui-test--actions))) "save"))
        (a2ui-apply-message session "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"s\",\"components\":[{\"id\":\"title\",\"component\":\"Text\",\"text\":\"Profile\"}]}}")
        (a2ui-vui-test--settle-inline instance)
        (goto-char (point-min))
        (should (search-forward "Profile" nil t))
        (should (eq (get-text-property (point) 'gptel) 'ignore))
        ;; Unmounting removes it and leaves the rest.
        (vui-unmount instance)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "> ### question\nanswer\n### next!"))))))

(ert-deftest a2ui-vui-display-fn ()
  ;; A session with a display function decides where new surfaces go.
  (let* ((a2ui-vui-test--sent nil)
         (a2ui-log-messages nil)
         (a2ui-vui-auto-show t)
         (shown nil)
         (session (a2ui-vui-test--session)))
    (setf (a2ui-session-display-fn session) (lambda (id) (push id shown)))
    (a2ui-vui-test--replay session (a2ui-vui-test--catalog "Text"))
    (should (equal (delete-dups shown) '("s")))
    (should-not (a2ui-vui--view session "s"))))

;;;; Images

(defconst a2ui-vui-test--png "\x89PNG\r\n\x1a\n\0\0\0\rIHDR"
  "The start of a PNG file, enough for `image-type-from-data'.")

(defmacro a2ui-vui-test--with-images (&rest body)
  "Run BODY as if in a frame that shows images."
  `(cl-letf (((symbol-function 'display-images-p) #'always)
             ((symbol-function 'create-image)
              (lambda (data &rest _) (list 'image :type 'png :data data))))
     (clrhash a2ui-vui--images)
     ,@body))

(defun a2ui-vui-test--image-surface (url)
  "Return messages for a surface showing an Image of URL."
  (a2ui-vui-test--surface-messages
   (format "[{\"id\":\"root\",\"component\":\"Image\",\"url\":%S,\"description\":\"Logo\"}]" url)))

(defun a2ui-vui-test--image-at-point-min ()
  "Return the image displayed at the start of the buffer, or nil."
  (let ((display (get-text-property (point-min) 'display)))
    (and (eq (car-safe display) 'image) display)))

(ert-deftest a2ui-vui-image-cache ()
  (let ((a2ui-vui--images (make-hash-table :test 'equal))
        (a2ui-vui--image-cache-bytes 10))
    ;; The oldest images go once the budget is spent.
    (a2ui-vui--cache-image "a" "aaaa")
    (a2ui-vui--cache-image "b" "bbbb")
    (a2ui-vui--cache-image "c" "cccc")
    (should-not (a2ui-vui--cached-image "a"))
    (should (equal (a2ui-vui--cached-image "c") "cccc"))
    ;; A failure is retried after a while.
    (a2ui-vui--cache-image "d" (cons 'failed (float-time)))
    (should (eq (a2ui-vui--cached-image "d") 'failed))
    (a2ui-vui--cache-image "d" (cons 'failed (- (float-time) 3600)))
    (should-not (a2ui-vui--cached-image "d"))))

(ert-deftest a2ui-vui-image-data-url ()
  (a2ui-vui-test--with-images
   (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--image-surface
                                                 (concat "data:image/png;base64," (base64-encode-string a2ui-vui-test--png))))
     (should (equal (plist-get (cdr (a2ui-vui-test--image-at-point-min)) :data) a2ui-vui-test--png)))))

(ert-deftest a2ui-vui-image-asks-before-fetching ()
  (a2ui-vui-test--with-images
   (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--image-surface "https://example.com/logo.png"))
     (should (equal (a2ui-vui-test--text buffer) "▣ Logo [show]"))
     (should-not (a2ui-vui-test--image-at-point-min))
     (let ((fetched nil) (asked nil))
       (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) t))
                 ((symbol-function 'url-retrieve)
                  (lambda (url callback &rest _)
                    (setq fetched url)
                    (with-current-buffer (generate-new-buffer " *http*")
                      (insert "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n" a2ui-vui-test--png)
                      (funcall callback nil)))))
         (a2ui-vui-test--press "root@/show"))
       (should (string-match-p "example.com/logo.png" asked))
       (should (equal fetched "https://example.com/logo.png"))
       (a2ui-vui-test--settle buffer)
       (should (equal (plist-get (cdr (a2ui-vui-test--image-at-point-min)) :data) a2ui-vui-test--png))))))

(ert-deftest a2ui-vui-image-allowed-host-and-links ()
  (a2ui-vui-test--with-images
   ;; An allowed host is fetched without asking; a failure leaves the link.
   (let ((a2ui-vui-image-hosts '("img.example.com"))
         (fetched nil))
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (url callback &rest _)
                  (setq fetched url)
                  (with-current-buffer (generate-new-buffer " *http*")
                    (funcall callback '(:error (error http 404)))))))
       (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--image-surface "https://img.example.com/a.png"))
         (a2ui-vui-test--settle buffer)
         (should (equal fetched "https://img.example.com/a.png"))
         (should (equal (a2ui-vui-test--text buffer) "▣ Logo")))))
   ;; With inline images off, only the link.
   (let ((a2ui-vui-inline-images nil))
     (a2ui-vui-test--with-surface (session buffer (a2ui-vui-test--image-surface "https://example.com/logo.png"))
       (should (equal (a2ui-vui-test--text buffer) "▣ Logo"))))))

(provide 'a2ui-vui-test)
;;; a2ui-vui-test.el ends here
