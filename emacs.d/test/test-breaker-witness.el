;; -*- lexical-binding: t; -*-
;; Tests: breaker witness (c363, state-md-two-writers-gap).
;; The witness is the machine-only marker on breaker fire records:
;; epoch+req from iar--reqlog, values the model cannot synthesize.

(require 'ert)
(require 'iar-breaker-witness)

;; --- iar--breaker-witness-line ---

(ert-deftest test-breaker-witness-line-format ()
  "The witness line matches the documented format exactly."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 42)
        (iar--reqlog-last-msgs 400))
    (should (equal (iar--breaker-witness-line)
                   "<!-- breaker-witness epoch=260925171000 req=42 msgs=400 -->"))))

(ert-deftest test-breaker-witness-line-unavailable-epoch ()
  "Missing epoch -> epoch=unavailable, never a signal, never omitted."
  (let ((iar--reqlog-epoch nil)
        (iar--reqlog-counter 7)
        (iar--reqlog-last-msgs 400))
    (should (equal (iar--breaker-witness-line)
                   "<!-- breaker-witness epoch=unavailable req=7 msgs=400 -->"))))

(ert-deftest test-breaker-witness-line-unavailable-req ()
  "Non-integer counter -> req=unavailable (fail-open, explicit)."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter "corrupt")
        (iar--reqlog-last-msgs 400))
    (should (equal (iar--breaker-witness-line)
                   "<!-- breaker-witness epoch=260925171000 req=unavailable msgs=400 -->"))))

(ert-deftest test-breaker-witness-line-unavailable-msgs ()
  "Non-integer msgs (NA contract from reqlog) -> msgs=unavailable."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 7)
        (iar--reqlog-last-msgs nil))
    (should (equal (iar--breaker-witness-line)
                   "<!-- breaker-witness epoch=260925171000 req=7 msgs=unavailable -->"))))

(ert-deftest test-breaker-witness-line-never-signals ()
  "All reqlog state unbound/garbage -> still returns a line, no signal."
  (let ((iar--reqlog-epoch (make-vector 3 'x))   ; wrong type on purpose
        (iar--reqlog-counter :atom)
        (iar--reqlog-last-msgs "not-int"))
    (should (string-match-p "^<!-- breaker-witness epoch=unavailable req=unavailable msgs=unavailable -->$"
                            (iar--breaker-witness-line)))))

;; --- iar--breaker-witness-verify ---

(ert-deftest test-breaker-witness-verify-ok ()
  "Live epoch + req <= counter -> ok."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 42))
    (let ((r (iar--breaker-witness-verify
              "<!-- breaker-witness epoch=260925171000 req=42 msgs=400 -->")))
      (should (eq (plist-get r :status) 'ok))
      (should (string-match-p "req=42" (plist-get r :detail))))))

(ert-deftest test-breaker-witness-verify-ok-req-below-counter ()
  "req < counter is still ok (fire happened earlier in the session)."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 100))
    (let ((r (iar--breaker-witness-verify
              "<!-- breaker-witness epoch=260925171000 req=99 msgs=400 -->")))
      (should (eq (plist-get r :status) 'ok)))))

(ert-deftest test-breaker-witness-verify-stale-epoch ()
  "Witness from a different session -> stale (belt checks against
REQUESTS.log, not live state)."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 42))
    (let ((r (iar--breaker-witness-verify
              "<!-- breaker-witness epoch=260924000000 req=3 msgs=400 -->")))
      (should (eq (plist-get r :status) 'stale)))))

(ert-deftest test-breaker-witness-verify-degraded-unavailable ()
  "epoch=unavailable -> degraded, not ok, not fabrication-class."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 42))
    (let ((r (iar--breaker-witness-verify
              "<!-- breaker-witness epoch=unavailable req=7 msgs=400 -->")))
      (should (eq (plist-get r :status) 'degraded)))))

(ert-deftest test-breaker-witness-verify-degraded-malformed ()
  "A hand-typed near-miss (the fake class) -> degraded/malformed."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 42))
    (let ((r (iar--breaker-witness-verify
              "<!-- breaker-witness epoch=260925171000 req=999999 msgs=400 -->")))
      ;; req > counter: cannot have happened yet -> degraded
      (should (eq (plist-get r :status) 'degraded)))))

(ert-deftest test-breaker-witness-verify-rejects-non-line ()
  "Not a witness line at all -> degraded malformed."
  (let ((r (iar--breaker-witness-verify "some random text")))
    (should (eq (plist-get r :status) 'degraded))))

(ert-deftest test-breaker-witness-verify-never-signals ()
  "Garbage input -> degraded, never a signal (fail-open contract)."
  (let ((r (iar--breaker-witness-verify (make-vector 4 'y))))
    (should (eq (plist-get r :status) 'degraded))))

;; --- the fake-class differential (the c361 attack, replayed) ---

(ert-deftest test-breaker-witness-fake-cannot-match ()
  "THE differential: a model hand-writing a fire line at c361's
shape has no epoch/req to put in the witness. Even if it copies the
format, its req value must be an integer <= the live counter AND the
epoch must equal the live epoch. A fabricated witness with a
guessed epoch fails the stale check; a fabricated one with the live
epoch but a guessed req fails only if req > counter -- which is why
the belt ALSO cross-checks the req id against REQUESTS.log REQ
START ids (structural check lives in the belt; this test pins the
live-state half)."
  (let ((iar--reqlog-epoch "260925171000")
        (iar--reqlog-counter 31))
    ;; Guessed epoch (wrong session) -> stale
    (should (eq (plist-get (iar--breaker-witness-verify
                            "<!-- breaker-witness epoch=999999999999 req=5 msgs=400 -->")
                           :status)
                'stale))
    ;; Live epoch, guessed future req -> degraded (impossible req)
    (should (eq (plist-get (iar--breaker-witness-verify
                            "<!-- breaker-witness epoch=260925171000 req=5000 msgs=400 -->")
                           :status)
                'degraded))))

(provide 'test-breaker-witness)