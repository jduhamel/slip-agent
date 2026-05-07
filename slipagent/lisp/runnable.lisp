;;;; runnable.lisp — the runnable protocol and runnable-lambda.
;;;;
;;;; Every slip-agent abstraction that takes input and produces output
;;;; (chat models, prompts, tools, parsers, agents, retrievers) is a
;;;; runnable.  The protocol is three methods — :invoke, :stream,
;;;; :batch — each implemented as a concrete template on this base
;;;; flavor that fires :on-chain-start / -end / -error around a call to
;;;; a subclass-provided :invoke-impl / :stream-impl / :batch-impl.
;;;;
;;;; Subclasses override the -impl methods only.  They get callback
;;;; firing and config-plist plumbing for free.
;;;;
;;;; Composition (pipe, parallel, branch) lands in D3.

(defflavor runnable () ()
  :abstract-flavor
  (:documentation
   "Abstract parent of every callable abstraction in slip-agent.  Three
public methods: :invoke (one input, one output), :stream (channel of
chunks), :batch (list of inputs to list of outputs).  Subclasses
override :invoke-impl etc., not the public methods."))

;;; ----------------------------------------------------------------------
;;; Public template methods — fire events, dispatch to subclass -impl.
;;; ----------------------------------------------------------------------

(defmethod (runnable :invoke) (input &rest config)
  "Invoke the runnable on input and return a single output.  config is
a plist; :callbacks is the canonical key but unknown keys are forwarded
to :invoke-impl unchanged."
  (let ((handlers (getf config :callbacks)))
    (fire-event :on-chain-start handlers self (list input) config)
    (gi:recover err
      (progn
        (fire-event :on-chain-error handlers self (list input err) config)
        (panic err))
      (let ((result (apply 'send self :invoke-impl input config)))
        (fire-event :on-chain-end handlers self (list input result) config)
        result))))

(defmethod (runnable :batch) (inputs &rest config)
  "Invoke the runnable on each element of inputs and return a list of
outputs.  Default :batch-impl loops :invoke-impl; subclasses that have
a real batch endpoint should override :batch-impl."
  (let ((handlers (getf config :callbacks)))
    (fire-event :on-chain-start handlers self (list inputs) config)
    (gi:recover err
      (progn
        (fire-event :on-chain-error handlers self (list inputs err) config)
        (panic err))
      (let ((result (apply 'send self :batch-impl inputs config)))
        (fire-event :on-chain-end handlers self (list inputs result) config)
        result))))

(defmethod (runnable :stream) (input &rest config)
  "Stream chunks of output for input on a gi:channel.  Returns the
channel immediately; chunks arrive on a producer goroutine.  Channel
close means stream complete.

The default :stream-impl synthesises a single chunk from :invoke-impl;
streaming providers override :stream-impl to push real deltas."
  (let ((handlers (getf config :callbacks))
        (out (make-channel 16)))
    (fire-event :on-chain-start handlers self (list input) config)
    (run
      (gi:recover err
        (progn
          (fire-event :on-chain-error handlers self (list input err) config)
          (channel-close out))
        (let ((in-channel (apply 'send self :stream-impl input config)))
          (range (lambda (chunk) (channel-push out chunk)) in-channel)
          (fire-event :on-chain-end handlers self (list input nil) config)
          (channel-close out))))
    out))

;;; ----------------------------------------------------------------------
;;; Default -impl methods.
;;;
;;; The default :invoke-impl panics — every concrete subclass must
;;; override it.  The default :batch-impl serially loops :invoke-impl.
;;; The default :stream-impl wraps the :invoke-impl result in a 1-cap
;;; channel — fine for non-streaming runnables (parsers, prompts, tools).
;;; ----------------------------------------------------------------------

(defmethod (runnable :invoke-impl) (input &rest config)
  (declare (ignore input config))
  (panic "runnable :invoke-impl must be overridden by a concrete subclass"))

(defmethod (runnable :batch-impl) (inputs &rest config)
  (let ((results nil))
    (dolist (input inputs)
      (push (apply 'send self :invoke-impl input config) results))
    (nreverse results)))

(defmethod (runnable :stream-impl) (input &rest config)
  (let ((ch (make-channel 1)))
    (channel-push ch (apply 'send self :invoke-impl input config))
    (channel-close ch)
    ch))

;;; ----------------------------------------------------------------------
;;; runnable-lambda — lift any one-arg Lisp function into a runnable.
;;; ----------------------------------------------------------------------

(defflavor runnable-lambda (func) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Wraps a one-argument Lisp function as a runnable.  func is called
with the input on :invoke; config is dropped.  Use this to splice raw
transforms into a pipe (e.g. between an LLM and a parser)."))

(defmethod (runnable-lambda :invoke-impl) (input &rest config)
  (declare (ignore config))
  (funcall func input))

(defun runnable-lambda (func)
  "Construct a runnable-lambda wrapping func."
  (make-instance 'runnable-lambda :func func))

;;; ----------------------------------------------------------------------
;;; Exports — only the public surface; -impl methods are subclasser API.
;;; ----------------------------------------------------------------------

(export 'runnable-lambda)
