;;; a2ui-agui.el --- AG-UI transport for A2UI surfaces -*- lexical-binding: t; -*-

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

;; A client for AG-UI agents (https://docs.ag-ui.com) that feeds the
;; A2UI surfaces they produce into an `a2ui-core' session.  Each run is
;; a POST of a RunAgentInput answered by a Server-Sent Events stream,
;; read through a curl subprocess.  The event reducer keeps the thread's
;; messages and state, and picks A2UI out of three places:
;;
;; - calls to the frontend tool `render_a2ui', which this client
;;   declares in every run (args: surfaceId, components, data);
;; - ACTIVITY_SNAPSHOT / ACTIVITY_DELTA events of type `a2ui-surface',
;;   as the AG-UI A2UI middleware emits them;
;; - tool results whose content is {"a2ui_operations": [...]}.
;;
;; A user action starts the next run.  By default it is written into
;; the history as a `log_a2ui_event' tool call and result, as the
;; middleware would; set `a2ui-agui-action-encoding' to
;; `forwarded-props' for agents behind that middleware.  Interrupts
;; are shown as small surfaces with Approve and Reject buttons.
;;
;; This file depends only on `a2ui-core'; a renderer subscribes through
;; `a2ui-agui-session-functions'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)
(require 'url-parse)
(require 'a2ui-core)

(defgroup a2ui-agui nil
  "AG-UI transport for A2UI surfaces."
  :group 'a2ui
  :prefix "a2ui-agui-")

(defcustom a2ui-agui-agents nil
  "Agents to connect to, as (NAME . PLIST).
PLIST takes :url, the AG-UI endpoint, and optionally :headers, an
alist of (HEADER . VALUE) where VALUE is a string or a function
called with PLIST that returns one, such as
`a2ui-agui-auth-from-authinfo'.  :action-encoding overrides
`a2ui-agui-action-encoding' for this agent."
  :type '(alist :key-type string :value-type plist))

(defcustom a2ui-agui-curl-program "curl"
  "The curl executable used to talk to agents."
  :type 'string)

(defcustom a2ui-agui-action-encoding 'messages
  "How a user action reaches the agent.
`messages' appends a `log_a2ui_event' tool call and its result to
the history, which any agent can read.  `forwarded-props' sends
forwardedProps.a2uiAction, for agents behind the AG-UI A2UI
middleware, which turns it into those messages itself."
  :type '(choice (const messages) (const forwarded-props)))

(defcustom a2ui-agui-catalog-detail 'digest
  "How much of the catalog to put in each run's context.
The agent's model needs it to write valid components.  `digest' sends
a line per component (`a2ui-catalog-digest'), around 700 tokens for
the basic catalog; `schema' sends the JSON Schema, several times that,
as the AG-UI A2UI middleware expects; nil sends only the catalog ids."
  :type '(choice (const digest) (const schema) (const :tag "Ids only" nil)))

(defcustom a2ui-agui-default-catalog-id nil
  "Catalog id for surfaces created by `render_a2ui' calls without one.
nil means the session's most capable catalog, the Emacs catalog when
`a2ui-emacs' is loaded."
  :type '(choice (const :tag "Most capable" nil) string))

(defcustom a2ui-agui-render-retries 2
  "How many times in a row to send failed renders straight back.
When a `render_a2ui' call fails validation, the errors are returned
as its result at once, so the agent can correct itself without the
user having to act."
  :type 'natnum)

(defvar a2ui-agui-session-functions nil
  "Abnormal hook run with each new agent's A2UI session.
A renderer adds itself here, e.g. `a2ui-vui-attach'.")

(defvar a2ui-agui-event-functions nil
  "Abnormal hook run with (AGENT DIRECTION OBJECT) for traffic.
DIRECTION is `out' for a RunAgentInput and `in' for an event.")

(defvar a2ui-agui-text-functions nil
  "Abnormal hook run with (AGENT ROLE TEXT) as messages stream in.
ROLE is \"assistant\" or \"user\" with a fragment of a message,
\"status\" with a line about the run, or \"end\" when a streamed
message ends.")

(defvar a2ui-agui-post-function #'a2ui-agui--curl-post
  "Function that sends a run: called with the agent and the JSON body.
It returns the process, or nil, and feeds the response to
`a2ui-agui-receive'.  Tests replace it.")

(defconst a2ui-agui-render-tool "render_a2ui"
  "Name of the frontend tool agents call to draw a surface.")

(defconst a2ui-agui-activity-type "a2ui-surface"
  "The AG-UI activity type that carries A2UI operations.")

(defconst a2ui-agui--interrupt-prefix "a2ui-agui-interrupt-"
  "Prefix of the ids of surfaces showing interrupts.")

;;;; Agents

(cl-defstruct (a2ui-agui-agent (:constructor a2ui-agui--make) (:copier nil))
  "A connection to one AG-UI agent: a thread and its run state."
  name config thread-id session
  (messages nil)                        ; history, oldest first
  (state (make-hash-table :test 'equal))
  (tool-calls (make-hash-table :test 'equal)) ; id -> plist
  (activities (make-hash-table :test 'equal)) ; messageId -> content
  interrupts                            ; pending interrupt objects
  resolutions                           ; interrupt id -> resume entry
  process run-id status
  (pending "")                          ; unparsed SSE text
  open-text open-tool                   ; ids of open *_CHUNK streams
  finished                              ; run ended with RUN_FINISHED/ERROR
  continue                              ; start another run on exit
  (retries 0)
  transcript)

(defvar a2ui-agui-current-agent nil
  "The agent `a2ui-agui-send' talks to.")

(defun a2ui-agui--uuid ()
  "Return a random UUID string."
  (let ((hex (md5 (format "%s%s%s" (random) (float-time) (emacs-pid)))))
    (format "%s-%s-4%s-a%s-%s" (substring hex 0 8) (substring hex 8 12)
            (substring hex 13 16) (substring hex 17 20) (substring hex 20 32))))

(defun a2ui-agui-create (name config)
  "Return a new agent NAME configured by the plist CONFIG.
Its session is announced through `a2ui-agui-session-functions'."
  (let ((agent (a2ui-agui--make :name name :config config
                                :thread-id (a2ui-agui--uuid)
                                :status "idle")))
    (setf (a2ui-agui-agent-session agent)
          (a2ui-session-create
           :name name
           :send-action-fn (lambda (message metadata)
                             (a2ui-agui--outbound agent message metadata))))
    (run-hook-with-args 'a2ui-agui-session-functions (a2ui-agui-agent-session agent))
    agent))

(defun a2ui-agui--encoding (agent)
  "Return the action encoding AGENT uses."
  (or (plist-get (a2ui-agui-agent-config agent) :action-encoding)
      a2ui-agui-action-encoding))

(defun a2ui-agui-running-p (agent)
  "Return non-nil while AGENT has a run in progress."
  (process-live-p (a2ui-agui-agent-process agent)))

(defun a2ui-agui--status (agent status)
  "Set AGENT's STATUS string and refresh mode lines."
  (setf (a2ui-agui-agent-status agent) status)
  (force-mode-line-update t))

;;;; History

(defun a2ui-agui--message (agent id)
  "Return AGENT's history message ID, or nil."
  (seq-find (lambda (m) (equal (gethash "id" m) id)) (a2ui-agui-agent-messages agent)))

(defun a2ui-agui--add-message (agent message)
  "Append MESSAGE to AGENT's history and return it."
  (setf (a2ui-agui-agent-messages agent)
        (append (a2ui-agui-agent-messages agent) (list message)))
  message)

(defun a2ui-agui--text (agent role text)
  "Report TEXT from ROLE in AGENT's conversation."
  (run-hook-with-args 'a2ui-agui-text-functions agent role text))

(defun a2ui-agui--call (agent id)
  "Return the plist of AGENT's tool call ID."
  (gethash id (a2ui-agui-agent-tool-calls agent)))

(defun a2ui-agui--call-put (agent id prop value)
  "Set PROP of AGENT's tool call ID to VALUE."
  (puthash id (plist-put (a2ui-agui--call agent id) prop value)
           (a2ui-agui-agent-tool-calls agent)))

;;;; RunAgentInput

(defconst a2ui-agui--render-guide
  "Call render_a2ui to show the user UI in Emacs instead of asking in prose.  Args: surfaceId (reuse it to update that surface), components (flat array of {\"id\",\"component\":Type,...props}; one has id \"root\"; children are named by id; a Button's child is a Text id), data (initial data model; bind with {\"path\":\"/x\"}).  The result only confirms the render; a button press arrives later as a log_a2ui_event tool result with the action name and resolved context."
  "How to use the render tool, sent as run context.")

(defun a2ui-agui--render-tool ()
  "Return the `render_a2ui' frontend tool definition."
  (a2ui-obj
   "name" a2ui-agui-render-tool
   "description" "Render a dynamic A2UI v0.9 surface with structured parameters. Follow the A2UI render tool usage guide provided in context."
   "parameters"
   (a2ui-obj "type" "object"
             "properties"
             (a2ui-obj "surfaceId" (a2ui-obj "type" "string")
                       "components" (a2ui-obj "type" "array"
                                              "items" (a2ui-obj "type" "object")
                                              "description" "A2UI v0.9 component array (flat format). The root component must have id \"root\".")
                       "data" (a2ui-obj "type" "object"
                                        "description" "Initial data model for the surface. Written to the root path."))
             "required" ["surfaceId" "components"])))

(defun a2ui-agui--default-catalog-id (agent)
  "Return the catalog id `render_a2ui' calls of AGENT default to."
  (or a2ui-agui-default-catalog-id
      (a2ui-catalog-id (car (a2ui-session-top-catalogs (a2ui-agui-agent-session agent))))))

(defun a2ui-agui--context (agent)
  "Return the context entries AGENT sends: catalogs, guide, components.
Only catalogs no other one extends are described; the rest are
inside them.  See `a2ui-agui-catalog-detail'."
  (let* ((session (a2ui-agui-agent-session agent))
         (top (a2ui-session-top-catalogs session))
         (catalogs (append top (seq-difference (a2ui-session-catalog-list session) top))))
    (vconcat
     (list (a2ui-obj "description" "A2UI catalog capabilities: available catalog IDs and custom component definitions the client can render."
                     "value" (concat "Available A2UI catalog:\n"
                                     (mapconcat (lambda (c) (concat "- " (a2ui-catalog-id c)))
                                                catalogs "\n")))
           (a2ui-obj "description" "A2UI render tool usage guide — how to call render_a2ui with valid arguments."
                     "value" a2ui-agui--render-guide))
     (delq nil
           (mapcar (lambda (c)
                     (pcase a2ui-agui-catalog-detail
                       ('digest
                        (when-let* ((digest (a2ui-catalog-digest c)))
                          (a2ui-obj "description" "A2UI catalog digest — the components and functions you can use, one per line."
                                    "value" digest)))
                       ('schema
                        (when-let* ((schema (a2ui-catalog-schema c)))
                          (a2ui-obj "description" "A2UI Component Schema — available components for generating UI surfaces. Use these component names and properties when creating A2UI operations."
                                    "value" (a2ui-json-encode
                                             (a2ui-obj "catalogId" (a2ui-catalog-id c)
                                                       "components" (gethash "components" schema))))))))
                   top)))))

(defun a2ui-agui--outgoing-messages (agent)
  "Return AGENT's history as sent to the agent: activity messages dropped."
  (vconcat (seq-remove (lambda (m) (equal (gethash "role" m) "activity"))
                       (a2ui-agui-agent-messages agent))))

(defun a2ui-agui-run-input (agent &optional resume forwarded-props)
  "Return the RunAgentInput for AGENT's next run.
RESUME is a vector of resume entries; FORWARDED-PROPS an object."
  (let ((input (a2ui-obj "threadId" (a2ui-agui-agent-thread-id agent)
                         "runId" (a2ui-agui--uuid)
                         "protocolVersion" "1.0"
                         "state" (a2ui-agui-agent-state agent)
                         "messages" (a2ui-agui--outgoing-messages agent)
                         "tools" (vector (a2ui-agui--render-tool))
                         "context" (a2ui-agui--context agent)
                         "forwardedProps" (let ((props (or forwarded-props (a2ui-obj))))
                                            (puthash "a2uiCatalogAvailable" t props)
                                            props))))
    (when resume (puthash "resume" resume input))
    input))

(defun a2ui-agui--answer-pending (agent)
  "Answer every unanswered `render_a2ui' call in AGENT's history.
AG-UI requires each frontend tool call to be answered before the
thread continues; a render is answered with its outcome."
  (maphash
   (lambda (id call)
     (when (and (equal (plist-get call :name) a2ui-agui-render-tool)
                (plist-get call :ended)
                (not (plist-get call :answered)))
       (let ((errors (plist-get call :errors)))
         (a2ui-agui--add-message
          agent (a2ui-obj "id" (a2ui-agui--uuid) "role" "tool" "toolCallId" id
                          "content" (a2ui-json-encode
                                     (if errors
                                         (a2ui-obj "status" "failed"
                                                   "errors" (vconcat (reverse errors)))
                                       (a2ui-obj "status" "rendered"
                                                 "surfaceIds" (vconcat (plist-get call :surfaces)))))))
         (a2ui-agui--call-put agent id :answered t))))
   (a2ui-agui-agent-tool-calls agent)))

(cl-defun a2ui-agui-run (agent &key resume forwarded-props)
  "Start a run of AGENT, answering pending render calls first.
RESUME and FORWARDED-PROPS go into the RunAgentInput."
  (when (a2ui-agui-running-p agent)
    (user-error "Agent %s is still running; wait or `a2ui-agui-abort'"
                (a2ui-agui-agent-name agent)))
  (a2ui-agui--answer-pending agent)
  (let ((input (a2ui-agui-run-input agent resume forwarded-props)))
    (setf (a2ui-agui-agent-run-id agent) (gethash "runId" input)
          (a2ui-agui-agent-pending agent) ""
          (a2ui-agui-agent-finished agent) nil
          (a2ui-agui-agent-open-text agent) nil
          (a2ui-agui-agent-open-tool agent) nil)
    (a2ui-agui--status agent "running")
    (run-hook-with-args 'a2ui-agui-event-functions agent 'out input)
    (setf (a2ui-agui-agent-process agent)
          (funcall a2ui-agui-post-function agent (a2ui-json-encode input)))
    input))

(defun a2ui-agui-send-message (agent text)
  "Send the user message TEXT to AGENT and start a run."
  (when (a2ui-agui-running-p agent)
    (user-error "Agent %s is still running; wait or `a2ui-agui-abort'"
                (a2ui-agui-agent-name agent)))
  ;; Pending calls are answered first: a tool result must follow the
  ;; assistant message that made the call.
  (a2ui-agui--answer-pending agent)
  (a2ui-agui--add-message agent (a2ui-obj "id" (a2ui-agui--uuid) "role" "user" "content" text))
  (a2ui-agui--text agent "user" text)
  (setf (a2ui-agui-agent-retries agent) 0)
  (a2ui-agui-run agent))

;;;; Outbound actions

(defun a2ui-agui--action-text (action)
  "Describe ACTION for the agent the way the AG-UI A2UI middleware does."
  (format "User performed action %S on surface %S (component: %s). Context: %s"
          (gethash "name" action) (gethash "surfaceId" action)
          (gethash "sourceComponentId" action)
          (a2ui-json-encode (or (gethash "context" action) (a2ui-obj)))))

(defun a2ui-agui--outbound (agent message metadata)
  "Handle MESSAGE, an outbound A2UI envelope, for AGENT.
METADATA is the transport metadata, holding the data model when the
surface asked for it."
  (cond
   ((gethash "error" message)
    (a2ui-agui--record-error agent (gethash "error" message)))
   ((gethash "action" message)
    (let ((action (gethash "action" message)))
      (if (string-prefix-p a2ui-agui--interrupt-prefix (gethash "surfaceId" action))
          (a2ui-agui--resolve-interrupt agent action)
        (a2ui-agui--send-action agent action metadata))))))

(defun a2ui-agui--send-action (agent action metadata)
  "Send ACTION, with METADATA, to AGENT as the start of a run."
  (if (a2ui-agui-running-p agent)
      (message "a2ui: %s is busy; try again when it finishes" (a2ui-agui-agent-name agent))
    (let ((props (a2ui-obj)))
      (when-let* ((model (and metadata (gethash "a2uiClientDataModel" metadata))))
        (puthash "a2uiClientDataModel" model props))
      (a2ui-agui--answer-pending agent)
      (pcase (a2ui-agui--encoding agent)
        ('forwarded-props
         (puthash "a2uiAction" (a2ui-obj "userAction" action) props))
        (_
         (let ((id (a2ui-agui--uuid)))
           (a2ui-agui--add-message
            agent (a2ui-obj "id" (concat "a2ui-action-assistant-" id) "role" "assistant" "content" ""
                            "toolCalls" (vector (a2ui-obj "id" id "type" "function"
                                                          "function" (a2ui-obj "name" "log_a2ui_event"
                                                                               "arguments" (a2ui-json-encode action))))))
           (a2ui-agui--add-message
            agent (a2ui-obj "id" (concat "a2ui-action-result-" id) "role" "tool" "toolCallId" id
                            "content" (a2ui-agui--action-text action))))))
      (a2ui-agui--text agent "status" (format "[%s on %s]" (gethash "name" action)
                                              (gethash "surfaceId" action)))
      (setf (a2ui-agui-agent-retries agent) 0)
      (a2ui-agui-run agent :forwarded-props props))))

(defvar a2ui-agui--current-call nil
  "The id of the `render_a2ui' call whose operations are being applied.")

(defun a2ui-agui--record-error (agent error)
  "Note the A2UI ERROR object against AGENT's current render call."
  (let ((text (format "[%s] %s: %s" (gethash "code" error)
                      (or (gethash "path" error) "") (gethash "message" error))))
    (a2ui-agui--text agent "status" (format "[A2UI error: %s]" text))
    (when a2ui-agui--current-call
      (a2ui-agui--call-put agent a2ui-agui--current-call :errors
                           (cons text (plist-get (a2ui-agui--call agent a2ui-agui--current-call)
                                                 :errors))))))

;;;; Applying A2UI

(defun a2ui-agui--apply-operations (agent operations)
  "Apply the A2UI OPERATIONS, a sequence of messages, to AGENT's session.
A createSurface for a surface that exists is skipped: activity
snapshots and repeated renders resend it each time.  Return the ids
of the surfaces touched."
  (let ((session (a2ui-agui-agent-session agent)) touched)
    (seq-doseq (op operations)
      (when (hash-table-p op)
        (let ((create (gethash "createSurface" op)))
          (unless (and (hash-table-p create)
                       (a2ui-session-surface session (gethash "surfaceId" create)))
            (setq touched (append touched (a2ui-apply-message session op)))))))
    (delete-dups touched)))

(defun a2ui-agui--render-operations (agent args)
  "Return the A2UI operations that `render_a2ui' ARGS stand for in AGENT.
Besides surfaceId/components/data, args holding a2ui_operations or
messages arrays are accepted."
  (let ((session (a2ui-agui-agent-session agent))
        (id (gethash "surfaceId" args)))
    (cond
     ((vectorp (gethash "a2ui_operations" args)) (gethash "a2ui_operations" args))
     ((vectorp (gethash "messages" args)) (gethash "messages" args))
     ((not (stringp id))
      (signal 'a2ui-error (list "render_a2ui needs a surfaceId string")))
     (t
      (delq nil
            (list (unless (a2ui-session-surface session id)
                    (a2ui-obj "version" "v0.9"
                              "createSurface" (a2ui-obj "surfaceId" id
                                                        "catalogId" (or (gethash "catalogId" args)
                                                                        (a2ui-agui--default-catalog-id agent)))))
                  (a2ui-obj "version" "v0.9"
                            "updateComponents" (a2ui-obj "surfaceId" id
                                                         "components" (or (gethash "components" args) [])))
                  (when (gethash "data" args)
                    (a2ui-obj "version" "v0.9"
                              "updateDataModel" (a2ui-obj "surfaceId" id "path" "/"
                                                          "value" (gethash "data" args))))))))))

(defun a2ui-agui--render (agent id)
  "Apply the finished `render_a2ui' call ID of AGENT."
  (let* ((call (a2ui-agui--call agent id))
         (a2ui-agui--current-call id))
    (condition-case err
        (let* ((args (a2ui-json-parse (let ((s (plist-get call :args)))
                                        (if (string-empty-p s) "{}" s))))
               (surfaces (a2ui-agui--apply-operations
                          agent (a2ui-agui--render-operations agent args))))
          (a2ui-agui--call-put agent id :surfaces surfaces)
          (a2ui-agui--text agent "status" (format "[surface %s]" (string-join surfaces ", "))))
      ((a2ui-error json-error)
       (a2ui-agui--record-error
        agent (a2ui-obj "code" "INVALID_ARGUMENTS" "path" "/"
                        "message" (format "render_a2ui arguments: %s" (error-message-string err))))))))

(defun a2ui-agui--operations-in (content)
  "Return the A2UI operations in tool result or activity CONTENT, or nil."
  (let ((obj (cond ((hash-table-p content) content)
                   ((and (stringp content) (string-match-p "a2ui_operations" content))
                    (ignore-errors (a2ui-json-parse content))))))
    (when (hash-table-p obj)
      (let ((ops (gethash "a2ui_operations" obj)))
        (and (vectorp ops) ops)))))

(defun a2ui-agui--activity (agent message-id content)
  "Show the a2ui-surface activity MESSAGE-ID of AGENT, now CONTENT."
  (puthash message-id content (a2ui-agui-agent-activities agent))
  (if-let* ((ops (a2ui-agui--operations-in content)))
      (a2ui-agui--apply-operations agent ops)
    (pcase (and (hash-table-p content) (gethash "status" content))
      ("failed" (a2ui-agui--text agent "status"
                                 (format "[A2UI render failed: %s]"
                                         (a2ui-stringify (gethash "error" content)))))
      ("retrying" (a2ui-agui--text agent "status" "[A2UI render retrying]")))))

;;;; Interrupts

(defun a2ui-agui--show-interrupts (agent interrupts)
  "Show each of INTERRUPTS from AGENT as a surface with two buttons."
  (setf (a2ui-agui-agent-interrupts agent) (append interrupts nil)
        (a2ui-agui-agent-resolutions agent) nil)
  (seq-doseq (interrupt interrupts)
    (let* ((iid (gethash "id" interrupt))
           (sid (concat a2ui-agui--interrupt-prefix iid))
           (button (lambda (id label name variant)
                     (list (a2ui-obj "id" (concat id "-label") "component" "Text" "text" label)
                           (a2ui-obj "id" id "component" "Button" "child" (concat id "-label")
                                     "variant" variant
                                     "action" (a2ui-obj "event" (a2ui-obj "name" name
                                                                          "context" (a2ui-obj "interruptId" iid))))))))
      (a2ui-agui--apply-operations
       agent
       (list (a2ui-obj "version" "v0.9"
                       "createSurface" (a2ui-obj "surfaceId" sid "catalogId" a2ui-basic-catalog-id))
             (a2ui-obj "version" "v0.9"
                       "updateComponents"
                       (a2ui-obj "surfaceId" sid
                                 "components"
                                 (vconcat
                                  (list (a2ui-obj "id" "root" "component" "Column"
                                                  "children" ["title" "message" "buttons"])
                                        (a2ui-obj "id" "title" "component" "Text" "variant" "h3"
                                                  "text" (format "%s asks you to confirm"
                                                                 (a2ui-agui-agent-name agent)))
                                        (a2ui-obj "id" "message" "component" "Text"
                                                  "text" (or (gethash "message" interrupt)
                                                             (format "Reason: %s" (gethash "reason" interrupt))))
                                        (a2ui-obj "id" "buttons" "component" "Row"
                                                  "children" ["approve" "reject"]))
                                  (funcall button "approve" "Approve" "approve" "primary")
                                  (funcall button "reject" "Reject" "reject" "default"))))))))
  (a2ui-agui--text agent "status" (format "[%d interrupt(s) waiting for you]" (length interrupts))))

(defun a2ui-agui--resolve-interrupt (agent action)
  "Record the user's ACTION on an interrupt surface of AGENT.
Once every interrupt has an answer, the run resumes."
  (let* ((iid (gethash "interruptId" (gethash "context" action)))
         (approved (equal (gethash "name" action) "approve")))
    (setf (alist-get iid (a2ui-agui-agent-resolutions agent) nil nil #'equal)
          (a2ui-obj "interruptId" iid "status" "resolved"
                    "payload" (a2ui-obj "approved" (a2ui-bool approved))))
    (a2ui-delete-surface (a2ui-agui-agent-session agent) (concat a2ui-agui--interrupt-prefix iid))
    (a2ui-agui--text agent "status" (format "[%s %s]" (if approved "approved" "rejected") iid))
    (when (cl-every (lambda (i) (assoc (gethash "id" i) (a2ui-agui-agent-resolutions agent)))
                    (a2ui-agui-agent-interrupts agent))
      (let ((resume (vconcat (mapcar (lambda (i)
                                       (cdr (assoc (gethash "id" i) (a2ui-agui-agent-resolutions agent))))
                                     (a2ui-agui-agent-interrupts agent)))))
        (setf (a2ui-agui-agent-interrupts agent) nil
              (a2ui-agui-agent-resolutions agent) nil)
        (a2ui-agui-run agent :resume resume)))))

;;;; Event reducer

(defun a2ui-agui--assistant (agent id)
  "Return AGENT's assistant message ID, creating it if needed."
  (or (a2ui-agui--message agent id)
      (a2ui-agui--add-message agent (a2ui-obj "id" id "role" "assistant"))))

(defun a2ui-agui--close-chunks (agent)
  "End AGENT's open TEXT_MESSAGE_CHUNK and TOOL_CALL_CHUNK streams."
  (when-let* ((id (a2ui-agui-agent-open-text agent)))
    (setf (a2ui-agui-agent-open-text agent) nil)
    (a2ui-agui--handle agent (a2ui-obj "type" "TEXT_MESSAGE_END" "messageId" id)))
  (when-let* ((id (a2ui-agui-agent-open-tool agent)))
    (setf (a2ui-agui-agent-open-tool agent) nil)
    (a2ui-agui--handle agent (a2ui-obj "type" "TOOL_CALL_END" "toolCallId" id))))

(defun a2ui-agui--handle-chunk (agent event)
  "Expand the *_CHUNK EVENT of AGENT into start, content and end events."
  (if (equal (gethash "type" event) "TEXT_MESSAGE_CHUNK")
      (let ((id (or (gethash "messageId" event) (a2ui-agui-agent-open-text agent))))
        (unless (equal id (a2ui-agui-agent-open-text agent))
          (a2ui-agui--close-chunks agent)
          (a2ui-agui--handle agent (a2ui-obj "type" "TEXT_MESSAGE_START" "messageId" id
                                             "role" (or (gethash "role" event) "assistant")))
          (setf (a2ui-agui-agent-open-text agent) id))
        (when (gethash "delta" event)
          (a2ui-agui--handle agent (a2ui-obj "type" "TEXT_MESSAGE_CONTENT" "messageId" id
                                             "delta" (gethash "delta" event)))))
    (let ((id (or (gethash "toolCallId" event) (a2ui-agui-agent-open-tool agent))))
      (unless (equal id (a2ui-agui-agent-open-tool agent))
        (a2ui-agui--close-chunks agent)
        (a2ui-agui--handle agent (a2ui-obj "type" "TOOL_CALL_START" "toolCallId" id
                                           "toolCallName" (gethash "toolCallName" event)
                                           "parentMessageId" (gethash "parentMessageId" event)))
        (setf (a2ui-agui-agent-open-tool agent) id))
      (when (gethash "delta" event)
        (a2ui-agui--handle agent (a2ui-obj "type" "TOOL_CALL_ARGS" "toolCallId" id
                                           "delta" (gethash "delta" event)))))))

(defconst a2ui-agui--chunk-neutral-events
  '("RAW" "ACTIVITY_SNAPSHOT" "ACTIVITY_DELTA" "REASONING_ENCRYPTED_VALUE"
    "TEXT_MESSAGE_CHUNK" "TOOL_CALL_CHUNK")
  "Events that do not close an open chunk stream.")

(defun a2ui-agui-handle-event (agent event)
  "Fold the AG-UI EVENT, a parsed object, into AGENT."
  (run-hook-with-args 'a2ui-agui-event-functions agent 'in event)
  (unless (member (gethash "type" event) a2ui-agui--chunk-neutral-events)
    (a2ui-agui--close-chunks agent))
  (a2ui-agui--handle agent event))

(defun a2ui-agui--handle (agent event)
  "Apply EVENT to AGENT, after chunk bookkeeping."
  (pcase (gethash "type" event)
    ("RUN_STARTED"
     (setf (a2ui-agui-agent-finished agent) nil)
     (a2ui-agui--status agent "running"))
    ("RUN_FINISHED" (a2ui-agui--run-finished agent event))
    ("RUN_ERROR"
     (setf (a2ui-agui-agent-finished agent) t)
     (a2ui-agui--status agent "error")
     (a2ui-agui--text agent "status" (format "[run failed: %s]" (gethash "message" event)))
     (message "a2ui: %s: %s" (a2ui-agui-agent-name agent) (gethash "message" event)))
    ("TEXT_MESSAGE_START"
     (let ((m (a2ui-agui--message agent (gethash "messageId" event))))
       (unless m
         (a2ui-agui--add-message agent (a2ui-obj "id" (gethash "messageId" event)
                                                 "role" (or (gethash "role" event) "assistant")
                                                 "content" "")))))
    ("TEXT_MESSAGE_CONTENT"
     (let ((m (a2ui-agui--assistant agent (gethash "messageId" event)))
           (delta (or (gethash "delta" event) "")))
       (puthash "content" (concat (or (gethash "content" m) "") delta) m)
       (a2ui-agui--text agent (or (gethash "role" m) "assistant") delta)))
    ("TEXT_MESSAGE_END"
     (a2ui-agui--text agent "end" ""))
    ((or "TEXT_MESSAGE_CHUNK" "TOOL_CALL_CHUNK") (a2ui-agui--handle-chunk agent event))
    ("TOOL_CALL_START"
     (let* ((id (gethash "toolCallId" event))
            (parent (or (gethash "parentMessageId" event) (concat "msg-" id)))
            (call (a2ui-obj "id" id "type" "function"
                            "function" (a2ui-obj "name" (gethash "toolCallName" event)
                                                 "arguments" "")))
            (m (a2ui-agui--assistant agent parent)))
       (puthash "toolCalls" (vconcat (gethash "toolCalls" m) (vector call)) m)
       (puthash id (list :name (gethash "toolCallName" event) :args "" :object call)
                (a2ui-agui-agent-tool-calls agent))))
    ("TOOL_CALL_ARGS"
     (let ((id (gethash "toolCallId" event)))
       (when (a2ui-agui--call agent id)
         (a2ui-agui--call-put agent id :args (concat (plist-get (a2ui-agui--call agent id) :args)
                                                     (or (gethash "delta" event) ""))))))
    ("TOOL_CALL_END"
     (when-let* ((id (gethash "toolCallId" event))
                 (call (a2ui-agui--call agent id)))
       (puthash "arguments" (plist-get call :args) (gethash "function" (plist-get call :object)))
       (a2ui-agui--call-put agent id :ended t)
       (when (equal (plist-get call :name) a2ui-agui-render-tool)
         (a2ui-agui--render agent id))))
    ("TOOL_CALL_RESULT"
     (let ((id (gethash "toolCallId" event))
           (content (gethash "content" event)))
       (a2ui-agui--add-message agent (a2ui-obj "id" (or (gethash "messageId" event) (a2ui-agui--uuid))
                                               "role" "tool" "toolCallId" id "content" content))
       (when (a2ui-agui--call agent id)
         (a2ui-agui--call-put agent id :answered t))
       (when-let* ((ops (a2ui-agui--operations-in content)))
         (a2ui-agui--apply-operations agent ops))))
    ("STATE_SNAPSHOT"
     (setf (a2ui-agui-agent-state agent) (or (gethash "snapshot" event) (a2ui-obj))))
    ("STATE_DELTA"
     (setf (a2ui-agui-agent-state agent)
           (a2ui-agui-json-patch (a2ui-agui-agent-state agent) (gethash "delta" event))))
    ("MESSAGES_SNAPSHOT"
     (setf (a2ui-agui-agent-messages agent)
           (seq-remove (lambda (m) (equal (gethash "role" m) "activity"))
                       (append (gethash "messages" event) nil)))
     ;; Calls the snapshot answers are answered.
     (dolist (m (a2ui-agui-agent-messages agent))
       (when-let* ((id (and (equal (gethash "role" m) "tool") (gethash "toolCallId" m))))
         (when (a2ui-agui--call agent id)
           (a2ui-agui--call-put agent id :answered t)))))
    ("ACTIVITY_SNAPSHOT"
     (when (equal (gethash "activityType" event) a2ui-agui-activity-type)
       (let* ((id (gethash "messageId" event))
              (old (gethash id (a2ui-agui-agent-activities agent)))
              (content (gethash "content" event)))
         (when (and (eq (gethash "replace" event) :false) (hash-table-p old) (hash-table-p content))
           (maphash (lambda (k v) (puthash k v old)) content)
           (setq content old))
         (a2ui-agui--activity agent id content))))
    ("ACTIVITY_DELTA"
     (when (equal (gethash "activityType" event) a2ui-agui-activity-type)
       (let ((id (gethash "messageId" event)))
         (a2ui-agui--activity agent id
                              (a2ui-agui-json-patch (or (gethash id (a2ui-agui-agent-activities agent))
                                                        (a2ui-obj))
                                                    (gethash "patch" event))))))
    (_ nil)))

(defun a2ui-agui--run-finished (agent event)
  "Handle RUN_FINISHED EVENT for AGENT: interrupts and render retries."
  (setf (a2ui-agui-agent-finished agent) t)
  (a2ui-agui--status agent "idle")
  (let ((outcome (gethash "outcome" event)))
    (if (and (hash-table-p outcome) (equal (gethash "type" outcome) "interrupt"))
        (progn (a2ui-agui--status agent "interrupted")
               (a2ui-agui--show-interrupts agent (gethash "interrupts" outcome)))
      ;; A render that failed validation goes straight back.
      (let (failed)
        (maphash (lambda (_id call)
                   (when (and (plist-get call :errors) (not (plist-get call :answered)))
                     (setq failed t)))
                 (a2ui-agui-agent-tool-calls agent))
        (when (and failed (< (a2ui-agui-agent-retries agent) a2ui-agui-render-retries))
          (cl-incf (a2ui-agui-agent-retries agent))
          (a2ui-agui--text agent "status" "[sending render errors back to the agent]")
          (setf (a2ui-agui-agent-continue agent) t))))))

;;;; Streaming

(defun a2ui-agui-sse-parse (pending chunk)
  "Split the SSE text PENDING plus CHUNK into complete events.
Return (EVENTS . REST): EVENTS lists the data strings of complete
events in order, and REST is the unfinished tail to pass as PENDING
next time.  Comments and fields other than `data' are ignored; an
event's `data' lines are joined with newlines."
  (let ((text (string-replace "\r" "" (concat pending chunk)))
        (start 0) end events)
    (while (setq end (string-search "\n\n" text start))
      (let (data)
        (dolist (line (split-string (substring text start end) "\n"))
          (when (string-prefix-p "data:" line)
            (push (string-remove-prefix " " (substring line 5)) data)))
        (when data
          (push (string-join (nreverse data) "\n") events)))
      (setq start (+ end 2)))
    (cons (nreverse events) (substring text start))))

(defun a2ui-agui-receive (agent chunk)
  "Feed CHUNK of AGENT's response stream through the event reducer."
  (pcase-let ((`(,events . ,rest) (a2ui-agui-sse-parse (a2ui-agui-agent-pending agent) chunk)))
    (setf (a2ui-agui-agent-pending agent) rest)
    (dolist (data events)
      (condition-case err
          (a2ui-agui-handle-event agent (a2ui-json-parse data))
        (error (message "a2ui: bad AG-UI event from %s: %s"
                        (a2ui-agui-agent-name agent) (error-message-string err)))))))

(defun a2ui-agui--run-ended (agent exit-code error-text)
  "Finish AGENT's run after its stream closed with EXIT-CODE.
ERROR-TEXT is what curl or the server said on failure."
  (setf (a2ui-agui-agent-process agent) nil)
  (cond
   ((equal (a2ui-agui-agent-status agent) "aborted"))
   ((not (zerop exit-code))
    (a2ui-agui--status agent "error")
    (let ((text (string-trim (concat error-text "\n" (a2ui-agui-agent-pending agent)))))
      (a2ui-agui--text agent "status" (format "[request failed: %s]" text))
      (message "a2ui: %s: request failed: %s" (a2ui-agui-agent-name agent) text)))
   ((not (a2ui-agui-agent-finished agent))
    (a2ui-agui--status agent "error")
    (a2ui-agui--text agent "status" "[stream ended before the run finished]"))
   ((a2ui-agui-agent-continue agent)
    (setf (a2ui-agui-agent-continue agent) nil)
    (a2ui-agui-run agent))))

(defun a2ui-agui--curl-config (url headers)
  "Return a curl config for URL and the alist HEADERS, read from stdin.
Keeping headers off the command line keeps tokens out of `ps'."
  (let ((q (lambda (s) (concat "\"" (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" s) "\""))))
    (concat (format "url = %s\n" (funcall q url))
            (mapconcat (lambda (h) (format "header = %s\n" (funcall q (format "%s: %s" (car h) (cdr h)))))
                       headers ""))))

(defun a2ui-agui--headers (config)
  "Return the request headers for agent CONFIG, values resolved."
  (append '(("Content-Type" . "application/json")
            ("Accept" . "text/event-stream"))
          (mapcar (lambda (h)
                    (cons (car h) (if (functionp (cdr h)) (funcall (cdr h) config) (cdr h))))
                  (plist-get config :headers))))

(defun a2ui-agui--curl-post (agent body)
  "POST BODY to AGENT's endpoint with curl; return the process."
  (let* ((config (a2ui-agui-agent-config agent))
         (file (make-temp-file "a2ui-agui-" nil ".json" body))
         (stderr (generate-new-buffer " *a2ui-agui-stderr*"))
         (proc (make-process
                :name (format "a2ui-agui-%s" (a2ui-agui-agent-name agent))
                :command (list a2ui-agui-curl-program "--silent" "--show-error" "--no-buffer"
                               "--fail-with-body" "--connect-timeout" "10"
                               "--data-binary" (concat "@" file) "--config" "-")
                :coding 'utf-8-unix
                :connection-type 'pipe
                :noquery t
                :stderr stderr
                :filter (lambda (_proc chunk) (a2ui-agui-receive agent chunk))
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (ignore-errors (delete-file file))
                    (let ((text (if (buffer-live-p stderr)
                                    (with-current-buffer stderr (buffer-string))
                                  "")))
                      (when (buffer-live-p stderr) (kill-buffer stderr))
                      (a2ui-agui--run-ended agent (process-exit-status proc) text)))))))
    (process-send-string proc (a2ui-agui--curl-config (plist-get config :url)
                                                      (a2ui-agui--headers config)))
    (process-send-eof proc)
    proc))

;;;; JSON Patch

(defun a2ui-agui--patch-parent (doc segments)
  "Return the node in DOC holding the target of SEGMENTS."
  (let ((node doc))
    (dolist (seg (butlast segments) node)
      (setq node (cond ((hash-table-p node) (gethash seg node))
                       ((vectorp node) (aref node (string-to-number seg)))
                       (t (signal 'a2ui-error (list (format "No container at %s" seg)))))))))

(defun a2ui-agui--patch-put (doc segments value)
  "Return DOC with the node at SEGMENTS replaced by VALUE."
  (if (null segments)
      value
    (let ((parent (a2ui-agui--patch-parent doc segments))
          (key (car (last segments))))
      (if (hash-table-p parent)
          (puthash key value parent)
        (aset parent (string-to-number key) value))
      doc)))

(defun a2ui-agui--patch-add (doc segments value)
  "Return DOC with VALUE added at SEGMENTS, inserting into arrays."
  (let ((parent (and segments (a2ui-agui--patch-parent doc segments)))
        (key (car (last segments))))
    (if (vectorp parent)
        (let ((i (if (equal key "-") (length parent) (string-to-number key))))
          (a2ui-agui--patch-put doc (butlast segments)
                                (vconcat (seq-subseq parent 0 i) (vector value)
                                         (seq-subseq parent i))))
      (a2ui-agui--patch-put doc segments value))))

(defun a2ui-agui--patch-remove (doc segments)
  "Return DOC with the node at SEGMENTS removed, closing array gaps."
  (let ((parent (a2ui-agui--patch-parent doc segments))
        (key (car (last segments))))
    (if (hash-table-p parent)
        (progn (remhash key parent) doc)
      (let ((i (string-to-number key)))
        (a2ui-agui--patch-put doc (butlast segments)
                              (vconcat (seq-subseq parent 0 i) (seq-subseq parent (1+ i))))))))

(defun a2ui-agui--json-equal (a b)
  "Return non-nil when the JSON values A and B are equal."
  (cond ((and (hash-table-p a) (hash-table-p b))
         (and (= (hash-table-count a) (hash-table-count b))
              (catch 'differ
                (maphash (lambda (k v)
                           (unless (a2ui-agui--json-equal v (gethash k b 'absent))
                             (throw 'differ nil)))
                         a)
                t)))
        ((and (vectorp a) (vectorp b))
         (and (= (length a) (length b))
              (cl-every #'a2ui-agui--json-equal a b)))
        ((and (numberp a) (numberp b)) (= a b))
        (t (equal a b))))

(defun a2ui-agui-json-patch (doc patch)
  "Apply the RFC 6902 JSON PATCH, a vector of operations, to DOC.
Return the new document; DOC may be modified."
  (seq-doseq (op patch)
    (let ((path (a2ui-pointer-segments (gethash "path" op)))
          (from (gethash "from" op)))
      (pcase (gethash "op" op)
        ("add" (setq doc (a2ui-agui--patch-add doc path (gethash "value" op))))
        ("remove" (setq doc (a2ui-agui--patch-remove doc path)))
        ("replace" (setq doc (a2ui-agui--patch-put doc path (gethash "value" op))))
        ("move" (let ((value (a2ui-pointer-get doc from)))
                  (setq doc (a2ui-agui--patch-add
                             (a2ui-agui--patch-remove doc (a2ui-pointer-segments from))
                             path value))))
        ("copy" (setq doc (a2ui-agui--patch-add
                           doc path (a2ui-json-parse (a2ui-json-encode (a2ui-pointer-get doc from))))))
        ("test" (unless (a2ui-agui--json-equal (a2ui-pointer-get doc (gethash "path" op))
                                               (gethash "value" op))
                  (signal 'a2ui-error (list (format "JSON Patch test failed at %s"
                                                    (gethash "path" op))))))
        (other (signal 'a2ui-error (list (format "Unknown JSON Patch op %s" other)))))))
  doc)

;;;; Authentication

(defun a2ui-agui-auth-from-authinfo (config)
  "Return a bearer Authorization value for agent CONFIG from auth-source.
The secret is looked up by the host of CONFIG's :url."
  (let* ((host (url-host (url-generic-parse-url (plist-get config :url))))
         (secret (auth-source-pick-first-password :host host)))
    (unless secret
      (user-error "No auth-source entry for host %s" host))
    (concat "Bearer " secret)))

;;;; Transcript

(defface a2ui-agui-user '((t :inherit bold))
  "Face for the user's messages in an agent transcript." :group 'a2ui-agui)
(defface a2ui-agui-status '((t :inherit shadow))
  "Face for status lines in an agent transcript." :group 'a2ui-agui)

(defvar-local a2ui-agui--transcript-agent nil
  "The agent whose conversation this buffer shows.")

(define-derived-mode a2ui-agui-transcript-mode special-mode "A2UI-Agent"
  "Major mode for the transcript of a conversation with an AG-UI agent."
  (setq-local mode-line-process
              '(:eval (when a2ui-agui--transcript-agent
                        (format " [%s]" (a2ui-agui-agent-status a2ui-agui--transcript-agent)))))
  (visual-line-mode 1))

(defun a2ui-agui-transcript (agent)
  "Return AGENT's transcript buffer, creating it if needed."
  (let ((buffer (a2ui-agui-agent-transcript agent)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create (format "*a2ui-agent: %s*" (a2ui-agui-agent-name agent))))
      (with-current-buffer buffer
        (a2ui-agui-transcript-mode)
        (setq a2ui-agui--transcript-agent agent))
      (setf (a2ui-agui-agent-transcript agent) buffer))
    buffer))

(defun a2ui-agui--paragraph ()
  "Start a new paragraph at point, the end of a transcript."
  (unless (bobp)
    (delete-region (save-excursion (skip-chars-backward "\n") (point)) (point))
    (insert "\n\n")))

(defun a2ui-agui--transcript-insert (agent role text)
  "Append TEXT from ROLE to AGENT's transcript."
  (with-current-buffer (a2ui-agui-transcript agent)
    (let ((inhibit-read-only t)
          (follow (= (point) (point-max))))
      (save-excursion
        (goto-char (point-max))
        (pcase role
          ("user" (a2ui-agui--paragraph)
                  (insert (propertize (concat "> " text) 'face 'a2ui-agui-user)))
          ("status" (a2ui-agui--paragraph)
                    (insert (propertize text 'face 'a2ui-agui-status)))
          ("end" nil)
          (_ (when (memq (get-text-property (max (point-min) (1- (point))) 'face)
                         '(a2ui-agui-user a2ui-agui-status))
               (a2ui-agui--paragraph))
             (insert text))))
      (when follow (goto-char (point-max))))))

(add-hook 'a2ui-agui-text-functions #'a2ui-agui--transcript-insert)

;;;; Commands

(defun a2ui-agui--read-agent ()
  "Read an agent name from `a2ui-agui-agents', or a URL."
  (completing-read "Agent (name or URL): " (mapcar #'car a2ui-agui-agents)))

;;;###autoload
(defun a2ui-agui-connect (name)
  "Start a new thread with the agent NAME and make it current.
NAME is a key of `a2ui-agui-agents', or an AG-UI endpoint URL."
  (interactive (list (a2ui-agui--read-agent)))
  (let* ((config (or (cdr (assoc name a2ui-agui-agents))
                     (if (string-match-p "\\`https?://" name)
                         (list :url name)
                       (user-error "Unknown agent %s; see `a2ui-agui-agents'" name))))
         (agent (a2ui-agui-create name config)))
    (setq a2ui-agui-current-agent agent)
    (display-buffer (a2ui-agui-transcript agent))
    agent))

;;;###autoload
(defun a2ui-agui-send (text)
  "Send TEXT to the current agent; surfaces appear as it responds."
  (interactive (list (read-string (format "Message to %s: "
                                          (if a2ui-agui-current-agent
                                              (a2ui-agui-agent-name a2ui-agui-current-agent)
                                            "agent")))))
  (let ((agent (or a2ui-agui-current-agent (call-interactively #'a2ui-agui-connect))))
    (display-buffer (a2ui-agui-transcript agent))
    (a2ui-agui-send-message agent text)))

(defun a2ui-agui-abort ()
  "Stop the current agent's run."
  (interactive)
  (if-let* ((agent a2ui-agui-current-agent)
            (proc (a2ui-agui-agent-process agent)))
      (progn (setf (a2ui-agui-agent-finished agent) t)
             (delete-process proc)
             (a2ui-agui--status agent "aborted")
             (a2ui-agui--text agent "status" "[aborted]"))
    (message "No run in progress")))

(provide 'a2ui-agui)
;;; a2ui-agui.el ends here
