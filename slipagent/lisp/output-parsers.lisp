;;;; output-parsers.lisp — string, JSON, and structured output parsers.
;;;;
;;;; Output parsers turn a chat-model response into a more useful Lisp
;;;; value.  All three are runnables; the canonical use is at the end
;;;; of a pipe:
;;;;
;;;;   (pipe prompt model (string-output-parser))
;;;;   (pipe prompt model (json-output-parser))
;;;;   (pipe prompt model (bag-output-parser :into (lambda (b) ...)))
;;;;
;;;; Input is typically an ai-message or ai-message-chunk; the parser
;;;; collapses to a string via message-text first.  A bare string
;;;; input also works.

;;; ----------------------------------------------------------------------
;;; output-parser abstract
;;; ----------------------------------------------------------------------

(defflavor output-parser () (runnable)
  :abstract-flavor
  (:documentation
   "Abstract parent of every output parser.  Concrete subclasses
override :parse text — :invoke-impl extracts text from the input
(string, ai-message, or ai-message-chunk) and dispatches."))

(defun extract-text (input)
  "Collapse parser input to a string.  Accepts a raw string, or a
message with content (the OpenAI/Anthropic shape)."
  (cond ((stringp input) input)
        ((or (typep input 'ai-message)
             (typep input 'ai-message-chunk)
             (typep input 'human-message)
             (typep input 'system-message)
             (typep input 'tool-message)
             (typep input 'function-message))
         (message-text input))
        (t (panic (format nil
                          "output-parser: cannot extract text from ~A"
                          (type-of input))))))

(defmethod (output-parser :invoke-impl) (input &rest config)
  (declare (ignore config))
  (send self :parse (extract-text input)))

;;; ----------------------------------------------------------------------
;;; string-output-parser
;;; ----------------------------------------------------------------------

(defflavor string-output-parser () (output-parser)
  (:documentation
   "Identity parser.  :parse returns the input string unchanged.
Useful as the terminal step of a chain that produces an ai-message but
the caller wants a string."))

(defmethod (string-output-parser :parse) (text)
  text)

(defun string-output-parser ()
  "Construct a string-output-parser."
  (make-instance 'string-output-parser))

;;; ----------------------------------------------------------------------
;;; json-output-parser
;;; ----------------------------------------------------------------------

(defflavor json-output-parser () (output-parser)
  (:documentation
   "Parses model text as JSON and returns a bag.  Panics with a clear
message if the text is not valid JSON.  Some models wrap JSON in
``` markdown fences — strip-json-fences handles the common shapes."))

(defun strip-json-fences (text)
  "If text is wrapped in a markdown ``` fence, strip the fence so the
inner JSON is parseable.  Recognises ```json, ```JSON, and bare ```.
Other input is returned unchanged."
  (let* ((trimmed (string-trim '(#\space #\newline #\tab) text))
         (backtick (char "`" 0)))
    (cond ((and (>= (length trimmed) 3)
                (eql (char trimmed 0) backtick)
                (eql (char trimmed 1) backtick)
                (eql (char trimmed 2) backtick))
           ;; Find first newline after the opening fence; everything
           ;; between that newline and the closing fence is the JSON.
           (let ((nl (position (char (string #\newline) 0) trimmed :start 3)))
             (if nl
                 (let ((closing (search "```" trimmed :start2 (1+ nl))))
                   (cond (closing (subseq trimmed (1+ nl) closing))
                         (t       (subseq trimmed (1+ nl)))))
                 trimmed)))
          (t trimmed))))

(defmethod (json-output-parser :parse) (text)
  (let ((stripped (strip-json-fences text)))
    (gi:recover err
      (panic (format nil "json-output-parser: parse failed: ~A" err))
      (make-bag stripped))))

(defun json-output-parser ()
  "Construct a json-output-parser."
  (make-instance 'json-output-parser))

;;; ----------------------------------------------------------------------
;;; bag-output-parser — JSON parse plus a caller-supplied coercion
;;;
;;; The :into slot is a one-arg function (bag) -> instance.  The
;;; canonical use is to call a defstruct or CLOS make-* constructor
;;; with the bag's fields.  D12 (response-format) supplies an into-fn
;;; that reads the model's JSON into the response-format struct.
;;; ----------------------------------------------------------------------

(defflavor bag-output-parser ((into nil)) (output-parser)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Parses model text as JSON, then optionally applies a coercion
function.  into is a one-arg function (bag) -> instance; if nil, the
parser returns the bag itself.  The split between JSON parsing and
coercion lets callers reuse the JSON step while plugging in different
target types."))

(defmethod (bag-output-parser :parse) (text)
  (let ((stripped (strip-json-fences text)))
    (gi:recover err
      (panic (format nil "bag-output-parser: parse failed: ~A" err))
      (let ((bag (make-bag stripped)))
        (cond ((null into) bag)
              (t           (funcall into bag)))))))

(defun bag-output-parser (&key into)
  "Construct a bag-output-parser.  into is an optional one-arg
function (bag) -> instance for converting the parsed bag into a target
type (e.g. a defstruct or CLOS instance)."
  (make-instance 'bag-output-parser :into into))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'string-output-parser)
(export 'json-output-parser)
(export 'bag-output-parser)

;; Helpers exported because Slip resolves intra-defun function
;; references at call-site package — see messages.lisp comment.
(export 'extract-text)
(export 'strip-json-fences)
