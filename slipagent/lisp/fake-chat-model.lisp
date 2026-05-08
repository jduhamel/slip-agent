;;;; fake-chat-model.lisp — deterministic chat-model for tests.
;;;;
;;;; Public flavor (exported) so users can write hermetic tests of
;;;; their agents without touching real provider APIs.  Pass a list of
;;;; ai-message instances via :scripted-responses; each :invoke pops
;;;; the next response in order.  :stream splits the next response's
;;;; text content into per-character chunks.

(defflavor fake-chat-model
    ((scripted-responses nil) (response-index 0))
    (chat-model)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A deterministic chat-model that returns scripted ai-message
instances.  Construct with (make-instance 'fake-chat-model
:scripted-responses (list ai1 ai2 ...)); each :invoke advances the
internal index and returns the next response.  Panics if invoked more
times than there are scripted responses."))

(defmethod (fake-chat-model :invoke-impl) (messages &rest config)
  (declare (ignore messages config))
  (when (>= response-index (length scripted-responses))
    (panic (format nil "fake-chat-model: ran out of scripted responses (used ~A)"
                   response-index)))
  (let ((response (nth response-index scripted-responses)))
    (setq response-index (1+ response-index))
    response))

(defmethod (fake-chat-model :stream-impl) (messages &rest config)
  (declare (ignore messages config))
  (when (>= response-index (length scripted-responses))
    (panic (format nil "fake-chat-model: ran out of scripted responses (used ~A)"
                   response-index)))
  (let* ((response (nth response-index scripted-responses))
         (text     (message-text response))
         (out      (make-channel 16)))
    (setq response-index (1+ response-index))
    (run
      (progn
        ;; Stream one character at a time as a chunk.  Real providers
        ;; chunk by token; for tests, character granularity is enough
        ;; to verify that consumers see multiple chunks.
        (dotimes (i (length text))
          (channel-push out
                        (ai-message-chunk
                         :content (string (char text i)))))
        ;; Send a final chunk that carries response-metadata + usage,
        ;; mirroring how providers signal end-of-stream.
        (channel-push out
                      (ai-message-chunk
                       :content ""
                       :response-metadata (send response :response-metadata)
                       :usage             (send response :usage)))
        (channel-close out)))
    out))

;; Override :copy to carry the fake-specific slots.  scripted-responses
;; carries forward; response-index resets to 0 so :bind-tools doesn't
;; consume the script.
(defmethod (fake-chat-model :copy) ()
  (make-instance 'fake-chat-model
                 :model               model
                 :temperature         temperature
                 :max-tokens          max-tokens
                 :tools               tools
                 :api-key             api-key
                 :base-url            base-url
                 :extra               extra
                 :scripted-responses  scripted-responses
                 :response-index      0))

(defun fake-chat-model (&key (model "fake") scripted-responses)
  "Construct a fake-chat-model.  scripted-responses is a list of
ai-message instances to return in order from :invoke."
  (make-instance 'fake-chat-model
                 :model              model
                 :scripted-responses scripted-responses))

(export 'fake-chat-model)
