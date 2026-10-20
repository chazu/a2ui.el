;;; a2ui.el --- Generative UI: render A2UI agent surfaces in buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/a2ui.el
;; Version: 0.1.2
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
(require 'a2ui-tools)
(require 'a2ui-agui)
(require 'a2ui-mcp)

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

(defcustom a2ui-log-max-size 2000000
  "Most characters each log buffer keeps; the oldest lines go first.
Nil keeps everything."
  :type '(choice (const :tag "Unlimited" nil) natnum)
  :group 'a2ui)

(defun a2ui--log-trim (&optional separator)
  "Drop the oldest entries of the current log past `a2ui-log-max-size'.
Entries end with SEPARATOR, a newline by default."
  (when (and a2ui-log-max-size (> (buffer-size) a2ui-log-max-size))
    (let ((inhibit-read-only t))
      (delete-region (point-min)
                     (save-excursion
                       (goto-char (- (point-max) a2ui-log-max-size))
                       (if (search-forward (or separator "\n") nil t)
                           (point)
                         (point-max)))))))

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
          (insert "\n")
          (a2ui--log-trim "\n\n"))
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
                  "\n")
          (a2ui--log-trim))))))

(add-hook 'a2ui-agui-event-functions #'a2ui--log-agui)
(add-hook 'a2ui-agui-session-functions #'a2ui-vui-attach)
(add-hook 'a2ui-tools-host-functions #'a2ui-vui-attach)

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

;;;; Surface list

(defun a2ui--live-surfaces ()
  "Return (SESSION . SURFACE) for every surface the renderer knows."
  (let (out)
    (maphash (lambda (session _views)
               (dolist (id (a2ui-session-surface-ids session))
                 (push (cons session (a2ui-session-surface session id)) out)))
             a2ui-vui--views)
    (nreverse out)))

(defun a2ui--surface-list-entries ()
  "Return the `tabulated-list-entries' of `a2ui-surface-list-mode'."
  (mapcar (lambda (entry)
            (let* ((session (car entry))
                   (surface (cdr entry))
                   (id (a2ui-surface-id surface))
                   (buffer (car (a2ui-vui--view session id))))
              (list entry
                    (vector (or (a2ui-session-name session) "")
                            id
                            (file-name-nondirectory
                             (directory-file-name (or (a2ui-catalog-id (a2ui-surface-catalog surface)) "")))
                            (number-to-string (hash-table-count (a2ui-surface-components surface)))
                            (if (buffer-live-p buffer) (buffer-name buffer) "")))))
          (a2ui--live-surfaces)))

(defun a2ui-surface-list-visit ()
  "Show the surface on this line."
  (interactive)
  (when-let* ((entry (tabulated-list-get-id)))
    (pop-to-buffer (a2ui-show-surface (car entry) (a2ui-surface-id (cdr entry))))))

(defun a2ui-surface-list-delete ()
  "Delete the surface on this line, after asking."
  (interactive)
  (when-let* ((entry (tabulated-list-get-id))
              (id (a2ui-surface-id (cdr entry))))
    (when (yes-or-no-p (format "Delete surface %s? " id))
      (let ((buffer (car (a2ui-vui--view (car entry) id))))
        (a2ui-delete-surface (car entry) id)
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (tabulated-list-revert))))

(defvar-keymap a2ui-surface-list-mode-map
  :doc "Keymap for `a2ui-list-surfaces'."
  "RET" #'a2ui-surface-list-visit
  "d" #'a2ui-surface-list-delete)

(define-derived-mode a2ui-surface-list-mode tabulated-list-mode "A2UI Surfaces"
  "Major mode listing live A2UI surfaces.
\\<a2ui-surface-list-mode-map>\\[a2ui-surface-list-visit] shows a surface, \\[a2ui-surface-list-delete] deletes it and \\`g' refreshes."
  (setq tabulated-list-format [("Session" 24 t) ("Surface" 24 t) ("Catalog" 10 t)
                               ("Components" 10 t :right-align t) ("Buffer" 0 t)]
        tabulated-list-entries #'a2ui--surface-list-entries)
  (tabulated-list-init-header))

;;;###autoload
(defun a2ui-list-surfaces ()
  "List the live A2UI surfaces of every session."
  (interactive)
  (with-current-buffer (get-buffer-create "*a2ui surfaces*")
    (a2ui-surface-list-mode)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

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
