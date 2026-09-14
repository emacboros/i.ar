;; -*- lexical-binding: t; -*-
;; Belt #2b TZ-boundary test (aria c293): the WRAPPER (iar.sh) names
;; the dated cycle log with SOPHON-LOCAL date; the belt runs on the
;; container UTC clock. In the sophon 21:00-23:59 window (= UTC
;; 00:00-02:59 next day) the wrapper writes YESTERDAY's dated log
;; while the belt staged only TODAY's -- the run's cycle log never
;; rode any belt (observed: continuo 00:56Z run, sophon 21:56 local,
;; her cycle-2026-09-13.log left dirty). Fix: stage BOTH today's and
;; yesterday's dated logs (missing files are skipped, so the common
;; case is unchanged).

(require 'ert)

(ert-deftest test-tool-call-belt2b-stages-yesterdays-cycle-log ()
  "record-paths includes yesterday's dated cycle log when present."
  (let* ((tmpdir (make-temp-file "belt2b-tz-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproj"))
    (unwind-protect
        (progn
          (let ((log-dir (expand-file-name "audit/testproj/testagent" tmpdir)))
            (make-directory log-dir t)
            (with-temp-file (expand-file-name "USAGE.log" log-dir) (insert "x"))
            (with-temp-file (expand-file-name "cycle-2026-09-13.log" log-dir) (insert "y"))
            (let ((paths (iar--usage--record-paths tmpdir log-dir)))
              (should (member "audit/testproj/testagent/cycle-2026-09-13.log" paths))
              (should (member "audit/testproj/testagent/USAGE.log" paths))
              ;; today's log absent -> not staged (no phantom entries)
              (should (not (member "audit/testproj/testagent/cycle-2026-09-14.log" paths))))))
      (delete-directory tmpdir t))))

(ert-deftest test-tool-call-belt2b-stages-both-dates ()
  "Both today's and yesterday's dated logs ride when both exist."
  (let* ((tmpdir (make-temp-file "belt2b-tz2-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproj"))
    (unwind-protect
        (progn
          (let ((log-dir (expand-file-name "audit/testproj/testagent" tmpdir)))
            (make-directory log-dir t)
            (with-temp-file (expand-file-name "cycle-2026-09-13.log" log-dir) (insert "y"))
            (with-temp-file (expand-file-name "cycle-2026-09-14.log" log-dir) (insert "t"))
            (let ((paths (iar--usage--record-paths tmpdir log-dir)))
              (should (member "audit/testproj/testagent/cycle-2026-09-13.log" paths))
              (should (member "audit/testproj/testagent/cycle-2026-09-14.log" paths)))))
      (delete-directory tmpdir t))))
