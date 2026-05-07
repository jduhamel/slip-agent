;;;; callbacks.lisp — base-callback-handler and the event dispatcher.
;;;;
;;;; Callbacks are how slip-agent surfaces lifecycle events from
;;;; runnables, chat models, tools, and retrievers to user code.  A
;;;; handler is an instance of base-callback-handler (or a subclass) and
;;;; is passed via the :callbacks keyword on :invoke / :stream / :batch.
;;;;
;;;; v0.1 ships 13 events:
;;;;   chain     :on-chain-start :on-chain-end :on-chain-error
;;;;   llm       :on-llm-start   :on-llm-end   :on-llm-error :on-llm-new-token
;;;;   tool      :on-tool-start  :on-tool-end  :on-tool-error
;;;;   retriever :on-retriever-start :on-retriever-end :on-retriever-error
;;;;
;;;; Deferred (v0.2+):
;;;;   :on-text :on-agent-action :on-agent-finish :on-custom-event
;;;;   :on-chat-model-start (currently collapsed into :on-llm-start).

(defvar *callback-error-mode* :swallow
  "Controls what happens when a callback handler panics during an event
dispatch.  :swallow (default) warns via cl:warn and continues with the
next handler — production-friendly.  :propagate re-raises the panic —
useful when debugging a handler.")

(defflavor base-callback-handler () ()
  (:documentation
   "Base flavor for all callback handlers.  Every event method is a
no-op default; subclass and override only the events you care about.

Each event method receives the firing object as the second argument
(after self), then any event-specific data, then a final &rest config
plist that carries :run-id, :tags, :metadata, and any other config
keys the originating call passed."))

;; ---- chain events (runnable, sequence, parallel, branch, agent) -------

(defmethod (base-callback-handler :on-chain-start) (runnable input &rest config)
  (declare (ignore runnable input config))
  nil)

(defmethod (base-callback-handler :on-chain-end) (runnable input output &rest config)
  (declare (ignore runnable input output config))
  nil)

(defmethod (base-callback-handler :on-chain-error) (runnable input condition &rest config)
  (declare (ignore runnable input condition config))
  nil)

;; ---- llm events (chat-model) ------------------------------------------

(defmethod (base-callback-handler :on-llm-start) (model messages &rest config)
  (declare (ignore model messages config))
  nil)

(defmethod (base-callback-handler :on-llm-end) (model response &rest config)
  (declare (ignore model response config))
  nil)

(defmethod (base-callback-handler :on-llm-error) (model messages condition &rest config)
  (declare (ignore model messages condition config))
  nil)

(defmethod (base-callback-handler :on-llm-new-token) (model token &rest config)
  (declare (ignore model token config))
  nil)

;; ---- tool events (base-tool) ------------------------------------------

(defmethod (base-callback-handler :on-tool-start) (tool input &rest config)
  (declare (ignore tool input config))
  nil)

(defmethod (base-callback-handler :on-tool-end) (tool input output &rest config)
  (declare (ignore tool input output config))
  nil)

(defmethod (base-callback-handler :on-tool-error) (tool input condition &rest config)
  (declare (ignore tool input condition config))
  nil)

;; ---- retriever events (vector-store-retriever) ------------------------

(defmethod (base-callback-handler :on-retriever-start) (retriever query &rest config)
  (declare (ignore retriever query config))
  nil)

(defmethod (base-callback-handler :on-retriever-end) (retriever query documents &rest config)
  (declare (ignore retriever query documents config))
  nil)

(defmethod (base-callback-handler :on-retriever-error) (retriever query condition &rest config)
  (declare (ignore retriever query condition config))
  nil)

;;; ----------------------------------------------------------------------
;;; Dispatcher
;;; ----------------------------------------------------------------------

(defun fire-event (event handlers receiver data config)
  "Dispatch event to each handler in handlers (sequentially), passing
receiver, the data list spliced as positional args, and config spliced
as &rest args.  Errors from handlers obey *callback-error-mode*."
  (when handlers
    (let ((args (append (list receiver) data config)))
      (dolist (handler handlers)
        (gi:recover err
          ;; on-recover form: warn or re-raise per mode.
          (cond ((eq *callback-error-mode* :propagate)
                 (panic err))
                (t
                 (warn "callback handler ~A on event ~A: ~A"
                       handler event err)
                 nil))
          ;; body — apply send so we can splice runtime arg lists.
          (apply 'send handler event args))))))

(export 'base-callback-handler)
(export '*callback-error-mode*)
(export 'fire-event)
