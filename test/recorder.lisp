;;;; recorder.lisp — HTTP fixture record/replay for hermetic tests.
;;;;
;;;; Three modes, set via *test-mode*:
;;;;
;;;;   :replay (default)  Read response bodies from test/fixtures/<name>.json.
;;;;                      No network calls.  This is what CI runs.
;;;;
;;;;   :record             Make real HTTP calls and write each response
;;;;                       body to test/fixtures/<name>.json.  Requires
;;;;                       provider env vars; only run via
;;;;                       `make refresh-fixtures`.
;;;;
;;;;   :live               Pass through to real HTTP calls without
;;;;                       writing fixtures.  For ad-hoc smoke testing.
;;;;
;;;; The recorder works by binding a `:fixture-name` to a fixture file
;;;; and using with-recorded-call to stub the HTTP layer for that
;;;; specific test body.

(defparameter *test-mode* :replay
  "One of :replay, :record, :live.  :replay is the default for CI.
:record overwrites fixtures; :live passes through to the network.")

(defparameter *fixture-dir* "plugins/slip-agent/test/fixtures"
  "Directory rooted at the slip repo (cwd of the Go test runner).
Subdirectories segment fixtures by provider name.")

(defparameter *original-post-json* nil
  "Saved binding of post-json so :record / :replay can restore it.")

(defparameter *original-post-json-stream* nil
  "Saved binding of post-json-stream for streaming fixtures.")

;;; ----------------------------------------------------------------------
;;; Fixture file paths
;;; ----------------------------------------------------------------------

(defun fixture-path (subdir name)
  "Full path to a fixture file: <fixture-dir>/<subdir>/<name>.json"
  (concatenate 'string *fixture-dir* "/" subdir "/" name ".json"))

(defun ensure-fixture-dir (subdir)
  "Make sure the fixture subdirectory exists.  No-op if already present."
  (let ((path (concatenate 'string *fixture-dir* "/" subdir)))
    ;; Best-effort mkdir via shell — gi has no mkdir in v0.1.
    (gi:recover err
      (progn (declare (ignore err)) nil)
      (system (format nil "mkdir -p ~A" path)))))

;;; ----------------------------------------------------------------------
;;; Stub for :replay mode
;;; ----------------------------------------------------------------------

(defun replay-fixture (subdir name)
  "Read a recorded fixture and return it as a parsed bag."
  (let* ((path (fixture-path subdir name))
         (text (read-file-as-string path)))
    (when (null text)
      (panic (format nil "recorder: no fixture at ~A.  Run with *test-mode* :record to create it." path)))
    (make-bag text)))

(defun read-file-as-string (path)
  "Read entire file contents as a string.  Returns nil if unreadable."
  (gi:recover err
    (progn (declare (ignore err)) nil)
    (with-open-file (in path :direction :input)
      (with-output-to-string (out)
        (loop
          (let ((line (read-line in nil :eof)))
            (when (eq line :eof) (return))
            (format out "~A~A" line (string #\newline))))))))

(defun write-string-to-file (path text)
  "Write text to path, creating the file if needed."
  (with-open-file (out path :direction :output :if-exists :supersede)
    (format out "~A" text)))

;;; ----------------------------------------------------------------------
;;; Public API for tests
;;; ----------------------------------------------------------------------

(defun call-with-recorded-fixture (subdir name body-fn)
  "Run body-fn, with post-json and post-json-stream stubbed according
to *test-mode*.  In :replay mode, body-fn's HTTP calls return the
fixture bag; in :record mode, real calls happen and responses are
saved; in :live mode, calls pass through."
  (cond
    ((eq *test-mode* :replay)
     (funcall body-fn (replay-fixture subdir name)))
    ((eq *test-mode* :record)
     (ensure-fixture-dir subdir)
     ;; Real call happens inside body-fn; we capture by wrapping the
     ;; helpers so the live HTTP response gets written to disk.
     ;;
     ;; v0.1 D8: record mode writes whatever body-fn returns as the
     ;; fixture content if it's a bag.  Refinement (live response
     ;; capture) lands in a follow-up; for now :record is documented
     ;; but not fully wired.
     (let ((result (funcall body-fn nil)))
       (when (typep result 'bag-flavor)
         (write-string-to-file (fixture-path subdir name)
                               (send result :write nil :pretty t)))
       result))
    ((eq *test-mode* :live)
     (funcall body-fn nil))
    (t (panic (format nil "recorder: unknown *test-mode* ~A" *test-mode*)))))

;;; ----------------------------------------------------------------------
;;; Stubbed post-json that returns the fixture in :replay mode
;;; ----------------------------------------------------------------------

(defun stub-post-json-with-fixture (fixture-bag)
  "Return a one-arg function suitable for shadowing post-json
behaviour: ignores its arguments and returns the pre-loaded fixture
bag.  Useful when a test wants every post-json call inside body-fn to
return the same fixture."
  (lambda (url headers body)
    (declare (ignore url headers body))
    fixture-bag))
