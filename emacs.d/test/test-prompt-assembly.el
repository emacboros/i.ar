;; -*- lexical-binding: t; -*-

;;; Tests for iar-prompt-assembly.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Load dependencies
(require 'iar-utils)
(require 'iar-project-parser)
(require 'iar-prompt-assembly)
(defvar iar-personalization-path nil)

;; Configs must be loaded
(defvar iar-archetypes-path nil)
(defvar iar-personalities-path nil)
(defvar iar-projects-path nil)
(defvar iar-docs-path nil)
(defvar iar-audit-path nil)
(defvar iar-personal-file-max-lines nil)
(defvar iar-knowledge-open-delimiter nil)
(defvar iar-knowledge-close-delimiter nil)
(defvar iar-knowledge-file-separator nil)

(ert-deftest test-assembly-read-archetype ()
  "Reading an archetype returns its content."
  (let ((content (iar--read-archetype "interactive")))
    (should (stringp content))
    (should (> (length content) 0))
    (should (string-match-p "INTERACTIVE" content))))

(ert-deftest test-assembly-read-archetype-not-found ()
  "Reading a non-existent archetype signals an error."
  (should-error (iar--read-archetype "nonexistent")))

(ert-deftest test-assembly-read-personality ()
  "Reading a personality returns its content."
  (let ((content (iar--read-personality "mirror")))
    (should (stringp content))
    (should (> (length content) 0))
    (should (string-match-p "mirror" content))))

(ert-deftest test-assembly-read-personality-not-found ()
  "Reading a non-existent personality signals an error."
  (should-error (iar--read-personality "nonexistent")))

(ert-deftest test-assembly-parse-mode-interactive ()
  "Parse mode from interactive archetype returns interactive."
  (let ((content (iar--read-archetype "interactive")))
    (should (eq (iar--parse-mode content) 'interactive))))

(ert-deftest test-assembly-parse-mode-autonomous ()
  "Parse mode from autonomous archetype returns autonomous."
  (let ((content (iar--read-archetype "autonomous")))
    (should (eq (iar--parse-mode content) 'autonomous))))

(ert-deftest test-assembly-parse-mode-continuous ()
  "Parse mode from continuous archetype returns continuous."
  (let ((content (iar--read-archetype "continuous")))
    (should (eq (iar--parse-mode content) 'continuous))))

(ert-deftest test-assembly-parse-mode-delegated ()
  "Parse mode from agent-assistant archetype returns delegated."
  (let ((content (iar--read-archetype "agent-assistant")))
    (should (eq (iar--parse-mode content) 'delegated))))

(ert-deftest test-assembly-parse-mode-no-metadata ()
  "Content without #+MODE defaults to interactive."
  (should (eq (iar--parse-mode "Some content without metadata") 'interactive)))

(ert-deftest test-assembly-inject-memory-interactive ()
  "Interactive mode injects LOGS.md if it exists."
  (let ((result (iar--inject-memory 'interactive "iar" "mirror")))
    ;; LOGS.md should exist for mirror
    (should (stringp result))
    ;; Either contains SESSION LOGS or is empty (if file doesn't exist)
    (or (string-match-p "SESSION LOGS\|JOURNAL" result)
        (string= result ""))))

(ert-deftest test-assembly-inject-memory-delegated ()
  "Delegated mode injects no memory."
  (should (string= (iar--inject-memory 'delegated "iar" "mirror") "")))

(ert-deftest test-assembly-inject-memory-one-shot ()
  "One-shot mode injects no memory."
  (should (string= (iar--inject-memory 'one-shot "iar" "darwin") "")))

(ert-deftest test-assembly-filter-tools-all ()
  "Nil tool-names returns all tools unchanged."
  (let ((tools (list 'fake-tool-1 'fake-tool-2)))
    (should (equal (iar--filter-tools tools nil) tools))))

(ert-deftest test-assembly-filter-tools-subset ()
  "Tool filtering returns only matching tools, preserving order."
  (let* ((tool-a (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (tool-b (gptel-make-tool :name "write_file" :function #'identity :description "test" :args nil))
         (tool-c (gptel-make-tool :name "delegate" :function #'identity :description "test" :args nil))
         (all-tools (list tool-a tool-b tool-c))
         (filtered (iar--filter-tools all-tools '("read_file" "delegate"))))
    (should (= (length filtered) 2))
    ;; Preserves original order: read_file first, delegate second
    (should (equal (gptel-tool-name (car filtered)) "read_file"))
    (should (equal (gptel-tool-name (cadr filtered)) "delegate"))))

(ert-deftest test-assembly-filter-tools-no-match ()
  "Tool filtering with no matches returns empty list."
  (let* ((tool-a (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (all-tools (list tool-a))
         (filtered (iar--filter-tools all-tools '("nonexistent_tool"))))
    (should (= (length filtered) 0))))

(ert-deftest test-assembly-assemble-full ()
  "Full assembly produces a prompt with all sections in correct order."
  (let ((result (iar--assemble-prompt "interactive" "mirror" "iar")))
    (should (plist-get result :prompt))
    (should (stringp (plist-get result :prompt)))
    (should (plist-get result :tools))
    (should (eq (plist-get result :mode) 'interactive))
    (should (string= (plist-get result :archetype) "interactive"))
    (should (string= (plist-get result :personality) "mirror"))
    (should (string= (plist-get result :project) "iar"))
    ;; Check assembly order using delimiter strings (not generic words
    ;; that might appear in knowledge content)
    (let ((prompt (plist-get result :prompt)))
      (should (string-match-p "ENVIRONMENT" prompt))
      (should (string-match-p "=== ARCHETYPE" prompt))
      (should (string-match-p "=== PERSONALITY" prompt))
      (should (string-match-p "=== PROJECT OBJECTIVE" prompt))
      ;; base_context (ENVIRONMENT) should come before archetype delimiter
      (should (< (string-match "ENVIRONMENT" prompt)
                 (string-match "=== ARCHETYPE" prompt)))
      ;; archetype delimiter should come before personality delimiter
      (should (< (string-match "=== ARCHETYPE" prompt)
                 (string-match "=== PERSONALITY" prompt))))))

(ert-deftest test-assembly-assemble-autonomous ()
  "Assembly with autonomous archetype returns autonomous mode."
  (let ((result (iar--assemble-prompt "autonomous" "darwin" "darwin")))
    (should (eq (plist-get result :mode) 'autonomous))
    (should (string= (plist-get result :archetype) "autonomous"))
    (should (string= (plist-get result :personality) "darwin"))))

(ert-deftest test-assembly-assemble-aria-cycle ()
  "Assembly with aria-cycle archetype returns aria-cycle mode and
injects the interactive-style memory set (DIGEST/LOGS/JOURNAL),
not STATE.org."
  (let ((result (iar--assemble-prompt "aria-cycle" "aria" "iar")))
    (should (eq (plist-get result :mode) 'aria-cycle))
    (should (string= (plist-get result :archetype) "aria-cycle"))
    (should (string= (plist-get result :personality) "aria"))
    (let ((prompt (plist-get result :prompt)))
      ;; Interactive-style memory: DIGEST and JOURNAL blocks present
      (should (string-match-p "=== DIGEST" prompt))
      (should (string-match-p "=== JOURNAL" prompt))
      ;; Autonomous-style memory absent
      (should-not (string-match-p "=== STATE" prompt)))))

(ert-deftest test-assembly-inject-memory-aria-cycle ()
  "iar--inject-memory with aria-cycle mode returns the same memory
set as interactive mode (DIGEST + LOGS + JOURNAL)."
  (let ((result (iar--inject-memory 'aria-cycle "iar" "aria")))
    (should (stringp result))
    (should (string-match-p "=== DIGEST" result))
    (should (string-match-p "=== JOURNAL" result))
    (should-not (string-match-p "=== STATE" result))))

(ert-deftest test-assembly-assemble-delegated-no-memory ()
  "Assembly with delegated archetype does not inject memory."
  (let ((result (iar--assemble-prompt "agent-assistant" "darwin" "agent-assistant")))
    (let ((prompt (plist-get result :prompt)))
      ;; Should NOT contain SESSION LOGS or STATE blocks
      (should-not (string-match-p "SESSION LOGS" prompt))
      (should-not (string-match-p "=== STATE" prompt)))))

(ert-deftest test-assembly-assemble-tool-gating ()
  "Assembly with restricted project returns filtered tools."
  (let ((result (iar--assemble-prompt "agent-assistant" "darwin" "reviewer")))
    ;; Reviewer project has limited tools
    (let ((tools (plist-get result :tools)))
      (should (listp tools))
      ;; Should not contain delegate tool
      (should-not (cl-some (lambda (t) (equal (gptel-tool-name t) "delegate")) tools)))))
;;; --- Container injection and tool gating tests ---

(ert-deftest test-assembly-format-containers-empty ()
  "format-containers returns empty string for nil/empty containers."
  (should (string= (iar--format-containers nil) ""))
  (should (string= (iar--format-containers '()) "")))

(ert-deftest test-assembly-format-containers-known ()
  "format-containers returns formatted block for known container types."
  (let ((result (iar--format-containers '("pentest"))))
    (should (stringp result))
    (should (string-match-p "AVAILABLE CONTAINERS" result))
    (should (string-match-p "pentest:" result))
    (should (string-match-p "nmap" result))))

(ert-deftest test-assembly-format-containers-unknown ()
  "format-containers handles unknown container types gracefully."
  (let ((result (iar--format-containers '("custom-unknown"))))
    (should (stringp result))
    (should (string-match-p "custom-unknown:" result))
    (should (string-match-p "Unknown container type" result))))

(ert-deftest test-assembly-format-containers-multiple ()
  "format-containers lists multiple targets."
  (let ((result (iar--format-containers '("pentest" "concepts"))))
    (should (string-match-p "pentest:" result))
    (should (string-match-p "concepts:" result))))

(ert-deftest test-assembly-filter-tools-with-containers ()
  "filter-tools includes execute_code_remote when containers is non-nil."
  (let* ((tool-read (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (tool-remote (gptel-make-tool :name "execute_code_remote" :function #'identity :description "test" :args nil))
         (all-tools (list tool-read tool-remote))
         ;; Only read_file in #+TOOLS, but containers implies execute_code_remote
         (filtered (iar--filter-tools all-tools '("read_file") '("pentest"))))
    (should (= (length filtered) 2))
    (should (cl-some (lambda (t) (equal (gptel-tool-name t) "execute_code_remote")) filtered))
    (should (cl-some (lambda (t) (equal (gptel-tool-name t) "read_file")) filtered))))

(ert-deftest test-assembly-filter-tools-without-containers ()
  "filter-tools does NOT include execute_code_remote when containers is nil."
  (let* ((tool-read (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (tool-remote (gptel-make-tool :name "execute_code_remote" :function #'identity :description "test" :args nil))
         (all-tools (list tool-read tool-remote))
         ;; Only read_file in #+TOOLS, no containers
         (filtered (iar--filter-tools all-tools '("read_file") nil)))
    (should (= (length filtered) 1))
    (should (equal (gptel-tool-name (car filtered)) "read_file"))))

(ert-deftest test-assembly-filter-tools-containers-already-in-tools ()
  "filter-tools does not duplicate execute_code_remote if already in #+TOOLS."
  (let* ((tool-read (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (tool-remote (gptel-make-tool :name "execute_code_remote" :function #'identity :description "test" :args nil))
         (all-tools (list tool-read tool-remote))
         ;; Both in #+TOOLS, containers also present
         (filtered (iar--filter-tools all-tools '("read_file" "execute_code_remote") '("pentest"))))
    (should (= (length filtered) 2))
    ;; Only one execute_code_remote
    (should (= (cl-count-if (lambda (t) (equal (gptel-tool-name t) "execute_code_remote")) filtered) 1))))

;;; --- DIGEST.md injection tests ---

(ert-deftest test-assembly-inject-memory-interactive-digest ()
  "Interactive mode injects DIGEST.md (full, untruncated) if it exists."
  (let ((result (iar--inject-memory 'interactive "iar" "aria")))
    (should (stringp result))
    (or (string-match-p "DIGEST" result)
        (string= result ""))))

(ert-deftest test-assembly-read-memory-file-full-no-truncation ()
  "iar--read-memory-file-full returns the entire file regardless of line count."
  (let* ((test-dir (expand-file-name
                    "test_project/test_agent"
                    (expand-file-name iar-audit-path iar-personalization-path)))
         (test-file (expand-file-name "DIGEST.md" test-dir))
         (long-content (concat (make-string 500 ?x) "\n")))
    (unwind-protect
        (progn
          (make-directory test-dir t)
          (with-temp-file test-file
            (dotimes (_ 300) (insert long-content)))
          (let ((result (iar--read-memory-file-full "test_project" "test_agent" "DIGEST.md")))
            ;; 300 lines x 501 chars = 150300 chars -- full content, no truncation
            (should (= (length result) (* 300 501)))))
      (when (file-exists-p test-file)
        (delete-file test-file))
      (ignore-errors (delete-directory test-dir t)))))

(ert-deftest test-assembly-read-memory-file-project-path ()
  "iar--read-memory-file reads from audit/<project>/<personality>/."
  (let* ((test-dir (expand-file-name
                    "test_project2/test_agent2"
                    (expand-file-name iar-audit-path iar-personalization-path)))
         (test-file (expand-file-name "LOGS.md" test-dir)))
    (unwind-protect
        (progn
          (make-directory test-dir t)
          (with-temp-file test-file (insert "project-scoped memory"))
          (let ((result (iar--read-memory-file "test_project2" "test_agent2" "LOGS.md")))
            (should (string= result "project-scoped memory"))))
      (when (file-exists-p test-file)
        (delete-file test-file))
      (ignore-errors (delete-directory test-dir t)))))

(provide 'test-prompt-assembly)
;;; test-prompt-assembly.el ends here
;;; --- Additional coverage tests ---

(ert-deftest test-assembly-archetypes-dir ()
  "iar--archetypes-dir should return a path containing archetypes."
  (let ((result (iar--archetypes-dir)))
    (should (stringp result))
    (should (string-match-p "archetypes" result))))

(ert-deftest test-assembly-personalities-dir ()
  "iar--personalities-dir should return a path containing personalities."
  (let ((result (iar--personalities-dir)))
    (should (stringp result))
    (should (string-match-p "personalities" result))))

(ert-deftest test-assembly-read-base-context ()
  "iar--read-base-context should return content from base_context.org."
  (let ((result (iar--read-base-context)))
    (should (stringp result))
    (should (> (length result) 0))))

(ert-deftest test-assembly-format-mcp-servers-empty ()
  "iar--format-mcp-servers should return empty string for nil/empty."
  (should (string= "" (iar--format-mcp-servers nil)))
  (should (string= "" (iar--format-mcp-servers '()))))

(ert-deftest test-assembly-format-mcp-servers-single ()
  "iar--format-mcp-servers should format a single server."
  (let ((result (iar--format-mcp-servers '("burp"))))
    (should (stringp result))
    (should (string-match-p "burp" result))))

(ert-deftest test-assembly-format-mcp-servers-multiple ()
  "iar--format-mcp-servers should format multiple servers."
  (let ((result (iar--format-mcp-servers '("burp" "other"))))
    (should (stringp result))
    (should (string-match-p "burp" result))
    (should (string-match-p "other" result))))

(ert-deftest test-assembly-inject-memory-autonomous ()
  "iar--inject-memory should inject STATE.org for autonomous mode."
  (let ((result (iar--inject-memory "autonomous" "iar" "darwin")))
    (should (stringp result))
    ;; STATE.org may or may not exist, but the function should not error
    ))

(ert-deftest test-assembly-inject-memory-continuous ()
  "iar--inject-memory should inject STATE.org for continuous mode."
  (let ((result (iar--inject-memory "continuous" "iar" "gardener")))
    (should (stringp result))))

(ert-deftest test-assembly-read-memory-file-nonexistent ()
  "iar--read-memory-file should return empty string for nonexistent file."
  (let ((result (iar--read-memory-file "iar" "nonexistent_agent" "LOGS.md")))
    (should (stringp result))
    (should (string= "" result))))

(ert-deftest test-assembly-auto-load-knowledge-nil ()
  "iar--auto-load-knowledge should return empty content for nil labels."
  (let ((result (iar--auto-load-knowledge nil)))
    (should (consp result))
    (should (string= "" (car result)))
    (should (null (cdr result)))))

(ert-deftest test-assembly-auto-load-knowledge-nonexistent ()
  "iar--auto-load-knowledge should handle nonexistent label gracefully."
  (let ((result (iar--auto-load-knowledge '("nonexistent_label/"))))
    (should (consp result))
    (should (string= "" (car result)))
    (should (null (cdr result)))))

(ert-deftest test-assembly-assemble-one-shot ()
  "iar--assemble-prompt should work with one-shot archetype."
  (let ((result (iar--assemble-prompt "one-shot" "mirror" "iar")))
    (should (plistp result))
    (should (stringp (plist-get result :prompt)))
    (should (eq (plist-get result :mode) 'one-shot))))

(ert-deftest test-assembly-assemble-continuous ()
  "iar--assemble-prompt should work with continuous archetype."
  (let ((result (iar--assemble-prompt "continuous" "gardener" "gardener")))
    (should (plistp result))
    (should (stringp (plist-get result :prompt)))
    (should (eq (plist-get result :mode) 'continuous))))

(provide 'test-prompt-assembly)
;;; test-prompt-assembly.el ends here

;;; --- Additional assemble-prompt coverage ---

(ert-deftest test-assembly-assemble-with-containers ()
  "iar--assemble-prompt should include containers block when project has containers."
  (let ((result (iar--assemble-prompt "interactive" "test" "test")))
    (should (plistp result))
    (should (plist-get result :containers))
    (should (member "pentest" (plist-get result :containers)))))

(ert-deftest test-assembly-assemble-delegated-mode ()
  "iar--assemble-prompt should work with delegated archetype."
  (let ((result (iar--assemble-prompt "agent-assistant" "agent-assistant" "agent-assistant")))
    (should (plistp result))
    (should (eq 'delegated (plist-get result :mode)))))

(ert-deftest test-assembly-assemble-implementer ()
  "iar--assemble-prompt should work with implementer personality."
  (let ((result (iar--assemble-prompt "implementer" "implementer" "implementer")))
    (should (plistp result))
    (should (stringp (plist-get result :prompt)))))

(ert-deftest test-assembly-assemble-reviewer ()
  "iar--assemble-prompt should work with reviewer personality."
  (let ((result (iar--assemble-prompt "reviewer" "reviewer" "reviewer")))
    (should (plistp result))
    (should (stringp (plist-get result :prompt)))))

(provide 'test-prompt-assembly)
;;; test-prompt-assembly.el ends here

;;; --- JOURNAL.org injection tests ---

(ert-deftest test-assembly-inject-memory-interactive-journal ()
  "Interactive mode injects JOURNAL.org if it exists."
  (let ((result (iar--inject-memory 'interactive "iar" "aria")))
    (should (stringp result))
    ;; JOURNAL.org should exist for aria after this session
    (or (string-match-p "JOURNAL" result)
        (string= result ""))))

(ert-deftest test-assembly-inject-memory-interactive-both ()
  "Interactive mode can inject both LOGS.md and JOURNAL.org."
  (let ((result (iar--inject-memory 'interactive "iar" "aria")))
    (should (stringp result))
    ;; If both exist, result should contain both sections
    ;; If neither exists, result is empty
    (or (string-match-p "SESSION LOGS\\|JOURNAL" result)
        (string= result ""))))


(ert-deftest test-assembly-extra-knowledge-labels ()
  "Extra knowledge labels append to the project's #+KNOWLEDGE.
Contract for iar.sh --knowledge -> iar-run-cycle :knowledge
(silently ignored before 2026-08-31).  Uses the \"iar\" label,
which exists in the test environment's docs tree."
  (let ((result (iar--assemble-prompt "aria-cycle" "aria" "iar" '("agora"))))
    (should (string-match-p "=== INJECTED KNOWLEDGE \\[agora\\] ==="
                            (plist-get result :prompt)))
    (should (member "agora" (plist-get result :knowledge-labels)))
    ;; project's own labels still load (they carry trailing slashes
    ;; from iar.org's #+KNOWLEDGE line -- pre-existing quirk)
    (should (member "iar-prod/" (plist-get result :knowledge-labels)))))


(ert-deftest test-assembly-extra-knowledge-dedupe ()
  "Extra label equivalent to a project label (trailing-slash or
whitespace difference) must not produce a second knowledge block.
Reviewer finding: iar.org has iar/ in #+KNOWLEDGE; --knowledge iar
would inject the same directory twice."
  (let* ((result (iar--assemble-prompt "aria-cycle" "aria" "iar" '("iar")))
         (prompt (plist-get result :prompt))
         (count 0)
         (pos 0))
    (while (string-match "=== INJECTED KNOWLEDGE \\[iar/?\\] ===" prompt pos)
      (setq count (1+ count) pos (match-end 0)))
    (should (= count 1))
    (should-not (member "iar" (plist-get result :knowledge-labels)))))
