;;;; tools.lisp — base-tool flavor, def-tool macro, registry, and
;;;; provider tool-spec serialisers.
;;;;
;;;; Tools are runnables — invoking a tool fires :on-tool-start /
;;;; :on-tool-end / :on-tool-error rather than :on-chain-* events
;;;; (the runnable :invoke template is overridden on base-tool to
;;;; switch the event names).
;;;;
;;;; Tool input is either a bag (already-parsed JSON), a string
;;;; (JSON to parse), or an alist (built by Lisp callers).  Args are
;;;; bound to the lambda-list by name: (def-tool calc (a b) ...) with
;;;; bag {a:1, b:2} produces (calc 1 2) at the underlying defun.

;;; ----------------------------------------------------------------------
;;; Tool registry
;;; ----------------------------------------------------------------------

(defparameter *tools* (make-hash-table :test #'equal)
  "Global registry of tools registered via def-tool, keyed by tool
name (a string).  Powers REPL discoverability via list-tools and the
agent loop's tool dispatch (D12 looks tools up by name).")

(defun register-tool (name description args-schema arg-names func)
  "Build a base-tool instance and register it in *tools*.  Returns
the instance.  Re-registering a name replaces the prior tool — useful
during interactive development."
  (let ((tool (make-instance 'base-tool
                             :tool-name   name
                             :description (or description "")
                             :args-schema args-schema
                             :arg-names   arg-names
                             :func        func)))
    (setf (gethash name *tools*) tool)
    tool))

(defun get-tool (name)
  "Look up a tool by name in *tools*; nil if not registered."
  (gethash name *tools*))

(defun list-tools ()
  "Return a list of all registered tools."
  (let ((result nil))
    (maphash (lambda (k v) (declare (ignore k)) (push v result)) *tools*)
    result))

(defun clear-tools ()
  "Remove all registered tools.  Useful in tests; agents do not call this."
  (clrhash *tools*))

;;; ----------------------------------------------------------------------
;;; base-tool flavor
;;;
;;; Slot name uses tool-name not name because base-message etc. already
;;; have a :name slot under different semantics; using a distinct name
;;; avoids accidental cross-flavor confusion when both can appear in
;;; the same alist (e.g. function-message has :name and tool also has
;;; a name).
;;; ----------------------------------------------------------------------

(defflavor base-tool (tool-name description args-schema arg-names func) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A function exposed to a chat model as a callable tool.  tool-name
is the string the model uses; description is shown to the model;
args-schema is an optional struct symbol or a bag containing a full
JSON schema; arg-names is the list of symbols from the lambda-list
used to bind bag values to positional args; func is the underlying
Lisp function."))

;; Override runnable :invoke to fire :on-tool-* events instead of
;; :on-chain-* events.  Tools are runnables but get their own event
;; category — chains, tools, and llm calls are visually distinct in
;; tracing UIs.
(defmethod (base-tool :invoke) (input &rest config)
  (let ((handlers (getf config :callbacks)))
    (fire-event :on-tool-start handlers self (list input) config)
    (gi:recover err
      (progn
        (fire-event :on-tool-error handlers self (list input err) config)
        (panic err))
      (let ((result (apply 'send self :invoke-impl input config)))
        (fire-event :on-tool-end handlers self (list input result) config)
        result))))

(defmethod (base-tool :invoke-impl) (input &rest config)
  (declare (ignore config))
  (let* ((bag  (normalize-tool-input input))
         (args (extract-tool-args arg-names bag)))
    (apply func args)))

(defun normalize-tool-input (input)
  "Coerce input to a bag.  Accepts: a bag, a JSON string, an alist
with keyword or string keys, or nil (empty bag)."
  (cond ((null input) (make-bag "{}"))
        ((stringp input) (make-bag input))
        ((typep input 'bag-flavor) input)
        ((listp input)
         (let ((bag (make-bag "{}")))
           (dolist (entry input)
             (let ((key (car entry))
                   (val (cdr entry)))
               (bag-set bag val
                        (cond ((stringp key) key)
                              ((symbolp key) (string-downcase (symbol-name key)))
                              (t (format nil "~A" key))))))
           bag))
        (t (panic (format nil "tool input must be a string, bag, or alist; got ~A"
                          (type-of input))))))

(defun extract-tool-args (arg-names bag)
  "Pull values from bag in arg-names order.  Each name is downcased
to match the JSON key convention.  v0.1 does not coerce types — the
bag values are passed through as the LLM provided them."
  (let ((result nil))
    (dolist (arg-name arg-names)
      (let ((key (string-downcase (symbol-name arg-name))))
        (push (send bag :get key) result)))
    (nreverse result)))

;;; ----------------------------------------------------------------------
;;; def-tool macro
;;; ----------------------------------------------------------------------

(defmacro def-tool (name lambda-list &rest body)
  "Define a tool: a Lisp function plus a base-tool instance bound to
the same symbol.  Shape:

  (def-tool name (a b c) \"docstring\" [:schema 'struct-name] forms...)

The docstring becomes the tool's description (shown to the model).
Without :schema, args are passed through from the bag as-is.  With
:schema, a struct symbol is recorded for D6+ schema → JSON Schema
conversion (v0.1 emits a minimal schema regardless; users wanting
full control can pass an args-schema bag directly to make-instance).

The same symbol is bound to (a) the underlying defun (callable as
(name args...)) and (b) the tool instance via defparameter (suitable
for (send tool :invoke ...) or (create-agent :tools (list tool ...))).
This works because Slip is a Lisp-2 — function and value cells are
distinct."
  (let* ((docstring (when (and body (stringp (car body))) (car body)))
         (rest      (if docstring (cdr body) body))
         (schema    nil)
         (forms     rest))
    (when (and (consp rest) (eq (car rest) :schema))
      (setq schema (cadr rest))
      (setq forms  (cddr rest)))
    ;; Note: schema is substituted as-is (just ,schema), NOT
    ;; (quote ,schema).  The user has already written the quote
    ;; ('sym, (quote sym), or nil) so the value evaluates correctly at
    ;; runtime.  lambda-list is bare symbols, so it does need (quote ,..).
    ;;
    ;; Slip's reader does not accept ',foo inside backquote (',foo
    ;; produces an unreadable marker), so the quote around lambda-list
    ;; is written as a full (quote ,..) form.
    `(progn
       (defun ,name ,lambda-list
         ,@(when docstring (list docstring))
         ,@forms)
       (defparameter ,name
         (register-tool ,(symbol-name name)
                        ,docstring
                        ,schema
                        (quote ,lambda-list)
                        (function ,name)))
       ,name)))

;;; ----------------------------------------------------------------------
;;; Provider tool-spec serialisers
;;;
;;; Both serialisers emit a minimal JSON Schema in v0.1: every arg is
;;; declared as a string parameter.  Real type inference from a
;;; defstruct schema is deferred — users who need precise schemas can
;;; build a bag manually and pass it as :args-schema.  This keeps D6
;;; finishable without depending on defstruct introspection (which
;;; would require Go-level work to surface from Slip).
;;; ----------------------------------------------------------------------

(defun build-default-schema-bag (arg-names)
  "Build a JSON Schema bag with every arg declared as a string."
  (let ((schema (make-bag "{type: object}"))
        (props  (make-bag "{}"))
        (required nil))
    (dolist (arg-name arg-names)
      (let* ((key  (string-downcase (symbol-name arg-name)))
             (slot (make-bag "{type: string}")))
        (bag-set props slot key)
        (push key required)))
    (bag-set schema props "properties")
    (bag-set schema (nreverse required) "required")
    schema))

(defun tool-schema-bag (tool)
  "Return the JSON Schema bag for tool's args.  If args-schema is a
bag use it directly; otherwise generate a minimal default."
  (let ((schema (send tool :args-schema)))
    (cond ((null schema)
           (build-default-schema-bag (send tool :arg-names)))
          ((typep schema 'bag-flavor) schema)
          (t (build-default-schema-bag (send tool :arg-names))))))

(defun tool->openai-spec (tool)
  "Serialise tool into the OpenAI function-call tool-spec shape:
{type: function, function: {name, description, parameters: <schema>}}."
  (let ((spec (make-bag "{}"))
        (fn   (make-bag "{}")))
    (bag-set spec "function" "type")
    (bag-set fn   (send tool :tool-name)   "name")
    (bag-set fn   (send tool :description) "description")
    (bag-set fn   (tool-schema-bag tool)   "parameters")
    (bag-set spec fn "function")
    spec))

(defun tool->anthropic-spec (tool)
  "Serialise tool into Anthropic's tool-use shape:
{name, description, input_schema: <schema>}."
  (let ((spec (make-bag "{}")))
    (bag-set spec (send tool :tool-name)   "name")
    (bag-set spec (send tool :description) "description")
    (bag-set spec (tool-schema-bag tool)   "input_schema")
    spec))

;;; ----------------------------------------------------------------------
;;; Exports — public surface only
;;; ----------------------------------------------------------------------

(export 'def-tool)
(export 'get-tool)
(export 'list-tools)
(export 'clear-tools)
(export '*tools*)
(export 'tool->openai-spec)
(export 'tool->anthropic-spec)

;; Helpers exported because Slip resolves intra-defun function
;; references at call-site package — see messages.lisp comment.
(export 'register-tool)
(export 'normalize-tool-input)
(export 'extract-tool-args)
(export 'build-default-schema-bag)
(export 'tool-schema-bag)
