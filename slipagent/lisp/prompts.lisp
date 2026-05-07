;;;; prompts.lisp — prompt-template, chat-prompt-template, messages-placeholder.
;;;;
;;;; Prompts are runnables.  prompt-template's :invoke produces a
;;;; string; chat-prompt-template's :invoke produces a list of
;;;; messages.  Chat models (D7+) accept either form, so the two
;;;; templates compose interchangeably with the rest of the runnable
;;;; protocol.
;;;;
;;;; Substitution syntax: {name} in the template is looked up via
;;;; assoc on a keyword key in the input alist.  Missing keys panic —
;;;; silent empty substitutions are a footgun.  Literal { is not
;;;; supported in v0.1; users who need it can use a non-templated
;;;; prompt or upstream concatenation.

;;; ----------------------------------------------------------------------
;;; Substitution
;;; ----------------------------------------------------------------------

;; Slip's reader does not accept #\{ as a character literal — { is a
;; reader-special syntax.  We pull the chars from one-character string
;; literals each time; the cost is negligible and inlining sidesteps
;; the cross-package symbol resolution that bit defvars in D1.

(defun substitute-vars (template input)
  "Replace {name} in template with the value of :name in input (an
alist with keyword keys).  Panics if a referenced key is absent."
  (with-output-to-string (out)
    (substitute-vars-inner template input 0 out)))

(defun substitute-vars-inner (template input pos out)
  ;; Use format with ~A rather than princ — princ of an empty string
  ;; emits the literal "" in Slip, which contaminates the result with
  ;; spurious double-quotes around the substituted variables.
  (let ((open (position (char "{" 0) template :start pos)))
    (cond ((null open)
           (format out "~A" (subseq template pos)))
          (t
           (format out "~A" (subseq template pos open))
           (let ((close (position (char "}" 0) template :start (1+ open))))
             (when (null close)
               (panic (format nil "substitute-vars: unmatched { at position ~A" open)))
             (let* ((name  (subseq template (1+ open) close))
                    (key   (intern name "keyword"))
                    (entry (assoc key input)))
               (when (null entry)
                 (panic (format nil "substitute-vars: no value for {~A} in input" name)))
               (format out "~A" (cdr entry)))
             (substitute-vars-inner template input (1+ close) out))))))

;;; ----------------------------------------------------------------------
;;; prompt-template — single-string template
;;; ----------------------------------------------------------------------

(defflavor prompt-template (template) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Single-string prompt template.  template is a string with {name}
placeholders.  :invoke returns the formatted string; :format is the
same operation without firing chain events (for use inside a larger
runnable's body)."))

(defmethod (prompt-template :invoke-impl) (input &rest config)
  (declare (ignore config))
  (substitute-vars template input))

(defmethod (prompt-template :format) (input)
  (substitute-vars template input))

(defun prompt-template (template)
  "Construct a prompt-template."
  (make-instance 'prompt-template :template template))

(defun prompt-template-from-template (template)
  "Constructor matching LangChain's PromptTemplate.from_template name."
  (prompt-template template))

;;; ----------------------------------------------------------------------
;;; messages-placeholder — splice point inside chat templates
;;; ----------------------------------------------------------------------

(defun messages-placeholder (key)
  "Return a placeholder marker for a chat-prompt-template entry list.
At :invoke time the value of key in the input alist is spliced into
the messages list.  The value must be a list of messages.

Equivalent to writing (:placeholder key) directly in the template
literal — provided as a function for API symmetry."
  (list :placeholder key))

;;; ----------------------------------------------------------------------
;;; chat-prompt-template — list of role-keyed message templates
;;; ----------------------------------------------------------------------

(defflavor chat-prompt-template (message-templates) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "List-of-messages prompt template.  message-templates is a list of
two-element lists, each either:

  (:system|:human|:user|:assistant|:ai \"template with {vars}\")
  (:placeholder :key)

:invoke returns a list of message instances; :format-messages is the
same operation without firing chain events."))

(defun format-message-template-entry (entry input)
  "Process one entry; returns a list of messages."
  (let ((role (car entry)))
    (cond
      ((eq role :placeholder)
       (let* ((key      (cadr entry))
              (alist-rec (assoc key input)))
         (when (null alist-rec)
           (panic (format nil "messages-placeholder: no value for ~A in input" key)))
         (let ((msgs (cdr alist-rec)))
           (when (not (listp msgs))
             (panic (format nil "messages-placeholder: value for ~A must be a list of messages" key)))
           msgs)))
      (t
       (let ((text (substitute-vars (cadr entry) input)))
         (cond ((eq role :system)    (list (system-message text)))
               ((or (eq role :human)
                    (eq role :user))      (list (human-message text)))
               ((or (eq role :assistant)
                    (eq role :ai))        (list (ai-message :content text)))
               (t (panic (format nil "chat-prompt-template: unknown role ~A" role)))))))))

(defun format-message-templates (templates input)
  "Walk a list of message templates, returning the flattened messages."
  (let ((result nil))
    (dolist (entry templates)
      (dolist (msg (format-message-template-entry entry input))
        (push msg result)))
    (nreverse result)))

(defmethod (chat-prompt-template :invoke-impl) (input &rest config)
  (declare (ignore config))
  (format-message-templates message-templates input))

(defmethod (chat-prompt-template :format-messages) (input)
  (format-message-templates message-templates input))

(defun chat-prompt-template-from-messages (message-templates)
  "Construct a chat-prompt-template.  message-templates is a list of
(role-keyword template-string) or (:placeholder key) entries."
  (make-instance 'chat-prompt-template :message-templates message-templates))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'prompt-template)
(export 'prompt-template-from-template)
(export 'chat-prompt-template-from-messages)
(export 'messages-placeholder)

;; Helpers exported because Slip resolves intra-defun function
;; references at call-site package — see messages.lisp comment for the
;; same pattern.
(export 'substitute-vars)
(export 'substitute-vars-inner)
(export 'format-message-template-entry)
(export 'format-message-templates)
