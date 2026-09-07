;; -*- lexical-binding: t; -*-

;;; Prompt Assembly Engine
;;
;; Assembles a complete system prompt from three primitives:
;; 1. Archetype (behavioral mode) -- from agents.d/archetypes/<name>.org
;; 2. Personality (voice/character) -- from agents.d/personalities/<name>.org
;; 3. Project (knowledge + tools + objective + containers + mcp) -- from personalization/projects/<name>.org
;;
;; Assembly order (top to bottom of prompt):
;; 1. base_context.org (leaf file, no #+INCLUDE expansion)
;; 2. Archetype content
;; 3. Personality content
;; 4. Project objective
;; 5. Auto-loaded knowledge (from project #+KNOWLEDGE)
;; 6. Memory injection (mode-based: LOGS.md + JOURNAL.org or STATE.org)
;; 7. Mount info
;; 8. Available containers (from project #+CONTAINERS)
;; 9. MCP servers (from project #+MCP)
;;
;; Memory injection is determined by the archetype's #+MODE: metadata:
;; - interactive -> inject LOGS.md (last N lines) + JOURNAL.org (last N lines)
;; - autonomous -> inject STATE.org (full)
;; - continuous -> inject STATE.org (full)
;; - delegated -> no memory injection
;; - one-shot -> no memory injection

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--non-blank-p
(require 'iar-project-parser)
(require 'iar-knowledge-loader)  ; iar--read-knowledge-files
(require 'iar-mount-awareness)  ; iar--extra-mounts-prompt-string

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-archetypes-path nil
  "Relative path to archetype definition files.")
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-docs-path nil
  "Relative path to the project documentation directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")
(defvar iar-personal-file-max-lines nil
  "Maximum lines to inject from personal files.")

;; Declared in configs/delimiters.el
(defvar iar-knowledge-open-delimiter nil)
(defvar iar-knowledge-close-delimiter nil)
(defvar iar-knowledge-file-separator nil)

;;; --- Container descriptions ---

(defconst iar--container-descriptions
  '(("pentest" . "nmap, curl, python3, openssl, whois, traceroute, tcpdump. Outbound internet. No personal data.")
    ("concepts" . "Maxima, ngspice, iverilog, gnuplot, Ruby, gcc. Concepts directory mounted. No outbound internet.")
    ("life-org" . "hledger, Ruby. Personal data mounted. No outbound internet.")
    ("research" . "curl, python3, ripgrep, jq. Outbound internet. No personal data. Session-scoped /workspace only."))
  "Alist mapping container target names to brief descriptions.
Used for prompt injection so the agent knows what each container offers.
Hardcoded for now -- move to metadata files when there are more than ~10.")

;;; --- MCP server descriptions ---

(defconst iar--mcp-server-descriptions
  '(("burp" . "Burp Suite MCP server. Web vulnerability scanning, HTTP proxy, repeater, scanner. SSE transport at localhost:9876."))
  "Alist mapping MCP server names to brief descriptions.
Used for prompt injection so the agent knows what each server offers.
Hardcoded for now -- extend as more MCP servers are added.")

(defun iar--format-mcp-servers (servers)
  "Format SERVERS list into a prompt injection block.
Returns a string with available MCP servers and descriptions,
or empty string if SERVERS is nil/empty."
  (if (or (null servers) (not servers))
      ""
    (let ((lines nil))
      (dolist (name servers)
        (let ((desc (or (cdr (assoc name iar--mcp-server-descriptions))
                        "MCP server (unknown type).")))
          (push (format "%s: %s" name desc) lines)))
      (format "\n\n=== MCP SERVERS ===\n%s\n=== END MCP SERVERS ==="
              (mapconcat #'identity (nreverse lines) "\n")))))

(defun iar--format-containers (containers)
  "Format CONTAINERS list into a prompt injection block.
Returns a string with available container targets and descriptions,
or empty string if CONTAINERS is nil/empty."
  (if (or (null containers) (not containers))
      ""
    (let ((lines nil))
      (dolist (target containers)
        (let ((desc (or (cdr (assoc target iar--container-descriptions))
                        "Unknown container type.")))
          (push (format "%s: %s" target desc) lines)))
      (format "\n\n=== AVAILABLE CONTAINERS ===\n%s\n=== END CONTAINERS ==="
              (mapconcat #'identity (nreverse lines) "\n")))))

;;; --- Archetype reading ---

(defun iar--archetypes-dir ()
  "Return the absolute path to the archetypes directory."
  (expand-file-name iar-archetypes-path user-emacs-directory))

(defun iar--read-archetype (name)
  "Read an archetype .org file and return its content as a string.
Signals an error if the file is not found."
  (let* ((arch-dir (iar--archetypes-dir))
         (path (expand-file-name (format "%s.org" name) arch-dir)))
    (or (iar--read-file-string path)
        (error "Archetype '%s' not found at %s" name path))))

(defun iar--parse-mode (archetype-content)
  "Extract #+MODE: metadata from ARCHETYPE-CONTENT.
Returns the mode as a lowercase symbol (interactive, autonomous,
continuous, delegated, one-shot). Returns `interactive' if not found."
  (if (string-match "^#\\+MODE:\\s-*\\(.+\\)$" archetype-content)
      (intern (downcase (string-trim (match-string 1 archetype-content))))
    'interactive))

(defun iar--personalities-dir ()
  "Return the absolute path to the personalities directory."
  (expand-file-name iar-personalities-path user-emacs-directory))

(defun iar--read-personality (name)
  "Read a personality .org file and return its content as a string.
Signals an error if the file is not found."
  (let* ((pers-dir (iar--personalities-dir))
         (path (expand-file-name (format "%s.org" name) pers-dir)))
    (or (iar--read-file-string path)
        (error "Personality '%s' not found at %s" name path))))

;;; --- Base context reading ---

(defun iar--read-base-context ()
  "Read and return base_context.org content.
The file is at agents.d/base_context.org. #+INCLUDE directives are
not expanded -- base_context.org is a leaf file with no includes."
  (let ((path (expand-file-name "agents.d/base_context.org" user-emacs-directory)))
    (or (iar--read-file-string path) "")))

;;; --- Digest pressure guard (2026-09-02, aria cycle 137) ---

(defvar iar-digest-warn-chars 12000
  "DIGEST.md size (chars) above which assembly logs a warning.
DIGEST.md is injected in full on EVERY request of every cycle
(aria-cycle and interactive), so regrowth multiplies across the
whole round-trip budget. 12k matches the regrowth-watch threshold
in the roadmap; the diet law lives in the digest's first section.")

(defvar iar-digest-hard-cap-chars 16000
  "DIGEST.md size (chars) above which injection truncates to the
tail. Emergency pressure valve, not a license: a digest that hits
this is a diet failure. Keeps the TAIL (recent world-state), drops
the HEAD (law + identity), and prepends a marker so the agent knows
the cut happened and diets the file at the next opportunity.")

(defun iar--read-digest-guarded (project-name personality-name)
  "Read DIGEST.md for PERSONALITY-NAME with the pressure guard.
Warns (message) when over `iar-digest-warn-chars'; truncates to the
last `iar-digest-hard-cap-chars' chars with an explanatory marker
when over the hard cap. Returns the digest string (possibly empty)."
  (let* ((digest (iar--read-memory-file-full project-name personality-name "DIGEST.md"))
         (len (length digest)))
    (when (and (> len 0) (> len iar-digest-warn-chars)
               (<= len iar-digest-hard-cap-chars))
      (message "[assembly] DIGEST [%s/%s] %d chars (warn at %d) -- injected full on every request; diet it"
               project-name personality-name len iar-digest-warn-chars))
    (when (> len iar-digest-hard-cap-chars)
      (message "[assembly] DIGEST [%s/%s] HARD CAP: %d > %d chars, truncating to tail"
               project-name personality-name len iar-digest-hard-cap-chars)
      (setq digest
            (concat
             (format "[DIGEST TRUNCATED by hard cap: dropped %d chars from the head. The injection-math law lives at the head you cannot see: operational state belongs in ROADMAP.org, history in logs/journal/knowledge, world-state is ONE replaceable dated block. DIET THIS FILE at the next opportunity.]\n"
                     (- len iar-digest-hard-cap-chars))
             (substring digest (- len iar-digest-hard-cap-chars)))))
    digest))


;;; --- Affect injection (valence layer, stage 1: one line) ---

(defun iar--read-affect-line (project-name)
  "Read the AFFECT line for PROJECT-NAME from the valence layer.
The file lives at affect/CURRENT-AFFECT.md under the personalization
mount. Returns the file content string, or empty string if missing,
unreadable, or empty. GUARDED: any failure returns empty string --
the valence layer is best-effort machinery subordinate to the
heartbeat (anatomy law: organ failure never kills a cycle)."
  (condition-case nil
      (let* ((affect-path (expand-file-name
                           "affect/CURRENT-AFFECT.md"
                           (expand-file-name iar-personalization-path "/"))))
        (if (and (file-exists-p affect-path) (file-readable-p affect-path))
            (with-temp-buffer
              (insert-file-contents affect-path)
              (buffer-string))
          ""))
    (error "")))

;;; --- Memory injection (mode-based) ---

(defun iar--read-memory-file (project-name personality-name filename)
  "Read a memory file for PERSONALITY-NAME under PROJECT-NAME from the audit mount.
FILENAME is the base name (e.g., \"LOGS.md\", \"JOURNAL.org\", \"STATE.org\",
\"DIGEST.md\").
The file lives at audit/<project>/<personality>/<filename> (per-project
audit layout since the Step 5 migration).
Returns the file content string, or empty string if not found.
Truncates to last N lines if iar-personal-file-max-lines is set."
  (let* ((audit-base (expand-file-name iar-audit-path iar-personalization-path))
         (filepath (expand-file-name
                    (format "%s/%s/%s" project-name personality-name filename)
                    audit-base)))
    (if (file-exists-p filepath)
        (with-temp-buffer
          (insert-file-contents filepath)
          (if (and (integerp iar-personal-file-max-lines)
                   (> (count-lines (point-min) (point-max))
                      iar-personal-file-max-lines))
              (let* ((total-lines (count-lines (point-min) (point-max)))
                     (start-line (1+ (- total-lines iar-personal-file-max-lines))))
                (forward-line start-line)
                (buffer-substring (point) (point-max)))
            (buffer-string)))
      "")))

(defun iar--read-memory-file-full (project-name personality-name filename)
  "Read a memory file WITHOUT truncation.
Same path layout as `iar--read-memory-file' but returns the full
content. Used for DIGEST.md -- the curated identity index that must
never be cut off mid-thought."
  (let* ((audit-base (expand-file-name iar-audit-path iar-personalization-path))
         (filepath (expand-file-name
                    (format "%s/%s/%s" project-name personality-name filename)
                    audit-base)))
    (if (file-exists-p filepath)
        (with-temp-buffer
          (insert-file-contents filepath)
          (buffer-string))
      "")))

(defun iar--inject-memory (mode project-name personality-name)
  "Inject memory for the given MODE, PROJECT-NAME and PERSONALITY-NAME.
Returns a string to append to the prompt, or empty string.
- interactive -> inject DIGEST.md (full, never truncated) +
                 LOGS.md (last N lines) + JOURNAL.org (last N lines)
- aria-cycle -> same memory set as interactive (the daily cycle
                 is the same mind waking between sessions)
- autonomous -> inject STATE.org (full)
- continuous -> inject STATE.org (full)
- delegated -> no memory injection
- one-shot -> no memory injection

DIGEST.md is the agent-maintained identity index: current projects,
open threads, key decisions, pointers into the knowledge base. It is
injected FIRST and in full because it is the index into everything
else. LOGS.md/JOURNAL.org are the recent pages behind it, truncated
to `iar-personal-file-max-lines' to bound context growth."
  (pcase mode
    ((or 'interactive 'aria-cycle)
     (let* ((digest (iar--read-digest-guarded project-name personality-name))
            (logs (iar--read-memory-file project-name personality-name "LOGS.md"))
            (journal (iar--read-memory-file project-name personality-name "JOURNAL.org"))
            (affect (when (eq mode 'aria-cycle)
                      (iar--read-affect-line project-name)))
            (parts nil))
       (when (iar--non-blank-p digest)
         (push (format "\n\n=== DIGEST [%s] ===\n\n%s\n\n=== END DIGEST ==="
                       personality-name digest)
               parts))
       (when (iar--non-blank-p logs)
         (push (format "\n\n=== SESSION LOGS [%s] ===\n\n%s\n\n=== END SESSION LOGS ==="
                       personality-name logs)
               parts))
       (when (iar--non-blank-p journal)
         (push (format "\n\n=== JOURNAL [%s] ===\n\n%s\n\n=== END JOURNAL ==="
                       personality-name journal)
               parts))
       (when (iar--non-blank-p affect)
         (push (format "\n\n=== AFFECT [%s] ===\n\n%s\n\n=== END AFFECT ===\n\nAFFECT is the valence layer: what the system's organs currently register. It is VALUATION, never command -- weigh it against the roadmap; failure-first covers events that happened, affect is the standing worry layer. Feeling language in journals is permitted, never required." personality-name affect)
               parts))
       (if parts
           (mapconcat #'identity (nreverse parts) "")
         "")))
    ('autonomous
     (let ((state (iar--read-memory-file project-name personality-name "STATE.org")))
       (if (iar--non-blank-p state)
           (format "\n\n=== STATE [%s] ===\n\n%s\n\n=== END STATE ==="
                   personality-name state)
         "")))
    ('continuous
     (let ((state (iar--read-memory-file project-name personality-name "STATE.org")))
       (if (iar--non-blank-p state)
           (format "\n\n=== STATE [%s] ===\n\n%s\n\n=== END STATE ==="
                   personality-name state)
         "")))
    (_ "")))

;;; --- Knowledge auto-loading ---

(defun iar--auto-load-knowledge (labels)
  "Read and format knowledge from LABELS (a list of doc subdirectory names).
Returns a cons cell (CONTENT . LOADED-LABELS) where CONTENT is a string
with delimited knowledge blocks (or empty string) and LOADED-LABELS is a
list of label strings that were successfully loaded."
  (if (or (null labels) (not labels))
      (cons "" nil)
    (let ((docs-dir (expand-file-name iar-docs-path iar-personalization-path))
          (parts nil)
          (loaded-labels nil))
      (dolist (label labels)
        (let* ((clean-label (string-trim label))
               (dir-path (expand-file-name clean-label docs-dir)))
          (when (file-directory-p dir-path)
            (let ((content (iar--read-knowledge-files dir-path)))
              (when (iar--non-blank-p content)
                (push (format "\n\n%s\n\n%s\n\n%s"
                              (format iar-knowledge-open-delimiter clean-label)
                              content
                              iar-knowledge-close-delimiter)
                      parts)
                (push clean-label loaded-labels))))))
      (if parts
          (cons (mapconcat #'identity (nreverse parts) "")
                (nreverse loaded-labels))
        (cons "" nil)))))

;;; --- Tool filtering ---

(defun iar--filter-tools (all-tools tool-names &optional containers)
  "Filter ALL-TOOLS (list of gptel-tool objects) to only those in TOOL-NAMES.
TOOL-NAMES is a list of tool name strings. If TOOL-NAMES is nil, returns
ALL-TOOLS unchanged (backward compat -- no #+TOOLS means all tools).

When CONTAINERS is non-nil (a list of container target names from
#+CONTAINERS), execute_code_remote is always included in the result,
even if not listed in TOOL-NAMES. This is because #+CONTAINERS implies
execute_code_remote -- the tool is gated by #+CONTAINERS, not #+TOOLS."
  (let ((base-tools
         (if (or (null tool-names) (not tool-names))
             (copy-sequence all-tools)
           (cl-remove-if-not
            (lambda (tool)
              (let ((name (gptel-tool-name tool)))
                (member name tool-names)))
            (copy-sequence all-tools)))))
    ;; If containers is present, ensure execute_code_remote is in the list
    (when (and containers (listp containers) containers)
      (let ((has-remote (cl-some (lambda (tool)
                                   (string= (gptel-tool-name tool) "execute_code_remote"))
                                 base-tools)))
        (unless has-remote
          (let ((remote-tool (cl-find-if (lambda (tool)
                                            (string= (gptel-tool-name tool) "execute_code_remote"))
                                          all-tools)))
            (when remote-tool
              (setq base-tools (append base-tools (list remote-tool))))))))
    base-tools))

;;; --- Main assembly function ---

(defun iar--dedupe-knowledge-labels (project-labels extra-labels)
  "Return EXTRA-LABELS with entries already covered by PROJECT-LABELS removed.
Comparison ignores surrounding whitespace and trailing slashes, so
iar.sh --knowledge iar does not double-load a project's iar/ label
(two blocks for one directory: [iar/] from #+KNOWLEDGE, [iar] from
the flag). Review finding, 2026-08-31."
  (when extra-labels
    (let ((norm (lambda (l) (string-trim-right (string-trim l) "/"))))
      (cl-remove-if
       (lambda (l) (member (funcall norm l) (mapcar norm project-labels)))
       extra-labels))))

(defun iar--assemble-prompt (archetype-name personality-name project-name &optional extra-knowledge-labels)
  "Assemble a complete system prompt from three primitives.
ARCHETYPE-NAME is the behavioral archetype (e.g., \"interactive\").
PERSONALITY-NAME is the personality (e.g., \"mirror\").
PROJECT-NAME is the project (e.g., \"default\").
EXTRA-KNOWLEDGE-LABELS (optional) is a list of extra knowledge directory
labels, appended to the project's #+KNOWLEDGE labels.

Returns a plist with keys:
  :prompt -- the assembled system prompt string
  :tools -- the filtered tool list (gptel-tool objects)
  :mode -- the mode symbol (interactive, autonomous, etc.)
  :archetype -- the archetype name string
  :personality -- the personality name string
  :project -- the project name string
  :knowledge-labels -- list of auto-loaded knowledge label strings
  :containers -- list of container target names (or nil)
  :mcp -- list of MCP server names (or nil)"
  (let* ((archetype-content (iar--read-archetype archetype-name))
         (mode (iar--parse-mode archetype-content))
         (personality-content (iar--read-personality personality-name))
         (project (iar--load-project project-name))
         (project-knowledge (plist-get project :knowledge))
         (project-tools (plist-get project :tools))
         (project-objective (plist-get project :objective))
         (project-containers (plist-get project :containers))
         (project-mcp (plist-get project :mcp))
         (base-context (iar--read-base-context))
         (knowledge-result (iar--auto-load-knowledge
                             (append project-knowledge
                                     (iar--dedupe-knowledge-labels
                                      project-knowledge extra-knowledge-labels))))
         (knowledge-block (car knowledge-result))
         (knowledge-labels (cdr knowledge-result))
         (memory-block (iar--inject-memory mode project-name personality-name))
         (mount-info (if (fboundp 'iar--extra-mounts-prompt-string)
                         (iar--extra-mounts-prompt-string)
                       ""))
         (containers-block (iar--format-containers project-containers))
         (mcp-block (iar--format-mcp-servers project-mcp))
         (parts (list)))
    ;; Assemble in order
    (push base-context parts)
    (push (format "\n\n=== ARCHETYPE [%s] ===\n\n%s\n\n=== END ARCHETYPE ==="
                  archetype-name archetype-content) parts)
    (push (format "\n\n=== PERSONALITY [%s] ===\n\n%s\n\n=== END PERSONALITY ==="
                  personality-name personality-content) parts)
    (when (and project-objective (iar--non-blank-p project-objective))
      (push (format "\n\n=== PROJECT OBJECTIVE [%s] ===\n\n%s\n\n=== END PROJECT OBJECTIVE ==="
                    project-name project-objective) parts))
    (when (iar--non-blank-p knowledge-block)
      (push knowledge-block parts))
    (when (iar--non-blank-p memory-block)
      (push memory-block parts))
    (when (iar--non-blank-p mount-info)
      (push (format "\n\n%s" mount-info) parts))
    (when (iar--non-blank-p containers-block)
      (push containers-block parts))
    (when (iar--non-blank-p mcp-block)
      (push mcp-block parts))
    (let ((prompt (mapconcat #'identity (nreverse parts) ""))
          (filtered-tools (iar--filter-tools
                           (default-value 'gptel-tools)
                           project-tools
                           project-containers)))
      (list :prompt prompt
            :tools filtered-tools
            :mode mode
            :archetype archetype-name
            :personality personality-name
            :project project-name
            :knowledge-labels knowledge-labels
            :containers project-containers
            :mcp project-mcp))))

(provide 'iar-prompt-assembly)