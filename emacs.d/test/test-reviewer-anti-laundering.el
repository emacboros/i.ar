;;; --- Reviewer anti-laundering tests (c334) ---
;;; The claim-laundering disease (c6158d1: dead module + green suite +
;;; green reviewer): the reviewer archetype must DEMAND wiring
;;; verification, so a reviewer delegate cannot pass an unwired build.

(ert-deftest test-assembly-reviewer-archetype-demands-wiring ()
  "The reviewer archetype prompt must contain the wiring rule."
  (let* ((text (iar--read-archetype "reviewer")))
    (should (stringp text))
    (should (string-match-p "WIRING IS PART OF CORRECTNESS" text))
    (should (string-match-p "loaded/required/registered" text))
    ;; NOTE: the + in the prompt text is literal; in a regex pattern it
    ;; is a quantifier, so escape it here (string-match-p is a regex).
    (should (string-match-p "Green suite \\+ unwired module" text))))

(ert-deftest test-assembly-reviewer-personality-demands-wiring ()
  "The reviewer personality prompt must mention wiring verification."
  (let* ((text (iar--read-personality "reviewer")))
    (should (string-match-p "REACHABLE from the running system" text))
    (should (string-match-p "unwired module" text))))

(ert-deftest test-assembly-assemble-reviewer-includes-wiring-rule ()
  "Assembled reviewer prompt (archetype path) carries the wiring rule."
  (let* ((result (iar--assemble-prompt "reviewer" "reviewer" "reviewer"))
         (prompt (plist-get result :prompt)))
    (should (stringp prompt))
    (should (string-match-p "WIRING IS PART OF CORRECTNESS" prompt))))