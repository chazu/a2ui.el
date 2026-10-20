;;; a2ui-mcp.el --- An MCP server in Emacs for A2UI tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/a2ui.el
;; Keywords: tools, comm
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A Model Context Protocol server, over Streamable HTTP with plain JSON
;; responses, that offers the `a2ui-tools' to MCP clients: Claude Code,
;; Codex, or any agent agent-shell starts.  It listens on 127.0.0.1
;; only, and each host gets its own endpoint, /mcp/TOKEN, with a random
;; token, so surfaces and actions stay with the conversation that made
;; them.
;;
;; `a2ui-mcp-start' starts it and makes a host for a terminal agent,
;; showing the commands that connect Claude Code or Codex to it.
;; a2ui_await_action keeps its HTTP response open until the user acts,
;; which is how a terminal agent learns of button presses.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'a2ui-core)
(require 'a2ui-tools)

(defcustom a2ui-mcp-port 0
  "Port the MCP server listens on; 0 picks a free one.
Set a fixed port, with `a2ui-mcp-token', to keep the endpoint of
`a2ui-mcp-start' the same across Emacs sessions, so a terminal agent
is configured once."
  :type 'natnum
  :group 'a2ui)

(defcustom a2ui-mcp-token nil
  "Token of the endpoint `a2ui-mcp-start' makes; nil makes a random one.
Any string of hex digits, e.g. from `(md5 \"something\")'.  The token is
the only thing standing between the endpoint and other programs on
this machine, so keep it private."
  :type '(choice (const :tag "Random" nil) string)
  :group 'a2ui)

(defconst a2ui-mcp-protocol-versions '("2025-06-18" "2025-03-26" "2024-11-05")
  "MCP protocol versions this server speaks, newest first.")

(defvar a2ui-mcp--server nil
  "The listening network process, or nil.")

(defvar a2ui-mcp--hosts (make-hash-table :test 'equal)
  "Endpoint token -> `a2ui-tools-host'.")

(defvar a2ui-mcp-host nil
  "The host `a2ui-mcp-start' made for agents in a terminal.")

(defvar a2ui-mcp--terminal-url nil
  "The endpoint of `a2ui-mcp-host'.")

;;;; Server

(defun a2ui-mcp-running-p ()
  "Return non-nil when the MCP server is listening."
  (process-live-p a2ui-mcp--server))

(defun a2ui-mcp-port ()
  "Return the port the MCP server listens on, starting it if needed."
  (unless (a2ui-mcp-running-p)
    (setq a2ui-mcp--server
          (make-network-process :name "a2ui-mcp" :server t
                                :host "127.0.0.1" :service a2ui-mcp-port :family 'ipv4
                                :coding 'binary :noquery t
                                :filter #'a2ui-mcp--filter)))
  (process-contact a2ui-mcp--server :service))

(defun a2ui-mcp-register (host &optional token)
  "Give HOST an endpoint and return its URL.
TOKEN, hex digits, names the endpoint; by default it is random."
  (let ((token (or token (substring (md5 (format "%s%s%s" (random) (float-time) (emacs-pid))) 0 24))))
    (unless (string-match-p "\\`[0-9a-f]+\\'" token)
      (signal 'a2ui-error (list (format "MCP token %S must be hex digits" token))))
    (puthash token host a2ui-mcp--hosts)
    (format "http://127.0.0.1:%d/mcp/%s" (a2ui-mcp-port) token)))

(defun a2ui-mcp-unregister (url)
  "Forget the endpoint at URL."
  (when (string-match "/mcp/\\([0-9a-f]+\\)\\'" url)
    (remhash (match-string 1 url) a2ui-mcp--hosts)))

(defun a2ui-mcp-stop ()
  "Stop the MCP server and forget every endpoint."
  (interactive)
  (when a2ui-mcp--server (delete-process a2ui-mcp--server))
  (setq a2ui-mcp--server nil a2ui-mcp-host nil a2ui-mcp--terminal-url nil)
  (clrhash a2ui-mcp--hosts))

;;;; HTTP

(defun a2ui-mcp--respond (proc status &optional body headers)
  "Send an HTTP response with STATUS and BODY, a string, on PROC.
HEADERS is an alist of extra headers."
  (when (process-live-p proc)
    (let ((bytes (if body (encode-coding-string body 'utf-8) "")))
      (process-send-string
       proc
       (concat (format "HTTP/1.1 %s\r\n" status)
               (if body "Content-Type: application/json\r\n" "")
               (format "Content-Length: %d\r\n" (length bytes))
               (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
               "\r\n" bytes)))))

(defun a2ui-mcp--filter (proc chunk)
  "Collect CHUNK of a request on PROC and handle complete requests."
  (process-put proc :input (concat (process-get proc :input) chunk))
  (let (request)
    (while (setq request (a2ui-mcp--take-request proc))
      (condition-case err
          (apply #'a2ui-mcp--handle proc request)
        (error (a2ui-mcp--respond proc "500 Internal Server Error"
                                  (a2ui-json-encode (a2ui-obj "error" (error-message-string err)))))))))

(defun a2ui-mcp--take-request (proc)
  "Remove one complete HTTP request from PROC's input; return it or nil.
The request is (METHOD PATH HEADERS BODY), HEADERS an alist with
downcased names and BODY a decoded string."
  (let* ((input (process-get proc :input))
         (end (and input (string-search "\r\n\r\n" input))))
    (when end
      (let* ((lines (split-string (substring input 0 end) "\r\n"))
             (start (split-string (car lines) " "))
             (headers (mapcar (lambda (line)
                                (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                                  (cons (downcase (match-string 1 line)) (match-string 2 line))))
                              (cdr lines)))
             (size (string-to-number (or (cdr (assoc "content-length" headers)) "0")))
             (body-start (+ end 4)))
        (when (>= (length input) (+ body-start size))
          (process-put proc :input (substring input (+ body-start size)))
          (list (car start) (cadr start) headers
                (decode-coding-string (substring input body-start (+ body-start size)) 'utf-8)))))))

(defun a2ui-mcp--handle (proc method path headers body)
  "Answer the request METHOD PATH with HEADERS and BODY on PROC."
  (let* ((token (and path (string-match "\\`/mcp/\\([0-9a-f]+\\)/?\\'" path) (match-string 1 path)))
         (host (and token (gethash token a2ui-mcp--hosts)))
         (origin (cdr (assoc "origin" headers))))
    (cond
     ;; Refuse pages a browser opens, as the MCP spec asks (DNS rebinding).
     ((and origin (not (string-match-p "\\`https?://\\(localhost\\|127\\.0\\.0\\.1\\)\\(:[0-9]+\\)?\\'" origin)))
      (a2ui-mcp--respond proc "403 Forbidden"))
     ((not host) (a2ui-mcp--respond proc "404 Not Found"))
     ((equal method "DELETE") (a2ui-mcp--respond proc "200 OK"))
     ((not (equal method "POST")) (a2ui-mcp--respond proc "405 Method Not Allowed" nil '(("Allow" . "POST, DELETE"))))
     (t (let ((message (ignore-errors (a2ui-json-parse body))))
          (if (vectorp message)
              ;; A batch: answer each request, together.
              (a2ui-mcp--batch proc host message)
            (a2ui-mcp--rpc host message
                           (lambda (reply)
                             (if reply
                                 (a2ui-mcp--respond proc "200 OK" (a2ui-json-encode reply))
                               (a2ui-mcp--respond proc "202 Accepted"))))))))))

(defun a2ui-mcp--batch (proc host messages)
  "Answer the JSON-RPC batch MESSAGES for HOST on PROC."
  (let ((replies nil) (left (length messages)))
    (seq-doseq (m messages)
      (a2ui-mcp--rpc host m (lambda (reply)
                              (when reply (push reply replies))
                              (when (zerop (cl-decf left))
                                (if replies
                                    (a2ui-mcp--respond proc "200 OK" (a2ui-json-encode (vconcat (nreverse replies))))
                                  (a2ui-mcp--respond proc "202 Accepted"))))))))

;;;; JSON-RPC

(defun a2ui-mcp--result (id result)
  "Return a JSON-RPC response to ID with RESULT."
  (a2ui-obj "jsonrpc" "2.0" "id" id "result" result))

(defun a2ui-mcp--error (id code message)
  "Return a JSON-RPC error response to ID with CODE and MESSAGE."
  (a2ui-obj "jsonrpc" "2.0" "id" id "error" (a2ui-obj "code" code "message" message)))

(defun a2ui-mcp-tools (host)
  "Return HOST's tools in MCP's tools/list shape."
  (vconcat (mapcar (lambda (spec)
                     (a2ui-obj "name" (plist-get spec :name)
                               "description" (plist-get spec :description)
                               "inputSchema" (plist-get spec :parameters)))
                   (a2ui-tools-specs host))))

(defun a2ui-mcp--rpc (host message reply)
  "Handle the JSON-RPC MESSAGE for HOST; call REPLY with the response.
REPLY gets nil for a notification."
  (let ((id (and (hash-table-p message) (gethash "id" message 'none)))
        (params (and (hash-table-p message) (or (gethash "params" message) (a2ui-obj)))))
    (cond
     ((not (hash-table-p message))
      (funcall reply (a2ui-mcp--error nil -32700 "Parse error")))
     ((eq id 'none) (funcall reply nil))  ; notifications/initialized and friends
     (t
      (pcase (gethash "method" message)
        ("initialize"
         (let ((asked (gethash "protocolVersion" params)))
           (funcall reply
                    (a2ui-mcp--result
                     id (a2ui-obj "protocolVersion" (if (member asked a2ui-mcp-protocol-versions)
                                                        asked
                                                      (car a2ui-mcp-protocol-versions))
                                  "capabilities" (a2ui-obj "tools" (a2ui-obj))
                                  "serverInfo" (a2ui-obj "name" "a2ui" "version" "0.1.0")
                                  "instructions" "Use render_a2ui to show the user interactive UI in Emacs; call a2ui_catalog first for the components.")))))
        ("ping" (funcall reply (a2ui-mcp--result id (a2ui-obj))))
        ("tools/list" (funcall reply (a2ui-mcp--result id (a2ui-obj "tools" (a2ui-mcp-tools host)))))
        ("tools/call"
         (a2ui-tools-call host (gethash "name" params) (or (gethash "arguments" params) (a2ui-obj))
                          (lambda (text)
                            (funcall reply
                                     (a2ui-mcp--result
                                      id (a2ui-obj "content" (vector (a2ui-obj "type" "text" "text" text))
                                                   "isError" (a2ui-bool (string-prefix-p "{\"status\":\"error\"" text))))))))
        (method (funcall reply (a2ui-mcp--error id -32601 (format "Method not found: %s" method)))))))))

;;;; Commands

(defun a2ui-mcp--show-setup (url)
  "Show how to connect agents in a terminal to URL."
  (with-current-buffer (get-buffer-create "*a2ui-mcp*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "a2ui MCP endpoint: " url "\n\n"
              "Claude Code:\n  claude mcp add --transport http a2ui " url "\n\n"
              "Codex:\n  codex mcp add a2ui --url " url "\n\n"
              "Surfaces appear in Emacs.  An agent in a terminal learns of button\n"
              "presses through a2ui_await_action, so tell it to wait for you, or say\n"
              "\"continue\" after pressing a button.\n")
      (special-mode))
    (display-buffer (current-buffer))))

;;;###autoload
(defun a2ui-mcp-start ()
  "Start the MCP server for agents in a terminal and show how to connect them.
Calling it again shows the same endpoint."
  (interactive)
  (unless (and a2ui-mcp-host a2ui-mcp--terminal-url (a2ui-mcp-running-p))
    (setq a2ui-mcp-host (a2ui-tools-host-create :name "mcp" :directory default-directory)
          a2ui-mcp--terminal-url (a2ui-mcp-register a2ui-mcp-host a2ui-mcp-token)))
  (let ((url a2ui-mcp--terminal-url))
    (kill-new url)
    (a2ui-mcp--show-setup url)
    (message "a2ui MCP endpoint %s (copied)" url)
    url))

(provide 'a2ui-mcp)
;;; a2ui-mcp.el ends here
