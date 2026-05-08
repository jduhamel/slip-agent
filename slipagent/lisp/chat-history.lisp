;;;; chat-history.lisp — conversation message history.
;;;;
;;;; Two flavors:
;;;;
;;;;   base-chat-message-history — abstract.  Subclass and override
;;;;     :add-message, :messages, and :clear to plug in a custom
;;;;     storage backend (database, file, KV store, etc.).
;;;;
;;;;   in-memory-chat-message-history — keeps messages in a slot.
;;;;     Mutex-protected so multiple goroutines can append safely.
;;;;
;;;; The agent loop in D12 will use a chat-history-backed runnable
;;;; wrapper for stateful conversations; v0.1 ships only the storage
;;;; layer.

(defflavor base-chat-message-history () ()
  :abstract-flavor
  (:documentation
   "Abstract parent of all conversation history backends.  Concrete
subclasses must implement :add-message, :messages, and :clear; the
default :add-messages calls :add-message in a loop."))

(defmethod (base-chat-message-history :add-message) (msg)
  (declare (ignore msg))
  (panic "base-chat-message-history :add-message must be overridden"))

(defmethod (base-chat-message-history :messages) ()
  (panic "base-chat-message-history :messages must be overridden"))

(defmethod (base-chat-message-history :clear) ()
  (panic "base-chat-message-history :clear must be overridden"))

(defmethod (base-chat-message-history :add-messages) (msgs)
  "Default :add-messages — loops :add-message.  Subclasses with a
batch-friendly backend may override."
  (dolist (m msgs)
    (send self :add-message m)))

;;; ----------------------------------------------------------------------
;;; in-memory-chat-message-history
;;; ----------------------------------------------------------------------

(defflavor in-memory-chat-message-history
    ((messages-list nil) (mutex nil))
    (base-chat-message-history)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "An in-memory message history.  Mutex-protected so concurrent
agent steps can append safely.  The mutex is created lazily on the
first :add-message call to keep make-instance side-effect-free."))

(defun ensure-history-mutex (history)
  "Lazily create the mutex on first use.  Returns the mutex.  Note:
parameter is named 'history' because 'instance' is a bound constant
in Slip and cannot be a parameter name."
  (let ((m (send history :mutex)))
    (cond (m m)
          (t (let ((new (make-mutex)))
               (setf (send history :mutex) new)
               new)))))

(defmethod (in-memory-chat-message-history :add-message) (msg)
  (with-mutex-lock (ensure-history-mutex self)
    (setq messages-list (append messages-list (list msg)))))

(defmethod (in-memory-chat-message-history :add-messages) (msgs)
  ;; Override the default :add-message-loop to take the lock once.
  (with-mutex-lock (ensure-history-mutex self)
    (setq messages-list (append messages-list msgs))))

(defmethod (in-memory-chat-message-history :messages) ()
  (with-mutex-lock (ensure-history-mutex self)
    ;; Return a copy so callers iterating outside the lock don't see
    ;; concurrent appends.
    (append messages-list nil)))

(defmethod (in-memory-chat-message-history :clear) ()
  (with-mutex-lock (ensure-history-mutex self)
    (setq messages-list nil)))

(defun in-memory-chat-message-history (&key messages)
  "Construct an in-memory-chat-message-history, optionally seeded
with an initial messages list."
  (let ((h (make-instance 'in-memory-chat-message-history
                          :messages-list (or messages nil))))
    ;; Enable Slip's per-instance synchronization so the flavor's
    ;; internal Vars map is mutex-protected too — without this,
    ;; concurrent :add-message calls race on the slot's value map
    ;; even though our own mutex protects messages-list.
    (set-synchronized h t)
    h))

(export 'in-memory-chat-message-history)

;; Helpers exported per the call-site-package gotcha.
(export 'ensure-history-mutex)
