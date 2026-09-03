;; -*- lexical-binding: t; -*-
;;; UTF-8 scrub tests (json-value-p sentinel crash fix)

(require 'cl-lib)
(require 'iar-utf8-scrub)

(ert-deftest test-utf8-scrub-clean-ascii-identity ()
  "Clean ASCII passes through unchanged (same object)."
  (let ((s "plain ascii output 123"))
    (should (eq (iar--utf8-scrub s) s))))

(ert-deftest test-utf8-scrub-clean-utf8-identity ()
  "Clean multibyte UTF-8 text passes through unchanged."
  (let ((s "café 中文 — naïve"))
    (should (eq (iar--utf8-scrub s) s))))

(ert-deftest test-utf8-scrub-raw-bytes-replaced ()
  "Raw-eight-bit chars become U+FFFD; json-serialize accepts result."
  (let* ((raw (decode-coding-string
               (string-as-unibyte "blob \301\203\300\277data")
               'utf-8 t))
         (v (iar--utf8-scrub raw)))
    (should (equal v "blob \uFFFD\uFFFD\uFFFD\uFFFDdata"))
    (should (condition-case err (progn (json-serialize (list :c v)) t)
             (error nil)))))

(ert-deftest test-utf8-scrub-mixed-valid-and-raw ()
  "Valid multibyte chars survive while raw bytes are replaced."
  (let* ((raw (decode-coding-string
               (string-as-unibyte "header caf\303\251 \301\203\300 tail")
               'utf-8 t))
         (v (iar--utf8-scrub raw)))
    (should (equal v "header café \uFFFD\uFFFD\uFFFD tail"))
    (should (condition-case err (progn (json-serialize (list :c v)) t)
             (error nil)))))

(ert-deftest test-utf8-scrub-unibyte-input ()
  "Unibyte strings with high bytes are decoded then scrubbed."
  (let* ((s "caf\303\251 \301\203\300 x")  ; unibyte: valid C3A9 + invalid C183C0
         (v (iar--utf8-scrub s)))
    (should (equal v "café \uFFFD\uFFFD\uFFFD x"))
    (should (condition-case err (progn (json-serialize (list :c v)) t)
             (error nil)))))

(ert-deftest test-utf8-scrub-non-string-passthrough ()
  "Non-string input (nil, numbers, symbols) passes through unchanged."
  (should (eq (iar--utf8-scrub nil) nil))
  (should (eq (iar--utf8-scrub 42) 42))
  (should (eq (iar--utf8-scrub 'sym) 'sym)))

(ert-deftest test-utf8-scrub-empty-string ()
  "Empty string returns empty string."
  (should (equal (iar--utf8-scrub "") "")))

(ert-deftest test-utf8-scrub-has-raw-bytes-detector ()
  "The fast-path detector finds raw bytes only when present."
  (should (iar--string-has-raw-bytes
           (decode-coding-string (string-as-unibyte "\301\203") 'utf-8 t)))
  (should-not (iar--string-has-raw-bytes "clean café text")))

(ert-deftest test-utf8-scrub-perf-clean-fast-path ()
  "1MB clean string scrubs quickly (no allocation on clean path)."
  (let ((big (make-string 1000000 ?x)))
    (should (eq (iar--utf8-scrub big) big))))