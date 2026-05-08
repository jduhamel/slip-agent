;;;; 05-structured-output.lisp — :response-format with create-agent.
;;;;
;;;; Demonstrates the synthetic-respond fallback path used by
;;;; providers without native response_format (Anthropic, Ollama).
;;;; OpenAI's native path takes the same :response-format keyword
;;;; and produces the same shape via response_format: json_schema.
;;;;
;;;; Usage (from the slip repo root):
;;;;
;;;;   ANTHROPIC_API_KEY=sk-ant-... \
;;;;     go run cmd/slip/main.go plugins/slip-agent/examples/05-structured-output.lisp
;;;;
;;;; Without an API key, fake-chat-model emits a synthetic-respond
;;;; tool call that the agent intercepts.

(require 'agent "plugins/slip-agent")

;; The shape we want back from the model.  The defstruct symbol is
;; passed as :response-format; v0.1 records it but does not introspect
;; slot types — schema details would normally be conveyed via the
;; agent's system prompt or downstream coercion.
(defstruct weather-report
  (city        "")
  (temperature 0)
  (conditions  ""))

(defun pick-model ()
  (cond ((getenv "ANTHROPIC_API_KEY")
         (init-chat-model "claude-haiku-4-5"))
        (t
         (fake-chat-model
          :scripted-responses
          (list (ai-message
                 :content (list (tool-use-block
                                 :id "respond"
                                 :name (synthetic-respond-tool-name)
                                 :input (make-bag
                                         "{city: \"Tokyo\", temperature: 22, conditions: \"clear\"}")))))))))

(let* ((model (pick-model))
       (agent (create-agent
               :model           model
               :system-prompt   "Return a weather report for the requested city."
               :response-format 'weather-report
               :response-into
               (lambda (bag)
                 (make-weather-report
                  :city        (send bag :get "city")
                  :temperature (send bag :get "temperature")
                  :conditions  (send bag :get "conditions")))))
       (report (send agent :invoke "What's the weather in Tokyo?")))
  (format t "City:        ~A~%" (weather-report-city        report))
  (format t "Temperature: ~A°C~%" (weather-report-temperature report))
  (format t "Conditions:  ~A~%" (weather-report-conditions  report)))
