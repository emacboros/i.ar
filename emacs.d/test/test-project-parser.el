;; -*- lexical-binding: t; -*-

;;; Tests for iar-project-parser.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-project-parser)

(defvar iar-projects-path nil)

(ert-deftest test-project-parser-load-iar ()
  "Loading the 'iar' project returns correct metadata."
  (let ((p (iar--load-project "iar")))
    (should (string= (plist-get p :name) "iar"))
    (should (member "iar/" (plist-get p :knowledge)))
    (should (member "read_file" (plist-get p :tools)))
    (should (stringp (plist-get p :objective)))
    (should (> (length (plist-get p :objective)) 0))))

(ert-deftest test-project-parser-load-implementer ()
  "Loading 'implementer' project returns restricted tool set."
  (let ((p (iar--load-project "implementer")))
    (should (string= (plist-get p :name) "implementer"))
    (should (member "read_file" (plist-get p :tools)))
    (should-not (member "delegate" (plist-get p :tools)))))

(ert-deftest test-project-parser-load-reviewer ()
  "Loading 'reviewer' project returns minimal read-only tool set."
  (let ((p (iar--load-project "reviewer")))
    (should (member "read_file" (plist-get p :tools)))
    (should-not (member "write_file" (plist-get p :tools)))))

(ert-deftest test-project-parser-candidates ()
  "Project candidates returns list of available projects."
  (let ((candidates (iar--project-candidates)))
    (should (consp candidates))
    (should (assoc "iar" candidates))
    (should-not (assoc "default" candidates))))

(ert-deftest test-project-parser-not-found ()
  "Loading a non-existent project signals an error."
  (should-error (iar--load-project "nonexistent-project-xyz")))

(ert-deftest test-project-parser-parse-metadata-knowledge ()
  "Parse #+KNOWLEDGE line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/ infra/ user/\n#+TOOLS: read_file\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :knowledge) '("iar/" "infra/" "user/")))))

(ert-deftest test-project-parser-parse-metadata-tools ()
  "Parse #+TOOLS line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file write_file\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :tools) '("read_file" "write_file")))))

(ert-deftest test-project-parser-parse-metadata-objective ()
  "Parse #+OBJECTIVE line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+OBJECTIVE: Do the thing.")))
    (should (string= (plist-get meta :objective) "Do the thing."))))

(ert-deftest test-project-parser-parse-metadata-mounts ()
  "Parse #+MOUNTS line with :rw and :ro suffixes."
  (let ((meta (iar--parse-project-metadata
               "#+MOUNTS: /path/a:rw /path/b:ro /path/c\n#+OBJECTIVE: Test")))
    (let ((mounts (plist-get meta :mounts)))
      (should (equal (cdr (assoc "/path/a" mounts)) "rw"))
      (should (equal (cdr (assoc "/path/b" mounts)) "ro"))
      ;; No suffix defaults to rw
      (should (equal (cdr (assoc "/path/c" mounts)) "rw")))))

(ert-deftest test-project-parser-parse-mount-entry ()
  "Parse individual mount entries."
  (should (equal (iar--parse-mount-entry "/path:rw") '("/path" . "rw")))
  (should (equal (iar--parse-mount-entry "/path:ro") '("/path" . "ro")))
  (should (equal (iar--parse-mount-entry "/path") '("/path" . "rw"))))

(ert-deftest test-project-parser-parse-metadata-missing-fields ()
  "Missing fields return nil gracefully."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+OBJECTIVE: Test")))
    (should (null (plist-get meta :tools)))
    (should (null (plist-get meta :mounts)))))

(ert-deftest test-project-parser-parse-metadata-empty ()
  "Empty content returns all nil."
  (let ((meta (iar--parse-project-metadata "")))
    (should (null (plist-get meta :knowledge)))
    (should (null (plist-get meta :tools)))
    (should (null (plist-get meta :mounts)))
    (should (null (plist-get meta :objective)))))

;;; --- #+CONTAINERS parsing tests ---

(ert-deftest test-project-parser-parse-metadata-containers ()
  "Parse #+CONTAINERS line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+CONTAINERS: pentest concepts\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :containers) '("pentest" "concepts")))))

(ert-deftest test-project-parser-parse-metadata-containers-missing ()
  "Missing #+CONTAINERS returns nil."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+OBJECTIVE: Test")))
    (should (null (plist-get meta :containers)))))

(ert-deftest test-project-parser-parse-metadata-containers-single ()
  "Parse single container target."
  (let ((meta (iar--parse-project-metadata
               "#+CONTAINERS: pentest\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :containers) '("pentest")))))

(ert-deftest test-project-parser-parse-metadata-all-fields ()
  "Parse all metadata fields including containers."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/ infra/\n#+TOOLS: read_file write_file\n#+MOUNTS: /path:rw\n#+CONTAINERS: pentest concepts life-org\n#+OBJECTIVE: Full project")))
    (should (equal (plist-get meta :knowledge) '("iar/" "infra/")))
    (should (equal (plist-get meta :tools) '("read_file" "write_file")))
    (should (equal (plist-get meta :containers) '("pentest" "concepts" "life-org")))
    (should (string= (plist-get meta :objective) "Full project"))))

;;; test-project-parser.el ends here
;;; --- #+MCP parsing tests ---

(ert-deftest test-project-parser-parse-metadata-mcp ()
  "Parse #+MCP line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+MCP: burp\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :mcp) '("burp")))))

(ert-deftest test-project-parser-parse-metadata-mcp-multiple ()
  "Parse #+MCP line with multiple servers."
  (let ((meta (iar--parse-project-metadata
               "#+MCP: burp custom-server\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :mcp) '("burp" "custom-server")))))

(ert-deftest test-project-parser-parse-metadata-mcp-missing ()
  "Missing #+MCP returns nil."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+OBJECTIVE: Test")))
    (should (null (plist-get meta :mcp)))))

(provide 'test-project-parser)
;;; test-project-parser.el ends here
;;; --- error path tests ---

(ert-deftest test-project-parser-parse-project-not-found ()
  "iar--parse-project should signal an error for nonexistent file."
  (should-error (iar--parse-project "/nonexistent/path/to/project.org")
                :type 'error))
