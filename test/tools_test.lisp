;;;; tools_test.lisp — base-tool, def-tool macro, registry, tool specs.

;;; A handler that captures tool events.  recording-handler in
;;; callbacks_test only listens for :on-chain-*; tools fire :on-tool-*
;;; instead, so a separate recorder is needed.
(defflavor recording-handler-tool ((events nil)) (base-callback-handler)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables)

(defmethod (recording-handler-tool :on-tool-start) (tool input &rest config)
  (declare (ignore tool config))
  (push (cons :on-tool-start input) events))

(defmethod (recording-handler-tool :on-tool-end) (tool input output &rest config)
  (declare (ignore tool config))
  (push (cons :on-tool-end (list input output)) events))

(defmethod (recording-handler-tool :on-tool-error) (tool input condition &rest config)
  (declare (ignore tool config))
  (push (cons :on-tool-error (list input condition)) events))

(let ((suite (defsuite "tools" agent-suite)))

  ;; ---- def-tool basic shape ---------------------------------------------

  (clear-tools)

  (def-tool calc-add (a b)
    "Adds two integers."
    (+ a b))

  (def-tool greet (name)
    "Greets a person by name."
    (concatenate 'string "Hello, " name "!"))

  (def-tool no-args ()
    "A nullary tool."
    42)

  (deftest "def-tool defines a callable function" suite
    (assert-equal 5 (calc-add 2 3))
    (assert-equal "Hello, Joe!" (greet "Joe"))
    (assert-equal 42 (no-args)))

  (deftest "def-tool binds the symbol to the tool instance" suite
    ;; The symbol calc-add is both a function (via defun) and a value
    ;; (via defparameter to the tool instance) — Slip Lisp-2.
    (assert-equal "calc-add" (send calc-add :tool-name))
    (assert-equal "Adds two integers." (send calc-add :description)))

  (deftest "def-tool stores arg-names" suite
    (assert-equal '(a b) (send calc-add :arg-names))
    (assert-equal '(name) (send greet :arg-names))
    ;; assert-nil checks for Go-nil; an empty list is not Go-nil in
    ;; Slip even though both print as "nil".  Use length-0 instead.
    (assert-equal 0 (length (send no-args :arg-names))))

  (deftest "def-tool registers in *tools*" suite
    (assert-equal calc-add (get-tool "calc-add"))
    (assert-equal greet    (get-tool "greet")))

  (deftest "list-tools returns all registered tools" suite
    ;; Four tools are defined at load time inside this suite block:
    ;; calc-add, greet, no-args, and calc-typed (further down).  Tests
    ;; that define tools inside their own deftest body (e.g.
    ;; throws-up) only register at run time, so the count here may
    ;; vary with test execution order.  We assert >= 4 for stability.
    (let ((tools (list-tools)))
      (assert-equal t (>= (length tools) 4))))

  (deftest "get-tool returns nil for unregistered names" suite
    (assert-nil (get-tool "no-such-tool")))

  ;; ---- :invoke with bag input -------------------------------------------

  (deftest "tool :invoke binds bag args by name" suite
    (let* ((input (make-bag "{a: 7, b: 5}"))
           (out   (send calc-add :invoke input)))
      (assert-equal 12 out)))

  (deftest "tool :invoke parses JSON string input" suite
    (let ((out (send calc-add :invoke "{\"a\": 11, \"b\": 4}")))
      (assert-equal 15 out)))

  (deftest "tool :invoke accepts alist input with keyword keys" suite
    (let ((out (send calc-add :invoke (list (cons :a 6) (cons :b 9)))))
      (assert-equal 15 out)))

  (deftest "tool :invoke accepts alist input with string keys" suite
    (let ((out (send calc-add :invoke (list (cons "a" 1) (cons "b" 2)))))
      (assert-equal 3 out)))

  (deftest "tool :invoke with nil input works for nullary tools" suite
    (assert-equal 42 (send no-args :invoke nil)))

  (deftest "tool :invoke with empty bag works for nullary tools" suite
    (assert-equal 42 (send no-args :invoke (make-bag "{}"))))

  ;; ---- callback events --------------------------------------------------

  (deftest "tool :invoke fires :on-tool-start and :on-tool-end" suite
    (let* ((h (make-instance 'recording-handler-tool))
           (out (send calc-add :invoke (make-bag "{a: 1, b: 2}")
                      :callbacks (list h))))
      (assert-equal 3 out)
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-tool-start (car (car events)))
        (assert-equal :on-tool-end   (car (cadr events))))))

  (deftest "tool :invoke fires :on-tool-error on panic" suite
    (def-tool throws-up (x)
      "Panics regardless."
      (declare (ignore x))
      (panic "tool died"))
    (let ((h (make-instance 'recording-handler-tool)))
      (assert-panic (send throws-up :invoke (make-bag "{x: 1}")
                          :callbacks (list h)))
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-tool-start (car (car events)))
        (assert-equal :on-tool-error (car (cadr events))))))

  (deftest "tool :invoke does NOT fire :on-chain-* events" suite
    ;; Tools have their own event category — chain events would be a
    ;; redundant signal in tracing UIs.
    (let* ((h (make-instance 'recording-handler))
           (out (send calc-add :invoke (make-bag "{a: 0, b: 0}")
                      :callbacks (list h))))
      (assert-equal 0 out)
      ;; recording-handler captures :on-chain-*; we should see none.
      (assert-nil (send h :events))))

  ;; ---- :schema option ---------------------------------------------------

  (defstruct calc-args (a 0 :type integer) (b 0 :type integer))

  (def-tool calc-typed (a b)
    "Adds two integers (typed schema)."
    :schema 'calc-args
    (+ a b))

  (deftest "def-tool stores :schema symbol on the tool" suite
    (assert-equal 'calc-args (send calc-typed :args-schema)))

  (deftest "def-tool with :schema still works at invoke time" suite
    ;; v0.1: :schema is recorded but coercion is not applied; bag
    ;; values pass through directly.
    (assert-equal 5 (send calc-typed :invoke (make-bag "{a:2, b:3}"))))

  ;; ---- tool-spec serialisers --------------------------------------------

  (deftest "tool->openai-spec produces the OpenAI tool shape" suite
    (let ((spec (tool->openai-spec calc-add)))
      (assert-equal "function" (send spec :get "type"))
      (let ((fn (send spec :get "function")))
        ;; Nested values come back as alists (Slip bag normalisation).
        (assert-equal "calc-add"
                      (cdr (assoc "name" fn :test #'equal)))
        (assert-equal "Adds two integers."
                      (cdr (assoc "description" fn :test #'equal))))))

  (deftest "tool->anthropic-spec produces the Anthropic tool shape" suite
    (let ((spec (tool->anthropic-spec calc-add)))
      (assert-equal "calc-add" (send spec :get "name"))
      (assert-equal "Adds two integers." (send spec :get "description"))
      ;; input_schema is present.
      (let ((schema (send spec :get "input_schema")))
        (assert-equal "object"
                      (cdr (assoc "type" schema :test #'equal))))))

  (deftest "default schema declares each arg with required positions" suite
    (let* ((spec   (tool->openai-spec calc-add))
           (fn     (send spec :get "function"))
           (params (cdr (assoc "parameters" fn :test #'equal)))
           (req    (cdr (assoc "required" params :test #'equal))))
      (assert-equal 2 (length req))
      ;; Order matches arg-names order.
      (assert-equal "a" (car req))
      (assert-equal "b" (cadr req)))))
