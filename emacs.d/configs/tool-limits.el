;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Filesystem Tool Parameters
;; =============================================================================

(defcustom iar-fs-read-max-size (* 1024 1024)
  "Maximum number of characters that read_file will return without truncation.
Files with more characters than this are truncated to this limit and a
truncation notice is appended.  This prevents accidentally loading huge
files (e.g., large log files, binary blobs) into the AI context, which
would consume excessive tokens and slow down responses.
Uses character count (not byte count) because insert-file-contents
decodes the file into Emacs internal representation, and AI token
consumption correlates more with character count than byte count.
Set to nil to disable truncation (read full file regardless of size)."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No limit" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;; =============================================================================
;; Tool Result Truncation Parameters
;; =============================================================================

(defcustom iar-tool-result-max-chars 10000
  "Maximum characters of tool result output before truncation.
When a tool result exceeds this size, the middle is replaced with a
truncation notice, preserving the first and last portions equally.
This prevents unbounded tool output (e.g., large file reads, verbose
command output) from consuming excessive context tokens.

The first half and last half of the result are preserved, with a
notice in between indicating the total size and how much was kept.

Set to nil to disable truncation (pass full result regardless of size)."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No truncation" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;; =============================================================================
;; Tool Result Timestamps
;; =============================================================================

(defcustom iar-tool-result-timestamps t
  "When non-nil, prepend a wall-clock timestamp to every tool result.
Format: [HH:MM:SS] prepended to the result text. Gives agents a sense
of elapsed time between tool calls -- the difference between operating
blind in time and knowing that 40 minutes passed between two actions.

Timestamps are added before truncation, so they survive even in
truncated results. Already-timestamped results are not re-stamped
(idempotent).

Set to nil to disable timestamps (bare results)."
  :type '(choice (const :tag "Enable timestamps" t)
                 (const :tag "Disable timestamps" nil))
  :safe #'booleanp
  :group 'iar)

;; =============================================================================
;; Audit Log Parameters
;; =============================================================================

(defcustom iar-audit-log-max-size (* 10 1024 1024)
  "Maximum size in bytes before the audit log is rotated.
When the log exceeds this size, it is renamed to `audit.log.1'
(overwriting any previous rotation) and a fresh log is started.
Set to nil to disable rotation.

Note: Only one generation of rotated log is retained (audit.log.1).
Each rotation overwrites the previous .1 file.  For compliance-grade
retention, configure external log rotation (e.g., logrotate) instead."
  :type '(choice (integer :tag "Max size in bytes")
                 (const :tag "No rotation" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

(provide 'iar-config-tool-limits)

;; =============================================================================
;; Request Watchdog Parameters (Track A1)
;; =============================================================================

(defcustom iar-request-watchdog-enabled t
  "When non-nil, the request watchdog aborts stalled gptel requests.
A stalled request (dead network stream, hung server) otherwise sits
in flight forever and the session hangs silently. The watchdog
aborts it via `gptel-abort', logs what was in flight, and inserts a
notice into the gptel buffer so the agent sees the abort.
Set to nil to disable (not recommended)."
  :type 'boolean
  :safe #'booleanp
  :group 'iar)

(defcustom iar-request-idle-timeout 180
  "Seconds without stream data before aborting a streaming request.
Streaming requests call the process filter on every chunk; no calls
for this many seconds means the stream died mid-response.
nil disables the idle check."
  :type '(choice (integer :tag "Seconds")
                 (const :tag "Disabled" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

(defcustom iar-request-total-timeout 900
  "Seconds without ANY data before aborting a request.
Covers non-streaming requests (never call the filter) and the
prompt-eval window before the first token of a streaming request.
nil disables the total check."
  :type '(choice (integer :tag "Seconds")
                 (const :tag "Disabled" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;; =============================================================================
;; Malformed Tool Call Feedback Parameters (Track A2)
;; =============================================================================

(defcustom iar-malformed-args-feedback t
  "When non-nil, wrap tool functions with structured error feedback.
Wrong argument shapes then return '<tool_call_error>' messages with
the expected spec and received values, instead of raw elisp error
strings the model cannot learn from.
Set to nil for raw gptel behavior (not recommended)."
  :type 'boolean
  :safe #'booleanp
  :group 'iar)
