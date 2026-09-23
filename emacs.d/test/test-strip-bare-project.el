;;; test-strip-v2.el -- c273: bare project-prefix doubling (iar/<task>)
;;; The c208 fix handled "project/personality/..." but agents also pass
;;; bare "project/task" paths (iar/history-dedupe-belt, iar/timeout-fork-
;;; guard, iar/nocturne-gate-dead-lineage) which doubled to
;;; tasks/iar/aria/iar/<task>. 12 tasks live under the doubled prefix.

(ert-deftest test-agent-utils-strip-agent-prefix-strips-bare-project ()
  "Bare '<project>/<task>' paths must lose the project segment (c273)."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "aria"))
      (should (string= "history-dedupe-belt"
                       (iar--task-path-strip-agent-prefix "iar/history-dedupe-belt")))
      (should (string= "timeout-fork-guard"
                       (iar--task-path-strip-agent-prefix "iar/timeout-fork-guard"))))))

(ert-deftest test-agent-utils-strip-agent-prefix-double-nested ()
  "Full 'project/personality/project/task' collapses to 'task'."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "aria"))
      (should (string= "timeout-fork-guard"
                       (iar--task-path-strip-agent-prefix "iar/aria/iar/timeout-fork-guard"))))))

(ert-deftest test-agent-utils-strip-agent-prefix-plain-untouched ()
  "Plain paths and non-project leading segments stay untouched."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "aria"))
      (should (string= "track/aria" (iar--task-path-strip-agent-prefix "track/aria")))
      (should (string= "iarx/task" (iar--task-path-strip-agent-prefix "iarx/task")))
      (should (string= "iar" (iar--task-path-strip-agent-prefix "iar"))))))

(ert-deftest test-agent-utils-resolve-task-dir-no-bare-project-doubling ()
  "End-to-end: 'iar/<task>' must resolve to tasks/<project>/<agent>/<task>."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "aria")
          (iar-tasks-path "tasks")
          (iar-personalization-path "/tmp/iar-fake-pers"))
      (let ((result (iar--resolve-task-dir "iar/history-dedupe-belt")))
        (should (string-match-p "tasks/iar/aria/history-dedupe-belt" result))
        (should-not (string-match-p "iar/aria/iar/" result))))))
