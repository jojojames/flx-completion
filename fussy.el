;;; fussy.el --- Fuzzy completion style using `flx' -*- lexical-binding: t; -*-

;; Copyright 2022 James Nguyen

;; Author: James Nguyen <james@jojojames.com>
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (flx "0.5"))
;; Keywords: matching
;; Homepage: https://github.com/jojojames/fussy

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a fuzzy Emacs completion style similar to the built-in
;; `flex' style, but using `flx' for scoring.  It also supports various other
;; fuzzy scoring systems in place of `flx'.

;; To use this style, prepend `fussy' to `completion-styles'.
;; To speed up `flx' matching, use https://github.com/jcs-elpa/flx-rs.

(require 'flx)

;;; Code:

(defgroup fussy nil
  "Fuzzy completion style using `flx.'."
  :group 'flx
  :link '(url-link :tag "GitHub" "https://github.com/jojojames/fussy"))

(defcustom fussy-max-query-length 128
  "Collections with queries longer than this are not scored using `flx'.

See `fussy-all-completions' for implementation details."
  :group 'fussy
  :type 'integer)

(defcustom fussy-max-candidate-limit 1000
  "Apply optimizations for collections greater than this limit.

`fussy-all-completions' will apply some optimizations.

N -> this variable's value

1. The collection (to be scored) will initially be filtered based off word
length.  e.g. The shortest length N words will be filtered to be scored.

2. Score only up to N words.  The rest won't be scored.

Additional implementation details:
https://github.com/abo-abo/swiper/issues/207#issuecomment-141541960"
  :group 'fussy
  :type 'integer)

(defcustom fussy-ignore-case t
  "If t, ignores `completion-ignore-case'."
  :group 'fussy
  :type 'boolean)

(defcustom fussy-max-word-length-to-score 1000
  "Words that are longer than this length are not scored."
  :group 'fussy
  :type 'integer)

(defcustom fussy-propertize-fn
  #'fussy--propertize-common-part
  "Function used to propertize matches.

Takes OBJ \(to be propertized\) and
SCORE \(list of indices of OBJ to be propertized\).
If this is nil, don't propertize (e.g. highlight matches) at all.
This can also be set to nil to assume highlighting from a different source.

e.g. `fussy-filter-orderless' can also be used for highlighting matches."
  :type `(choice
          (const :tag "No highlighting" nil)
          (const :tag "By completions-common face."
                 ,#'fussy--propertize-common-part)
          (const :tag "By flx propertization." ,'flx-propertize)
          (function :tag "Custom function"))
  :group 'fussy)

(defcustom fussy-compare-same-score-fn
  #'fussy-strlen<
  "Function used to compare matches with the same 'completion-score.

FN takes in and compares two candidate strings C1 and C2 and
returns which candidates should have precedence.

If this is nil, do nothing."
  :type `(choice
          (const :tag "Don't compare candidates with same score." nil)
          (const :tag "Shorter candidates have precedence."
                 ,#'fussy-strlen<)
          (const :tag "Longer candidates have precedence."
                 ,#'fussy-strlen>)
          (const :tag "Recent candidates have precedence."
                 ,#'fussy-histlen<)
          (const :tag "Recent (then shorter length) candidates have precedence."
                 ,#'fussy-histlen->strlen<)
          (function :tag "Custom function"))
  :group 'fussy)

(defcustom fussy-max-limit-preferred-candidate-fn
  #'fussy-strlen<
  "Function used when collection length is greater than\

`fussy-max-candidate-limit'.

FN takes in and compares two candidate strings C1 and C2 and
returns which candidates should have precedence.

If this is nil, take the first `fussy-max-candidate-limit' number
of candidates that was returned by the completion table."
  :type `(choice
          (const :tag "Take the first X number of candidates." nil)
          (const :tag "Shorter candidates have precedence."
                 ,#'fussy-strlen<)
          (const :tag "Longer candidates have precedence."
                 ,#'fussy-strlen>)
          (const :tag "Recent candidates have precedence."
                 ,#'fussy-histlen<)
          (const :tag "Recent (then shorter length) candidates have precedence."
                 ,#'fussy-histlen->strlen<)
          (function :tag "Custom function"))
  :group 'fussy)

(defcustom fussy-filter-fn
  #'fussy-filter-flex
  "Function used for filtering candidates before scoring.

FN takes in the same arguments as `fussy-try-completions'.

This FN should not be nil.

Use `fussy-filter-orderless' for faster filtering through the
`all-completions' (written in C) interface."
  :type `(choice
          (const :tag "Built in Flex Filtering"
                 ,#'fussy-filter-flex)
          (const :tag "Orderless Filtering"
                 ,#'fussy-filter-orderless)
          (function :tag "Custom function"))
  :group 'fussy)

(defcustom fussy-score-fn
  'flx-score
  "Function used for scoring candidates.

FN should at least take in STR and QUERY."
  :type `(choice
          (const :tag "Score using Elisp"
                 ,'flx-score)
          (const :tag "Score using Rust"
                 ,'flx-rs-score)
          (const :tag "Score using Fuz"
                 #'fussy-fuz-score)
          (const :tag "Score using Fuz-Bin"
                 #'fussy-fuz-bin-score)
          (const :tag "Score using LiquidMetal"
                 #'fussy-liquidmetal-score)
          (const :tag "Score using Sublime-Fuzzy"
                 #'fussy-sublime-fuzzy-score)
          (function :tag "Custom function"))
  :group 'fussy)

(defcustom fussy-fuz-use-skim-p t
  "If t, use skim fuzzy matching algorithm with `fuz'.

If nil, use clangd fuzzy matching algorithm with `fuz'.

This boolean is only used if `fussy-fuz-score' is the `fussy-score-fn'."
  :group 'fussy
  :type 'boolean)

;;;###autoload
(defcustom fussy-adjust-metadata-fn
  #'fussy--adjust-metadata
  "Used for `completion--adjust-metadata' to adjust completion metadata.

`completion--adjust-metadata' is what is used to set up sorting of candidates
based on `completion-score'.  The default `flex' completion style in
`completion-styles' uses `completion--flex-adjust-metadata' which respects
the original completion table's sort functions:

  e.g. display-sort-function, cycle-sort-function

The default of `fussy-adjust-metadata-fn' is used instead to ignore
existing sort functions in favor of sorting based only on the scoring done by
`fussy-score-fn'."
  :type `(choice
          (const :tag "Adjust metadata using fussy."
                 ,#'fussy--adjust-metadata)
          (const :tag "Adjust metadata using flex."
                 ,#'completion--flex-adjust-metadata)
          (function :tag "Custom function"))
  :group 'fussy)

(defmacro fussy--measure-time (&rest body)
  "Measure the time it takes to evaluate BODY.
https://lists.gnu.org/archive/html/help-gnu-emacs/2008-06/msg00087.html"
  `(let ((time (current-time)))
     (let ((result ,@body))
       (message "%.06f" (float-time (time-since time)))
       result)))

(defun fussy--propertize-common-part (obj score)
  "Return propertized copy of OBJ according to score.

SCORE of nil means to clear the properties."
  (let ((block-started (cadr score))
        (last-char nil)
        ;; Originally we used `substring-no-properties' when setting str but
        ;; that strips text properties that other packages may set.
        ;; One example is `consult', which sprinkles text properties onto
        ;; the candidate. e.g. `consult--line-prefix' will check for
        ;; 'consult-location on str candidate.
        (str (if (consp obj) (car obj) obj)))
    (when score
      (dolist (char (cdr score))
        (when (and last-char
                   (not (= (1+ last-char) char)))
          (add-face-text-property block-started (1+ last-char)
                                  'completions-common-part nil str)
          (setq block-started char))
        (setq last-char char))
      (add-face-text-property block-started (1+ last-char)
                              'completions-common-part nil str)
      (when (and
             last-char
             (> (length str) (+ 2 last-char)))
        (add-face-text-property (1+ last-char) (+ 2 last-char)
                                'completions-first-difference
                                nil
                                str)))
    (if (consp obj)
        (cons str (cdr obj))
      str)))

(defun fussy-try-completions (string table pred point)
  "Try to flex-complete STRING in TABLE given PRED and POINT.

Implement `try-completions' interface by using `completion-flex-try-completion'."
  (completion-flex-try-completion string table pred point))

(defun fussy-all-completions (string table pred point)
  "Get flex-completions of STRING in TABLE, given PRED and POINT.

Implement `all-completions' interface with additional fuzzy / `flx' scoring."
  (pcase-let* ((metadata (completion-metadata string table pred))
               (completion-ignore-case fussy-ignore-case)
               (using-pcm-highlight (eq table 'completion-file-name-table))
               (cache (if (memq (completion-metadata-get metadata 'category)
                                '(file
                                  project-file))
                          flx-file-cache
                        flx-strings-cache))
               (`(,all ,pattern ,prefix)
                (funcall fussy-filter-fn
                         string table pred point)))
    (when all
      (nconc
       (if (or (> (length string) fussy-max-query-length)
               (string= string ""))
           (fussy--maybe-highlight pattern all :always-highlight)
         (if (< (length all) fussy-max-candidate-limit)
             (fussy--maybe-highlight
              pattern
              (fussy--score all string using-pcm-highlight cache)
              using-pcm-highlight)
           (let ((unscored-candidates '())
                 (candidates-to-score '()))
             ;; Pre-sort the candidates by length before partitioning.
             (setq unscored-candidates
                   (if fussy-max-limit-preferred-candidate-fn
                       (sort
                        all fussy-max-limit-preferred-candidate-fn)
                     ;; If `fussy-max-limit-preferred-candidate-fn'
                     ;; is nil, we'll partition the candidates as is.
                     all))
             ;; Partition the candidates into sorted and unsorted groups.
             (dotimes (_n (min (length unscored-candidates)
                               fussy-max-candidate-limit))
               (push (pop unscored-candidates) candidates-to-score))
             (append
              ;; Compute all of the fuzzy scores only for cands-to-sort.
              (fussy--maybe-highlight
               pattern
               (fussy--score
                (reverse candidates-to-score) string using-pcm-highlight cache)
               using-pcm-highlight)
              ;; Add the unsorted candidates.
              ;; We could highlight these too,
              ;; (e.g. with `fussy--maybe-highlight') but these are
              ;; at the bottom of the pile of candidates.
              unscored-candidates))))
       (length prefix)))))

(defun fussy--score (candidates string using-pcm-highlight cache)
  "Score and propertize \(if not USING-PCM-HIGHLIGHT\) CANDIDATES using STRING.

Use CACHE for scoring."
  (mapcar
   (lambda (x)
     (setq x (copy-sequence x))
     (cond
      ((> (length x) fussy-max-word-length-to-score)
       (put-text-property 0 1 'completion-score 0 x))
      (:default
       (let ((score
              (funcall fussy-score-fn
                       x string
                       cache)))
         ;; This is later used by `completion--adjust-metadata' for sorting.
         (put-text-property 0 1 'completion-score
                            (car score)
                            x)
         ;; If we're using pcm highlight, we don't need to propertize the
         ;; string here. This is faster than the pcm highlight but doesn't
         ;; seem to work with `find-file'.
         (unless (or using-pcm-highlight
                     (fussy--orderless-p)
                     (null fussy-propertize-fn))
           (setq
            x (funcall fussy-propertize-fn x score))))))
     x)
   candidates))

(defun fussy--maybe-highlight (pattern collection using-pcm-highlight)
  "Highlight COLLECTION using PATTERN if USING-PCM-HIGHLIGHT is true."
  (if (and using-pcm-highlight
           (not (fussy--orderless-p)))
      ;; This seems to be the best way to get highlighting to work consistently
      ;; with `find-file'.
      (completion-pcm--hilit-commonality pattern collection)
    ;; This will be the case when the `completing-read' function is not
    ;; `find-file'.
    ;; Assume that the collection has already been highlighted.
    ;; e.g. When `using-pcm-highlight' is nil or we're using `orderless' for
    ;; filtering and highlighting.
    collection))

;;;###autoload
(progn
  (put 'fussy 'completion--adjust-metadata fussy-adjust-metadata-fn)
  (add-to-list 'completion-styles-alist
               '(fussy fussy-try-completions fussy-all-completions
                       "Smart Fuzzy completion with scoring.")))

(defun fussy--adjust-metadata (metadata)
  "If actually doing filtering, adjust METADATA's sorting."
  (let ((flex-is-filtering-p
         ;; JT@2019-12-23: FIXME: this is kinda wrong.  What we need
         ;; to test here is "some input that actually leads/led to
         ;; flex filtering", not "something after the minibuffer
         ;; prompt".  E.g. The latter is always true for file
         ;; searches, meaning we'll be doing extra work when we
         ;; needn't.
         (or (not (window-minibuffer-p))
             (> (point-max) (minibuffer-prompt-end)))))
    `(metadata
      ,@(and flex-is-filtering-p
             `((display-sort-function . fussy--sort)))
      ,@(and flex-is-filtering-p
             `((cycle-sort-function . fussy--sort)))
      ,@(cdr metadata))))

(defun fussy--sort (completions)
  "Sort COMPLETIONS using `completion-score' and completion length."
  (sort
   completions
   (lambda (c1 c2)
     (let ((s1 (or (get-text-property 0 'completion-score c1) 0))
           (s2 (or (get-text-property 0 'completion-score c2) 0)))
       (if (and (= s1 s2)
                fussy-compare-same-score-fn)
           (funcall fussy-compare-same-score-fn c1 c2)
         ;; Candidates with higher completion score have precedence.
         (> s1 s2))))))

(defun fussy-strlen< (c1 c2)
  "Return t if C1's length is less than C2's length."
  (< (length c1) (length c2)))

(defun fussy-strlen> (c1 c2)
  "Return t if C1's length is greater than C2's length."
  (> (length c1) (length c2)))

(defun fussy-histlen< (c1 c2)
  "Return t if C1 occurred more recently than C2.

Check C1 and C2 in `minibuffer-history-variable'."
  (let* ((hist (and (not (eq minibuffer-history-variable t))
                    (symbol-value minibuffer-history-variable))))
    (catch 'found
      (dolist (h hist)
        (when (string= c1 h)
          (throw 'found t))
        (when (string= c2 h)
          (throw 'found nil))))))

(defun fussy-histlen->strlen< (c1 c2)
  "Return t if C1 occurs more recently than C2 or is shorter than C2."
  (let* ((hist (and (not (eq minibuffer-history-variable t))
                    (symbol-value minibuffer-history-variable))))
    (let ((result (catch 'found
                    (dolist (h hist)
                      (when (string= c1 h)
                        (throw 'found 'c1))
                      (when (string= c2 h)
                        (throw 'found 'c2))))))
      (if result
          (eq result 'c1)
        (fussy-strlen< c1 c2)))))

(defun fussy--orderless-p ()
  "Return whether or not we're using `orderless' for filtering."
  (eq fussy-filter-fn 'fussy-filter-orderless))

;; Filtering functions.

(declare-function "orderless-filter" "orderless")
(declare-function "orderless-highlight-matches" "orderless")
(declare-function "orderless--prefix+pattern" "orderless")
(defvar orderless-skip-highlighting)
;; Make sure this is defined. Otherwise there will be some weird behavior
;; when compared against the .elc version of this file.
;; For example, `orderless-filter' will not respect the let* bound
;; `orderless-matching-styles'.
(defvar orderless-matching-styles)

(defun fussy-filter-orderless (string table pred _point)
  "Match STRING to the entries in TABLE.

Use `orderless' for filtering by passing STRING, TABLE and PRED to

`orderless-filter'.  _POINT is not used."
  (require 'orderless)
  (when (and (fboundp 'orderless-filter)
             (fboundp 'orderless-highlight-matches)
             (fboundp 'orderless--prefix+pattern))
    (let* ((orderless-matching-styles '(orderless-flex))
           (completions (orderless-filter string table pred)))
      (when completions
        (pcase-let* ((`(,prefix . ,pattern)
                      (orderless--prefix+pattern string table pred))
                     (skip-highlighting
                      (if (functionp orderless-skip-highlighting)
                          (funcall orderless-skip-highlighting)
                        orderless-skip-highlighting)))
          (if skip-highlighting
              (list completions pattern prefix)
            (list (orderless-highlight-matches pattern completions)
                  pattern prefix)))))))

(defun fussy-filter-flex (string table pred point)
  "Match STRING to the entries in TABLE.

Respect PRED and POINT.  The filter here is the same as in
`completion-flex-all-completions'."
  (pcase-let ((`(,completions ,pattern ,prefix ,_suffix ,_carbounds)
               (completion-substring--all-completions
                string
                table pred point
                #'completion-flex--make-flex-pattern)))
    (list completions pattern prefix)))

;; Integrations

;; `company' integration.
(defvar company-backend)
;; Use with `company-transformers'.
;; (setq company-transformers
;;           '(fussy-company-sort-by-completion-score))
(defun fussy-company-sort-by-completion-score (candidates)
  "`company' transformer to sort CANDIDATES."
  (if (functionp company-backend)
      candidates
    (fussy--sort candidates)))

;; `fuz' integration.
(declare-function "fuz-fuzzy-match-skim" "fuz")
(declare-function "fuz-calc-score-skim" "fuz")
(declare-function "fuz-fuzzy-match-clangd" "fuz")
(declare-function "fuz-calc-score-clangd" "fuz")

(defun fussy-fuz-score (str query &rest _args)
  "Score STR for QUERY using `fuz'.

skim or clangd algorithm can be used.

If `orderless' is used for filtering, we skip calculating matches
for more speed."
  (require 'fuz)
  (if fussy-fuz-use-skim-p
      (if (eq fussy-filter-fn 'fussy-filter-orderless)
          (when (fboundp 'fuz-calc-score-skim)
            (list (fuz-calc-score-skim query str)))
        (when (fboundp 'fuz-fuzzy-match-skim)
          (fuz-fuzzy-match-skim query str)))
    (if (eq fussy-filter-fn 'fussy-filter-orderless)
        (when (fboundp 'fuz-calc-score-clangd)
          (list (fuz-calc-score-clangd query str)))
      (when (fboundp 'fuz-fuzzy-match-clangd)
        (fuz-fuzzy-match-clangd query str)))))

;; `fuz-bin' integration.
(declare-function "fuz-bin-dyn-score-skim" "fuz-bin")
(declare-function "fuz-bin-score-skim" "fuz-bin")
(declare-function "fuz-bin-dyn-score-clangd" "fuz-bin")
(declare-function "fuz-bin-score-clangd" "fuz-bin")

(defun fussy-fuz-bin-score (str query &rest _args)
  "Score STR for QUERY using `fuz-bin'.

skim or clangd algorithm can be used.

If `orderless' is used for filtering, we skip calculating matches
for more speed."
  (require 'fuz-bin)
  (if fussy-fuz-use-skim-p
      (if (eq fussy-filter-fn 'fussy-filter-orderless)
          (when (fboundp 'fuz-bin-dyn-score-skim)
            (list (fuz-bin-dyn-score-skim query str)))
        (when (fboundp 'fuz-bin-score-skim)
          (fuz-bin-score-skim query str)))
    (if (eq fussy-filter-fn 'fussy-filter-orderless)
        (when (fboundp 'fuz-bin-dyn-score-clangd)
          (list (fuz-bin-dyn-score-clangd query str)))
      (when (fboundp 'fuz-bin-score-clangd)
        (fuz-bin-score-clangd query str)))))

;; `liquidmetal' integration
(declare-function "liquidmetal-score" "liquidmetal")

(defun fussy-liquidmetal-score (str query &rest _args)
  "Score STR for QUERY using `liquidmetal'.

This should be paired with `fussy-filter-orderless' to obtain match
highlighting."
  (require 'liquidmetal)
  (when (fboundp 'liquidmetal-score)
    (list (liquidmetal-score str query))))

;; sublime-fuzzy`
(declare-function "sublime-fuzzy-score" "sublime-fuzzy")

(defun fussy-sublime-fuzzy-score (str query &rest _args)
  "Score STR for QUERY using `sublime-fuzzy"
  (require 'sublime-fuzzy)
  (when (fboundp 'sublime-fuzzy-score)
    (list (sublime-fuzzy-score query str))))

(provide 'fussy)
;;; fussy.el ends here
