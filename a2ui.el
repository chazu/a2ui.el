;;; a2ui.el --- Generative UI: render A2UI agent surfaces in buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/a2ui.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vui "1.4.0"))
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

;; a2ui.el lets agents that speak A2UI (https://a2ui.org) draw native,
;; interactive UI in Emacs buffers: forms, lists, cards and pickers
;; bound to a live data model.
;;
;; This file holds the user commands.  The protocol lives in
;; `a2ui-core' and the renderer in `a2ui-vui'; other packages can use
;; those two directly with their own transport.
;;
;; To talk to an AG-UI agent, configure `a2ui-agui-agents' and run
;; `a2ui-agui-send'.  Without an agent, `a2ui-replay-file' feeds a
;; JSONL file of A2UI messages into a local session.  `a2ui-show-log'
;; shows every A2UI message in and out, and `a2ui-agui-show-log' the
;; raw AG-UI traffic.

;;; Code:

(require 'a2ui-core)
(require 'a2ui-vui)
(require 'a2ui-emacs)
(require 'a2ui-agui)

(defcustom a2ui-log-buffer-name "*a2ui-log*"
  "Name of the buffer recording protocol messages."
  :type 'string
  :group 'a2ui)

(defcustom a2ui-log-messages t
  "When non-nil, record every protocol message in the log buffer."
  :type 'boolean
  :group 'a2ui)

(defcustom a2ui-agui-log-buffer-name "*a2ui-agui-log*"
  "Name of the buffer recording AG-UI runs and events."
  :type 'string
  :group 'a2ui)

(defcustom a2ui-agui-log-events t
  "When non-nil, record AG-UI traffic, one event per line."
  :type 'boolean
  :group 'a2ui)

;;;; Log

(defun a2ui--log-buffer ()
  "Return the log buffer, creating it in `special-mode' if needed."
  (or (get-buffer a2ui-log-buffer-name)
      (with-current-buffer (get-buffer-create a2ui-log-buffer-name)
        (special-mode)
        (current-buffer))))

(defun a2ui--pretty-json (value)
  "Return VALUE as indented JSON."
  (with-temp-buffer
    (insert (a2ui-json-encode value))
    (json-pretty-print-buffer)
    (buffer-string)))

(defun a2ui--log-message (direction session message metadata)
  "Append MESSAGE, going in DIRECTION for SESSION, to the log.
METADATA is shown after outbound messages that carry it."
  (when a2ui-log-messages
    (with-current-buffer (a2ui--log-buffer)
      (let ((inhibit-read-only t)
            (moving (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize (format "%s %s %s\n"
                                      (format-time-string "%T.%3N")
                                      (if (eq direction 'in) "<- in " "-> out")
                                      (or (a2ui-session-name session) ""))
                              'face (if (eq direction 'in) 'font-lock-comment-face 'bold))
                  (a2ui--pretty-json message) "\n")
          (when metadata
            (insert (propertize "metadata:\n" 'face 'shadow)
                    (a2ui--pretty-json metadata) "\n"))
          (insert "\n"))
        (when moving (goto-char (point-max)))))))

(add-hook 'a2ui-message-functions #'a2ui--log-message)

(defun a2ui--log-agui (agent direction object)
  "Record OBJECT, an AG-UI event or run input going DIRECTION for AGENT."
  (when a2ui-agui-log-events
    (with-current-buffer (or (get-buffer a2ui-agui-log-buffer-name)
                             (with-current-buffer (get-buffer-create a2ui-agui-log-buffer-name)
                               (special-mode)
                               (current-buffer)))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize (format "%s %s %s " (format-time-string "%T.%3N")
                                      (if (eq direction 'in) "<-" "->")
                                      (a2ui-agui-agent-name agent))
                              'face 'shadow)
                  (if (eq direction 'in)
                      (a2ui-json-encode object)
                    ;; The run input repeats the whole history and the
                    ;; catalog; log its shape, not all of it.
                    (format "RunAgentInput runId=%s messages=%d resume=%s"
                            (gethash "runId" object) (length (gethash "messages" object))
                            (if (gethash "resume" object) "yes" "no")))
                  "\n"))))))

(add-hook 'a2ui-agui-event-functions #'a2ui--log-agui)
(add-hook 'a2ui-agui-session-functions #'a2ui-vui-attach)

;;;###autoload
(defun a2ui-agui-show-log ()
  "Show the log of AG-UI runs and events."
  (interactive)
  (display-buffer (get-buffer-create a2ui-agui-log-buffer-name)))

;;;###autoload
(defun a2ui-show-log ()
  "Show the log of A2UI messages sent and received."
  (interactive)
  (display-buffer (a2ui--log-buffer)))

;;;; Replay

(defvar a2ui-replay-session nil
  "The session created by the last `a2ui-replay-file'.")

;;;###autoload
(defun a2ui-replay-file (file)
  "Feed the A2UI messages in FILE, one JSON object per line, to a new session.
Surfaces are displayed as they are created.  Actions go to the log,
since there is no agent to receive them.  Return the session."
  (interactive "fA2UI messages (.jsonl): ")
  (let ((session (a2ui-session-create
                  :name (format "replay:%s" (file-name-nondirectory file))
                  :send-action-fn
                  (lambda (message _metadata)
                    (when-let* ((action (gethash "action" message)))
                      (message "a2ui: action %s sent (see %s)"
                               (gethash "name" action) a2ui-log-buffer-name))))))
    (a2ui-vui-attach session)
    (dolist (m (a2ui-read-jsonl file))
      (a2ui-apply-message session m))
    (setq a2ui-replay-session session)))

(provide 'a2ui)
;;; a2ui.el ends here
