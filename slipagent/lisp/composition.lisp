;;;; composition.lisp — runnable composition (pipe, parallel, branch).
;;;;
;;;; Three composition patterns lift a set of runnables into a single
;;;; runnable.  All three are themselves runnables, so they fire chain
;;;; events and inherit batch / streaming semantics from the runnable
;;;; template.
;;;;
;;;;   pipe r1 r2 r3       — r1 -> r2 -> r3, threaded sequentially
;;;;   parallel alist      — each value runs on the same input;
;;;;                         result is an alist with same keys
;;;;   branch cases default — first matching predicate selects a runnable
;;;;
;;;; passthrough is the identity runnable, used inside parallel to
;;;; carry the input through to the next step alongside transformed
;;;; values (e.g. RAG context fan-out).

;;; ----------------------------------------------------------------------
;;; passthrough
;;; ----------------------------------------------------------------------

(defflavor passthrough () (runnable)
  (:documentation "Identity runnable: :invoke returns input unchanged."))

(defmethod (passthrough :invoke-impl) (input &rest config)
  (declare (ignore config))
  input)

(defun passthrough ()
  "Construct a passthrough runnable."
  (make-instance 'passthrough))

;;; ----------------------------------------------------------------------
;;; runnable-sequence — sequential composition (the | pipe)
;;; ----------------------------------------------------------------------

(defflavor runnable-sequence (steps) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Sequential composition.  steps is a list of runnables; :invoke
threads the input forward step-by-step, returning the last step's
output."))

(defmethod (runnable-sequence :invoke-impl) (input &rest config)
  (when (null steps)
    (panic "runnable-sequence: cannot invoke an empty sequence"))
  (let ((current input))
    (dolist (step steps)
      (setq current (apply 'send step :invoke current config)))
    current))

(defmethod (runnable-sequence :stream-impl) (input &rest config)
  "Invoke each step except the last fully, then stream the last."
  (when (null steps)
    (panic "runnable-sequence: cannot stream an empty sequence"))
  (let ((current input)
        (last-step nil)
        (others nil))
    ;; Split into all-but-last and last.
    (let ((rev (reverse steps)))
      (setq last-step (car rev))
      (setq others (nreverse (cdr rev))))
    (dolist (step others)
      (setq current (apply 'send step :invoke current config)))
    (apply 'send last-step :stream current config)))

(defun pipe (&rest runnables)
  "Compose runnables sequentially: (pipe r1 r2 r3) returns a runnable
that calls r1, threads the result into r2, then into r3."
  (make-instance 'runnable-sequence :steps runnables))

;;; ----------------------------------------------------------------------
;;; runnable-parallel — concurrent fan-out
;;; ----------------------------------------------------------------------

(defflavor runnable-parallel (alist) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Concurrent fan-out.  alist maps keys to runnables; each runnable
gets the same input on its own goroutine; :invoke returns an alist
with the same keys mapped to each runnable's output, in alist order."))

(defmethod (runnable-parallel :invoke-impl) (input &rest config)
  ;; Spawn one goroutine per child; collect via a 1-cap channel each.
  ;; Each entry on the channel is (:ok value) or (:error condition).
  (let ((entries nil))
    (dolist (pair alist)
      (let* ((key (car pair))
             (r   (cdr pair))
             (ch  (make-channel 1)))
        (push (cons key ch) entries)
        ;; Capture pair-local r and ch by closing over them in the run form.
        (let ((r-cap r) (ch-cap ch))
          (run
            (gi:recover err
              (channel-push ch-cap (list :error err))
              (channel-push ch-cap
                            (list :ok (apply 'send r-cap :invoke input config))))))))
    ;; Collect results in original alist order.
    (let ((results nil))
      (dolist (entry (nreverse entries))
        (let* ((key    (car entry))
               (ch     (cdr entry))
               (result (channel-pop ch)))
          (cond ((eq (car result) :error)
                 (panic (cadr result)))
                (t
                 (push (cons key (cadr result)) results)))))
      (nreverse results))))

(defun parallel (alist)
  "Construct a runnable-parallel.  alist maps keys to runnables.  Each
runnable receives the same input on its own goroutine; the result is
an alist with the same keys mapped to each runnable's output."
  (make-instance 'runnable-parallel :alist alist))

;;; ----------------------------------------------------------------------
;;; runnable-branch — predicate-driven selection
;;; ----------------------------------------------------------------------

(defflavor runnable-branch (cases default-runnable) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Predicate-driven runnable selection.  cases is a list of
(predicate runnable) pairs; predicates are called with the input and
the first one that returns non-nil selects the runnable to invoke.
default-runnable runs if no predicate matches; if it is nil and no
predicate matches, :invoke panics."))

(defun select-branch (cases default input)
  "Walk cases looking for a matching predicate; return the chosen
runnable or default if none match.  Panics if both fail."
  (let ((chosen nil))
    (dolist (case cases)
      (when (and (null chosen) (funcall (car case) input))
        (setq chosen (cadr case))))
    (when (null chosen)
      (setq chosen default))
    (when (null chosen)
      (panic "runnable-branch: no predicate matched and no default"))
    chosen))

(defmethod (runnable-branch :invoke-impl) (input &rest config)
  (apply 'send (select-branch cases default-runnable input)
         :invoke input config))

(defmethod (runnable-branch :stream-impl) (input &rest config)
  (apply 'send (select-branch cases default-runnable input)
         :stream input config))

(defun branch (cases &optional default)
  "Construct a runnable-branch.  cases is a list of (predicate runnable)
pairs."
  (make-instance 'runnable-branch :cases cases :default-runnable default))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'passthrough)
(export 'pipe)
(export 'parallel)
(export 'branch)

;; Exported because Slip resolves intra-defun function references at
;; call-site package — see messages.lisp comment for the same pattern.
(export 'select-branch)
