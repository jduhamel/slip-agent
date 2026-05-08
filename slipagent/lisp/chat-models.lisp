;;;; chat-models.lisp — chat-model abstract.
;;;;
;;;; Concrete providers (chat-anthropic D8, chat-openai/chat-ollama D9,
;;;; fake-chat-model below) extend chat-model and override :invoke-impl
;;;; and :stream-impl.  The abstract template fires :on-llm-start /
;;;; :on-llm-end / :on-llm-error around the impl call (instead of the
;;;; chain events that runnable's template fires).
;;;;
;;;; Input is a list of messages, a single string (auto-wrapped in a
;;;; human-message), or a prompt-value (D4) — normalize-messages
;;;; handles the dispatch.

(defflavor chat-model
    ((model nil) (temperature nil) (max-tokens nil) (tools nil)
     (api-key nil) (base-url nil) (extra nil))
    (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  :abstract-flavor
  (:documentation
   "Abstract parent of all chat-model providers.  model is the
provider's model name (e.g. claude-opus-4-7); temperature, max-tokens
mirror the API surface; tools is a list of base-tool instances bound
via :bind-tools; api-key and base-url are resolved from environment
or constructor; extra is an alist of provider-specific options
forwarded to the request body."))

;; Override runnable :invoke and :stream to fire :on-llm-* events
;; instead of :on-chain-* events.  Subclasses implement :invoke-impl
;; and :stream-impl as before.

(defmethod (chat-model :invoke) (input &rest config)
  (let ((handlers (getf config :callbacks))
        (messages (normalize-messages input)))
    (fire-event :on-llm-start handlers self (list messages) config)
    (gi:recover err
      (progn
        (fire-event :on-llm-error handlers self (list messages err) config)
        (panic err))
      (let ((result (apply 'send self :invoke-impl messages config)))
        (fire-event :on-llm-end handlers self (list result) config)
        result))))

(defmethod (chat-model :stream) (input &rest config)
  (let ((handlers (getf config :callbacks))
        (messages (normalize-messages input))
        (out (make-channel 16)))
    (fire-event :on-llm-start handlers self (list messages) config)
    (run
      (gi:recover err
        (progn
          (fire-event :on-llm-error handlers self (list messages err) config)
          (channel-close out))
        (let ((in-channel (apply 'send self :stream-impl messages config)))
          (range (lambda (chunk)
                   (channel-push out chunk)
                   ;; Per-chunk token event for streaming UIs / counters.
                   (fire-event :on-llm-new-token handlers self
                               (list chunk) config))
                 in-channel)
          (fire-event :on-llm-end handlers self (list nil) config)
          (channel-close out))))
    out))

;; Default :invoke-impl and :stream-impl panic — concrete providers
;; must override.  :batch-impl loops :invoke-impl (inherited).

(defmethod (chat-model :invoke-impl) (messages &rest config)
  (declare (ignore messages config))
  (panic "chat-model :invoke-impl must be overridden by a concrete provider"))

(defmethod (chat-model :stream-impl) (messages &rest config)
  (declare (ignore messages config))
  (panic "chat-model :stream-impl must be overridden by a concrete provider"))

;;; ----------------------------------------------------------------------
;;; :bind-tools
;;;
;;; Returns a fresh instance of the same flavor with tools set.  The
;;; default :copy method copies just the base chat-model slots;
;;; subclasses with additional slots (e.g. an Anthropic-specific
;;; cache-control flag) override :copy to include them.
;;; ----------------------------------------------------------------------

(defmethod (chat-model :copy) ()
  (make-instance (type-of self)
                 :model       model
                 :temperature temperature
                 :max-tokens  max-tokens
                 :tools       tools
                 :api-key     api-key
                 :base-url    base-url
                 :extra       extra))

(defmethod (chat-model :bind-tools) (new-tools)
  (let ((copy (send self :copy)))
    (setf (send copy :tools) new-tools)
    copy))

;;; ----------------------------------------------------------------------
;;; :with-structured-output
;;;
;;; Default implementation: use the synthetic terminal tool path
;;; (Q8d).  For OpenAI in D9 we'll override to use native
;;; response_format: json_schema.  This day ships only the abstract
;;; signature; the concrete agent-loop integration lands in D12.
;;; ----------------------------------------------------------------------

(defmethod (chat-model :with-structured-output) (schema-name &key into)
  (declare (ignore schema-name into))
  (panic "chat-model :with-structured-output not yet implemented in v0.1 D7 — lands with create-agent in D12"))

;;; ----------------------------------------------------------------------
;;; Helpers
;;; ----------------------------------------------------------------------

(defun normalize-messages (input)
  "Coerce input to a list of messages.  Accepts:
  - a list of message instances (used as-is)
  - a single message instance (wrapped in a 1-element list)
  - a string (wrapped in a single human-message)"
  (cond ((stringp input)
         (list (human-message input)))
        ((or (typep input 'human-message)
             (typep input 'system-message)
             (typep input 'ai-message)
             (typep input 'tool-message)
             (typep input 'function-message))
         (list input))
        ((listp input) input)
        (t (panic (format nil "chat-model input must be a string, message, or list of messages; got ~A"
                          (type-of input))))))

(defun resolve-api-key (model-instance env-var)
  "Return the api-key from the model-instance's slot if set; otherwise
read from env-var.  Panics if neither yields a value."
  (let ((from-slot (send model-instance :api-key)))
    (cond ((and from-slot (> (length from-slot) 0)) from-slot)
          (t (let ((env-val (getenv env-var)))
               (when (or (null env-val) (zerop (length env-val)))
                 (panic (format nil "no API key: pass :api-key or set ~A"
                                env-var)))
               env-val)))))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

;; chat-model itself is abstract — exporting the symbol so subclassers
;; can `(defflavor my-provider ... (chat-model) ...)` without an
;; agent:: prefix is the only reason it's public.  Conservative
;; export per Q11(b) means concrete subclassers reach in via agent::.
;; The abstract base is the documented extension surface, so it gets
;; exported.

(export 'chat-model)
(export 'normalize-messages)
(export 'resolve-api-key)
