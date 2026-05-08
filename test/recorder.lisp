;;;; recorder.lisp — HTTP fixture record/replay for hermetic tests.
;;;;
;;;; The slip-agent providers (chat-anthropic, D9 chat-openai/ollama)
;;;; expose a :poster slot that lets tests substitute the HTTP layer
;;;; with a recorded fixture or a capture-and-pass-through wrapper.
;;;;
;;;; Three modes, set by env var AGENT_TEST_MODE (read at suite startup):
;;;;
;;;;   :replay (default)  Read response bodies from
;;;;                      test/fixtures/<provider>/<name>.json.  No
;;;;                      network calls.  This is what `make test`
;;;;                      runs; it must work without any API keys.
;;;;
;;;;   :record             Make real HTTP calls and write each response
;;;;                       body to disk.  Run via `make refresh-fixtures`,
;;;;                       requires provider env vars (ANTHROPIC_API_KEY
;;;;                       etc).  Overwrites existing fixtures.
;;;;
;;;;   :live               Pass through to real HTTP calls without
;;;;                       writing fixtures.  Run via `make test-live`.
;;;;                       For ad-hoc smoke testing.
;;;;
;;;; AGENT_LIVE_TESTS=1 must also be set for :record and :live modes
;;;; to actually hit the network — protects against accidental real
;;;; calls if AGENT_TEST_MODE is set in someone's shell.
;;;;
;;;; Usage in a test:
;;;;
;;;;   (let* ((poster (recorded-poster "anthropic" "invoke-text"))
;;;;          (model  (chat-anthropic :api-key "test" :poster poster))
;;;;          (msg    (send model :invoke "hi")))
;;;;     (assert-equal "..." (message-text msg)))

(defparameter *fixture-dir* "plugins/slip-agent/test/fixtures"
  "Directory rooted at the slip repo root (the cwd of the Go test runner).
Subdirectories segment fixtures by provider name.")

(defun current-test-mode ()
  "Return the active test mode from AGENT_TEST_MODE env var."
  (let ((s (getenv "AGENT_TEST_MODE")))
    (cond ((or (null s) (zerop (length s))) :replay)
          ((string= s "record") :record)
          ((string= s "live")   :live)
          ((string= s "replay") :replay)
          (t (panic (format nil "AGENT_TEST_MODE must be replay|record|live; got ~A" s))))))

(defun live-tests-enabled-p ()
  "Return t iff AGENT_LIVE_TESTS=1 in env."
  (let ((s (getenv "AGENT_LIVE_TESTS")))
    (and s (string= s "1"))))

(defun fixture-path (subdir fixture-name)
  (concatenate 'string *fixture-dir* "/" subdir "/" fixture-name ".json"))

(defun ensure-fixture-dir (subdir)
  "Create the fixture subdirectory if missing.  Best-effort via shell."
  (let ((path (concatenate 'string *fixture-dir* "/" subdir)))
    (recover err
      (progn (declare (ignore err)) nil)
      (system (format nil "mkdir -p ~A" path)))))

(defun read-fixture-text (path)
  "Read the entire file as a string.  Panics if missing — fixture
absence is a test author error."
  (recover err
    (panic (format nil "recorder: cannot read fixture ~A (~A).~%Run with AGENT_TEST_MODE=record AGENT_LIVE_TESTS=1 make refresh-fixtures to create it."
                   path err))
    (with-open-file (in path :direction :input)
      (with-output-to-string (out)
        (let ((done nil))
          (loop
            (let ((line (read-line in nil :eof)))
              (cond ((eq line :eof) (setq done t))
                    (t (format out "~A~A" line (string #\newline)))))
            (when done (return nil))))))))

(defun read-fixture-bag (subdir fixture-name)
  "Read a fixture and parse it as a bag."
  (make-bag (read-fixture-text (fixture-path subdir fixture-name))))

(defun write-fixture (subdir fixture-name response-bag)
  "Write a response bag as pretty-printed JSON to the fixture file."
  (ensure-fixture-dir subdir)
  (with-open-file (out (fixture-path subdir fixture-name)
                       :direction :output :if-exists :supersede)
    (format out "~A" (send response-bag :write nil :pretty t))))

;;; ----------------------------------------------------------------------
;;; recorded-poster — produces a (url headers body) -> bag function
;;; suitable for chat-anthropic's :poster slot.
;;; ----------------------------------------------------------------------

(defun recorded-poster (subdir fixture-name)
  "Return a poster function for the given fixture, dispatching on
*test-mode*.

  :replay  reads test/fixtures/<subdir>/<fixture-name>.json and returns
           its parsed bag, ignoring url/headers/body.

  :record  makes the real HTTP call via post-json, saves the response
           to the fixture path, and returns the response bag.  Panics
           if AGENT_LIVE_TESTS != 1.

  :live    makes the real HTTP call and returns the response bag, no
           fixture written.

Note: parameter is named fixture-name (not name) — `name` collides
with the test framework's per-test name variable, which would shadow
this parameter in closures created inside a deftest body."
  (let ((mode (current-test-mode)))
    (cond
      ((eq mode :replay)
       (lambda (url headers body)
         (declare (ignore url headers body))
         (read-fixture-bag subdir fixture-name)))
      ((eq mode :record)
       (cond ((not (live-tests-enabled-p))
              (panic "recorder: AGENT_TEST_MODE=record requires AGENT_LIVE_TESTS=1"))
             (t
              (lambda (url headers body)
                (let ((response-bag (post-json url headers body)))
                  (write-fixture subdir fixture-name response-bag)
                  response-bag)))))
      ((eq mode :live)
       (cond ((not (live-tests-enabled-p))
              (panic "recorder: AGENT_TEST_MODE=live requires AGENT_LIVE_TESTS=1"))
             (t (lambda (url headers body) (post-json url headers body)))))
      (t (panic (format nil "recorder: unknown mode ~A" mode))))))

;;; ----------------------------------------------------------------------
;;; record-required-p / skip helpers for tests that only run when live
;;; ----------------------------------------------------------------------

(defun network-tests-p ()
  "Return t iff the active mode requires network access (record or live)."
  (let ((mode (current-test-mode)))
    (or (eq mode :record) (eq mode :live))))
