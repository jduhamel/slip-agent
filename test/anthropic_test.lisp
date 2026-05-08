;;;; anthropic_test.lisp — chat-anthropic provider, request/response,
;;;; SSE parsing, fixture round-trip.

(let ((suite (defsuite "anthropic" agent-suite)))

  ;; ---- system message extraction ---------------------------------------

  (deftest "anthropic-system-from-messages pulls system text out" suite
    (let* ((msgs   (list (system-message "be brief")
                         (human-message "hi")))
           (split  (anthropic-system-from-messages msgs)))
      (assert-equal "be brief" (car split))
      (assert-equal 1 (length (cdr split)))
      (assert-equal "user" (message-role (car (cdr split))))))

  (deftest "anthropic-system-from-messages joins multiple system msgs" suite
    (let* ((msgs   (list (system-message "rule 1")
                         (system-message "rule 2")
                         (human-message "go")))
           (split  (anthropic-system-from-messages msgs)))
      ;; Go's regexp doesn't span newlines via . by default.  (?s)
      ;; activates dotall mode.
      (assert-match "(?s)rule 1.*rule 2" (car split))
      (assert-equal 1 (length (cdr split)))))

  (deftest "anthropic-system-from-messages with no system returns nil" suite
    (let ((split (anthropic-system-from-messages
                  (list (human-message "hi")))))
      (assert-nil (car split))
      (assert-equal 1 (length (cdr split)))))

  ;; ---- request body construction ----------------------------------------

  (deftest "build-anthropic-request includes model and max_tokens" suite
    (let* ((body (build-anthropic-request
                  "claude-opus-4-7"
                  (list (human-message "hi"))
                  nil nil nil nil nil)))
      (assert-equal "claude-opus-4-7" (send body :get "model"))
      (assert-equal 1024 (send body :get "max_tokens"))))

  (deftest "build-anthropic-request honors max-tokens override" suite
    (let ((body (build-anthropic-request
                 "claude-opus-4-7"
                 (list (human-message "hi"))
                 nil nil 4096 nil nil)))
      (assert-equal 4096 (send body :get "max_tokens"))))

  (deftest "build-anthropic-request adds system field from system-message" suite
    (let ((body (build-anthropic-request
                 "claude-opus-4-7"
                 (list (system-message "be brief")
                       (human-message "go"))
                 nil nil nil nil nil)))
      (assert-equal "be brief" (send body :get "system"))))

  (deftest "build-anthropic-request adds stream:true when streaming" suite
    (let ((body (build-anthropic-request
                 "claude-opus-4-7"
                 (list (human-message "hi"))
                 nil nil nil nil t)))
      (assert-equal t (send body :get "stream"))))

  (deftest "build-anthropic-request omits stream when not streaming" suite
    (let ((body (build-anthropic-request
                 "claude-opus-4-7"
                 (list (human-message "hi"))
                 nil nil nil nil nil)))
      (assert-nil (send body :get "stream"))))

  (deftest "build-anthropic-request includes tools array when bound" suite
    (def-tool ant-add (a b) "add" (+ a b))
    (let* ((body  (build-anthropic-request
                   "claude-opus-4-7"
                   (list (human-message "compute 2+2"))
                   (list ant-add) nil nil nil nil))
           (tools (send body :get "tools")))
      (assert-equal 1 (length tools))
      (assert-equal "ant-add"
                    (cdr (assoc "name" (car tools) :test #'equal)))))

  (deftest "build-anthropic-request with cache-control wraps system in blocks" suite
    (let* ((body   (build-anthropic-request
                    "claude-opus-4-7"
                    (list (system-message "long instructions")
                          (human-message "go"))
                    nil t nil nil nil))
           ;; sys-field rather than 'system' — system is a bound constant.
           (sys-field (send body :get "system")))
      ;; With caching, system becomes a list of blocks instead of a string.
      (assert-equal t (listp sys-field))
      (let ((first-block (car sys-field)))
        (assert-equal "text"
                      (cdr (assoc "type" first-block :test #'equal)))
        (assert-equal "long instructions"
                      (cdr (assoc "text" first-block :test #'equal))))))

  (deftest "build-anthropic-request adds cache_control to tools when caching" suite
    (def-tool ant-cached (a) "cached tool" a)
    (let* ((body  (build-anthropic-request
                   "claude-opus-4-7"
                   (list (human-message "hi"))
                   (list ant-cached) t nil nil nil))
           (tools (send body :get "tools"))
           (cc    (cdr (assoc "cache_control" (car tools) :test #'equal))))
      (assert-equal "ephemeral"
                    (cdr (assoc "type" cc :test #'equal)))))

  ;; ---- message serialisation -------------------------------------------

  (deftest "tool-message serialises to user role with tool_result block" suite
    (let* ((body (build-anthropic-request
                  "claude-opus-4-7"
                  (list (tool-message "the answer is 42" "toolu_01"))
                  nil nil nil nil nil))
           (msgs (send body :get "messages")))
      (assert-equal 1 (length msgs))
      (let* ((m       (car msgs))
             (role    (cdr (assoc "role" m :test #'equal)))
             (content (cdr (assoc "content" m :test #'equal)))
             (block   (car content)))
        (assert-equal "user" role)
        (assert-equal "tool_result"
                      (cdr (assoc "type" block :test #'equal)))
        (assert-equal "toolu_01"
                      (cdr (assoc "tool_use_id" block :test #'equal)))
        (assert-equal "the answer is 42"
                      (cdr (assoc "content" block :test #'equal))))))

  ;; ---- response parsing ------------------------------------------------

  ;; Parser tests against recorded fixtures use shape-based assertions
  ;; (string-ness, types, presence) rather than exact-value asserts —
  ;; refresh-fixtures captures whatever the live model actually said
  ;; on that run, which is nondeterministic.

  (deftest "parse-anthropic-response of single text-block returns string" suite
    (let* ((bag (read-fixture "anthropic" "invoke-text"))
           (msg (parse-anthropic-response bag)))
      (assert-equal "assistant" (message-role msg))
      (assert-equal t (stringp (send msg :content)))
      (assert-equal t (> (length (send msg :content)) 0))
      (assert-match "^msg_" (send msg :id))))

  (deftest "parse-anthropic-response includes response-metadata" suite
    (let* ((bag (read-fixture "anthropic" "invoke-text"))
           (msg (parse-anthropic-response bag)))
      (assert-equal "claude-opus-4-7"
                    (cdr (assoc :model (send msg :response-metadata))))
      (assert-equal "end_turn"
                    (cdr (assoc :stop-reason (send msg :response-metadata))))))

  (deftest "parse-anthropic-response includes usage" suite
    (let* ((bag (read-fixture "anthropic" "invoke-text"))
           (msg (parse-anthropic-response bag)))
      (assert-equal t (numberp (cdr (assoc :input-tokens  (send msg :usage)))))
      (assert-equal t (numberp (cdr (assoc :output-tokens (send msg :usage)))))))

  (deftest "parse-anthropic-response with tools preserves blocks list" suite
    (let* ((bag    (read-fixture "anthropic" "invoke-with-tools"))
           (msg    (parse-anthropic-response bag))
           (blocks (send msg :content)))
      ;; Multi-block content stays as a list.  The model may or may not
      ;; emit a preamble text block before the tool_use; either way at
      ;; least one tool-use-block must be present.
      (assert-equal t (listp blocks))
      (assert-equal t (>= (length blocks) 1))
      (let ((tool-blocks nil))
        (dolist (b blocks)
          (when (typep b 'tool-use-block) (push b tool-blocks)))
        (assert-equal t (>= (length tool-blocks) 1)))))

  (deftest "parse-anthropic-response :tool-calls method extracts tool calls" suite
    (let* ((bag   (read-fixture "anthropic" "invoke-with-tools"))
           (msg   (parse-anthropic-response bag))
           (calls (send msg :tool-calls)))
      (assert-equal t (>= (length calls) 1))
      (let ((call (car calls)))
        (assert-match "^toolu_" (send call :id))
        (assert-equal t (stringp (send call :name)))
        ;; Args come back as strings under v0.1 schema generation.
        (assert-equal t (or (numberp (send (send call :input) :get "a"))
                            (stringp (send (send call :input) :get "a")))))))

  (deftest "parse-anthropic-response preserves reasoning blocks (Level A)" suite
    (let* ((bag   (read-fixture "anthropic" "invoke-with-thinking"))
           (msg   (parse-anthropic-response bag))
           (blocks (send msg :content)))
      (assert-equal 2 (length blocks))
      (let ((rb (car blocks)))
        (assert-equal t (typep rb 'reasoning-block))
        (assert-equal "abc123sig" (send rb :signature))
        (assert-match "2\\+2" (send rb :text)))))

  ;; ---- SSE parser -------------------------------------------------------

  (deftest "parse-sse-string handles a single OpenAI-style data frame" suite
    (let* ((sse    (concatenate 'string
                                "data: {\"answer\":42}" (string #\newline)
                                (string #\newline)))
           (frames (parse-sse-string sse)))
      (assert-equal 1 (length frames))
      (let ((frame (car frames)))
        (assert-equal "message" (car frame))
        (assert-equal 42 (send (cdr frame) :get "answer")))))

  (deftest "parse-sse-string handles Anthropic-style event+data frames" suite
    (let* ((sse    (concatenate 'string
                                "event: message_start" (string #\newline)
                                "data: {\"type\":\"message_start\"}" (string #\newline)
                                (string #\newline)
                                "event: content_block_delta" (string #\newline)
                                "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}" (string #\newline)
                                (string #\newline)))
           (frames (parse-sse-string sse)))
      (assert-equal 2 (length frames))
      (assert-equal "message_start" (car (car frames)))
      (assert-equal "content_block_delta" (car (cadr frames)))))

  (deftest "parse-sse-string stops at [DONE] terminator" suite
    (let* ((sse    (concatenate 'string
                                "data: {\"a\":1}" (string #\newline) (string #\newline)
                                "data: [DONE]" (string #\newline) (string #\newline)
                                "data: {\"b\":2}" (string #\newline) (string #\newline)))
           (frames (parse-sse-string sse)))
      ;; Only the first frame; [DONE] closes the channel.
      (assert-equal 1 (length frames))))

  ;; v0.1 note: Slip's make-bag is permissive (SEN-style) so it
  ;; doesn't actually panic on most malformed JSON — the recover path
  ;; in push-sse-frame is mostly defensive.  Keeping the test below
  ;; verifies that even non-JSON data: lines don't break the stream.
  (deftest "parse-sse-string survives non-JSON data lines" suite
    (let* ((sse    (concatenate 'string
                                "data: hello" (string #\newline) (string #\newline)
                                "data: {\"ok\":true}" (string #\newline) (string #\newline)))
           (frames (parse-sse-string sse)))
      ;; Both frames come through — Slip parses 'hello' as a bag too.
      (assert-equal 2 (length frames))))

  ;; ---- frame -> chunk translation --------------------------------------

  (deftest "anthropic-frame-to-chunk converts text_delta to content chunk" suite
    (let* ((bag   (make-bag "{type: content_block_delta, delta: {type: text_delta, text: hello}}"))
           (chunk (anthropic-frame-to-chunk
                   (cons "content_block_delta" bag))))
      (assert-equal "hello" (send chunk :content))))

  (deftest "anthropic-frame-to-chunk surfaces stop_reason on message_delta" suite
    (let* ((bag   (make-bag "{type: message_delta, delta: {stop_reason: end_turn}, usage: {output_tokens: 7}}"))
           (chunk (anthropic-frame-to-chunk
                   (cons "message_delta" bag))))
      (assert-equal "end_turn"
                    (cdr (assoc :stop-reason (send chunk :response-metadata))))
      (assert-equal 7
                    (cdr (assoc :output-tokens (send chunk :usage))))))

  (deftest "anthropic-frame-to-chunk returns nil for ping" suite
    (let ((chunk (anthropic-frame-to-chunk
                  (cons "ping" (make-bag "{type: ping}")))))
      (assert-nil chunk)))

  ;; ---- constructor and slot defaults ------------------------------------

  (deftest "chat-anthropic constructor defaults" suite
    (let ((m (chat-anthropic)))
      (assert-equal "claude-opus-4-7" (send m :model))
      (assert-nil (send m :tools))
      (assert-nil (send m :cache-control))))

  (deftest "chat-anthropic :copy preserves cache-control" suite
    (let* ((m1 (chat-anthropic :model "claude-haiku-4-5" :cache-control t))
           (m2 (send m1 :bind-tools nil)))
      (assert-equal "claude-haiku-4-5" (send m2 :model))
      (assert-equal t (send m2 :cache-control))))

  ;; ---- End-to-end tests via recorded-poster ---------------------------
  ;;
  ;; These exercise the full chat-anthropic invoke path: build request,
  ;; POST (or replay), parse response.  In :replay mode (the default,
  ;; used by `make test`) the fixtures on disk supply the response so
  ;; no network is touched.  In :record mode (`make refresh-fixtures`
  ;; with AGENT_LIVE_TESTS=1 + ANTHROPIC_API_KEY) the same tests make
  ;; real calls and overwrite the fixtures.

  (deftest "chat-anthropic end-to-end invoke (replay)" suite
    (let* ((poster (recorded-poster "anthropic" "invoke-text"))
           (model  (chat-anthropic :model "claude-opus-4-7"
                                   ;; Real key when recording/live; placeholder
                                   ;; when replaying (key isn't sent on disk fixture).
                                   :api-key (or (getenv "ANTHROPIC_API_KEY")
                                                "test-key")
                                   :poster poster))
           (msg    (send model :invoke "Hi")))
      (assert-equal "assistant" (message-role msg))
      (assert-equal t (stringp (send msg :content)))
      ;; ID is nondeterministic across record runs — match the prefix.
      (assert-match "^msg_[0-9a-zA-Z]+" (send msg :id))
      (assert-equal "claude-opus-4-7"
                    (cdr (assoc :model (send msg :response-metadata))))))

  (deftest "chat-anthropic end-to-end invoke with tools (replay)" suite
    (def-tool ant-calc-add (a b) "Add two ints." (+ a b))
    (let* ((poster (recorded-poster "anthropic" "invoke-with-tools"))
           (model  (send (chat-anthropic :model "claude-opus-4-7"
                                         ;; Real key when recording/live; placeholder
                                   ;; when replaying (key isn't sent on disk fixture).
                                   :api-key (or (getenv "ANTHROPIC_API_KEY")
                                                "test-key")
                                         :poster poster)
                         :bind-tools (list ant-calc-add)))
           (msg    (send model :invoke "compute 17+25"))
           (calls  (send msg :tool-calls)))
      (assert-equal 1 (length calls))
      ;; Tool name is whatever def-tool registered (here: ant-calc-add).
      (assert-equal "ant-calc-add" (send (car calls) :name))
      ;; v0.1's schema generation declares every arg as :type string,
      ;; so the model returns string-typed values regardless of the
      ;; underlying Lisp type.  Real coercion lands when defstruct
      ;; introspection arrives in v0.2.
      (assert-equal "17" (send (send (car calls) :input) :get "a"))
      (assert-equal "25" (send (send (car calls) :input) :get "b"))))

  ;; Parser-only test for thinking blocks.  Reads the fixture directly
  ;; (NOT via recorded-poster) so `make refresh-fixtures` does not
  ;; overwrite it.  v0.1 has no public API for enabling extended
  ;; thinking on the request — that's Level B work, deferred — so a
  ;; real call would never produce reasoning blocks.  The hand-crafted
  ;; fixture is what we test the parser against.
  (deftest "parse-anthropic-response handles thinking fixture" suite
    (let* ((bag    (read-fixture-bag "anthropic" "invoke-with-thinking"))
           (msg    (parse-anthropic-response bag))
           (blocks (send msg :content)))
      (assert-equal t (listp blocks))
      (assert-equal t (typep (car blocks) 'reasoning-block))
      (assert-equal "abc123sig" (send (car blocks) :signature)))))


;;; ----------------------------------------------------------------------
;;; Helpers
;;;
;;; read-fixture is defined here (rather than in recorder.lisp) because
;;; the test suite uses the simpler load-and-parse path.  recorder.lisp
;;; documents the fuller record/replay machinery for when live capture
;;; lands.
;;; ----------------------------------------------------------------------

(defun read-fixture (subdir name)
  "Read and parse a fixture file as a bag."
  (let ((path (concatenate 'string
                           "plugins/slip-agent/test/fixtures/"
                           subdir "/" name ".json")))
    (with-open-file (in path :direction :input)
      (let ((text (with-output-to-string (out)
                    (loop
                      (let ((line (read-line in nil :eof)))
                        (when (eq line :eof) (return))
                        (format out "~A~A" line (string #\newline)))))))
        (make-bag text)))))
