;;; devdocs-browser.el --- Browser documents in devdocs.io  -*- lexical-binding: t; -*-

;; Copyright (C) 2021

;; Author: blahgeek <i@blahgeek.com>
;; Keywords: docs, help, tools
;; Package-Requires: ((emacs "26.1"))

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

;; Browse devdocs documents in Emacs.

;;; Code:

(require 'files)
(require 'shr)
(require 'eww)


(defgroup devdocs-browser nil
  "Browse devdocs.io."
  :group 'tools
  :group 'web)

(defcustom devdocs-browser-cache-directory
  (expand-file-name "devdocs-browser" user-emacs-directory)
  "Directory to store devdocs cache files."
  :type 'directory
  :group 'devdocs-browser)

(defcustom devdocs-browser-base-url "https://devdocs.io/"
  "Base URL to fetch json metadata files."
  :type 'string)

(defcustom devdocs-browser-doc-base-url "https://documents.devdocs.io/"
  "Base URL for doc contents."
  :type 'string)

(defcustom devdocs-browser-major-mode-docs-alist
  '((c++-mode . ("cpp"))
    (python-mode . ("Python")))
  "Alist of MAJOR-MODE and list of docset names.
When calling `devdocs-browser-open', this variable will be used
to pick a list of docsets based on the current MAJOR-MODE.
Docset name may be SLUG (e.g. 'python~3.8') or NAME (e.g. 'Python'),
if it's a NAME and multiple choices are possible,
one of the installed docs with the NAME will be used.
Also see `devdocs-browser-active-docs'."
  :type '(alist :key-type function
                :value-type (list string)))

(defvar-local devdocs-browser-active-docs
  nil
  "List of docset names used by `devdocs-browser-open' to pick docsets.
If this var is set to non-nil,
it have higher priority than `devdocs-browser-major-mode-docs-alist'.
See `devdocs-browser-major-mode-docs-alist' for the meaning of NAME.")

(defcustom devdocs-browser-highlight-lang-mode-alist '()
  "Alist of language name and MAJOR-MODE, to highlight HTML pre blocks.
If language is not found in this alist,
`devdocs-browser-highlight-lang-mode-alist-default' will be used.
See https://prismjs.com/ for list of language names."
  :type '(alist :key-type string
                :value-type function))

(defvar devdocs-browser-highlight-lang-mode-alist-default
  '(("html" . html-mode)
    ("xml" . xml-mode)
    ("css" . css-mode)
    ("clike" . c-mode)
    ("javascript" . js-mode)
    ("js" . js-mode)
    ("bash" . sh-mode)
    ("shell" . sh-mode)
    ("c" . c-mode)
    ("cpp" . c++-mode)
    ("cmake" . cmake-mode)
    ("go" . go-mode)
    ("haskell" . haskell-mode)
    ("hs" . haskell-mode)
    ("java" . java-mode)
    ("json" . js-mode)
    ("elisp" . elisp-mode)
    ("emacs" . elisp-mode)
    ("lua" . lua-mode)
    ("makefile" . makefile-mode)
    ("markdown" . markdown-mode)
    ("md" . markdown-mode)
    ("nginx" . conf-mode)
    ("objectivec" . objc-mode)
    ("objc" . objc-mode)
    ("perl" . perl-mode)
    ("protobuf" . protobuf-mode)
    ("python" . python-mode)
    ("py" . python-mode)
    ("ruby" . ruby-mode)
    ("rb" . ruby-mode)
    ("sql" . sql-mode))
  "Default value for `devdocs-browser-highlight-lang-mode-alist'.")


(defun devdocs-browser--eww-fontify-pre (dom)
  "Return fontified string for pre DOM."
  (with-temp-buffer
    (shr-generic dom)
    (let* ((language (dom-attr dom 'data-language))
           (mode (cdr (or (assoc language devdocs-browser-highlight-lang-mode-alist)
                          (assoc language devdocs-browser-highlight-lang-mode-alist-default)))))
      (when (fboundp mode)
        (delay-mode-hooks (funcall mode))
        (font-lock-default-function mode)
        (font-lock-default-fontify-region (point-min) (point-max) nil)))
    (buffer-string)))

(defun devdocs-browser--eww-tag-pre (dom)
  "Rendering function for pre DOM."
  (let ((shr-folding-mode 'none)
        (shr-current-font 'default))
    (shr-ensure-newline)
    (insert (devdocs-browser--eww-fontify-pre dom))
    (shr-ensure-newline)))

(defun devdocs-browser--eww-tag-h1 (dom)
  "Rendering function for h1 DOM.  Maybe use it as title."
  (when (zerop (length (plist-get eww-data :title)))
    (message "updating title")
    (eww-tag-title dom))
  (shr-tag-h1 dom))

(defun devdocs-browser--eww-tag-h2 (dom)
  "Rendering function for h2 DOM."
  (shr-heading dom (if shr-use-fonts
                       '(variable-pitch (:height 1.2 :weight bold))
                     'bold)))

(defun devdocs-browser--eww-tag-h3 (dom)
  "Rendering function for h2 DOM."
  (shr-heading dom (if shr-use-fonts
                       '(variable-pitch (:height 1.1 :weight bold))
                     'bold)))

(defun devdocs-browser--eww-tag-h4 (dom)
  "Rendering function for h4 DOM."
  (shr-heading dom 'bold))

(defun devdocs-browser--eww-tag-h5 (dom)
  "Rendering function for h5 DOM."
  (shr-heading dom 'italic))

(defvar-local devdocs-browser--eww-data '()
  "Plist data for current eww page, contain :doc and :path.")

(defun devdocs-browser--eww-fix-url (url)
  "Fix links' URL in docs by appending suffix and mtime."
  ;; shr-expand-url may be call in a temp buffer
  ;; we need to temporary bind this buffer to access the buffer-local variable.
  (with-current-buffer (window-buffer)
    (when (and devdocs-browser--eww-data
               (not (string-match-p "\\.html" url)))
      (let ((url-parsed (url-generic-parse-url url))
            (mtime (plist-get (plist-get devdocs-browser--eww-data :doc) :mtime)))
        (setf (url-filename url-parsed)
              (if (equal (url-type url-parsed) "file")
                  (concat (url-filename url-parsed) ".html")
                (format "%s.html?%s" (url-filename url-parsed) mtime)))
        (setq url (url-recreate-url url-parsed)))))
  url)

(defun devdocs-browser--eww-page-targets ()
  "Return targets in current page, result is an alist of name and target."
  (when-let* ((doc (plist-get devdocs-browser--eww-data :doc))
              (entries (plist-get (plist-get doc :index) :entries))
              (page-path (plist-get devdocs-browser--eww-data :path))
              (page-url (url-generic-parse-url page-path)))
    (let (res)
      (mapc (lambda (entry)
              (when-let* ((name (plist-get entry :name))
                          (path (plist-get entry :path))
                          (url (url-generic-parse-url path))
                          (target (url-target url)))
                (when (equal (url-filename url) (url-filename page-url))
                  (setq res (push (cons name target) res)))))
            entries)
      res)))

(defun devdocs-browser-eww-goto-target (target)
  "Goto TARGET in current devdocs eww page."
  (interactive
   (let* ((rows (devdocs-browser--eww-page-targets))
          (selected-row
           (completing-read "Goto target: " rows nil t))
          (selected-target
           (cdr (assoc selected-row rows))))
     (list selected-target)))
  (goto-char (point-min))
  (let ((match (text-property-search-forward 'shr-target-id target t)))
    (when match
      (goto-char (prop-match-beginning match)))))

(defun devdocs-browser-eww-open-in-default-browser ()
  "Open current page in devdocs.io in browser."
  (interactive)
  (when-let* ((doc (plist-get devdocs-browser--eww-data :doc))
              (slug (plist-get doc :slug))
              (path (plist-get devdocs-browser--eww-data :path))
              (url (concat devdocs-browser-base-url slug "/" path)))
    (browse-url-default-browser url)))

(define-minor-mode devdocs-browser-eww-mode
  "Minor mode for browsing devdocs pages with eww."
  :lighter " Devdocs"
  :interactive nil
  :group 'devdocs-browser
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c r") #'devdocs-browser-eww-goto-target)
            (define-key map (kbd "C-c o") #'devdocs-browser-eww-open-in-default-browser)
            map)
  (setq-local shr-external-rendering-functions
              (append shr-external-rendering-functions
                      '((pre . devdocs-browser--eww-tag-pre)
                        (h1 . devdocs-browser--eww-tag-h1)
                        (h2 . devdocs-browser--eww-tag-h2)
                        (h3 . devdocs-browser--eww-tag-h3)
                        (h4 . devdocs-browser--eww-tag-h4)
                        (h5 . devdocs-browser--eww-tag-h5))))
  (advice-add 'shr-expand-url :filter-return #'devdocs-browser--eww-fix-url))

(defvar devdocs-browser--docs-dir "docs")
(defvar devdocs-browser--index-json-filename "index.json")
(defvar devdocs-browser--metadata-filename "metadata.el")
(defvar devdocs-browser--offline-data-json-filename "content.json")
(defvar devdocs-browser--offline-data-dir-name "content")

(defun devdocs-browser--json-parse-buffer ()
  "Same as `json-parse-buffer', with custom settings."
  (json-parse-buffer :object-type 'plist :array-type 'array))

(defun devdocs-browser--read-json (file-path)
  "Read json file in FILE-PATH, if it's a relative path, find it in cache dir."
  (let ((filename (expand-file-name file-path devdocs-browser-cache-directory)))
    (when (file-exists-p filename)
      (with-temp-buffer
        (insert-file-contents filename)
        (devdocs-browser--json-parse-buffer)))))

(defun devdocs-browser--fetch-json (url-path file-path &optional base-url)
  "Fetch json from BASE-URL / URL-PATH, also save to FILE-PATH.
BASE-URL defaults to `devdocs-browser-base-url'."
  (let ((cache-filename (expand-file-name file-path devdocs-browser-cache-directory)))
      (unless (file-exists-p (file-name-directory cache-filename))
        (make-directory (file-name-directory cache-filename) t))
      (with-temp-file cache-filename
        (erase-buffer)
        (url-insert-file-contents (concat (or base-url devdocs-browser-base-url) url-path))
        (devdocs-browser--json-parse-buffer))))


(defvar devdocs-browser--docs-list-cache nil "Cached docs list.")

;;;###autoload
(defun devdocs-browser-list-docs (&optional refresh-cache)
  "Get doc metadata lists, reload cache if REFRESH-CACHE."
  (setq devdocs-browser--docs-list-cache
        (or (and (not refresh-cache) devdocs-browser--docs-list-cache)
            (and (not refresh-cache) (devdocs-browser--read-json "docs.json"))
            (devdocs-browser--fetch-json "docs.json" "docs.json"))))

;;;###autoload
(defun devdocs-browser-update-docs ()
  "Update doc metadata list.
To upgrade docs content, see `devdocs-browser-upgrade-doc'."
  (interactive)
  (let ((count (length (devdocs-browser-list-docs t))))
    (message (concat "Doc metadata updated, found total %s docs. "
                     "You may want to run `devdocs-browser-install-doc' "
                     "or `devdocs-browser-upgrade-doc'.")
             count)))

(defun devdocs-browser-find-doc (slug-or-name)
  "Find doc from docs list by SLUG-OR-NAME."
  (let ((docs-list (devdocs-browser-list-docs)))
    (seq-find (lambda (doc)
                (or (equal (plist-get doc :slug) slug-or-name)
                    (equal (plist-get doc :name) slug-or-name)))
              docs-list)))

(defvar devdocs-browser--docs-cache '() "Cached doc indexes plist.")

(defun devdocs-browser--install-doc-internal (doc)
  "(Re-)install doc identified by plist DOC.  Return t if success."
  (let* ((slug (plist-get doc :slug))
         (mtime (plist-get doc :mtime))
         (docs-dir (expand-file-name devdocs-browser--docs-dir devdocs-browser-cache-directory))
         (doc-dir (expand-file-name slug docs-dir))
         success)
    (unless (file-exists-p docs-dir)
      (make-directory docs-dir t))
    (when (file-exists-p doc-dir)
      (delete-directory doc-dir t))

    ;; do not leave empty directory
    (unwind-protect
        (progn
          (devdocs-browser--fetch-json
           (format "docs/%s/index.json?%s" slug mtime)
           (expand-file-name devdocs-browser--index-json-filename doc-dir))
          (with-temp-file (expand-file-name devdocs-browser--metadata-filename doc-dir)
            (print doc (current-buffer)))
          (setq success t))
      (unless success
        (delete-directory doc-dir t)))

    (if success
        (message "Installed devdocs doc %s version %s" slug mtime)
      (message "Failed to install devdocs doc %s" slug))
    ;; remove cache
    (setq devdocs-browser--docs-cache
          (plist-put devdocs-browser--docs-cache slug nil))
    success))

(defun devdocs-browser--doc-readable-name (doc)
  "Get human readable name for DOC."
  (let ((slug (plist-get doc :slug))
        (name (plist-get doc :name))
        (version (plist-get doc :version))
        (release (plist-get doc :release))
        res)
    (setq res (concat slug " (" name))
    (unless (zerop (length version))
      (setq res (concat res " " version)))
    (unless (zerop (length release))
      (setq res (concat res ", " release)))
    (setq res (concat res ")"))
    res))

;;;###autoload
(defun devdocs-browser-install-doc (slug-or-name &optional force)
  "Install doc by SLUG-OR-NAME.
When called interactively, user can choose from the list.
When called interactively with prefix, or FORCE is t, reinstall existing doc."
  (interactive
   (let* ((force current-prefix-arg)
          (installed-docs
           (devdocs-browser-list-installed-slugs))
          (rows
           (mapcar (lambda (doc)
                     (let ((slug (plist-get doc :slug)))
                       (unless (and (not force)
                                    (member slug installed-docs))
                         (cons (devdocs-browser--doc-readable-name doc)
                               slug))))
                   (devdocs-browser-list-docs)))
          (selected-row
           (completing-read "Install doc: " (delq nil rows) nil t))
          (selected-slug
           (cdr (assoc selected-row rows))))
     (list selected-slug force)))
  (let ((doc (devdocs-browser-find-doc slug-or-name)))
    (unless (and (not force)
                 (member (plist-get doc :slug) (devdocs-browser-list-installed-slugs)))
      (devdocs-browser--install-doc-internal doc))))

;;;###autoload
(defun devdocs-browser-uninstall-doc (slug)
  "Uninstall doc by SLUG.
When called interactively, user can choose from the list."
  (interactive (list (completing-read "Uninstall doc: "
                                      (devdocs-browser-list-installed-slugs)
                                      nil t)))
  (let* ((docs-dir (expand-file-name devdocs-browser--docs-dir devdocs-browser-cache-directory))
         (doc-dir (expand-file-name slug docs-dir)))
    (when (file-exists-p doc-dir)
      (delete-directory doc-dir t)))
  (setq devdocs-browser--docs-cache
        (plist-put devdocs-browser--docs-cache slug nil)))

(defun devdocs-browser--upgrade-readable-name (old-doc new-doc)
  "Get humane readable name for upgrade from OLD-DOC to NEW-DOC."
  (let ((slug (plist-get old-doc :slug))
        (name (plist-get old-doc :name))
        (old-version (plist-get old-doc :version))
        (old-release (plist-get old-doc :release))
        (old-mtime (plist-get old-doc :mtime))
        (new-version (plist-get new-doc :version))
        (new-release (plist-get new-doc :release))
        (new-mtime (plist-get new-doc :mtime))
        res)
    (setq res (format "%s (%s" slug name))
    (when (not (equal old-version new-version))
      (setq res (concat res (format " %s->%s" old-version new-version))))
    (when (not (equal old-release new-release))
      (setq res (concat res (format ", %s->%s" old-release new-release))))
    (setq res (concat res (format ", %s->%s)" old-mtime new-mtime)))
    res))

(defun devdocs-browser--upgrade-readable-name-or-nil (slug)
  "Get human readable name for upgrading SLUG if it needs upgrade."
  (let ((old-doc (devdocs-browser--load-doc slug))
        (new-doc (devdocs-browser-find-doc slug)))
    (when (and new-doc
               (> (plist-get new-doc :mtime) (plist-get old-doc :mtime)))
      (devdocs-browser--upgrade-readable-name old-doc new-doc))))

;;;###autoload
(defun devdocs-browser-upgrade-doc (slug)
  "Upgrade doc by SLUG, return t if upgrade success.
Also download new version of offline data if
there's offline data for current version.
When called interactively, user can choose from list.
You may need to call `devdocs-browser-update-docs' first."
  (interactive
   (let (rows)
     (dolist (slug (devdocs-browser-list-installed-slugs))
       (let ((desc (devdocs-browser--upgrade-readable-name-or-nil slug)))
         (when desc
           (push (cons desc slug) rows))))
     (if (null rows)
         (progn
           (message "All docs up to date")
           (list nil))
       (list
        (cdr (assoc (completing-read "Upgrade doc: " rows nil t) rows))))))
  (when (and slug (devdocs-browser--upgrade-readable-name-or-nil slug))
    (let* ((has-offline-data (devdocs-browser-offline-data-dir slug))
           (doc (devdocs-browser-find-doc slug))
           (install-success (devdocs-browser--install-doc-internal doc)))
      (when (and has-offline-data install-success)
        (devdocs-browser--download-offline-data-internal doc))
      install-success)))

;;;###autoload
(defun devdocs-browser-upgrade-all-docs ()
  "Upgrade all docs."
  (interactive)
  (let ((count 0))
    (dolist (slug (devdocs-browser-list-installed-slugs))
      (message "Processing %s..." slug)
      (when (devdocs-browser-upgrade-doc slug)
        (setq count (1+ count))))
    (message "Upgraded %s docs" count)))

(defun devdocs-browser-list-installed-slugs ()
  "Get a list of installed docs' slug name."
  (let ((dir (expand-file-name devdocs-browser--docs-dir devdocs-browser-cache-directory)))
    (when (file-exists-p dir)
      (directory-files dir nil
                       ;; ignore ".", ".." and hidden files
                       "^[^.].*"))))

(defun devdocs-browser-find-installed-doc (slug-or-name)
  "Find installed doc by SLUG-OR-NAME."
  (let ((docs-list (mapcar #'devdocs-browser-installed-doc-info
                           (devdocs-browser-list-installed-slugs))))
    (seq-find (lambda (doc)
                (or (equal (plist-get doc :slug) slug-or-name)
                    (equal (plist-get doc :name) slug-or-name)))
              docs-list)))

(defun devdocs-browser-installed-doc-info (slug)
  "Get plist info of installed doc identified by SLUG."
  (cddr (devdocs-browser--load-doc slug)))

(defun devdocs-browser--load-doc (slug &optional refresh-cache)
  "Load doc identified by SLUG, reload cache if REFRESH-CACHE is not nil.
Result is a plist metadata, with an extra :index field at the beginning."
  (or (and (not refresh-cache) (plist-get devdocs-browser--docs-cache slug))
      (let* ((docs-dir (expand-file-name devdocs-browser--docs-dir
                                         devdocs-browser-cache-directory))
             (doc-dir (expand-file-name slug docs-dir))
             (metadata-filename (expand-file-name devdocs-browser--metadata-filename doc-dir))
             (metadata nil)
             (index-filename (expand-file-name devdocs-browser--index-json-filename doc-dir))
             (index (devdocs-browser--read-json index-filename))
             res)
        (when (file-exists-p metadata-filename)
          (with-temp-buffer
            (insert-file-contents metadata-filename)
            (setq metadata (read (current-buffer))))
          (setq res (append `(:index ,index) metadata))
          (setq devdocs-browser--docs-cache
                (plist-put devdocs-browser--docs-cache slug res)))
        res)))

(defun devdocs-browser--download-offline-data-internal (doc)
  "(re-)Download and extract offline data for DOC."
  (let* ((slug (plist-get doc :slug))
         (mtime (plist-get doc :mtime))
         (docs-dir (expand-file-name devdocs-browser--docs-dir devdocs-browser-cache-directory))
         (doc-dir (expand-file-name slug docs-dir))
         (data-dir (expand-file-name devdocs-browser--offline-data-dir-name doc-dir))
         success)
    (unless (file-exists-p doc-dir)
      (make-directory doc-dir t))
    (when (file-exists-p data-dir)
      (delete-directory data-dir t))

    ;; do not leave half-complete data directory
    (unwind-protect
        (let ((data (devdocs-browser--fetch-json
                     (format "%s/db.json?%s" slug mtime)
                     (expand-file-name devdocs-browser--offline-data-json-filename doc-dir)
                     devdocs-browser-doc-base-url)))
          ;; write data to files
          (dolist (kv (seq-partition data 2))
            (when-let* ((name (substring (symbol-name (car kv)) 1))
                        (value (cadr kv))
                        (path (expand-file-name (concat name ".html") data-dir)))
              (unless (file-exists-p (file-name-directory path))
                (make-directory (file-name-directory path)))
              (write-region value nil path)))
          (setq success t))
      (unless success
        (delete-directory data-dir t)))

    (if success
        (message "Installed devdocs offline data %s version %s" slug mtime)
      (message "Failed to install devdocs offline data %s" slug))

    success))

(defun devdocs-browser-offline-data-dir (slug)
  "Return doc SLUG's offline data dir if present, return nil otherwise."
  (let* ((docs-dir (expand-file-name devdocs-browser--docs-dir devdocs-browser-cache-directory))
         (doc-dir (expand-file-name slug docs-dir))
         (data-dir (expand-file-name devdocs-browser--offline-data-dir-name doc-dir)))
    (when (file-exists-p data-dir)
      (file-name-as-directory data-dir))))

(defun devdocs-browser-download-offline-data (slug)
  "Download offline data for doc SLUG.
Offline data contains full content pages,
which allows you to view docs without Internet connection.
It may take some time to download offline data.
When called interactively, user can choose from the list."
  (interactive (list (completing-read
                      "Install offline data: "
                      (seq-filter
                       (lambda (slug) (null (devdocs-browser-offline-data-dir slug)))
                       (devdocs-browser-list-installed-slugs))
                      nil t)))
  (when-let* ((doc (devdocs-browser--load-doc slug)))
    (devdocs-browser--download-offline-data-internal doc)))

(defun devdocs-browser-remove-offline-data (slug)
  "Remove offline data for doc SLUG.
When called interactively, user can choose from the list."
  (interactive (list (completing-read
                      "Remove offline data: "
                      (seq-filter
                       #'devdocs-browser-offline-data-dir
                       (devdocs-browser-list-installed-slugs))
                      nil t)))
  (when-let* ((data-dir (devdocs-browser-offline-data-dir slug)))
    (delete-directory data-dir t)))

(defun devdocs-browser--eww-open (doc path)
  "Open PATH for document DOC using eww."
  (let* ((slug (plist-get doc :slug))
         (mtime (plist-get doc :mtime))
         (local-hook (lambda () (setq-local devdocs-browser--eww-data
                                        (list :doc doc
                                              :path path))))
         url)
    ;; cannot use format directory because `path' may contains #query
    (let ((offline-data-dir (devdocs-browser-offline-data-dir slug)))
      (if offline-data-dir
          (progn
            (setq url (url-generic-parse-url (concat "file://" offline-data-dir path)))
            (setf (url-filename url) (concat (url-filename url) ".html")))
        (setq url (url-generic-parse-url (concat devdocs-browser-doc-base-url path)))
        (setf (url-filename url)
              (format "/%s%s.html?%s" slug (url-filename url) mtime))))

    (add-hook 'eww-mode-hook #'devdocs-browser-eww-mode)
    (add-hook 'eww-mode-hook local-hook)
    (unwind-protect
        (eww-browse-url (url-recreate-url url)) ;;)
      (remove-hook 'eww-mode-hook #'devdocs-browser-eww-mode)
      (remove-hook 'eww-mode-hook local-hook))))

(defun devdocs-browser--default-active-slugs ()
  "Default active doc slugs for current buffer."
  (if devdocs-browser--eww-data
      (list (plist-get (plist-get devdocs-browser--eww-data :doc) :slug))
    (let ((names (or devdocs-browser-active-docs
                     (alist-get major-mode devdocs-browser-major-mode-docs-alist)))
          slugs)
      (dolist (name names)
        (when-let* ((doc (devdocs-browser-find-installed-doc name))
                    (slug (plist-get doc :slug)))
          (setq slugs (push slug slugs))))
      (or slugs
          (devdocs-browser-list-installed-slugs)))))

;;;###autoload
(defun devdocs-browser-open-in (slug-or-name-list)
  "Open entry in specified docs SLUG-OR-NAME-LIST.
When called interactively, user can choose from the list."
  (interactive
   (list (list (completing-read
                "Select doc: "
                (devdocs-browser-list-installed-slugs)
                nil t))))

  (let* ((slugs
          (delq nil (mapcar
                     (lambda (slug-or-name)
                       (plist-get
                        (devdocs-browser-find-installed-doc slug-or-name)
                        :slug))
                     slug-or-name-list)))
         (rows
          (mapcan (lambda (slug)
                    (let* ((doc (devdocs-browser--load-doc slug))
                           (index (plist-get doc :index))
                           (entries (plist-get index :entries))
                           (mtime (plist-get doc :mtime)))
                      (message "%s: %s" slug mtime)
                      (mapcar (lambda (entry)
                                (let ((name (plist-get entry :name))
                                      (path (plist-get entry :path))
                                      (type (plist-get entry :type)))
                                  (cons (format "%s: %s (%s)" slug name type)
                                        (list doc path))))
                              entries)))
                  slugs))
         (selected-name
          (completing-read (format "Devdocs browser (%s): "
                                   (mapconcat #'identity slugs ","))
                           rows
                           ;; require-match
                           nil t
                           (thing-at-point 'word t)))
         (selected-row
          (assoc selected-name rows)))
    (when selected-row
      (apply #'devdocs-browser--eww-open (cdr selected-row)))))

;;;###autoload
(defun devdocs-browser-open ()
  "Open entry in active docs.
Active docs are specified by `devdocs-browser-active-docs',
or `devdocs-browser-major-mode-docs-alist',
or the current doc type if called in a devdocs eww buffer.
When all of them are nil, all installed docs are used."
  (interactive)
  (devdocs-browser-open-in (devdocs-browser--default-active-slugs)))


(provide 'devdocs-browser)
;;; devdocs-browser.el ends here