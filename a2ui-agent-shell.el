;;; a2ui-agent-shell.el --- A2UI surfaces for agent-shell agents -*- lexical-binding: t; -*-

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

;; Lets the agents agent-shell runs (Claude Code, Codex, ...) draw A2UI
;; surfaces.  `a2ui-agent-shell-setup' adds an entry to
;; `agent-shell-mcp-servers'; when a shell starts, the entry gives it
;; its own endpoint on the `a2ui-mcp' server, so the agent gets the
;; `a2ui-tools'.  A button press comes back to the shell as the next
;; prompt, queued when the agent is busy.
;;
;; agent-shell is not required to load this file; it is used once a
;; shell asks for its endpoint.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'subr-x)
(require 'a2ui-tools)
(require 'a2ui-mcp)
(require 'a2ui-vui)

(defcustom a2ui-agent-shell-auto-approve t
  "When non-nil, agents may use a2ui's tools without asking each time.
The tools only draw UI in Emacs and report your clicks, so approving
them is safe; every other permission request is left to you.  Takes
effect through `a2ui-agent-shell-setup'."
  :type 'boolean
  :group 'a2ui)

(defcustom a2ui-agent-shell-inline-surfaces nil
  "When non-nil, draw surfaces in the agent-shell buffer itself.
Each new surface appears above the prompt when the agent's turn ends.
When nil, each surface gets a buffer of its own."
  :type 'boolean
  :group 'a2ui)

(defvar agent-shell-mcp-servers)
(defvar comint-last-prompt)
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(defvar agent-shell-permission-responder-function)
(declare-function agent-shell-insert "agent-shell" (&rest args))
(declare-function agent-shell-cwd "agent-shell" ())
(declare-function agent-shell--prompt-queue-enqueue "agent-shell-prompt-queue" (&rest args))
(declare-function shell-maker-busy "shell-maker" ())

(defvar-local a2ui-agent-shell--url nil
  "This shell's a2ui MCP endpoint.")

(defvar-local a2ui-agent-shell--pending nil
  "Ids of surfaces to draw inline when the agent's turn ends.")

(defvar-local a2ui-agent-shell--subscribed nil
  "Non-nil once this shell tells a2ui when turns end.")

(defun a2ui-agent-shell--show-inline (buffer session surface-id)
  "Draw SURFACE-ID of SESSION in shell BUFFER when the turn ends."
  (with-current-buffer buffer
    (unless (member surface-id a2ui-agent-shell--pending)
      (setq a2ui-agent-shell--pending (append a2ui-agent-shell--pending (list surface-id))))
    (unless a2ui-agent-shell--subscribed
      (setq a2ui-agent-shell--subscribed t)
      (agent-shell-subscribe-to :shell-buffer buffer :event 'turn-complete
                                :on-event (lambda (_)
                                            (a2ui-agent-shell--insert-pending buffer session))))
    (unless (and (fboundp 'shell-maker-busy) (shell-maker-busy))
      (a2ui-agent-shell--insert-pending buffer session))))

(defun a2ui-agent-shell--insert-pending (buffer session)
  "Draw BUFFER's waiting surfaces of SESSION above its prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((ids (prog1 a2ui-agent-shell--pending (setq a2ui-agent-shell--pending nil)))
                  (prompt (and comint-last-prompt (marker-position (car comint-last-prompt)))))
        (dolist (id ids)
          (when (a2ui-session-surface session id)
            ;; Plain newlines on both sides: the shell's own text is
            ;; read-only, and a surface re-renders at its edges.
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char prompt)
                (insert (propertize "\n\n" 'rear-nonsticky t))))
            (let ((instance (a2ui-vui-insert-surface session id (1+ prompt))))
              (setq prompt (1+ (or (cdr (vui--inline-bounds instance)) prompt))))))
        ;; The prompt moved down; keep comint's idea of it.
        (set-marker (car comint-last-prompt) prompt)))))

(defun a2ui-agent-shell--submit (buffer text)
  "Send TEXT to the agent in shell BUFFER, queued if it is busy."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (fboundp 'shell-maker-busy) (shell-maker-busy)
               (fboundp 'agent-shell--prompt-queue-enqueue))
          (agent-shell--prompt-queue-enqueue :prompt text)
        (agent-shell-insert :text text :submit t :no-focus t :shell-buffer buffer)))))

(defun a2ui-agent-shell-url ()
  "Return the current shell's a2ui MCP endpoint, making it on first use.
Called by agent-shell, in the shell buffer, when the shell starts."
  (or a2ui-agent-shell--url
      (let* ((buffer (current-buffer))
             (host (a2ui-tools-host-create
                    :name (buffer-name buffer)
                    :directory (if (fboundp 'agent-shell-cwd) (agent-shell-cwd) default-directory)
                    :deliver (lambda (text) (a2ui-agent-shell--submit buffer text))))
             (session (a2ui-tools-host-session host))
             (url (a2ui-mcp-register host)))
        (when a2ui-agent-shell-inline-surfaces
          (setf (a2ui-session-display-fn session)
                (lambda (id) (a2ui-agent-shell--show-inline buffer session id))))
        (add-hook 'kill-buffer-hook (lambda () (a2ui-mcp-unregister url)) nil t)
        (setq a2ui-agent-shell--url url))))

(defun a2ui-agent-shell-mcp-server ()
  "Return the `agent-shell-mcp-servers' entry for a2ui.
Its url is a function, which agent-shell calls when a shell starts."
  (list '(name . "a2ui")
        '(type . "http")
        '(headers . [])
        (cons 'url (lambda () (a2ui-agent-shell-url)))))

(defun a2ui-agent-shell-allow-a2ui (permission)
  "Approve PERMISSION when it asks to use one of a2ui's tools.
For `agent-shell-permission-responder-function': return non-nil when
handled, nil to let agent-shell ask as usual."
  (when (string-match-p "mcp__a2ui__"
                        (format "%s" (map-elt (map-elt permission :tool-call) :title)))
    (when-let* ((choice (seq-find (lambda (option) (equal (map-elt option :kind) "allow_once"))
                                  (map-elt permission :options))))
      (funcall (map-elt permission :respond) (map-elt choice :option-id))
      t)))

(defun a2ui-agent-shell--chain-responder (previous)
  "Return a permission responder that tries a2ui's, then PREVIOUS."
  (let ((responder (lambda (permission)
                     (or (a2ui-agent-shell-allow-a2ui permission)
                         (and (functionp previous) (funcall previous permission))))))
    (put 'a2ui-agent-shell--chain-responder 'installed responder)
    responder))

;;;###autoload
(defun a2ui-agent-shell-setup ()
  "Give agents started by agent-shell the A2UI tools from now on.
Adds the a2ui MCP server to `agent-shell-mcp-servers'; shells
started afterwards get it.  With `a2ui-agent-shell-auto-approve',
a2ui's tools are approved without asking."
  (interactive)
  (when (and a2ui-agent-shell-auto-approve
             (let ((installed (get 'a2ui-agent-shell--chain-responder 'installed)))
               (not (and installed
                         (eq installed (bound-and-true-p agent-shell-permission-responder-function))))))
    (setq agent-shell-permission-responder-function
          (a2ui-agent-shell--chain-responder
           (bound-and-true-p agent-shell-permission-responder-function))))
  ;; Before agent-shell loads, this makes the variable; its defcustom
  ;; then keeps the value.
  (setq agent-shell-mcp-servers
        (cons (a2ui-agent-shell-mcp-server)
              (seq-remove (lambda (s) (equal (alist-get 'name s) "a2ui"))
                          (bound-and-true-p agent-shell-mcp-servers)))))

(provide 'a2ui-agent-shell)
;;; a2ui-agent-shell.el ends here
