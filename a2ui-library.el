;;; a2ui-library.el --- Save and recall named A2UI surfaces -*- lexical-binding: t; -*-

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

;; Persist declarative surface snapshots as JSON in a repository library.
;; Files contain components and current data, never executable Lisp or
;; conversation state.  Recalled actions belong to the receiving session.

;;; Code:

(require 'a2ui-core)
(require 'json)
(require 'project)

(defcustom a2ui-library-directory ".a2ui"
  "Directory for saved UIs.
A relative name is resolved at the session's project root, or its
working directory outside a project.  An absolute name selects a
shared library.  The directory is created on the first save."
  :type 'directory
  :group 'a2ui)

(defun a2ui-library-directory (session)
  "Return the library directory for SESSION."
  (let* ((directory (a2ui-session-directory session))
         (project (and (not (file-name-absolute-p a2ui-library-directory))
                       (project-current nil directory))))
    (file-name-as-directory
     (expand-file-name a2ui-library-directory
                       (if project (project-root project) directory)))))

(defun a2ui-library--file (session name)
  "Return SESSION's library file for NAME, rejecting unsafe names or links."
  (unless (and (stringp name)
               (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" name))
    (signal 'a2ui-error '("UI name must start with a letter or digit and contain only letters, digits, - or _")))
  (let* ((directory (a2ui-library-directory session))
         (file (expand-file-name (concat name ".json") directory)))
    (when (or (file-symlink-p (directory-file-name directory))
              (file-symlink-p file))
      (signal 'a2ui-error '("Saved UI directories and files must not be symbolic links")))
    file))

(defun a2ui-library--snapshot (surface description)
  "Return a JSON snapshot of SURFACE with DESCRIPTION."
  (a2ui-obj
   "format" "a2ui-library" "version" 1 "description" (or description "")
   "surface" (a2ui-obj
              "surfaceId" (a2ui-surface-id surface)
              "catalogId" (a2ui-catalog-id (a2ui-surface-catalog surface))
              "theme" (a2ui-surface-theme surface)
              "sendDataModel" (a2ui-bool (a2ui-surface-send-data-model surface))
              "components" (vconcat
                            (sort (hash-table-values (a2ui-surface-components surface))
                                  (lambda (a b) (string< (gethash "id" a) (gethash "id" b)))))
              "data" (a2ui-surface-data surface))))

(defun a2ui-library--read (file)
  "Read a saved UI from FILE and check its envelope."
  (let ((snapshot (with-temp-buffer
                    (insert-file-contents file)
                    (a2ui-json-parse (buffer-string)))))
    (unless (and (hash-table-p snapshot)
                 (equal (gethash "format" snapshot) "a2ui-library")
                 (equal (gethash "version" snapshot) 1)
                 (stringp (gethash "description" snapshot))
                 (hash-table-p (gethash "surface" snapshot)))
      (signal 'a2ui-error '("Unsupported saved UI format; expected a2ui-library version 1")))
    snapshot))

(defun a2ui-library--validate (session snapshot &optional surface-id)
  "Validate SNAPSHOT for SESSION and return a detached surface.
SURFACE-ID overrides the stored id.  Validation has no visible side effects."
  (let* ((body (gethash "surface" snapshot))
         (id (or surface-id (gethash "surfaceId" body)))
         (components (gethash "components" body))
         (errors nil)
         (a2ui-message-functions nil)
         (scratch (a2ui-session-create
                   :catalogs nil :directory (a2ui-session-directory session)
                   :send-action-fn (lambda (message _metadata)
                                     (when (gethash "error" message)
                                       (push (gethash "message" (gethash "error" message)) errors))))))
    (unless (and (stringp id) (not (string-empty-p id))
                 (stringp (gethash "catalogId" body))
                 (vectorp components)
                 (not (eq (gethash "data" body 'absent) 'absent))
                 (memq (gethash "sendDataModel" body) '(t :false))
                 (or (null (gethash "theme" body)) (hash-table-p (gethash "theme" body))))
      (signal 'a2ui-error '("Invalid saved UI surface")))
    (setf (a2ui-session-catalogs scratch) (a2ui-session-catalogs session))
    (dolist (operation
             (list (a2ui-obj "createSurface"
                              (a2ui-obj "surfaceId" id "catalogId" (gethash "catalogId" body)
                                        "theme" (gethash "theme" body)
                                        "sendDataModel" (gethash "sendDataModel" body)))
                   (a2ui-obj "updateComponents" (a2ui-obj "surfaceId" id "components" components))
                   (a2ui-obj "updateDataModel" (a2ui-obj "surfaceId" id "path" "/"
                                                        "value" (gethash "data" body)))))
      (a2ui-apply-message scratch operation))
    (when errors
      (signal 'a2ui-error (list (string-join (nreverse errors) "; "))))
    (let ((surface (a2ui-session-surface scratch id)))
      (unless (a2ui-surface-component surface "root")
        (signal 'a2ui-error '("Saved UI needs a root component")))
      surface)))

(defun a2ui-library-save (session surface-id name &optional description overwrite)
  "Save SESSION's SURFACE-ID as NAME with DESCRIPTION; return its file.
Include the current data model.  Refuse existing files unless OVERWRITE
is non-nil.  Write atomically so a failed save leaves the old file intact."
  (let* ((file (a2ui-library--file session name))
         (surface (a2ui-session-surface session surface-id)))
    (unless surface
      (signal 'a2ui-error (list (format "No surface %s; render it first" surface-id))))
    (unless (or (null description) (stringp description))
      (signal 'a2ui-error '("description must be a string")))
    (when (and (file-exists-p file) (not overwrite))
      (signal 'a2ui-error '("Saved UI already exists; use overwrite to replace it")))
    (let ((snapshot (a2ui-library--snapshot surface description))
          temporary)
      (a2ui-library--validate session snapshot)
      (make-directory (file-name-directory file) t)
      (unwind-protect
          (progn
            (setq temporary (make-temp-file (expand-file-name ".a2ui-" (file-name-directory file))))
            (with-temp-buffer
              (let ((json (a2ui-json-encode snapshot)))
                (insert (if (multibyte-string-p json) json
                          (decode-coding-string json 'utf-8))))
              (json-pretty-print-buffer)
              (insert "\n")
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (point-min) (point-max) temporary nil 'silent)))
            (rename-file temporary file overwrite)
            file)
        (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))

(defun a2ui-library-list (session)
  "Return a vector of saved UI names and descriptions for SESSION.
Report unreadable or unsupported files as entries with an error field."
  (let ((directory (a2ui-library-directory session)))
    ;; Check the directory even when it is empty.
    (a2ui-library--file session "check")
    (vconcat
     (when (file-directory-p directory)
       (mapcar
        (lambda (file)
          (let ((name (file-name-base file)))
            (condition-case err
                (let ((snapshot (a2ui-library--read (a2ui-library--file session name))))
                  (a2ui-obj "name" name "description" (gethash "description" snapshot)))
              (error (a2ui-obj "name" name "error" (error-message-string err))))))
        (directory-files directory t "\\.json\\'"))))))

(defun a2ui-library-recall (session name &optional surface-id data)
  "Recall NAME into SESSION, optionally using SURFACE-ID; return its id.
DATA, a JSON object, replaces the saved data's top-level keys it
names, so one call can recall a UI and fill it in.  Validate before
replacing any existing surface.  Buttons send actions to SESSION, and
relative file references use SESSION's directory."
  (unless (or (null data) (hash-table-p data))
    (signal 'a2ui-error '("data must be an object of top-level keys to replace")))
  (let* ((snapshot (a2ui-library--read (a2ui-library--file session name)))
         (surface (a2ui-library--validate session snapshot surface-id))
         (id (a2ui-surface-id surface)))
    (when data
      (let ((model (a2ui-surface-data surface)))
        (unless (hash-table-p model)
          (setq model (a2ui-obj))
          (setf (a2ui-surface-data surface) model))
        (maphash (lambda (k v) (puthash k v model)) data)))
    (setf (a2ui-surface-session surface) session)
    (puthash id surface (a2ui-session-surfaces session))
    (a2ui--notify session (list id))
    id))

(provide 'a2ui-library)
;;; a2ui-library.el ends here
