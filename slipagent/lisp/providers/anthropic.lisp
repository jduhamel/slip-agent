;;;; providers/anthropic.lisp — chat-anthropic provider.
;;;;
;;;; Implements the Anthropic Messages API.  Wire format:
;;;;
;;;;   POST https://api.anthropic.com/v1/messages
;;;;   x-api-key: <key>
;;;;   anthropic-version: 2023-06-01
;;;;   content-type: application/json
;;;;
;;;;   {
;;;;     "model": "claude-opus-4-7",
;;;;     "max_tokens": 1024,
;;;;     "system": "...",
;;;;     "messages": [{"role": "user|assistant", "content": "string|blocks"}],
;;;;     "tools": [...],
;;;;     "stream": true
;;;;   }
;;;;
;;;; Level A reasoning support (PLAN.md): all content-block types are
;;;; preserved verbatim across response parse and replay, including
;;;; reasoning, redacted_reasoning, and any unknown block types future
;;;; Anthropic versions add.  Reasoning signatures round-trip in the
;;;; signature slot.
;;;;
;;;; Prompt caching: pass :cache-control t on the chat-anthropic
;;;; instance to add cache_control: {type: "ephemeral"} to the system
;;;; prompt and tool definitions on each request — cuts cost and
;;;; latency when the same setup is sent across many turns.

;; defparameter cross-package access is unreliable in Slip (the
;; values resolve in the call-site package, not the defining one).
;; Wrap them in functions instead — function symbol lookup works
;; cross-package once exported.
(defun anthropic-default-base-url () "https://api.anthropic.com/v1/messages")
(defun anthropic-default-version  () "2023-06-01")

(defflavor chat-anthropic
    ((cache-control nil) (poster nil) (stream-poster nil))
    (chat-model)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Anthropic Messages API provider.  Constructor accepts the standard
chat-model slots plus :cache-control t for prompt caching.  base-url
defaults to api.anthropic.com; api-key is read from the slot or the
ANTHROPIC_API_KEY environment variable.

poster and stream-poster are test-injection seams.  When non-nil they
are called instead of post-json / post-json-stream — the recorder uses
them for fixture replay and capture.  Production code leaves them nil."))

(defmethod (chat-anthropic :copy) ()
  (make-instance 'chat-anthropic
                 :model         model
                 :temperature   temperature
                 :max-tokens    max-tokens
                 :tools         tools
                 :api-key       api-key
                 :base-url      base-url
                 :extra         extra
                 :cache-control cache-control
                 :poster        poster
                 :stream-poster stream-poster))

;;; ----------------------------------------------------------------------
;;; Request body construction
;;; ----------------------------------------------------------------------

(defun anthropic-system-from-messages (messages)
  "Anthropic puts system prompt(s) in a top-level system field, not in
messages.  Walk messages, pulling out any system-message texts and
joining with two newlines.  Returns (system-string . non-system-msgs)."
  (let ((system-parts  nil)
        (other-msgs    nil))
    (dolist (m messages)
      (cond ((typep m 'system-message)
             (push (message-text m) system-parts))
            (t (push m other-msgs))))
    (cons (cond ((null system-parts) nil)
                (t (with-output-to-string (out)
                     (let ((first t))
                       (dolist (p (nreverse system-parts))
                         (cond (first (setq first nil))
                               (t (format out "~A~A"
                                          (string #\newline)
                                          (string #\newline))))
                         (format out "~A" p))))))
          (nreverse other-msgs))))

(defun content-block->anthropic-bag (block)
  "Serialise one content-block to the Anthropic API shape."
  (let ((bag (make-bag "{}")))
    (cond
      ((typep block 'text-block)
       (bag-set bag "text" "type")
       (bag-set bag (send block :text) "text"))
      ((typep block 'image-block)
       (bag-set bag "image" "type")
       (let ((src (make-bag "{}")))
         (cond ((send block :url)
                (bag-set src "url" "type")
                (bag-set src (send block :url) "url"))
               (t
                (bag-set src "base64" "type")
                (bag-set src (send block :media-type) "media_type")
                (bag-set src (send block :data) "data")))
         (bag-set bag src "source")))
      ((typep block 'tool-use-block)
       (bag-set bag "tool_use" "type")
       (bag-set bag (send block :id) "id")
       (bag-set bag (send block :name) "name")
       (bag-set bag (or (send block :input) (make-bag "{}")) "input"))
      ((typep block 'tool-result-block)
       (bag-set bag "tool_result" "type")
       (bag-set bag (send block :tool-use-id) "tool_use_id")
       (bag-set bag (or (send block :content) "") "content")
       (when (send block :is-error)
         (bag-set bag t "is_error")))
      ((typep block 'reasoning-block)
       (bag-set bag "thinking" "type")
       (bag-set bag (send block :text) "thinking")
       (when (send block :signature)
         (bag-set bag (send block :signature) "signature")))
      ((typep block 'redacted-reasoning-block)
       (bag-set bag "redacted_thinking" "type")
       (bag-set bag (send block :data) "data"))
      ((typep block 'unknown-content-block)
       ;; Preserve the raw bag verbatim — Level A round-trip.
       (return-from content-block->anthropic-bag (send block :raw)))
      (t (panic (format nil "anthropic: cannot serialise content-block of type ~A"
                        (type-of block)))))
    bag))

(defun message->anthropic-bag (msg)
  "Serialise a message to the Anthropic API shape.  System messages
are extracted upstream by anthropic-system-from-messages and never
reach this function."
  (let ((bag (make-bag "{}"))
        (content (send msg :content)))
    (cond
      ((typep msg 'human-message) (bag-set bag "user"      "role"))
      ((typep msg 'tool-message)  (bag-set bag "user"      "role"))
      ((typep msg 'ai-message)    (bag-set bag "assistant" "role"))
      (t (panic (format nil "anthropic: unsupported message type ~A"
                        (type-of msg)))))
    ;; Tool messages: wrap content into a single tool_result block.
    (cond
      ((typep msg 'tool-message)
       (let ((blocks (list
                      (tool-result-block
                       :tool-use-id (send msg :tool-call-id)
                       :content     (cond ((stringp content) content)
                                          (t (message-text msg)))
                       :is-error    (send msg :is-error)))))
         (bag-set bag (anthropic-blocks-to-list blocks) "content")))
      ;; String content stays a string in the simple text case.
      ((stringp content)
       (bag-set bag content "content"))
      ;; Block-list content: serialise each block.
      ((listp content)
       (bag-set bag (anthropic-blocks-to-list content) "content")))
    bag))

(defun anthropic-blocks-to-list (blocks)
  "Convert a list of content-block instances to a list of native bag
representations suitable for bag-set into a parent's array slot.
Returns the list of native (alist) forms, since bag-set normalises
nested bags anyway."
  (let ((result nil))
    (dolist (b blocks)
      (push (send (content-block->anthropic-bag b) :native) result))
    (nreverse result)))

(defun build-anthropic-request (model messages tools cache-control max-tokens temperature streaming-p)
  "Construct the JSON request body bag for the Anthropic Messages API."
  (let* ((sys+rest    (anthropic-system-from-messages messages))
         (system-text (car sys+rest))
         (rest-msgs   (cdr sys+rest))
         (body        (make-bag "{}")))
    (bag-set body model "model")
    (bag-set body (or max-tokens 1024) "max_tokens")
    (when temperature
      (bag-set body temperature "temperature"))
    (when streaming-p
      (bag-set body t "stream"))
    (when system-text
      (cond
        (cache-control
         (let ((sys-blocks (list (make-cached-text-block system-text))))
           (bag-set body sys-blocks "system")))
        (t (bag-set body system-text "system"))))
    ;; messages
    (let ((msg-list nil))
      (dolist (m rest-msgs)
        (push (send (message->anthropic-bag m) :native) msg-list))
      (bag-set body (nreverse msg-list) "messages"))
    ;; tools
    (when tools
      (let ((tool-list nil))
        (dolist (tool tools)
          (let ((spec (tool->anthropic-spec tool)))
            (when cache-control
              (bag-set spec (make-cache-control-bag) "cache_control"))
            (push (send spec :native) tool-list)))
        (bag-set body (nreverse tool-list) "tools")))
    body))

(defun make-cached-text-block (text)
  "A native-form text block with cache_control: ephemeral set."
  (let ((b (make-bag "{}")))
    (bag-set b "text" "type")
    (bag-set b text "text")
    (bag-set b (make-cache-control-bag) "cache_control")
    (send b :native)))

(defun make-cache-control-bag ()
  (let ((b (make-bag "{}")))
    (bag-set b "ephemeral" "type")
    b))

;;; ----------------------------------------------------------------------
;;; Response parsing
;;; ----------------------------------------------------------------------

(defun anthropic-bag->content-block (bag-alist)
  "Parse one content-block entry from the response.  bag-alist is the
nested-value alist form returned by (send response :get \"content\"
...)."
  (let ((type-str (cdr (assoc "type" bag-alist :test #'equal))))
    (cond
      ((string= type-str "text")
       (text-block (cdr (assoc "text" bag-alist :test #'equal))))
      ((string= type-str "tool_use")
       (let* ((input-alist (cdr (assoc "input" bag-alist :test #'equal)))
              (input-bag   (cond ((null input-alist) (make-bag "{}"))
                                 (t (alist-to-bag input-alist)))))
         (tool-use-block
          :id    (cdr (assoc "id" bag-alist :test #'equal))
          :name  (cdr (assoc "name" bag-alist :test #'equal))
          :input input-bag)))
      ((string= type-str "thinking")
       (reasoning-block
        :text      (cdr (assoc "thinking" bag-alist :test #'equal))
        :signature (cdr (assoc "signature" bag-alist :test #'equal))))
      ((string= type-str "redacted_thinking")
       (redacted-reasoning-block
        (cdr (assoc "data" bag-alist :test #'equal))))
      (t
       ;; Unknown — preserve verbatim per Level A reasoning support.
       (unknown-content-block type-str (alist-to-bag bag-alist))))))

(defun alist-to-bag (alist)
  "Round-trip an alist back to a bag by writing JSON and re-parsing.
Used when reading nested values back into bag form for round-trip."
  (let ((bag (make-bag "{}")))
    (dolist (entry alist)
      (let ((key (car entry))
            (val (cdr entry)))
        (bag-set bag val
                 (cond ((stringp key) key)
                       ((symbolp key) (symbol-name key))
                       (t (format nil "~A" key))))))
    bag))

(defun parse-anthropic-response (response-bag)
  "Convert an Anthropic Messages API response bag into an ai-message.
Preserves the full content-block list verbatim — including reasoning
blocks and unknown block types — so agent-loop replay does not lose
information."
  (let* ((content-list (send response-bag :get "content"))
         (blocks       nil))
    (dolist (entry content-list)
      (push (anthropic-bag->content-block entry) blocks))
    (let* ((blocks-rev (nreverse blocks))
           ;; If content is a single text-block, surface as a string
           ;; for ergonomics; otherwise keep the block list.
           (final-content
             (cond ((and (= (length blocks-rev) 1)
                         (typep (car blocks-rev) 'text-block))
                    (send (car blocks-rev) :text))
                   (t blocks-rev))))
      (ai-message
       :content           final-content
       :id                (send response-bag :get "id")
       :response-metadata (list
                           (cons :model       (send response-bag :get "model"))
                           (cons :stop-reason (send response-bag :get "stop_reason")))
       :usage             (parse-anthropic-usage
                           (send response-bag :get "usage"))))))

(defun parse-anthropic-usage (usage-alist)
  "Convert Anthropic usage block (nested alist form) to our
keyword-keyed alist."
  (cond ((null usage-alist) nil)
        (t (list
            (cons :input-tokens
                  (cdr (assoc "input_tokens" usage-alist :test #'equal)))
            (cons :output-tokens
                  (cdr (assoc "output_tokens" usage-alist :test #'equal)))
            (cons :cache-creation-input-tokens
                  (cdr (assoc "cache_creation_input_tokens" usage-alist :test #'equal)))
            (cons :cache-read-input-tokens
                  (cdr (assoc "cache_read_input_tokens" usage-alist :test #'equal)))))))

;;; ----------------------------------------------------------------------
;;; :invoke-impl and :stream-impl
;;; ----------------------------------------------------------------------

(defmethod (chat-anthropic :invoke-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (anthropic-default-base-url)))
         (key     (resolve-api-key self "ANTHROPIC_API_KEY"))
         (body    (build-anthropic-request
                   model messages tools cache-control
                   max-tokens temperature nil))
         (headers (list (cons "x-api-key" key)
                        (cons "anthropic-version" (anthropic-default-version))))
         ;; poster slot lets tests substitute a fixture-replay or
         ;; record-capturing function.  nil = direct call.
         (response-bag (cond (poster (funcall poster url headers body))
                             (t (post-json url headers body)))))
    (parse-anthropic-response response-bag)))

(defmethod (chat-anthropic :stream-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (anthropic-default-base-url)))
         (key     (resolve-api-key self "ANTHROPIC_API_KEY"))
         (body    (build-anthropic-request
                   model messages tools cache-control
                   max-tokens temperature t))
         (headers (list (cons "x-api-key" key)
                        (cons "anthropic-version" (anthropic-default-version))))
         (response (cond (stream-poster (funcall stream-poster url headers body))
                         (t (post-json-stream url headers body))))
         (sse-ch   (make-channel 64))
         (out-ch   (make-channel 64)))
    ;; Pump SSE frames from the response body onto sse-ch.
    (run
      (gi:recover err
        (progn (declare (ignore err)) (channel-close sse-ch))
        (parse-sse-stream (send response :body) sse-ch)))
    ;; Translate SSE frames into ai-message-chunks on out-ch.
    (run
      (gi:recover err
        (progn (declare (ignore err)) (channel-close out-ch))
        (range (lambda (frame)
                 (let ((chunk (anthropic-frame-to-chunk frame)))
                   (when chunk (channel-push out-ch chunk))))
               sse-ch)
        (send response :close)
        (channel-close out-ch)))
    out-ch))

(defun anthropic-frame-to-chunk (frame)
  "Convert an Anthropic SSE frame (cons event-type bag) into an
ai-message-chunk, or nil for events that don't carry user-visible
data (ping, content_block_start, etc).

content_block_delta with text_delta becomes a chunk with text content.
message_delta carries usage updates and stop_reason in metadata."
  (let* ((event (car frame))
         (bag   (cdr frame)))
    (cond
      ((string= event "content_block_delta")
       (let* ((delta-alist (send bag :get "delta"))
              (delta-type  (cdr (assoc "type" delta-alist :test #'equal))))
         (cond
           ((string= delta-type "text_delta")
            (ai-message-chunk
             :content (cdr (assoc "text" delta-alist :test #'equal))))
           ((string= delta-type "input_json_delta")
            ;; Tool args streamed as partial JSON — surface as an empty
            ;; chunk; full assembly arrives via concat-chunks in v0.2.
            (ai-message-chunk :content ""))
           ((string= delta-type "thinking_delta")
            (ai-message-chunk :content ""))
           (t nil))))
      ((string= event "message_delta")
       (let* ((delta-alist (send bag :get "delta"))
              (usage-alist (send bag :get "usage"))
              (stop-reason (cdr (assoc "stop_reason" delta-alist :test #'equal))))
         (ai-message-chunk
          :content ""
          :response-metadata (cond (stop-reason
                                    (list (cons :stop-reason stop-reason)))
                                   (t nil))
          :usage             (parse-anthropic-usage usage-alist))))
      (t nil))))

;;; ----------------------------------------------------------------------
;;; Constructor
;;; ----------------------------------------------------------------------

(defun chat-anthropic (&key (model "claude-opus-4-7") temperature max-tokens
                            tools api-key base-url cache-control
                            poster stream-poster)
  "Construct a chat-anthropic chat-model.  api-key falls back to the
ANTHROPIC_API_KEY environment variable; base-url defaults to the
public Anthropic endpoint; cache-control t enables prompt caching.

poster and stream-poster are test-injection seams; production code
leaves them nil."
  (make-instance 'chat-anthropic
                 :model         model
                 :temperature   temperature
                 :max-tokens    max-tokens
                 :tools         tools
                 :api-key       api-key
                 :base-url      base-url
                 :cache-control cache-control
                 :poster        poster
                 :stream-poster stream-poster))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'chat-anthropic)

;; Helpers exported per the call-site-package gotcha.
(export 'anthropic-default-base-url)
(export 'anthropic-default-version)
(export 'build-anthropic-request)
(export 'parse-anthropic-response)
(export 'parse-anthropic-usage)
(export 'anthropic-system-from-messages)
(export 'content-block->anthropic-bag)
(export 'message->anthropic-bag)
(export 'anthropic-blocks-to-list)
(export 'anthropic-bag->content-block)
(export 'alist-to-bag)
(export 'make-cached-text-block)
(export 'make-cache-control-bag)
(export 'anthropic-frame-to-chunk)
