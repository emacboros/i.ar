;;; test-gptel-markdown-mime.el --- image-mime branch coverage -*- lexical-binding: t; -*-

;; c617: continuo's 06:08Z edit replaced (require 'mailcap) with
;; (require 'files nil t) and mailcap-file-name-to-mime-type with
;; file-mime-type. file-mime-type does not exist in Emacs 30.2 ->
;; void-function at runtime in the image-mime branch of
;; gptel-markdown--validate-link. Neither suite caught it in place:
;; the i.ar suite (1422) never exercises the link path, and the
;; gptel-test md-2 test SKIPs when markdown-mode is absent (it was).
;; This file ports md-2's coverage into the i.ar suite so the
;; branch is exercised whenever markdown-mode is installed, and
;; FAILS LOUDLY on a missing mime function instead of skipping.
;;
;; The test requires the fork (run-tests.el puts it on load-path).
;; If markdown-mode is absent, the mime branch is unreachable in a
;; real session too -- assert that honestly (skip) rather than
;; pretend coverage.

(require 'gptel-request)
(require 'ert)

(ert-deftest test-gptel-markdown-mime-image-path ()
  "Image file link validation must resolve a mime type without error.
Exercises the `gptel--file-binary-p' + mime branch of
`gptel-markdown--validate-link' (the branch continuo's mailcap
edit broke: void-function file-mime-type)."
  (skip-unless (fboundp 'markdown-mode))
  (let ((png (make-temp-file "aria-mime-test" nil ".png")))
    (unwind-protect
        (progn
          (with-temp-file png (insert "\x89PNG\r\n\x1a\n")) ; PNG magic
          (should
           (equal (gptel-markdown--validate-link
                   (list "text" 0 (+ 7 (length png)) png))
                  (list t "file" png 'file t t t "image/png"))))
      (delete-file png))))

(ert-deftest test-gptel-markdown-mime-http-link ()
  "HTTP link validation must not call any file-mime function."
  (skip-unless (fboundp 'markdown-mode))
  (should
   (equal (gptel-markdown--validate-link
           (list "text" 0 40 "http://example.com/x.jpg"))
          (list nil "http" "http://example.com/x.jpg" nil nil nil nil nil))))

(provide 'test-gptel-markdown-mime)
;;; test-gptel-markdown-mime.el ends here