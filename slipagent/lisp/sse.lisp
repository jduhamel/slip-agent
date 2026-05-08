;;;; sse.lisp — Server-Sent Events parser for streaming responses.
;;;;
;;;; Both Anthropic and OpenAI use SSE for streaming chat completions.
;;;; This parser is generic enough for both, with one minor variation:
;;;;
;;;;   - Anthropic emits   event: <type>\ndata: <json>\n\n
;;;;   - OpenAI emits      data: <json>\n\n  (no event line)
;;;;   - OpenAI terminates with  data: [DONE]
;;;;   - Anthropic terminates with the message_stop event + connection close
;;;;
;;;; The parser reads lines from an input-stream, accumulates a frame
;;;; (event-type + data buffer) until a blank line, then emits the
;;;; frame as (cons event-type-string parsed-bag).  [DONE] sentinels
;;;; close the channel.  Parser ends when the stream EOFs.

(defun parse-sse-stream (in-stream channel)
  "Read SSE frames from in-stream, push each frame as a (cons type bag)
onto channel.  Closes the channel on stream EOF or [DONE] terminator.

Slip gotcha: `return` inside an inner cond that has subsequent forms
in the outer branch gets shadowed by those forms.  We use a `done`
flag and check it as the last form in the loop body, so the
*ReturnResult* is the loop body's final value."
  (let ((event-type nil)
        (data-buf   nil)
        (done       nil))
    (loop
      (let ((line (read-line in-stream nil :eof)))
        (cond
          ;; End of stream — flush any buffered frame, mark done.
          ((eq line :eof)
           (when (and data-buf (not (sse-terminator-p data-buf)))
             (push-sse-frame channel event-type data-buf))
           (setq done t))
          ;; Blank line — frame terminator.  Either [DONE] (mark done)
          ;; or push the buffered frame.
          ((zerop (length line))
           (cond ((null data-buf) nil)
                 ((sse-terminator-p data-buf) (setq done t))
                 (t (push-sse-frame channel event-type data-buf)))
           (setq event-type nil)
           (setq data-buf nil))
          ;; event: line — sets event-type for next frame.
          ((sse-line-prefix-p line "event: ")
           (setq event-type (subseq line 7)))
          ;; data: line — accumulate.  Multiple data: lines in one
          ;; frame are joined with newlines per the SSE spec.
          ((sse-line-prefix-p line "data: ")
           (let ((chunk (subseq line 6)))
             (cond ((null data-buf) (setq data-buf chunk))
                   (t (setq data-buf
                            (concatenate 'string data-buf
                                         (string #\newline) chunk))))))
          ;; id:, retry:, : (comment) — ignored in v0.1.
          (t nil)))
      ;; Check the flag last — if set, this form's value is *ReturnResult*
      ;; and the loop honours it.
      (when done (return nil)))
    (channel-close channel)))

(defun sse-line-prefix-p (line prefix)
  "True iff line starts with prefix (string=)."
  (and (>= (length line) (length prefix))
       (string= (subseq line 0 (length prefix)) prefix)))

(defun sse-terminator-p (data)
  "True iff data is the OpenAI [DONE] terminator (with optional whitespace)."
  (let ((trimmed (string-trim '(#\space #\newline #\tab) data)))
    (string= trimmed "[DONE]")))

(defun push-sse-frame (channel event-type data)
  "Parse data as JSON and push (cons event-type bag) onto channel.
Malformed frames are silently dropped — providers occasionally emit
keep-alive pings that don't parse as message bags."
  ;; recover (without gi: prefix) so the macro resolves when this
  ;; defun is called from cl-user context — gi:recover macros
  ;; sometimes fail to resolve in defuns called cross-package.
  (recover err
    (progn
      (declare (ignore err))
      nil)
    (channel-push channel
                  (cons (or event-type "message")
                        (make-bag data)))))

;;; ----------------------------------------------------------------------
;;; Convenience: parse SSE from a string.  Useful for tests and for
;;; small responses where buffering the whole body is fine.
;;; ----------------------------------------------------------------------

(defun parse-sse-string (text)
  "Parse a complete SSE stream from a string.  Returns a list of
(cons event-type bag) frames."
  ;; in-stream rather than 'stream' — stream is a bound constant in Slip.
  (let* ((in-stream (make-string-input-stream text))
         (ch        (make-channel 64))
         (frames    nil))
    (parse-sse-stream in-stream ch)
    (range (lambda (frame) (push frame frames)) ch)
    (nreverse frames)))

(export 'parse-sse-stream)
(export 'parse-sse-string)

;; Internal helpers — exported per the call-site-package gotcha.
(export 'sse-line-prefix-p)
(export 'sse-terminator-p)
(export 'push-sse-frame)
