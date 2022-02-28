;;; magit-transient.el --- support for transients  -*- lexical-binding: t -*-

;; Copyright (C) 2008-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This library implements Magit-specific prefix and suffix classes,
;; and their methods.

;;; Code:

(require 'magit-git)
(require 'magit-mode)
(require 'magit-process)

(require 'transient)

;;; Classes

(defclass magit--git-variable (transient-variable)
  ((scope       :initarg :scope)
   (global      :initarg :global      :initform nil)))

(defclass magit--git-variable:choices (magit--git-variable)
  ((choices     :initarg :choices)
   (fallback    :initarg :fallback    :initform nil)
   (default     :initarg :default     :initform nil)))

(defclass magit--git-variable:urls (magit--git-variable)
  ((seturl-arg  :initarg :seturl-arg  :initform nil)))

;;; Methods
;;;; Init

(cl-defmethod transient-init-scope ((obj magit--git-variable))
  (oset obj scope
        (cond (transient--prefix
               (oref transient--prefix scope))
              ((slot-boundp obj 'scope)
               (funcall (oref obj scope) obj)))))

(cl-defmethod transient-init-value ((obj magit--git-variable))
  (let ((variable (format (oref obj variable)
                          (oref obj scope)))
        (arg (if (oref obj global) "--global" "--local")))
    (oset obj variable variable)
    (oset obj value
          (cond ((oref obj multi-value)
                 (magit-get-all arg variable))
                (t
                 (magit-get arg variable))))))

;;;; Read

(cl-defmethod transient-infix-read :around ((obj magit--git-variable:urls))
  (transient--with-emergency-exit
    (transient--with-suspended-override
     (mapcar (lambda (url)
               (if (string-prefix-p "~" url)
                   (expand-file-name url)
                 url))
             (cl-call-next-method obj)))))

(cl-defmethod transient-infix-read ((obj magit--git-variable:choices))
  (let ((choices (oref obj choices)))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (if-let ((value (oref obj value)))
        (cadr (member value choices))
      (car choices))))

;;;; Readers

(defun magit-transient-read-person (prompt initial-input history)
  (magit-completing-read
   prompt
   (mapcar (lambda (line)
             (save-excursion
               (and (string-match "\\`[\s\t]+[0-9]+\t" line)
                    (list (substring line (match-end 0))))))
           (magit-git-lines "shortlog" "-n" "-s" "-e" "HEAD"))
   nil nil initial-input history))

(defun magit-transient-read-revision (prompt initial-input history)
  (or (magit-completing-read prompt (cons "HEAD" (magit-list-refnames))
                             nil nil initial-input history
                             (or (magit-branch-or-commit-at-point)
                                 (magit-get-current-branch)))
      (user-error "Nothing selected")))

;;;; Set

(cl-defmethod transient-infix-set ((obj magit--git-variable) value)
  (let ((variable (oref obj variable))
        (arg (if (oref obj global) "--global" "--local")))
    (oset obj value value)
    (if (oref obj multi-value)
        (magit-set-all value arg variable)
      (magit-set value arg variable))
    (magit-refresh)
    (unless (or value transient--prefix)
      (message "Unset %s" variable))))

(cl-defmethod transient-infix-set ((obj magit--git-variable:urls) values)
  (let ((previous (oref obj value))
        (seturl   (oref obj seturl-arg))
        (remote   (oref transient--prefix scope)))
    (oset obj value values)
    (dolist (v (-difference values previous))
      (magit-call-git "remote" "set-url" seturl "--add" remote v))
    (dolist (v (-difference previous values))
      (magit-call-git "remote" "set-url" seturl "--delete" remote
                      (concat "^" (regexp-quote v) "$")))
    (magit-refresh)))

;;;; Draw

(cl-defmethod transient-format-description ((obj magit--git-variable))
  (or (oref obj description)
      (oref obj variable)))

(cl-defmethod transient-format-value ((obj magit--git-variable))
  (if-let ((value (oref obj value)))
      (if (oref obj multi-value)
          (if (cdr value)
              (mapconcat (lambda (v)
                           (concat "\n     "
                                   (propertize v 'face 'transient-value)))
                         value "")
            (propertize (car value) 'face 'transient-value))
        (propertize (car (split-string value "\n"))
                    'face 'transient-value))
    (propertize "unset" 'face 'transient-inactive-value)))

(cl-defmethod transient-format-value ((obj magit--git-variable:choices))
  (let* ((variable (oref obj variable))
         (choices  (oref obj choices))
         (globalp  (oref obj global))
         (value    nil)
         (global   (magit-git-string "config" "--global" variable))
         (default  (oref obj default))
         (fallback (oref obj fallback))
         (fallback (and fallback
                        (when-let ((val (magit-get fallback)))
                          (concat fallback ":" val)))))
    (if (not globalp)
        (setq value (magit-git-string "config" "--local"  variable))
      (setq value global)
      (setq global nil))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (concat
     (propertize "[" 'face 'transient-inactive-value)
     (mapconcat (lambda (choice)
                  (propertize choice 'face (if (equal choice value)
                                               (if (member choice choices)
                                                   'transient-value
                                                 'font-lock-warning-face)
                                             'transient-inactive-value)))
                (if (and value (not (member value choices)))
                    (cons value choices)
                  choices)
                (propertize "|" 'face 'transient-inactive-value))
     (and (or global fallback default)
          (concat
           (propertize "|" 'face 'transient-inactive-value)
           (cond (global
                  (propertize (concat "global:" global)
                              'face (cond (value
                                           'transient-inactive-value)
                                          ((member global choices)
                                           'transient-value)
                                          (t
                                           'font-lock-warning-face))))
                 (fallback
                  (propertize fallback
                              'face (if value
                                        'transient-inactive-value
                                      'transient-value)))
                 (default
                   (propertize (concat "default:" default)
                               'face (if value
                                         'transient-inactive-value
                                       'transient-value))))))
     (propertize "]" 'face 'transient-inactive-value))))

;;; _
(provide 'magit-transient)
;;; magit-transient.el ends here
