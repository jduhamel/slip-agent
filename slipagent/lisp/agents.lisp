;;;; agents.lisp — create-agent: tool-calling loop with optional
;;;; structured output.
;;;;
;;;; create-agent returns a runnable.  :invoke runs the loop:
;;;;
;;;;   1. Build initial messages from system-prompt + input.
;;;;   2. Bind tools to the model and call it.
;;;;   3. Append the assistant response to the running history,
;;;;      preserving its full content-blocks list verbatim (Level A
;;;;      reasoning support — reasoning blocks and unknown blocks
;;;;      round-trip without modification).
;;;;   4. If no tool-calls and no response-format: return the
;;;;      ai-message.
;;;;   5. If response-format is set and the model returned a synthetic
;;;;      :respond call (or native JSON): parse it and return the
;;;;      structured value.
;;;;   6. Otherwise dispatch each tool-call (serial or parallel),
;;;;      append a tool-message per result, and loop.
;;;;   7. After max-iterations turns without termination, panic.

(defflavor agent-runnable
    ((agent-model nil) (agent-tools nil) (system-prompt nil)
     (max-iterations 25) (parallel-tool-calls nil)
     (on-tool-error :return-as-message)
     (response-format nil) (response-into nil))
    (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A runnable that runs a tool-calling loop against a chat model.
Constructed via create-agent; consumers send :invoke or :stream as
with any runnable.  See create-agent for the slot semantics."))

;;; ----------------------------------------------------------------------
;;; Synthetic terminal tool for non-native structured output
;;;
;;; Anthropic and Ollama don't have a native response_format API, so
;;; we add a virtual tool named _respond whose args-schema is the
;;; response-format struct.  The model is instructed (via the system
;;; prompt) to call _respond exactly once when it has the final
;;; answer.  When the loop sees that call, it terminates and parses
;;; the args as the structured result.
;;; ----------------------------------------------------------------------

;; Inlined as a zero-arg function rather than a defparameter — Slip's
;; defparameter cross-package access is unreliable.
(defun synthetic-respond-tool-name ()
  "respond_with_final_answer")

(defun build-synthetic-respond-tool (schema-name)
  "Construct a base-tool whose schema represents the response-format
struct; the underlying func is never called (the agent loop intercepts
the call before it dispatches)."
  (let ((tool (make-instance 'base-tool
                             :tool-name   (synthetic-respond-tool-name)
                             :description (format nil
                                                  "Call this tool exactly once to deliver the final structured answer for type ~A.  All other tool calls are intermediate work."
                                                  schema-name)
                             :args-schema schema-name
                             :arg-names   nil
                             :func        (lambda (&rest args)
                                            (declare (ignore args))
                                            nil))))
    tool))

(defun synthetic-respond-prompt-suffix (schema-name)
  "Text appended to the system prompt when the synthetic-respond
mechanism is active."
  (format nil "~%~%When you have the final answer, call the ~A tool exactly once with arguments matching the ~A schema.  Use other tools for intermediate work; do not call ~A more than once."
          (synthetic-respond-tool-name)
          schema-name
          (synthetic-respond-tool-name)))

(defun is-native-structured-output-provider-p (model)
  "True iff model handles response-format natively (no synthetic
tool needed).  v0.1: only chat-openai (and chat-ollama by inheritance)."
  (or (typep model 'chat-openai)
      (typep model 'chat-ollama)))

;;; ----------------------------------------------------------------------
;;; Tool dispatch
;;; ----------------------------------------------------------------------

(defun find-tool-by-name (tools tool-name)
  "Look up a tool by its tool-name string; nil if not found."
  (let ((found nil))
    (dolist (tool tools)
      (when (and (null found)
                 (string= (send tool :tool-name) tool-name))
        (setq found tool)))
    found))

(defun dispatch-tool-call (tools call on-tool-error-mode handlers config)
  "Look up the tool by name and invoke it with the call's input.
Returns a tool-message.  On panic, behaviour depends on
on-tool-error-mode (:raise re-raises; :return-as-message wraps as an
errored tool-message)."
  (declare (ignore config))
  (let* ((name (send call :name))
         (tool (find-tool-by-name tools name))
         (id   (send call :id)))
    (cond
      ((null tool)
       (tool-message
        (format nil "Error: tool ~A is not registered with this agent" name)
        id
        :is-error t))
      (t
       (recover err
         (cond ((eq on-tool-error-mode :raise) (panic err))
               (t (tool-message
                   (format nil "Error: ~A" err)
                   id
                   :is-error t)))
         (let ((result (send tool :invoke (send call :input)
                             :callbacks handlers)))
           (tool-message
            (cond ((stringp result) result)
                  (t (format nil "~A" result)))
            id)))))))

(defun dispatch-tool-calls (tools calls parallel-p on-tool-error-mode handlers config)
  "Dispatch each call.  Returns a list of tool-messages in the same
order as calls.  When parallel-p, one goroutine per call; otherwise
serial."
  (cond
    ((null parallel-p)
     (let ((result nil))
       (dolist (call calls)
         (push (dispatch-tool-call tools call on-tool-error-mode
                                   handlers config)
               result))
       (nreverse result)))
    (t
     ;; Spawn one goroutine per call; collect via 1-cap channels and
     ;; reorder to match the original calls list.  Same pattern as
     ;; runnable-parallel from D3.
     (let ((entries nil))
       (dolist (call calls)
         (let* ((id (send call :id))
                (ch (make-channel 1))
                (call-cap call))
           (push (cons id ch) entries)
           (run
             (recover err
               (channel-push ch
                             (cond ((eq on-tool-error-mode :raise) (panic err))
                                   (t (tool-message
                                       (format nil "Error: ~A" err)
                                       (send call-cap :id)
                                       :is-error t))))
               (channel-push ch
                             (dispatch-tool-call tools call-cap
                                                 on-tool-error-mode
                                                 handlers config))))))
       ;; Collect in original call order.
       (let ((result nil))
         (dolist (call calls)
           (let* ((id (send call :id))
                  (entry (cdr (assoc id (nreverse entries)
                                     :test #'string=))))
             (push (channel-pop entry) result)))
         (nreverse result))))))

;;; ----------------------------------------------------------------------
;;; The loop
;;; ----------------------------------------------------------------------

(defmethod (agent-runnable :invoke-impl) (input &rest config)
  (let* ((handlers       (getf config :callbacks))
         (using-synthetic (and response-format
                               (not (is-native-structured-output-provider-p agent-model))))
         (effective-tools (cond (using-synthetic
                                 (cons (build-synthetic-respond-tool
                                        response-format)
                                       agent-tools))
                                (t agent-tools)))
         (effective-system (cond (using-synthetic
                                   (concatenate 'string
                                                (or system-prompt "")
                                                (synthetic-respond-prompt-suffix
                                                 response-format)))
                                  (t system-prompt)))
         (model-with-rf (cond
                          ((and response-format
                                (is-native-structured-output-provider-p
                                 agent-model))
                           (let ((m (send agent-model :copy)))
                             (setf (send m :response-format) response-format)
                             m))
                          (t agent-model)))
         (bound-model (cond (effective-tools
                              (send model-with-rf :bind-tools effective-tools))
                             (t model-with-rf)))
         (messages       (build-initial-messages effective-system input))
         (iter-left      max-iterations)
         (final-result   nil)
         (done           nil))
    (loop
      (when (zerop iter-left)
        (panic (format nil "create-agent: max-iterations (~A) exceeded"
                       max-iterations)))
      (let* ((ai-msg (send bound-model :invoke messages
                           :callbacks handlers))
             (calls  (send ai-msg :tool-calls)))
        ;; Append assistant message verbatim — Level A guarantee.
        (setq messages (append messages (list ai-msg)))
        (cond
          ;; No tool calls: terminate.
          ((null calls)
           (setq final-result
                 (cond
                   ;; Native structured output: parse content as JSON.
                   ((and response-format
                         (is-native-structured-output-provider-p agent-model))
                    (parse-native-structured-result ai-msg response-into))
                   (t ai-msg)))
           (setq done t))
          ;; If using synthetic-respond and that tool was called,
          ;; intercept and parse its args.
          (using-synthetic
           (let ((respond-call (find-respond-call calls)))
             (cond (respond-call
                     (setq final-result
                           (parse-synthetic-respond-args
                            respond-call response-into))
                     (setq done t))
                   (t
                    ;; Otherwise dispatch the real tool calls and loop.
                    (let ((tool-msgs
                            (dispatch-tool-calls
                             effective-tools calls parallel-tool-calls
                             on-tool-error handlers config)))
                      (setq messages (append messages tool-msgs))
                      (setq iter-left (1- iter-left)))))))
          ;; Regular tool-calling path.
          (t
           (let ((tool-msgs
                   (dispatch-tool-calls
                    effective-tools calls parallel-tool-calls
                    on-tool-error handlers config)))
             (setq messages (append messages tool-msgs))
             (setq iter-left (1- iter-left))))))
      (when done (return final-result)))))

(defun build-initial-messages (system-prompt input)
  "Return a list of messages suitable as the initial agent input.
input may be a string (becomes a human-message), a single message,
or a list of messages."
  (let ((tail (cond ((stringp input)               (list (human-message input)))
                    ((typep input 'human-message)  (list input))
                    ((typep input 'system-message) (list input))
                    ((typep input 'ai-message)     (list input))
                    ((typep input 'tool-message)   (list input))
                    ((listp input)                 input)
                    (t (panic
                         (format nil
                                 "create-agent: invoke input must be a string, message, or list; got ~A"
                                 (type-of input)))))))
    (cond ((and system-prompt (> (length system-prompt) 0))
           (cons (system-message system-prompt) tail))
          (t tail))))

(defun find-respond-call (calls)
  "Find a tool-use-block whose name matches the synthetic-respond
tool name; nil if not present."
  (let ((found nil))
    (dolist (call calls)
      (when (and (null found)
                 (string= (send call :name) (synthetic-respond-tool-name)))
        (setq found call)))
    found))

(defun parse-synthetic-respond-args (call into-fn)
  "The synthetic-respond tool's input bag is the structured answer.
If into-fn is non-nil, apply it; otherwise return the bag."
  (let ((args (send call :input)))
    (cond ((null into-fn) args)
          (t (funcall into-fn args)))))

(defun parse-native-structured-result (ai-msg into-fn)
  "Parse the AI message's content as JSON (it should be the
structured answer per the response_format contract) and optionally
apply into-fn."
  (let* ((parser (bag-output-parser :into into-fn))
         (text   (message-text ai-msg)))
    (send parser :parse text)))

;;; ----------------------------------------------------------------------
;;; :stream-impl — for v0.1, fall back to a 1-cap channel of the
;;; final result.  Per-step streaming (text deltas as the model
;;; thinks, tool_use breaks, etc.) lands in v0.2.
;;; ----------------------------------------------------------------------

(defmethod (agent-runnable :stream-impl) (input &rest config)
  (let ((ch (make-channel 1)))
    (channel-push ch (apply 'send self :invoke-impl input config))
    (channel-close ch)
    ch))

;;; ----------------------------------------------------------------------
;;; Constructor
;;; ----------------------------------------------------------------------

(defun create-agent (&key model tools system-prompt
                          (max-iterations 25)
                          parallel-tool-calls
                          (on-tool-error :return-as-message)
                          response-format response-into)
  "Construct an agent runnable.

  :model              chat-model instance (chat-anthropic, chat-openai, …)
  :tools              list of base-tool instances bound to the model
  :system-prompt      optional system-message text prepended to input
  :max-iterations     loop bound, default 25.  Panics on overrun.
  :parallel-tool-calls  serial (default) or parallel via gi:run+channel
  :on-tool-error      :return-as-message (default) or :raise
  :response-format    optional defstruct symbol or schema bag for
                      structured output.  Native on chat-openai/chat-ollama;
                      synthetic-tool-fallback elsewhere.
  :response-into      optional one-arg function (bag) -> instance for
                      coercing structured output into a domain type.

The returned object is a runnable; :invoke / :stream / :batch all
work against it."
  (when (null model)
    (panic "create-agent: :model is required"))
  (make-instance 'agent-runnable
                 :agent-model         model
                 :agent-tools         tools
                 :system-prompt       system-prompt
                 :max-iterations      max-iterations
                 :parallel-tool-calls parallel-tool-calls
                 :on-tool-error       on-tool-error
                 :response-format     response-format
                 :response-into       response-into))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'create-agent)
(export 'synthetic-respond-tool-name)
(export 'build-synthetic-respond-tool)
(export 'is-native-structured-output-provider-p)
(export 'find-tool-by-name)
(export 'dispatch-tool-call)
(export 'dispatch-tool-calls)
(export 'build-initial-messages)
(export 'find-respond-call)
(export 'parse-synthetic-respond-args)
(export 'parse-native-structured-result)
(export 'synthetic-respond-prompt-suffix)
