;;; a2ui-hosts-test.el --- Tests for the tool layer and its hosts -*- lexical-binding: t; -*-

;;; Commentary:

;; The shared A2UI tools, the MCP server (over real HTTP, through
;; curl), the gptel adapter (through gptel's own argument handling) and
;; the agent-shell adapter (with agent-shell's functions stubbed).

;;; Code:

(require 'ert)
(require 'a2ui)
(require 'a2ui-agent-shell)
(require 'a2ui-gptel)
(require 'gptel)

(defvar agent-shell-mcp-servers)
(defvar agent-shell-permission-responder-function)

(defun a2ui-hosts-test--host (&optional deliver)
  "Return a host, without a renderer, that delivers with DELIVER."
  (let ((a2ui-tools-host-functions nil))
    (a2ui-tools-host-create :name "test" :deliver deliver)))

(defun a2ui-hosts-test--call (host name json)
  "Call tool NAME of HOST with JSON arguments; return the result string."
  (let (result)
    (a2ui-tools-call host name (a2ui-json-parse json) (lambda (r) (setq result r)))
    result))

(defconst a2ui-hosts-test--form
  "{\"surfaceId\":\"f\",\"components\":[{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"name\",\"go\"]},{\"id\":\"name\",\"component\":\"TextField\",\"label\":\"Name\",\"value\":{\"path\":\"/name\"}},{\"id\":\"go_l\",\"component\":\"Text\",\"text\":\"Go\"},{\"id\":\"go\",\"component\":\"Button\",\"child\":\"go_l\",\"action\":{\"event\":{\"name\":\"submit\",\"context\":{\"name\":{\"path\":\"/name\"}}}}}],\"data\":{\"name\":\"Ada\"}}"
  "render_a2ui arguments for a small form.")

(defun a2ui-hosts-test--press (host surface-id button)
  "Press BUTTON on HOST's surface SURFACE-ID."
  (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) surface-id)))
    (a2ui-dispatch-action surface (a2ui-surface-component surface button))))

;;;; Tools

(ert-deftest a2ui-hosts-render ()
  (let ((host (a2ui-hosts-test--host)))
    (should (equal (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
                   "{\"status\":\"shown\",\"surfaceId\":\"f\"}"))
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "f")))
      (should (equal (a2ui-get surface "/name") "Ada"))
      ;; The most capable catalog is the default.
      (should (eq (a2ui-surface-catalog surface) (a2ui-catalog 'emacs))))
    ;; Rendering again replaces the surface's components.
    (a2ui-hosts-test--call host "render_a2ui" "{\"surfaceId\":\"f\",\"components\":[{\"id\":\"root\",\"component\":\"Text\",\"text\":\"done\"}]}")
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "f")))
      (should (a2ui-surface-component surface "root"))
      (should-not (a2ui-surface-component surface "name")))))

(ert-deftest a2ui-hosts-render-invalid ()
  (let* ((host (a2ui-hosts-test--host))
         (result (a2ui-json-parse (a2ui-hosts-test--call host "render_a2ui"
                                                         "{\"surfaceId\":\"x\",\"components\":[{\"id\":\"root\",\"component\":\"Blink\"}]}"))))
    (should (equal (gethash "status" result) "invalid"))
    (should (string-match-p "Unknown component type Blink" (aref (gethash "errors" result) 0)))
    (should (string-match-p "a2ui_catalog" (gethash "hint" result)))))

(ert-deftest a2ui-hosts-normalize ()
  (let* ((host (a2ui-hosts-test--host))
         (result (a2ui-hosts-test--call
                  host "render_a2ui"
                  "{\"surfaceId\":\"n\",\"components\":[{\"id\":\"root\",\"component\":\"Column\",\"props\":{\"children\":[{\"id\":\"t\",\"component\":\"Text\",\"text\":\"hi\"},{\"id\":\"b\",\"component\":\"Button\",\"child\":{\"id\":\"bl\",\"component\":\"Text\",\"text\":\"Go\"},\"action\":{\"event\":{\"name\":\"go\"}}}]}}]}")))
    (should (equal result "{\"status\":\"shown\",\"surfaceId\":\"n\"}"))
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "n")))
      (should (equal (gethash "children" (a2ui-surface-component surface "root")) ["t" "b"]))
      (should (equal (gethash "child" (a2ui-surface-component surface "b")) "bl"))
      (should (a2ui-surface-component surface "bl")))))

(ert-deftest a2ui-hosts-update ()
  (let ((host (a2ui-hosts-test--host)))
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (should (equal (a2ui-hosts-test--call
                    host "update_a2ui"
                    "{\"surfaceId\":\"f\",\"components\":[{\"id\":\"go_l\",\"component\":\"Text\",\"text\":\"Send\"}],\"data\":[{\"path\":\"/name\",\"value\":\"Grace\"},{\"path\":\"/extra\",\"value\":1},{\"path\":\"/extra\"}]}")
                   "{\"status\":\"shown\",\"surfaceId\":\"f\"}"))
    (let ((surface (a2ui-session-surface (a2ui-tools-host-session host) "f")))
      (should (equal (a2ui-get surface "/name") "Grace"))
      (should (eq (gethash "extra" (a2ui-surface-data surface) 'absent) 'absent))
      (should (equal (gethash "text" (a2ui-surface-component surface "go_l")) "Send"))
      (should (a2ui-surface-component surface "name")))
    (should (string-match-p "No surface nope"
                            (a2ui-hosts-test--call host "update_a2ui" "{\"surfaceId\":\"nope\"}")))))

(ert-deftest a2ui-hosts-catalog ()
  (let ((host (a2ui-hosts-test--host)))
    (should (string-match-p "^Table: " (a2ui-hosts-test--call host "a2ui_catalog" "{}")))
    (let ((schemas (a2ui-json-parse (a2ui-hosts-test--call host "a2ui_catalog" "{\"components\":[\"Diff\",\"Nope\"]}"))))
      (should (hash-table-p (gethash "Diff" schemas)))
      (should (equal (gethash "Nope" schemas) "unknown component")))))

(ert-deftest a2ui-hosts-actions-delivery ()
  ;; With DELIVER and no waiter, actions go to DELIVER.
  (let* ((delivered nil)
         (host (a2ui-hosts-test--host (lambda (text) (push text delivered)))))
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (a2ui-hosts-test--press host "f" "go")
    (should (equal delivered '("User performed action \"submit\" on surface \"f\" (component: go). Context: {\"name\":\"Ada\"}")))
    ;; A waiting a2ui_await_action takes it instead.
    (let (awaited)
      (a2ui-tools-call host "a2ui_await_action" (a2ui-json-parse "{\"surfaceId\":\"f\"}") (lambda (r) (setq awaited r)))
      (should-not awaited)
      (a2ui-hosts-test--press host "f" "go")
      (should (string-match-p "action \"submit\"" awaited))
      (should (= 1 (length delivered))))))

(ert-deftest a2ui-hosts-await-queue-and-timeout ()
  (let ((host (a2ui-hosts-test--host)))
    (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
    (let ((inhibit-message t)) (a2ui-hosts-test--press host "f" "go"))
    ;; Without DELIVER the action waits for a2ui_await_action.
    (should (string-match-p "action \"submit\"" (a2ui-hosts-test--call host "a2ui_await_action" "{}")))
    (let (result)
      (a2ui-tools-call host "a2ui_await_action" (a2ui-json-parse "{\"timeoutSeconds\":0.05}") (lambda (r) (setq result r)))
      (sleep-for 0.2)
      (should (string-match-p "\"status\":\"waiting\"" result))
      (should-not (a2ui-tools-host-waiters host)))))

(ert-deftest a2ui-hosts-from-lisp ()
  (let ((v (a2ui-tools-from-lisp '(:a [1 (:b :json-false)] :c :null :d ((x . 1))))))
    (should (equal (a2ui-json-encode v) "{\"a\":[1,{\"b\":false}],\"c\":null,\"d\":{\"x\":1}}"))))

(ert-deftest a2ui-hosts-specs-are-small ()
  (let ((size (length (a2ui-json-encode (vconcat (mapcar (lambda (s) (a2ui-obj "name" (plist-get s :name)
                                                                               "description" (plist-get s :description)
                                                                               "parameters" (plist-get s :parameters)))
                                                         (a2ui-tools-specs nil)))))))
    ;; The four tools cost a few hundred tokens; the catalog comes on demand.
    (should (< size 3200))))

;;;; MCP over HTTP

(defun a2ui-hosts-test--http (method url &optional body headers)
  "Send METHOD to URL with BODY and HEADERS via curl; return (STATUS . BODY).
Emacs keeps serving requests while it waits."
  (let* ((out (generate-new-buffer " *curl*"))
         (proc (make-process :name "curl" :buffer out :noquery t :sentinel #'ignore
                             :command (append (list "curl" "-s" "-o" "-" "-w" "\n%{http_code}" "-X" method url
                                                    "-H" "Content-Type: application/json")
                                              (mapcan (lambda (h) (list "-H" h)) headers)
                                              (when body (list "--data-binary" body)))))
         (deadline (+ (float-time) 10)))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (with-current-buffer out
      (prog1 (let* ((text (buffer-string))
                    (nl (string-search "\n" text (max 0 (- (length text) 5)))))
               (cons (string-to-number (substring text (1+ nl))) (substring text 0 nl)))
        (kill-buffer out)))))

(defmacro a2ui-hosts-test--with-mcp (spec &rest body)
  "Run BODY with an MCP endpoint; SPEC is (HOST URL)."
  (declare (indent 1))
  `(let* ((a2ui-tools-host-functions nil)
          (,(car spec) (a2ui-tools-host-create :name "mcp-test"))
          (,(cadr spec) (a2ui-mcp-register ,(car spec))))
     (unwind-protect (progn ,@body)
       (a2ui-mcp-unregister ,(cadr spec)))))

(defun a2ui-hosts-test--rpc (url method &optional params id)
  "Call METHOD with PARAMS at URL as JSON-RPC request ID; return the reply."
  (let ((reply (a2ui-hosts-test--http
                "POST" url (a2ui-json-encode (a2ui-obj "jsonrpc" "2.0" "id" (or id 1) "method" method
                                                       "params" (or params (a2ui-obj)))))))
    (should (= (car reply) 200))
    (a2ui-json-parse (cdr reply))))

(ert-deftest a2ui-hosts-mcp-handshake ()
  (skip-unless (executable-find "curl"))
  (a2ui-hosts-test--with-mcp (host url)
    (let ((init (gethash "result" (a2ui-hosts-test--rpc url "initialize"
                                                        (a2ui-obj "protocolVersion" "2025-03-26"
                                                                  "capabilities" (a2ui-obj)
                                                                  "clientInfo" (a2ui-obj "name" "t" "version" "1"))))))
      (should (equal (gethash "protocolVersion" init) "2025-03-26"))
      (should (hash-table-p (gethash "tools" (gethash "capabilities" init)))))
    (should (= 202 (car (a2ui-hosts-test--http "POST" url "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))))
    (let ((tools (gethash "tools" (gethash "result" (a2ui-hosts-test--rpc url "tools/list")))))
      (should (equal (mapcar (lambda (tool) (gethash "name" tool)) tools)
                     '("render_a2ui" "update_a2ui" "a2ui_catalog" "a2ui_await_action")))
      (should (equal (gethash "type" (gethash "inputSchema" (aref tools 0))) "object")))
    (should (= 405 (car (a2ui-hosts-test--http "GET" url))))
    (should (= 404 (car (a2ui-hosts-test--http "POST" (concat url "00") "{}"))))
    (should (= 403 (car (a2ui-hosts-test--http "POST" url "{}" '("Origin: https://evil.example")))))
    (should (equal (gethash "code" (gethash "error" (a2ui-hosts-test--rpc url "frobnicate"))) -32601))))

(ert-deftest a2ui-hosts-mcp-fixed-token ()
  (let ((a2ui-tools-host-functions nil))
    (let ((url (a2ui-mcp-register (a2ui-tools-host-create :name "fixed") "c0ffee")))
      (unwind-protect (should (string-suffix-p "/mcp/c0ffee" url))
        (a2ui-mcp-unregister url)))
    (should-error (a2ui-mcp-register (a2ui-tools-host-create :name "bad") "not hex") :type 'a2ui-error)))

(ert-deftest a2ui-hosts-mcp-tools-call-and-await ()
  (skip-unless (executable-find "curl"))
  (a2ui-hosts-test--with-mcp (host url)
    (let ((result (gethash "result" (a2ui-hosts-test--rpc url "tools/call"
                                                          (a2ui-obj "name" "render_a2ui"
                                                                    "arguments" (a2ui-json-parse a2ui-hosts-test--form))))))
      (should (eq (gethash "isError" result) :false))
      (should (equal (gethash "text" (aref (gethash "content" result) 0)) "{\"status\":\"shown\",\"surfaceId\":\"f\"}")))
    ;; a2ui_await_action holds the HTTP response until the button is pressed.
    (let* ((out (generate-new-buffer " *await*"))
           (proc (make-process :name "curl-await" :buffer out :noquery t :sentinel #'ignore
                               :command (list "curl" "-s" "-X" "POST" url "-H" "Content-Type: application/json"
                                              "--data-binary"
                                              (a2ui-json-encode (a2ui-obj "jsonrpc" "2.0" "id" 7 "method" "tools/call"
                                                                          "params" (a2ui-obj "name" "a2ui_await_action"
                                                                                             "arguments" (a2ui-obj "surfaceId" "f")))))))
           (deadline (+ (float-time) 5)))
      (while (and (null (a2ui-tools-host-waiters host)) (< (float-time) deadline))
        (accept-process-output nil 0.02))
      (should (process-live-p proc))
      (a2ui-hosts-test--press host "f" "go")
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output nil 0.02))
      (let ((reply (with-current-buffer out (a2ui-json-parse (buffer-string)))))
        (should (equal (gethash "id" reply) 7))
        (should (string-match-p "User performed action \"submit\""
                                (gethash "text" (aref (gethash "content" (gethash "result" reply)) 0)))))
      (kill-buffer out))))

;;;; gptel

(defun a2ui-hosts-test--gptel-call (tool json)
  "Run gptel TOOL with JSON args the way gptel does; return the result."
  (let ((args (gptel--json-read-string json))
        result)
    (apply (gptel-tool-function tool) (lambda (r) (setq result r))
           (gptel--map-tool-args tool args))
    result))

(ert-deftest a2ui-hosts-gptel-tools ()
  (let* ((a2ui-tools-host-functions nil)
         (tools (a2ui-gptel-tools))
         (render (seq-find (lambda (tool) (equal (gptel-tool-name tool) "render_a2ui")) tools)))
    (should (equal (mapcar #'gptel-tool-name tools)
                   '("render_a2ui" "update_a2ui" "a2ui_catalog" "a2ui_await_action")))
    (should (gptel-tool-async render))
    (with-temp-buffer
      (should (equal (a2ui-hosts-test--gptel-call render a2ui-hosts-test--form)
                     "{\"status\":\"shown\",\"surfaceId\":\"f\"}"))
      (let ((surface (a2ui-session-surface (a2ui-tools-host-session (a2ui-gptel-host)) "f")))
        (should (equal (a2ui-get surface "/name") "Ada"))))))

(ert-deftest a2ui-hosts-gptel-sends-actions ()
  (let* ((a2ui-tools-host-functions nil)
         (render (car (a2ui-gptel-tools)))
         (sent nil))
    (with-temp-buffer
      (setq-local gptel-mode t)
      (insert "### hello\n")
      (a2ui-hosts-test--gptel-call render a2ui-hosts-test--form)
      (cl-letf (((symbol-function 'gptel-send) (lambda (&rest _) (push (buffer-string) sent))))
        (a2ui-hosts-test--press (a2ui-gptel-host) "f" "go"))
      (should (= 1 (length sent)))
      (should (string-match-p "\\`### hello\nUser performed action \"submit\"" (car sent))))))

(ert-deftest a2ui-hosts-gptel-enable ()
  (let ((gptel-tools nil)
        (a2ui-tools-host-functions nil))
    (a2ui-gptel-enable)
    (a2ui-gptel-enable)
    (should (= 4 (length gptel-tools)))))

;;;; agent-shell

(ert-deftest a2ui-hosts-agent-shell-permissions-from-nothing ()
  (let ((agent-shell-permission-responder-function nil)
        (agent-shell-mcp-servers nil))
    (put 'a2ui-agent-shell--chain-responder 'installed nil)
    (a2ui-agent-shell-setup)
    (should (functionp agent-shell-permission-responder-function))))

(ert-deftest a2ui-hosts-agent-shell-permissions ()
  (let* ((agent-shell-permission-responder-function (lambda (_p) 'previous))
         (agent-shell-mcp-servers nil)
         (answered nil)
         (permission (lambda (title)
                       (list (cons :tool-call (list (cons :title title)))
                             (cons :options (list (list (cons :kind "allow_once") (cons :option-id "ok"))))
                             (cons :respond (lambda (id) (setq answered id)))))))
    (a2ui-agent-shell-setup)
    (a2ui-agent-shell-setup)
    (should (eq t (funcall agent-shell-permission-responder-function
                           (funcall permission "mcp__a2ui__render_a2ui"))))
    (should (equal answered "ok"))
    ;; Anything else goes to the responder that was there before.
    (setq answered nil)
    (should (eq 'previous (funcall agent-shell-permission-responder-function (funcall permission "Bash"))))
    (should-not answered)))

(ert-deftest a2ui-hosts-agent-shell ()
  (let ((agent-shell-mcp-servers '(((name . "other") (command . "x"))))
        (a2ui-tools-host-functions nil)
        (inserted nil) (queued nil) (busy nil))
    (a2ui-agent-shell-setup)
    (a2ui-agent-shell-setup)
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) agent-shell-mcp-servers) '("a2ui" "other")))
    ;; A real buffer: temp buffers skip `kill-buffer-hook'.
    (with-current-buffer (generate-new-buffer "*agent-shell test*")
      (cl-letf (((symbol-function 'agent-shell-cwd) (lambda () "/tmp/project/"))
                ((symbol-function 'shell-maker-busy) (lambda () busy))
                ((symbol-function 'agent-shell-insert) (lambda (&rest args) (push args inserted)))
                ((symbol-function 'agent-shell--prompt-queue-enqueue) (lambda (&rest args) (push args queued))))
        ;; agent-shell calls the url function in the shell buffer.
        (let* ((url (funcall (alist-get 'url (car agent-shell-mcp-servers))))
               (host (gethash (car (last (split-string url "/"))) a2ui-mcp--hosts)))
          (should (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+/mcp/[0-9a-f]+\\'" url))
          (should (equal url (a2ui-agent-shell-url)))
          (should (equal (a2ui-session-directory (a2ui-tools-host-session host)) "/tmp/project/"))
          (a2ui-hosts-test--call host "render_a2ui" a2ui-hosts-test--form)
          (a2ui-hosts-test--press host "f" "go")
          (should (equal (plist-get (car inserted) :submit) t))
          (should (string-match-p "action \"submit\"" (plist-get (car inserted) :text)))
          (setq busy t)
          (a2ui-hosts-test--press host "f" "go")
          (should (string-match-p "action \"submit\"" (plist-get (car queued) :prompt)))
          (should (= 1 (length inserted)))
          (kill-buffer (current-buffer))
          (should-not (gethash (car (last (split-string url "/"))) a2ui-mcp--hosts)))))))

(provide 'a2ui-hosts-test)
;;; a2ui-hosts-test.el ends here
