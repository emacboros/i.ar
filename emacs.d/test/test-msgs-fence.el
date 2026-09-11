;; -*- lexical-binding: t; -*-

;;; Tests for iar-msgs-fence.el (relay 0035 option B)

(require 'ert)
(require 'cl-lib)

(require 'iar-msgs-fence)

;;; --- Gate plumbing ---

(ert-deftest test-msgs-fence-disabled ()
  "When the fence is disabled, all calls pass."
  (let ((iar-msgs-fence nil)
        (iar--reqlog-last-msgs 9999)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

(ert-deftest test-msgs-fence-no-msgs-yet ()
  "First request of a run (no msgs published) -> allow."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs nil)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

(ert-deftest test-msgs-fence-zero-msgs ()
  "Zero msgs (degenerate) -> allow (fence keys on > 0)."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 0)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

(ert-deftest test-msgs-fence-no-state ()
  "No active state (interactive session) -> allow."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 9999)
        (iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

(ert-deftest test-msgs-fence-under-caps ()
  "msgs under both caps -> allow."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 100)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

;;; --- Soft warn ---

(ert-deftest test-msgs-fence-soft-warn-blocks-once ()
  "msgs >= soft cap -> ONE block with converge notice; retry
passes; the warn does not fire twice."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 420)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (let ((r1 (iar--msgs-fence-pre-call (list :name "read_file"))))
      (should (plist-get r1 :block))
      (should (string-match-p "MSGS FAT" (plist-get r1 :block)))
      ;; Retry passes (warned flag set)
      (should-not (iar--msgs-fence-pre-call (list :name "read_file")))
      ;; And a second warn never fires even on another call
      (should-not (iar--msgs-fence-pre-call (list :name "execute_code_local"))))))

(ert-deftest test-msgs-fence-soft-warn-writeback ()
  "The warned flag survives the fence-state writeback (the c-scar
law: absent-key setf through the alias is lossy)."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 420)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (iar--msgs-fence-pre-call (list :name "read_file"))
    (should (plist-get iar--cycle-state :msgs-warned))))

;;; --- Hard cap ---

(ert-deftest test-msgs-fence-hard-cap-blocks ()
  "msgs >= hard cap -> block with landing instruction."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 650)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar-msgs-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (let ((r (iar--msgs-fence-pre-call (list :name "read_file"))))
      (should (plist-get r :block))
      (should (string-match-p "MSGS HARD CAP" (plist-get r :block))))))

(ert-deftest test-msgs-fence-hard-cap-escalates-to-exit ()
  "After iar-msgs-hard-cap-blocks ignored blocks, the run ends
(completed + exit-code 1) and the block says so."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 650)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar-msgs-hard-cap-blocks 2)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    ;; First block: arms the counter
    (should (plist-get (iar--msgs-fence-pre-call (list :name "read_file")) :block))
    (should-not (plist-get iar--cycle-state :completed))
    ;; Second block: force-end
    (let ((r (iar--msgs-fence-pre-call (list :name "read_file"))))
      (should (plist-get r :block))
      (should (plist-get iar--cycle-state :completed))
      (should (= (plist-get iar--cycle-state :exit-code) 1)))))

(ert-deftest test-msgs-fence-memory-tools-never-blocked ()
  "Memory/record tools pass even past the hard cap (the landing IS
the memory pass)."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 9999)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar-msgs-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (dolist (tool '("append_file" "write_file" "write_subtask"
                    "write_roadmap" "git_commit" "send_telegram"))
      (should-not (iar--msgs-fence-pre-call (list :name tool))))))

;;; --- Absence of data ---

(ert-deftest test-msgs-fence-na-msgs-never-fires ()
  "msgs NA (nil, the dump's NA->nil contract) -> allow, never fire."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs nil)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--msgs-fence-pre-call (list :name "read_file")))))

;;; --- One-shot dispatch ---

(ert-deftest test-msgs-fence-one-shot-dispatch ()
  "One-shot state is fenced too (fence parity, 2026-09-03 fix)."
  (let ((iar-msgs-fence t)
        (iar--reqlog-last-msgs 650)
        (iar-msgs-soft-cap 400)
        (iar-msgs-hard-cap 600)
        (iar-msgs-hard-cap-blocks 5)
        (iar--cycle-state nil)
        (iar--one-shot-state (list :agent "t" :tool-call-count 0)))
    (should (plist-get (iar--msgs-fence-pre-call (list :name "read_file")) :block))))

;;; --- Reset contract ---

(ert-deftest test-reqlog-reset-last-clears-msgs ()
  "iar--reqlog-reset-last clears iar--reqlog-last-msgs (a stale
count from a previous cycle must never be read as this cycle's
first response)."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 100)
        (iar--reqlog-last-tokens-in 200)
        (iar--reqlog-last-tool-specs '((:name "x")))
        (iar--reqlog-last-msgs 500))
    (iar--reqlog-reset-last)
    (should-not iar--reqlog-last-msgs)))

;;; --- Publish contract ---

(ert-deftest test-reqlog-dump-parse-publishes-msgs ()
  "The dump publishes iar--reqlog-last-msgs from the FSM info's
:data :messages; NA (non-vector) -> nil."
  ;; Direct test of the publish expression's contract via
  ;; iar--reqlog-msgs-count: integer for a vector, NA otherwise.
  (let ((info (list :data (list :messages
                                (vector (list :role "user" :content "hi")
                                        (list :role "assistant" :content "yo"))))))
    (should (= (iar--reqlog-msgs-count info) 2)))
  (should (equal (iar--reqlog-msgs-count (list :data nil)) "NA"))
  (should (equal (iar--reqlog-msgs-count nil) "NA"))
  (should (equal (iar--reqlog-msgs-count (list :data (list :messages "not-a-vector")))
                 "NA")))

(ert-deftest test-reqlog-msgs-count-never-signals ()
  "iar--reqlog-msgs-count never signals on garbage input."
  (should (equal (iar--reqlog-msgs-count :garbage) "NA"))
  (should (equal (iar--reqlog-msgs-count (list :data :garbage)) "NA"))
  (should (equal (iar--reqlog-msgs-count (list :data (list :messages 42))) "NA")))

(provide 'test-msgs-fence)