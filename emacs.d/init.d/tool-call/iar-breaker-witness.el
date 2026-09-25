;; -*- lexical-binding: t; -*-

;;; STATE.md fire-record integrity -- machine-only witness marker
;;
;; c361/c363 (tasks/iar/aria/state-md-two-writers-gap): STATE.md has
;; two writers with no contract -- the model (append_file/write_file
;; at cycle close) and the context circuit breaker (fire record at
;; fire time). Continuo hand-wrote a shape-identical fake fire line
;; on 2026-09-25 15:26:11 (all three claims false: no journal
;; emission, no cycle-log emission, msgs was actually 62). The belt
;; (knowledge/aria/bin/breaker-record-belt.sh) catches fakes AFTER
;; the fact; this module makes them impossible to fake convincingly
;; IN the record itself.
;;
;; Mechanism (Option A from the design gap): every breaker fire
;; record carries a machine-only witness line
;;
;;   <!-- breaker-witness epoch=<boot-epoch> req=<req-counter> msgs=<n> -->
;;
;; built from iar--reqlog-epoch + iar--reqlog-counter -- values the
;; model cannot know at write time (the counter increments at the
;; NEXT request START, after the fire; the epoch is set once at
;; session load). A hand-written fake must now also predict a future
;; counter value AND match it against the REQUESTS.log REQ START of
;; the fire turn -- two coupled unknowns instead of a copyable
;; string.
;;
;; The belt gains a second witness: a fire line without a matching
;; witness line = fabrication (the breaker ALWAYS writes the pair);
;; a witness whose epoch+req does not appear as a REQ START in
;; REQUESTS.log = fabrication. INSTRUMENT-RECORDS-ARE-NOT-HAND-WRITTEN
;; moves from convention to structure.
;;
;; Fail-open: witness construction never signals; if the reqlog
;; values are unavailable the witness says so explicitly
;; (epoch=unavailable) rather than being omitted -- a missing witness
;; is a belt FAIL, so the belt must be able to distinguish "breaker
;; degraded" from "model lied". The belt treats epoch=unavailable as
;; DEGRADED (warning), not FABRICATION.

(require 'iar-utils)

;; Forward-declared: owned by iar-request-log.el (loads via `load' in
;; init.el). CRITICAL LOAD-ORDER NOTE (c363): these declarations use
;; (defvar NAME) WITHOUT a value -- the value-carrying defvar in
;; iar-request-log.el must win. A (defvar X nil) here would CLOBBER
;; the boot-time epoch (defvar re-evaluates when the variable is
;; unbound; loading this file after iar-request-log.el with an
;; explicit nil default resets the boot epoch to nil -- the exact
;; c363 suite failure: test-reqlog-epoch-set-once-at-load saw nil).
;; Bare (defvar X) declares without touching an existing value.
(defvar iar--reqlog-last-msgs)
(defvar iar--reqlog-epoch)
(defvar iar--reqlog-counter)

(declare-function iar--fs-append-file "append_file.el" (filepath content))
(declare-function iar--tool-create-task "create_task.el" (path description))
(declare-function iar--fence-state-writeback "iar-agent-cycle.el" (state))

(defun iar--breaker-witness-line ()
  "Build the machine-only witness line for a breaker fire record.
Reads iar--reqlog-epoch and iar--reqlog-counter at FIRE time. The
fire happens pre-tool-call, i.e. AFTER the triggering request
completed: the counter value recorded is the count of requests
STARTED so far this session (START advice increments before the
request is sent), so witness req = the id of the request whose
response triggered the fire. Never signals: on missing values
emits epoch=unavailable (the belt reads that as DEGRADED, not
FABRICATION)."
  (let ((epoch (and (boundp 'iar--reqlog-epoch)
                    (stringp iar--reqlog-epoch)
                    iar--reqlog-epoch))
        (req (and (boundp 'iar--reqlog-counter)
                  (integerp iar--reqlog-counter)
                  iar--reqlog-counter))
        (msgs (and (boundp 'iar--reqlog-last-msgs)
                   (integerp iar--reqlog-last-msgs)
                   iar--reqlog-last-msgs)))
    (format "<!-- breaker-witness epoch=%s req=%s msgs=%s -->"
            (or epoch "unavailable")
            (or req "unavailable")
            (or msgs "unavailable"))))

(defun iar--breaker-witness-verify (witness-line)
  "Verify a witness line against the live reqlog state. Returns a
plist (:status ok|degraded|stale :detail STRING). ok = epoch matches
this session and req is a sane integer <= counter. degraded =
unavailable or malformed. stale = epoch from a DIFFERENT session
(the belt checks cross-session lines against REQUESTS.log REQ START
ids, not live state -- live verification only applies to this
session's lines)."
  (condition-case err
      (let ((m (and (stringp witness-line)
                    (string-match
                     "^<!-- breaker-witness epoch=\\([^ ]+\\) req=\\([^ ]+\\) msgs=\\([^ ]+\\) -->$"
                     witness-line))))
        (cond
         ((not m) (list :status 'degraded
                        :detail (format "malformed witness: %S" witness-line)))
         ((string= (match-string 1 witness-line) "unavailable")
          (list :status 'degraded :detail "epoch=unavailable"))
         ((and (boundp 'iar--reqlog-epoch)
               (stringp iar--reqlog-epoch)
               (not (string= (match-string 1 witness-line)
                             iar--reqlog-epoch)))
          (list :status 'stale
                :detail (format "epoch %s != live %s"
                                (match-string 1 witness-line)
                                iar--reqlog-epoch)))
         (t
          (let ((req (string-to-number (match-string 2 witness-line))))
            (if (and (integerp req) (>= req 0)
                     (boundp 'iar--reqlog-counter)
                     (integerp iar--reqlog-counter)
                     (<= req iar--reqlog-counter))
                (list :status 'ok
                      :detail (format "epoch=%s req=%d <= %d"
                                      (match-string 1 witness-line)
                                      req iar--reqlog-counter))
              (list :status 'degraded
                    :detail (format "req %s not a sane integer"
                                    (match-string 2 witness-line))))))))
    (error
     (list :status 'degraded
           :detail (format "verify error: %s" (error-message-string err))))))

(provide 'iar-breaker-witness)