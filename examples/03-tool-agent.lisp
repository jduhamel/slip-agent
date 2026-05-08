;;;; 03-tool-agent.lisp — calculator agent with create-agent.
;;;;
;;;; Two tools (calc-add, calc-mul); the model decides when to call them.
;;;;
;;;; Usage (from the slip repo root):
;;;;
;;;;   ANTHROPIC_API_KEY=sk-ant-... \
;;;;     go run cmd/slip/main.go plugins/slip-agent/examples/03-tool-agent.lisp
;;;;
;;;; Without an API key the example falls back to a scripted
;;;; fake-chat-model that mimics the tool-call -> answer flow.

(require 'agent "plugins/slip-agent")

;; def-tool is a macro defined inside the agent package.  Slip
;; compiles a whole file's top-level forms before evaluating any of
;; them, so a macro resolved at compile time isn't yet available
;; when the file is read top-to-bottom.  Wrapping the example body
;; in a (let ()...) defers evaluation past the (require ...) above,
;; at which point the macro is known.  See SLIP-FOOTGUNS.md.
(let ()

(def-tool calc-add (a b)
  "Adds two numbers and returns the sum."
  (+ a b))

(def-tool calc-mul (a b)
  "Multiplies two numbers and returns the product."
  (* a b))

(defun pick-model ()
  (cond ((getenv "ANTHROPIC_API_KEY")
         (init-chat-model "claude-haiku-4-5"))
        (t
         ;; Scripted: turn 1 calls calc-add, turn 2 calls calc-mul,
         ;; turn 3 returns the final answer.  Models must use real
         ;; argument types — a and b are sent as numbers.
         (fake-chat-model
          :scripted-responses
          (list
           (ai-message
            :content (list (text-block "I'll start with the addition.")
                           (tool-use-block :id "1" :name "calc-add"
                                           :input (make-bag "{a: 17, b: 25}"))))
           (ai-message
            :content (list (text-block "Now I'll multiply by 2.")
                           (tool-use-block :id "2" :name "calc-mul"
                                           :input (make-bag "{a: 42, b: 2}"))))
           (ai-message
            :content "(17 + 25) * 2 = 84"))))))

(let* ((model (pick-model))
       (agent (create-agent
               :model model
               :tools (list calc-add calc-mul)
               :system-prompt
               "You are a calculator.  Use the calc-add and calc-mul tools to compute numerical answers.  Show your work step by step.")))
  (format t "Q: What is (17 + 25) * 2?~%")
  (format t "A: ~A~%"
          (message-text (send agent :invoke "What is (17 + 25) * 2?"))))

) ;; close the deferring let

