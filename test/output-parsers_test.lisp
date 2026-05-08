;;;; output-parsers_test.lisp — string, JSON, and bag-with-coercion parsers.

(let ((suite (defsuite "output-parsers" agent-suite)))

  ;; ---- string-output-parser ---------------------------------------------

  (deftest "string-output-parser passes through a raw string" suite
    (let ((p (string-output-parser)))
      (assert-equal "hello" (send p :invoke "hello"))))

  (deftest "string-output-parser extracts content from an ai-message" suite
    (let* ((p (string-output-parser))
           (m (ai-message :content "the answer is 42")))
      (assert-equal "the answer is 42" (send p :invoke m))))

  (deftest "string-output-parser collapses content blocks via message-text" suite
    (let* ((p (string-output-parser))
           (m (ai-message :content (list (text-block "hello, ")
                                         (text-block "world")))))
      (assert-equal "hello, world" (send p :invoke m))))

  (deftest "string-output-parser ignores reasoning blocks (Level A)" suite
    ;; reasoning-blocks are part of the message but message-text drops
    ;; them — the visible response is the text-blocks only.
    (let* ((p (string-output-parser))
           (m (ai-message :content (list (reasoning-block :text "hidden")
                                         (text-block "visible")))))
      (assert-equal "visible" (send p :invoke m))))

  (deftest "string-output-parser :parse method works directly" suite
    (let ((p (string-output-parser)))
      (assert-equal "raw" (send p :parse "raw"))))

  ;; ---- json-output-parser -----------------------------------------------

  (deftest "json-output-parser parses raw JSON to a bag" suite
    (let* ((p (json-output-parser))
           (b (send p :invoke "{\"a\": 1, \"b\": 2}")))
      (assert-equal 1 (send b :get "a"))
      (assert-equal 2 (send b :get "b"))))

  (deftest "json-output-parser extracts JSON from an ai-message" suite
    (let* ((p (json-output-parser))
           (m (ai-message :content "{\"answer\": 42}"))
           (b (send p :invoke m)))
      (assert-equal 42 (send b :get "answer"))))

  (deftest "json-output-parser strips ```json markdown fences" suite
    (let* ((p (json-output-parser))
           (text (concatenate 'string
                              "```json" (string #\newline)
                              "{\"x\": 7}" (string #\newline)
                              "```"))
           (b (send p :invoke text)))
      (assert-equal 7 (send b :get "x"))))

  (deftest "json-output-parser strips bare ``` fences" suite
    (let* ((p (json-output-parser))
           (text (concatenate 'string
                              "```" (string #\newline)
                              "{\"x\": 9}" (string #\newline)
                              "```"))
           (b (send p :invoke text)))
      (assert-equal 9 (send b :get "x"))))

  (deftest "json-output-parser panics on malformed JSON" suite
    (let ((p (json-output-parser)))
      (assert-panic (send p :invoke "{not json}"))))

  ;; ---- bag-output-parser ------------------------------------------------

  (deftest "bag-output-parser without :into returns a bag" suite
    (let* ((p (bag-output-parser))
           (b (send p :invoke "{\"k\": \"v\"}")))
      (assert-equal "v" (send b :get "k"))))

  (deftest "bag-output-parser :into is applied to the parsed bag" suite
    (let* ((p (bag-output-parser
               :into (lambda (bag)
                       (cons (send bag :get "name")
                             (send bag :get "score")))))
           (result (send p :invoke "{\"name\": \"Joe\", \"score\": 95}")))
      (assert-equal "Joe" (car result))
      (assert-equal 95   (cdr result))))

  (deftest "bag-output-parser :into can construct an ai-message" suite
    ;; A small reproduction of the shape D12 will use for response-format:
    ;; the into-fn pulls fields out of the bag and constructs a domain
    ;; object.  Here we use ai-message as a stand-in.
    (let* ((p (bag-output-parser
               :into (lambda (b) (ai-message :content (send b :get "answer")))))
           (m (send p :invoke "{\"answer\": \"forty-two\"}")))
      (assert-equal "forty-two" (message-text m))))

  (deftest "bag-output-parser strips fences before coercing" suite
    (let* ((p (bag-output-parser
               :into (lambda (b) (send b :get "v"))))
           (text (concatenate 'string
                              "```json" (string #\newline)
                              "{\"v\": 11}" (string #\newline)
                              "```")))
      (assert-equal 11 (send p :invoke text))))

  (deftest "bag-output-parser panics on malformed JSON" suite
    (let ((p (bag-output-parser :into (lambda (b) b))))
      (assert-panic (send p :invoke "not json"))))

  ;; ---- composition with chain events ------------------------------------

  (deftest "string-output-parser piped after a runnable-lambda fires events" suite
    (let* ((h     (make-instance 'recording-handler))
           (chain (pipe (runnable-lambda (lambda (q)
                                           (ai-message :content
                                                       (concatenate 'string
                                                                    "echo: " q))))
                        (string-output-parser))))
      (assert-equal "echo: hi"
                    (send chain :invoke "hi" :callbacks (list h)))
      ;; outer sequence + 2 inner steps = 6 events
      (assert-equal 6 (length (send h :events)))))

  (deftest "json parser piped end-to-end produces typed Lisp values" suite
    (let* ((stub-model (runnable-lambda
                        (lambda (q)
                          (declare (ignore q))
                          (ai-message :content "{\"sum\": 42}"))))
           (chain      (pipe stub-model
                             (bag-output-parser
                              :into (lambda (b) (send b :get "sum"))))))
      (assert-equal 42 (send chain :invoke "what is 19+23?")))))
