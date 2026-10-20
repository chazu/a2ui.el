;;; a2ui-agui-test.el --- Tests for the AG-UI transport -*- lexical-binding: t; -*-

;;; Commentary:

;; Recorded SSE streams are fed through the event reducer, split at
;; awkward boundaries, and the run inputs the client would send are
;; checked.  fixtures/agui/scripted/ was recorded from
;; examples/agents/deploy_agent.py with examples/agents/drive-deploy.el;
;; fixtures/agui/middleware.sse follows the event shapes of the AG-UI
;; A2UI middleware.  One test drives a real curl-shaped subprocess.

;;; Code:

(require 'ert)
(require 'a2ui-agui)

(defconst a2ui-agui-test--dir
  (expand-file-name "fixtures/agui" (file-name-directory (or load-file-name buffer-file-name))))

(defun a2ui-agui-test--read (name)
  "Return the text of fixture NAME."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents (expand-file-name name a2ui-agui-test--dir)))
    (buffer-string)))

(defun a2ui-agui-test--feed (agent text &optional sizes)
  "Feed TEXT to AGENT in chunks cycling through SIZES (default 1-13)."
  (let ((sizes (or sizes '(1 2 3 5 8 13))) (i 0) (k 0))
    (while (< i (length text))
      (let ((n (min (nth (% k (length sizes)) sizes) (- (length text) i))))
        (a2ui-agui-receive agent (substring text i (+ i n)))
        (setq i (+ i n) k (1+ k))))))

(defvar a2ui-agui-test--inputs nil
  "Run inputs sent in the current test, newest first.")

(defmacro a2ui-agui-test--with-agent (spec &rest body)
  "Run BODY with an agent whose runs replay recorded streams.
SPEC is (AGENT FIXTURES [CONFIG]): each run consumes the next of the
fixture files FIXTURES, fed in small chunks."
  (declare (indent 1))
  (let ((queue (make-symbol "queue")))
    `(let* ((,queue (copy-sequence ,(nth 1 spec)))
            (a2ui-agui-test--inputs nil)
            (a2ui-agui-session-functions nil)
            (a2ui-agui-text-functions nil)
            (a2ui-message-functions nil)
            (a2ui-agui-catalog-detail nil)
            (a2ui-agui-post-function
             (lambda (agent body)
               (push (a2ui-json-parse body) a2ui-agui-test--inputs)
               (when-let* ((fixture (pop ,queue)))
                 (a2ui-agui-test--feed agent (a2ui-agui-test--read fixture)))
               (a2ui-agui--run-ended agent 0 "")
               nil))
            (,(car spec) (a2ui-agui-create "test" ,(or (nth 2 spec) '(list :url "http://agent")))))
       ,@body)))

(defun a2ui-agui-test--roles (input)
  "Return the roles of INPUT's messages."
  (mapcar (lambda (m) (gethash "role" m)) (gethash "messages" input)))

(defun a2ui-agui-test--last-input ()
  "Return the most recent run input."
  (car a2ui-agui-test--inputs))

(defun a2ui-agui-test--event (agent json)
  "Feed the single event JSON to AGENT."
  (a2ui-agui-receive agent (concat "data: " json "\n\n")))

;;;; SSE

(ert-deftest a2ui-agui-sse-framing ()
  (let ((parsed (a2ui-agui-sse-parse "" ": comment\n\nevent: x\ndata: {\"a\":\ndata: 1}\nid: 7\n\ndata:{\"b\":2}\n\ndata: {\"c\"")))
    (should (equal (car parsed) '("{\"a\":\n1}" "{\"b\":2}")))
    (should (equal (cdr parsed) "data: {\"c\""))
    (should (equal (car (a2ui-agui-sse-parse (cdr parsed) ":3}\r\n\r\n")) '("{\"c\":3}")))))

(ert-deftest a2ui-agui-chunking-does-not-matter ()
  (let ((whole nil) (split nil))
    (dolist (sizes '((100000) (1) (7 3 11)))
      (a2ui-agui-test--with-agent (agent nil)
        (a2ui-agui-test--feed agent (a2ui-agui-test--read "scripted/deploy-1.sse") sizes)
        (let ((summary (list (a2ui-json-encode (vconcat (a2ui-agui-agent-messages agent)))
                             (a2ui-session-surface-ids (a2ui-agui-agent-session agent)))))
          (if whole (setq split (cons summary split)) (setq whole summary)))))
    (dolist (s split) (should (equal s whole)))))

;;;; The deploy example, recorded from deploy_agent.py

(ert-deftest a2ui-agui-deploy-render ()
  (a2ui-agui-test--with-agent (agent '("scripted/deploy-1.sse"))
    (a2ui-agui-send-message agent "deploy the billing service")
    (let* ((input (a2ui-agui-test--last-input))
           (session (a2ui-agui-agent-session agent))
           (surface (a2ui-session-surface session "deploy_params")))
      ;; What the client sent.
      (should (equal (gethash "protocolVersion" input) "1.0"))
      (should (equal (a2ui-agui-test--roles input) '("user")))
      (should (equal (gethash "name" (aref (gethash "tools" input) 0)) "render_a2ui"))
      (let ((catalogs (gethash "value" (aref (gethash "context" input) 0))))
        (should (string-prefix-p "Available A2UI catalog:\n- " catalogs))
        (should (string-search a2ui-basic-catalog-id catalogs)))
      (should (eq (gethash "a2uiCatalogAvailable" (gethash "forwardedProps" input)) t))
      ;; What came back: text, a rendered surface, a pending call.
      (should surface)
      (should (a2ui-surface-component surface "go"))
      (should (equal (a2ui-get surface "/form/replicas") "3"))
      (should (equal (a2ui-agui-agent-status agent) "idle"))
      (let ((assistant (seq-find (lambda (m) (equal (gethash "role" m) "assistant"))
                                 (a2ui-agui-agent-messages agent))))
        (should (equal (gethash "content" assistant) "I need a couple of details before I deploy billing."))
        (should (equal (gethash "name" (gethash "function" (aref (gethash "toolCalls" assistant) 0)))
                       "render_a2ui"))))))

(ert-deftest a2ui-agui-deploy-action-interrupt-resume ()
  (a2ui-agui-test--with-agent (agent '("scripted/deploy-1.sse" "scripted/deploy-2.sse" "scripted/deploy-3.sse"))
    (a2ui-agui-send-message agent "deploy the billing service")
    (let* ((session (a2ui-agui-agent-session agent))
           (surface (a2ui-session-surface session "deploy_params")))
      (a2ui-set surface "/form/env" ["prod"])
      (a2ui-set surface "/form/replicas" "5")
      (a2ui-dispatch-action surface (a2ui-surface-component surface "go"))
      ;; The action run: the render call answered, then the action.
      (let* ((input (a2ui-agui-test--last-input))
             (messages (gethash "messages" input)))
        (should (equal (a2ui-agui-test--roles input) '("user" "assistant" "tool" "assistant" "tool")))
        (should (equal (gethash "toolCallId" (aref messages 2))
                       (gethash "id" (aref (gethash "toolCalls" (aref messages 1)) 0))))
        (should (a2ui-agui--json-equal
                 (a2ui-json-parse (gethash "content" (aref messages 2)))
                 (a2ui-json-parse "{\"status\":\"rendered\",\"surfaceIds\":[\"deploy_params\"]}")))
        (let* ((call (aref (gethash "toolCalls" (aref messages 3)) 0))
               (args (a2ui-json-parse (gethash "arguments" (gethash "function" call)))))
          (should (equal (gethash "name" (gethash "function" call)) "log_a2ui_event"))
          (should (equal (gethash "name" args) "deploy"))
          (should (equal (gethash "replicas" (gethash "context" args)) "5"))
          (should (equal (gethash "toolCallId" (aref messages 4)) (gethash "id" call)))
          (should (string-match-p "\\`User performed action \"deploy\" on surface \"deploy_params\" (component: go)\\. Context: "
                                  (gethash "content" (aref messages 4))))))
      ;; The run ended in an interrupt, shown as a surface.
      (should (equal (a2ui-agui-agent-status agent) "interrupted"))
      (let* ((iid (gethash "id" (car (a2ui-agui-agent-interrupts agent))))
             (isurface (a2ui-session-surface session (concat "a2ui-agui-interrupt-" iid))))
        (should isurface)
        (should (equal (gethash "text" (a2ui-surface-component isurface "message"))
                       "Deploy billing to prod with 5 replicas?"))
        (a2ui-dispatch-action isurface (a2ui-surface-component isurface "approve"))
        (should-not (a2ui-session-surface session (concat "a2ui-agui-interrupt-" iid)))
        (let ((resume (aref (gethash "resume" (a2ui-agui-test--last-input)) 0)))
          (should (equal (gethash "interruptId" resume) iid))
          (should (equal (gethash "status" resume) "resolved"))
          (should (eq (gethash "approved" (gethash "payload" resume)) t))))
      ;; The resumed run updated the same surface.
      (should (equal (gethash "children" (a2ui-surface-component surface "root")) ["title" "status"]))
      (should (equal (gethash "text" (a2ui-surface-component surface "status")) "✓ Deployed billing to prod."))
      (should (equal (a2ui-agui-agent-status agent) "idle"))
      (should (= 3 (length a2ui-agui-test--inputs))))))

(ert-deftest a2ui-agui-reject-interrupt ()
  (a2ui-agui-test--with-agent (agent '("scripted/deploy-1.sse" "scripted/deploy-2.sse" nil))
    (a2ui-agui-send-message agent "deploy the billing service")
    (let ((surface (a2ui-session-surface (a2ui-agui-agent-session agent) "deploy_params")))
      (a2ui-dispatch-action surface (a2ui-surface-component surface "go")))
    (let* ((iid (gethash "id" (car (a2ui-agui-agent-interrupts agent))))
           (isurface (a2ui-session-surface (a2ui-agui-agent-session agent)
                                           (concat "a2ui-agui-interrupt-" iid))))
      (a2ui-dispatch-action isurface (a2ui-surface-component isurface "reject"))
      (let ((resume (aref (gethash "resume" (a2ui-agui-test--last-input)) 0)))
        (should (eq (gethash "approved" (gethash "payload" resume)) :false))))))

(ert-deftest a2ui-agui-user-message-answers-pending-first ()
  (a2ui-agui-test--with-agent (agent '("scripted/deploy-1.sse" nil))
    (a2ui-agui-send-message agent "deploy the billing service")
    (a2ui-agui-send-message agent "never mind")
    ;; The open render is answered before the new user message.
    (should (equal (a2ui-agui-test--roles (a2ui-agui-test--last-input))
                   '("user" "assistant" "tool" "user")))))

(ert-deftest a2ui-agui-forwarded-props-encoding ()
  (a2ui-agui-test--with-agent (agent '("scripted/deploy-1.sse" nil)
                                     (list :url "http://agent" :action-encoding 'forwarded-props))
    (a2ui-agui-send-message agent "deploy the billing service")
    (let ((surface (a2ui-session-surface (a2ui-agui-agent-session agent) "deploy_params")))
      (a2ui-dispatch-action surface (a2ui-surface-component surface "go")))
    (let* ((input (a2ui-agui-test--last-input))
           (action (gethash "userAction" (gethash "a2uiAction" (gethash "forwardedProps" input)))))
      (should (equal (gethash "name" action) "deploy"))
      (should (equal (gethash "surfaceId" action) "deploy_params"))
      (should (equal (gethash "sourceComponentId" action) "go"))
      (should (equal (a2ui-agui-test--roles input) '("user" "assistant" "tool"))))))

(ert-deftest a2ui-agui-send-data-model ()
  (a2ui-agui-test--with-agent (agent '(nil))
    (a2ui-agui--apply-operations
     agent (list (a2ui-json-parse (format "{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"s\",\"catalogId\":%S,\"sendDataModel\":true}}"
                                          a2ui-basic-catalog-id))))
    (let ((surface (a2ui-session-surface (a2ui-agui-agent-session agent) "s")))
      (a2ui-set surface "/x" 1)
      (a2ui-dispatch-action surface (a2ui-json-parse "{\"id\":\"b\",\"action\":{\"event\":{\"name\":\"go\"}}}")))
    (should (equal (a2ui-json-encode (gethash "a2uiClientDataModel" (gethash "forwardedProps" (a2ui-agui-test--last-input))))
                   "{\"version\":\"v0.9\",\"surfaces\":{\"s\":{\"x\":1}}}"))))

;;;; Middleware-style streams

(ert-deftest a2ui-agui-middleware-stream ()
  (a2ui-agui-test--with-agent (agent nil)
    (let ((errors nil))
      (cl-letf (((symbol-function 'a2ui-agui--record-error)
                 (lambda (_agent err) (push err errors))))
        (a2ui-agui-test--feed agent (a2ui-agui-test--read "middleware.sse")))
      ;; Repeated createSurface in cumulative snapshots is not an error.
      (should-not errors))
    (let* ((session (a2ui-agui-agent-session agent))
           (hotels (a2ui-session-surface session "hotels"))
           (flights (a2ui-session-surface session "flights")))
      ;; The toolkits' basic catalog id resolves to the basic catalog.
      (should (eq (a2ui-surface-catalog hotels) (a2ui-catalog 'basic)))
      (should (equal (a2ui-get hotels "/items/1/name") "Cliff House"))
      (should (equal (a2ui-get flights "/summary") "2 flights found"))
      ;; Chunks were expanded into messages.
      (let ((m1 (a2ui-agui--message agent "m1")))
        (should (equal (gethash "content" m1) "Looking up hotels."))
        (should (equal (gethash "name" (gethash "function" (aref (gethash "toolCalls" m1) 0)))
                       "generate_a2ui")))
      (let ((m2 (a2ui-agui--message agent "m2")))
        (should (equal (gethash "arguments" (gethash "function" (aref (gethash "toolCalls" m2) 0)))
                       "{\"to\":\"SFO\"}")))
      ;; State snapshot and JSON Patch delta.
      (should (equal (a2ui-json-encode (a2ui-agui-agent-state agent))
                     "{\"trip\":{\"city\":\"Lisbon\",\"nights\":3,\"tags\":[\"quiet\",\"sea\"]}}"))
      (should (equal (a2ui-agui-agent-status agent) "idle")))))

(ert-deftest a2ui-agui-activity-delta-and-status ()
  (a2ui-agui-test--with-agent (agent nil)
    (let ((said nil))
      (let ((a2ui-agui-text-functions (list (lambda (_a _r text) (push text said)))))
        (a2ui-agui-test--event agent "{\"type\":\"ACTIVITY_SNAPSHOT\",\"messageId\":\"a\",\"activityType\":\"a2ui-surface\",\"content\":{\"status\":\"failed\",\"error\":\"no luck\"}}"))
      (should (member "[A2UI render failed: no luck]" said)))
    (a2ui-agui-test--event
     agent (format "{\"type\":\"ACTIVITY_SNAPSHOT\",\"messageId\":\"a\",\"activityType\":\"a2ui-surface\",\"content\":{\"a2ui_operations\":[{\"version\":\"v0.9\",\"createSurface\":{\"surfaceId\":\"d\",\"catalogId\":%S}}]}}"
                   a2ui-basic-catalog-id))
    (a2ui-agui-test--event
     agent "{\"type\":\"ACTIVITY_DELTA\",\"messageId\":\"a\",\"activityType\":\"a2ui-surface\",\"patch\":[{\"op\":\"add\",\"path\":\"/a2ui_operations/-\",\"value\":{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"d\",\"components\":[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"hi\"}]}}}]}")
    (should (a2ui-surface-component (a2ui-session-surface (a2ui-agui-agent-session agent) "d") "root"))))

;;;; Render failures go back to the agent

(defun a2ui-agui-test--render-stream (call-id components)
  "Return an SSE run calling render_a2ui as CALL-ID with COMPONENTS JSON."
  (mapconcat (lambda (e) (concat "data: " e "\n\n"))
             (list "{\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\"}"
                   (format "{\"type\":\"TOOL_CALL_START\",\"toolCallId\":%S,\"toolCallName\":\"render_a2ui\",\"parentMessageId\":\"p-%s\"}" call-id call-id)
                   (format "{\"type\":\"TOOL_CALL_ARGS\",\"toolCallId\":%S,\"delta\":%S}" call-id
                           (format "{\"surfaceId\":\"s\",\"components\":%s}" components))
                   (format "{\"type\":\"TOOL_CALL_END\",\"toolCallId\":%S}" call-id)
                   "{\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\"}")
             ""))

(ert-deftest a2ui-agui-render-errors-retry ()
  (let ((bad "[{\"id\":\"root\",\"component\":\"Blink\"}]")
        (good "[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"ok\"}]")
        (dir (make-temp-file "a2ui-agui-test" t)))
    (unwind-protect
        (let ((a2ui-agui-test--dir dir))
          (with-temp-file (expand-file-name "bad1.sse" dir) (insert (a2ui-agui-test--render-stream "c1" bad)))
          (with-temp-file (expand-file-name "bad2.sse" dir) (insert (a2ui-agui-test--render-stream "c2" bad)))
          (with-temp-file (expand-file-name "bad3.sse" dir) (insert (a2ui-agui-test--render-stream "c3" bad)))
          (with-temp-file (expand-file-name "good.sse" dir) (insert (a2ui-agui-test--render-stream "c4" good)))
          (a2ui-agui-test--with-agent (agent '("bad1.sse" "bad2.sse" "bad3.sse" "good.sse"))
            (a2ui-agui-send-message agent "draw")
            ;; Two automatic retries, then it waits for the user.
            (should (= 3 (length a2ui-agui-test--inputs)))
            (let* ((input (a2ui-agui-test--last-input))
                   (tool (car (last (append (gethash "messages" input) nil))))
                   (content (a2ui-json-parse (gethash "content" tool))))
              (should (equal (gethash "toolCallId" tool) "c2"))
              (should (equal (gethash "status" content) "failed"))
              (should (string-match-p "Unknown component type Blink" (aref (gethash "errors" content) 0))))
            ;; The third failure is answered with the next user message.
            (a2ui-agui-send-message agent "try again")
            (let ((roles (a2ui-agui-test--roles (a2ui-agui-test--last-input))))
              (should (equal (last roles 3) '("assistant" "tool" "user"))))
            (should (a2ui-surface-component (a2ui-session-surface (a2ui-agui-agent-session agent) "s") "root"))))
      (delete-directory dir t))))

;;;; Other events

(ert-deftest a2ui-agui-messages-snapshot ()
  (a2ui-agui-test--with-agent (agent nil)
    (a2ui-agui-test--event agent "{\"type\":\"TOOL_CALL_START\",\"toolCallId\":\"c\",\"toolCallName\":\"render_a2ui\"}")
    (a2ui-agui-test--event agent "{\"type\":\"MESSAGES_SNAPSHOT\",\"messages\":[{\"id\":\"u\",\"role\":\"user\",\"content\":\"hi\"},{\"id\":\"act\",\"role\":\"activity\",\"activityType\":\"x\",\"content\":{}},{\"id\":\"t\",\"role\":\"tool\",\"toolCallId\":\"c\",\"content\":\"done\"}]}")
    (should (equal (mapcar (lambda (m) (gethash "id" m)) (a2ui-agui-agent-messages agent)) '("u" "t")))
    (should (plist-get (a2ui-agui--call agent "c") :answered))))

(ert-deftest a2ui-agui-run-error ()
  (a2ui-agui-test--with-agent (agent nil)
    (a2ui-agui-test--event agent "{\"type\":\"RUN_ERROR\",\"message\":\"boom\",\"code\":\"X\"}")
    (should (equal (a2ui-agui-agent-status agent) "error"))))

(ert-deftest a2ui-agui-truncated-stream ()
  (a2ui-agui-test--with-agent (agent nil)
    (a2ui-agui-test--event agent "{\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\"}")
    (a2ui-agui--run-ended agent 0 "")
    (should (equal (a2ui-agui-agent-status agent) "error"))))

(ert-deftest a2ui-agui-json-patch ()
  (let ((doc (a2ui-json-parse "{\"a\":[1,2,3],\"b\":{\"c\":1}}")))
    (setq doc (a2ui-agui-json-patch doc (a2ui-json-parse
                                         "[{\"op\":\"add\",\"path\":\"/a/1\",\"value\":9},
                                           {\"op\":\"remove\",\"path\":\"/a/0\"},
                                           {\"op\":\"move\",\"from\":\"/b/c\",\"path\":\"/d\"},
                                           {\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/e\"},
                                           {\"op\":\"test\",\"path\":\"/d\",\"value\":1.0},
                                           {\"op\":\"replace\",\"path\":\"/e/0\",\"value\":\"x\"}]")))
    (should (equal (a2ui-json-encode doc) "{\"a\":[9,2,3],\"b\":{},\"d\":1,\"e\":[\"x\",2,3]}"))
    (should-error (a2ui-agui-json-patch doc (a2ui-json-parse "[{\"op\":\"test\",\"path\":\"/d\",\"value\":2}]"))
                  :type 'a2ui-error)))

(ert-deftest a2ui-agui-curl-config-quoting ()
  (should (equal (a2ui-agui--curl-config "http://h/x" '(("Authorization" . "Bearer a\"b\\c")))
                 "url = \"http://h/x\"\nheader = \"Authorization: Bearer a\\\"b\\\\c\"\n")))

(ert-deftest a2ui-agui-header-functions ()
  (let ((headers (a2ui-agui--headers (list :url "http://h" :headers '(("X-Token" . (lambda (c) (plist-get c :url))))))))
    (should (equal (cdr (assoc "X-Token" headers)) "http://h"))
    (should (equal (cdr (assoc "Accept" headers)) "text/event-stream"))))

;;;; A real subprocess

(ert-deftest a2ui-agui-subprocess ()
  "Run the curl code path against a stand-in that prints a fixture."
  (skip-unless (executable-find "sh"))
  (let* ((dir (make-temp-file "a2ui-agui-curl" t))
         (script (expand-file-name "fake-curl" dir))
         (config (expand-file-name "config" dir))
         (a2ui-agui-curl-program script)
         (a2ui-agui-session-functions nil)
         (a2ui-agui-text-functions nil)
         (a2ui-message-functions nil)
         (a2ui-agui-catalog-detail nil))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "#!/bin/sh\n"
                    ;; Keep the config curl reads from stdin; find the body file.
                    "cat > " (shell-quote-argument config) "\n"
                    "for a in \"$@\"; do case \"$a\" in @*) cp \"${a#@}\" "
                    (shell-quote-argument (expand-file-name "body" dir)) ";; esac; done\n"
                    "cat " (shell-quote-argument (expand-file-name "scripted/deploy-1.sse" a2ui-agui-test--dir)) "\n"))
          (set-file-modes script #o755)
          (let ((agent (a2ui-agui-create "proc" (list :url "http://example.test/agent"
                                                      :headers '(("Authorization" . "Bearer secret"))))))
            (a2ui-agui-send-message agent "deploy the billing service")
            (let ((deadline (+ (float-time) 10)))
              (while (and (a2ui-agui-running-p agent) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (equal (a2ui-agui-agent-status agent) "idle"))
            (should (a2ui-session-surface (a2ui-agui-agent-session agent) "deploy_params"))
            (let ((text (with-temp-buffer (insert-file-contents config) (buffer-string))))
              (should (string-match-p "url = \"http://example.test/agent\"" text))
              (should (string-match-p "header = \"Authorization: Bearer secret\"" text))
              (should (string-match-p "header = \"Accept: text/event-stream\"" text)))
            (should (equal (gethash "threadId" (with-temp-buffer
                                                 (insert-file-contents (expand-file-name "body" dir))
                                                 (a2ui-json-parse (buffer-string))))
                           (a2ui-agui-agent-thread-id agent)))))
      (delete-directory dir t))))

(ert-deftest a2ui-agui-subprocess-http-error ()
  (skip-unless (executable-find "sh"))
  (let* ((dir (make-temp-file "a2ui-agui-curl" t))
         (script (expand-file-name "fake-curl" dir))
         (a2ui-agui-curl-program script)
         (a2ui-agui-session-functions nil)
         (a2ui-agui-text-functions nil)
         (a2ui-agui-catalog-detail nil)
         (said nil))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "#!/bin/sh\ncat >/dev/null\necho '{\"detail\":\"bad input\"}'\n"
                    "echo 'curl: (22) The requested URL returned error: 422' >&2\nexit 22\n"))
          (set-file-modes script #o755)
          (let ((a2ui-agui-text-functions (list (lambda (_a _r text) (push text said))))
                (agent (a2ui-agui-create "proc" (list :url "http://example.test/agent"))))
            (a2ui-agui-send-message agent "hi")
            (let ((deadline (+ (float-time) 10)))
              (while (and (a2ui-agui-running-p agent) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (equal (a2ui-agui-agent-status agent) "error"))
            (should (seq-some (lambda (s) (string-match-p "422.*bad input" (replace-regexp-in-string "\n" " " s)))
                              said))))
      (delete-directory dir t))))

(provide 'a2ui-agui-test)
;;; a2ui-agui-test.el ends here
