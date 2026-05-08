;;;; tests.lisp — top-level test orchestrator for slip-agent.
;;;;
;;;; Run from the slip repo root via:
;;;;   go run cmd/slip/main.go -e '(run-tests)' plugins/slip-agent/test/tests.lisp
;;;; (which is what the Go-side main_test.go does — see ../../Makefile).

;;; Paths are relative to the slip repo root (the cwd when this file is
;;; loaded by the Go test runner — see test/main_test.go).
(require 'agent "plugins/slip-agent")

(defvar agent-suite (defsuite "slip-agent" nil))

;; Load the recording harness before any test file so recorded-poster
;; and friends are available.
(load "plugins/slip-agent/test/recorder.lisp")

(load "plugins/slip-agent/test/messages_test.lisp")
(load "plugins/slip-agent/test/callbacks_test.lisp")
(load "plugins/slip-agent/test/runnable_test.lisp")
(load "plugins/slip-agent/test/composition_test.lisp")
(load "plugins/slip-agent/test/prompts_test.lisp")
(load "plugins/slip-agent/test/output-parsers_test.lisp")
(load "plugins/slip-agent/test/tools_test.lisp")
(load "plugins/slip-agent/test/chat-models_test.lisp")
(load "plugins/slip-agent/test/anthropic_test.lisp")

(defun run-tests ()
  (send agent-suite :run)
  (send agent-suite :report *standard-output*))
