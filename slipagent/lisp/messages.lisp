;;;; messages.lisp — message and content-block flavors.
;;;;
;;;; Content blocks model the per-block structure of provider responses
;;;; (text, images, tool calls, tool results, reasoning).  Messages wrap a
;;;; role plus content (a string or a list of content blocks) and the
;;;; per-role metadata each role needs.
;;;;
;;;; The content-block list is preserved verbatim across agent loop replay
;;;; so that any block type a provider emits — including reasoning blocks
;;;; whose signatures must round-trip — survives without explicit support.

;;; ----------------------------------------------------------------------
;;; Content blocks
;;; ----------------------------------------------------------------------

(defflavor text-block (text) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation "A run of plain text inside a message."))

(defflavor image-block ((url nil) (media-type nil) (data nil) (detail nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "An image inside a message.  Either url or data is set; media-type is
the IANA type for inline data; detail is provider-specific (OpenAI's
:low/:high/:auto)."))

(defflavor tool-use-block ((id nil) (name nil) (input nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A request from the model to invoke a tool.  id identifies the call
for matching with a tool-result-block; name is the tool name; input is a
bag of arguments."))

(defflavor tool-result-block ((tool-use-id nil) (content nil) (is-error nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "The result of invoking a tool.  tool-use-id matches a tool-use-block
on a previous turn.  content is a string or a list of content blocks.
is-error is non-nil when the tool raised."))

(defflavor reasoning-block ((text nil) (signature nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A run of model reasoning (Anthropic extended thinking).  signature is
the cryptographic signature that must be sent back unaltered on tool-use
turns; v0.1 preserves it but does not surface a public API for enabling
thinking — see PLAN.md \"Reasoning Level B\" deferred."))

(defflavor redacted-reasoning-block ((data nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "An opaque reasoning block whose contents were redacted by the
provider's safety system.  data is the encrypted blob; round-trip it as
opaque."))

(defflavor unknown-content-block ((block-type nil) (raw nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Catch-all for content-block types slip-agent does not recognise.
block-type is the provider's type string; raw is the original bag.
Preserved verbatim across agent loop replay."))

;;; ----------------------------------------------------------------------
;;; Messages
;;; ----------------------------------------------------------------------

(defflavor base-message ((content "") (id nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  :abstract-flavor
  (:documentation
   "Abstract parent of all messages.  content is a string or a list of
content blocks.  id is an optional provider-supplied message id."))

(defflavor human-message () (base-message)
  (:documentation "A message from the user."))

(defflavor system-message () (base-message)
  (:documentation
   "A system instruction.  Most providers treat the first system message
specially; multiple system messages are merged or rejected depending on
the provider."))

(defflavor ai-message ((response-metadata nil) (usage nil)) (base-message)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A message from the assistant.  response-metadata is an alist of
provider-specific extras (model, stop reason, finish reason, headers);
usage is an alist of token counts (input, output, cache-read,
cache-creation)."))

(defflavor ai-message-chunk ((response-metadata nil) (usage nil)) (base-message)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "An incremental delta from a streaming response.  Same slots as
ai-message but represents a partial; concat-chunks merges a list into a
single ai-message."))

(defflavor tool-message ((tool-call-id nil) (is-error nil)) (base-message)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "The result of executing a tool, sent back to the model.
tool-call-id matches the id of the tool-use-block that requested the
call.  is-error is non-nil when the tool raised."))

(defflavor function-message ((name nil)) (base-message)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Legacy OpenAI function-call result message.  Kept for parity with
older OpenAI tool-calling shape; new code should use tool-message."))

;;; ----------------------------------------------------------------------
;;; Methods on ai-message
;;; ----------------------------------------------------------------------

(defun extract-tool-use-blocks (content)
  "Walk a content-block list and return only the tool-use-blocks, in
order.  Returns nil for string content or a list with no tool-use-blocks."
  (cond ((stringp content) nil)
        ((listp content)
         (let ((result nil))
           (dolist (block content)
             (when (typep block 'tool-use-block)
               (push block result)))
           (nreverse result)))))

(defmethod (ai-message :tool-calls) ()
  "Return a list of tool-use-block instances in the message's content,
or nil if content is a string or has no tool-use-blocks.  Computed lazily
from content blocks; not stored."
  (extract-tool-use-blocks content))

(defmethod (ai-message-chunk :tool-calls) ()
  "Same as ai-message :tool-calls — chunk surface mirrors the final shape."
  (extract-tool-use-blocks content))

;;; ----------------------------------------------------------------------
;;; Constructor helpers — terse, exported, hide make-instance from callers
;;; ----------------------------------------------------------------------

(defun human-message (content)
  "Construct a human-message.  content is a string or a list of content blocks."
  (make-instance 'human-message :content content))

(defun system-message (content)
  "Construct a system-message.  content is a string or a list of content blocks."
  (make-instance 'system-message :content content))

(defun ai-message (&key content response-metadata usage id)
  "Construct an ai-message.  content is a string or a list of content blocks."
  (make-instance 'ai-message
                 :content (or content "")
                 :response-metadata response-metadata
                 :usage usage
                 :id id))

(defun ai-message-chunk (&key content response-metadata usage id)
  "Construct an ai-message-chunk.  See ai-message."
  (make-instance 'ai-message-chunk
                 :content (or content "")
                 :response-metadata response-metadata
                 :usage usage
                 :id id))

(defun tool-message (content tool-call-id &key is-error)
  "Construct a tool-message.  content is a string or content-block list;
tool-call-id matches a tool-use-block id from a prior assistant turn."
  (make-instance 'tool-message
                 :content content
                 :tool-call-id tool-call-id
                 :is-error is-error))

(defun function-message (content name)
  "Construct a function-message (legacy OpenAI function-call result)."
  (make-instance 'function-message :content content :name name))

(defun text-block (text)
  "Construct a text-block."
  (make-instance 'text-block :text text))

(defun image-block (&key url media-type data detail)
  "Construct an image-block.  Either url or data is required; media-type
is the IANA type for inline data; detail is provider-specific."
  (make-instance 'image-block
                 :url url :media-type media-type
                 :data data :detail detail))

(defun tool-use-block (&key id name input)
  "Construct a tool-use-block.  id identifies the call; name is the tool
name; input is a bag of arguments."
  (make-instance 'tool-use-block :id id :name name :input input))

(defun tool-result-block (&key tool-use-id content is-error)
  "Construct a tool-result-block."
  (make-instance 'tool-result-block
                 :tool-use-id tool-use-id
                 :content content
                 :is-error is-error))

(defun reasoning-block (&key text signature)
  "Construct a reasoning-block."
  (make-instance 'reasoning-block :text text :signature signature))

(defun redacted-reasoning-block (data)
  "Construct a redacted-reasoning-block."
  (make-instance 'redacted-reasoning-block :data data))

(defun unknown-content-block (block-type raw)
  "Construct an unknown-content-block.  Used as a catch-all for block
types slip-agent does not recognise; round-tripped verbatim."
  (make-instance 'unknown-content-block :block-type block-type :raw raw))

;;; ----------------------------------------------------------------------
;;; Helpers
;;; ----------------------------------------------------------------------

(defun message-text (msg)
  "Return the textual content of msg as a string.  When content is a
string it is returned as-is; when it is a list of blocks the text-blocks
are concatenated and other block types ignored.  Reasoning blocks are
intentionally excluded — they are not part of the visible response."
  (let ((c (send msg :content)))
    (cond ((stringp c) c)
          ((listp c)
           (with-output-to-string (out)
             (dolist (block c)
               (when (typep block 'text-block)
                 (princ (send block :text) out))))))))

(defun concat-chunks (chunks)
  "Merge a list of ai-message-chunk instances into a single ai-message.
v0.1 supports text concatenation; mid-stream tool-use-block delta
assembly arrives in D8.  Returns an ai-message."
  (when (null chunks)
    (return-from concat-chunks (ai-message)))
  (let ((all-strings t)
        (last-meta nil)
        (last-usage nil)
        (last-id nil))
    (dolist (chunk chunks)
      (unless (stringp (send chunk :content))
        (setq all-strings nil))
      (when (send chunk :response-metadata)
        (setq last-meta (send chunk :response-metadata)))
      (when (send chunk :usage)
        (setq last-usage (send chunk :usage)))
      (when (send chunk :id)
        (setq last-id (send chunk :id))))
    (cond
      (all-strings
       (let ((joined (with-output-to-string (out)
                       (dolist (chunk chunks)
                         (princ (send chunk :content) out)))))
         (ai-message :content joined
                     :response-metadata last-meta
                     :usage last-usage
                     :id last-id)))
      (t
       ;; Block-list path — concatenate block lists; merge consecutive
       ;; text-blocks for cleanliness.
       (let ((merged nil))
         (dolist (chunk chunks)
           (let ((c (send chunk :content)))
             (cond ((stringp c)
                    (push (text-block c) merged))
                   ((listp c)
                    (dolist (block c)
                      (push block merged))))))
         (ai-message :content (merge-adjacent-text-blocks (nreverse merged))
                     :response-metadata last-meta
                     :usage last-usage
                     :id last-id))))))

(defun merge-adjacent-text-blocks (blocks)
  "Coalesce runs of text-blocks into single text-blocks.  Other block
types pass through unchanged."
  (let ((result nil)
        (acc nil))
    (dolist (block blocks)
      (cond ((typep block 'text-block)
             (setq acc (cons (send block :text) acc)))
            (t
             (when acc
               (push (text-block (apply #'concatenate 'string (nreverse acc))) result)
               (setq acc nil))
             (push block result))))
    (when acc
      (push (text-block (apply #'concatenate 'string (nreverse acc))) result))
    (nreverse result)))

;;; ----------------------------------------------------------------------
;;; OpenAI-style wire-format conversion
;;;
;;; Anthropic round-trips content-blocks directly; that path lands in D8
;;; alongside chat-anthropic.  D1 ships only the OpenAI shape because it
;;; doubles as a hash-map serialisation any test fixture can read.
;;; ----------------------------------------------------------------------

(defun message-role (msg)
  "Return the OpenAI-style role string for a message."
  (cond ((typep msg 'human-message)    "user")
        ((typep msg 'system-message)   "system")
        ((typep msg 'ai-message)       "assistant")
        ((typep msg 'ai-message-chunk) "assistant")
        ((typep msg 'tool-message)     "tool")
        ((typep msg 'function-message) "function")
        (t (error "message-role: not a message: ~S" msg))))

(defun message->bag (msg)
  "Serialise a message into an OpenAI-style bag with keys role, content,
plus role-specific extras.  ai-message tool-calls are emitted as the
OpenAI tool_calls array."
  (let ((bag (make-bag "{}")))
    (bag-set bag (message-role msg) "role")
    (bag-set bag (message-text msg) "content")
    (cond
      ((typep msg 'tool-message)
       (bag-set bag (send msg :tool-call-id) "tool_call_id"))
      ((typep msg 'function-message)
       (bag-set bag (send msg :name) "name"))
      ((typep msg 'ai-message)
       (let ((calls (send msg :tool-calls)))
         (when calls
           (let ((entries nil))
             (dolist (call calls)
               (push (tool-use-block->openai-bag call) entries))
             (bag-set bag (nreverse entries) "tool_calls"))))))
    bag))

(defun tool-use-block->openai-bag (block)
  "Serialise a tool-use-block into an OpenAI tool_call entry."
  (let ((b (make-bag "{}"))
        (fn (make-bag "{}"))
        (input (send block :input)))
    (bag-set b (send block :id) "id")
    (bag-set b "function" "type")
    (bag-set fn (send block :name) "name")
    ;; OpenAI sends arguments as a JSON-encoded string, not a nested object.
    (bag-set fn (bag-write (cond ((null input) (make-bag "{}"))
                                 (t input)))
             "arguments")
    (bag-set b fn "function")
    b))

(defun bag->message (bag)
  "Reverse of message->bag.  Reads the role and dispatches to the right
constructor.  Tool-call payloads on assistant messages become
tool-use-blocks inside content."
  (let ((role (send bag :get "role")))
    (cond
      ((string= role "user")
       (human-message (or (send bag :get "content") "")))
      ((string= role "system")
       (system-message (or (send bag :get "content") "")))
      ((string= role "tool")
       (tool-message (or (send bag :get "content") "")
                     (send bag :get "tool_call_id")))
      ((string= role "function")
       (function-message (or (send bag :get "content") "")
                         (send bag :get "name")))
      ((string= role "assistant")
       (let* ((text  (or (send bag :get "content") ""))
              (calls (send bag :get "tool_calls"))
              (blocks (cond
                        ((and (zerop (length text)) (null calls))
                         "")
                        ((null calls)
                         text)
                        (t
                         (let ((tu-blocks nil))
                           (dolist (entry calls)
                             (push (openai-bag->tool-use-block entry) tu-blocks))
                           (cons (text-block text) (nreverse tu-blocks)))))))
         (ai-message :content blocks)))
      (t (error "bag->message: unknown role ~S" role)))))

(defun openai-bag->tool-use-block (entry)
  "Reverse of tool-use-block->openai-bag.  entry is an alist (the form
nested values take when read out of a parent bag via :get).  Parses the
OpenAI arguments JSON string into a fresh bag."
  (let* ((fn       (cdr (assoc "function" entry :test #'equal)))
         (args-str (cdr (assoc "arguments" fn :test #'equal)))
         (input    (cond ((null args-str)            (make-bag "{}"))
                         ((zerop (length args-str))  (make-bag "{}"))
                         (t                          (make-bag args-str)))))
    (tool-use-block :id    (cdr (assoc "id" entry :test #'equal))
                    :name  (cdr (assoc "name" fn :test #'equal))
                    :input input)))

;;; ----------------------------------------------------------------------
;;; Exports — only entry points; flavor names stay package-private.
;;; ----------------------------------------------------------------------

(export 'human-message)
(export 'system-message)
(export 'ai-message)
(export 'ai-message-chunk)
(export 'tool-message)
(export 'function-message)
(export 'text-block)
(export 'image-block)
(export 'tool-use-block)
(export 'tool-result-block)
(export 'reasoning-block)
(export 'redacted-reasoning-block)
(export 'unknown-content-block)
(export 'message-text)
(export 'message-role)
(export 'concat-chunks)
(export 'message->bag)
(export 'bag->message)

;; Helpers exported because Slip resolves intra-defun function references
;; at call-site package rather than defun-site.  Exporting them keeps the
;; cross-package call working without per-call `agent::` qualification.
(export 'tool-use-block->openai-bag)
(export 'openai-bag->tool-use-block)
(export 'merge-adjacent-text-blocks)
(export 'extract-tool-use-blocks)
(export 'message-role)
