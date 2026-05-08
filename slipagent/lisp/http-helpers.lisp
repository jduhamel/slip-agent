;;;; http-helpers.lisp — thin wrappers around net:http-client-flavor.
;;;;
;;;; Two helpers cover the slip-agent provider needs:
;;;;
;;;;   post-json — POST a bag, return parsed response bag.  Used for
;;;;   non-streaming chat completions and embeddings.
;;;;
;;;;   post-json-stream — POST a bag, return the http-response so the
;;;;   caller can drain (send response :body) line-by-line through
;;;;   the SSE parser.
;;;;
;;;; Both helpers compose headers as the http-client-flavor expects:
;;;; an alist where each entry is (name v1 v2 ...).  Content-Type is
;;;; injected automatically; callers pass auth and provider-specific
;;;; headers via the headers alist parameter.
;;;;
;;;; Note: net:http-client-flavor's :post 3-arg form has a quirk where
;;;; the headers argument overwrites the implicit Content-Type set
;;;; from a bag body.  These helpers always include Content-Type in
;;;; the headers alist they pass to the underlying call.

(defun build-header-list (headers content-type)
  "Convert an alist of (name . value) headers to the list-of-lists
form the http-client expects, injecting Content-Type."
  (let ((result (list (list "Content-Type" content-type))))
    (dolist (entry headers)
      (push (list (car entry) (cdr entry)) result))
    (nreverse result)))

(defun post-json (url headers body)
  "POST body (a bag or a string) as application/json to url.  headers
is an alist of (name . value); auth and provider-version go here.
Returns the parsed response bag.  Panics on non-2xx with the raw
response text in the error message so failures are debuggable."
  (let* ((client    (make-instance 'net:http-client-flavor :url url))
         (header-list (build-header-list headers "application/json"))
         (response  (send client :post body nil header-list))
         (status    (send response :status))
         (content   (send response :content)))
    (when (or (< status 200) (>= status 300))
      (panic (format nil "post-json: HTTP ~A from ~A: ~A"
                     status url content)))
    (make-bag content)))

(defun post-json-stream (url headers body)
  "POST body as application/json to url, returning the open
http-response.  Caller is responsible for draining (send response :body)
through parse-sse-stream and calling (send response :close) when done.

For streaming, providers expect the body itself to set stream:true —
this helper does not modify the body."
  (let* ((client    (make-instance 'net:http-client-flavor :url url))
         (header-list (cons (list "Accept" "text/event-stream")
                            (build-header-list headers "application/json")))
         (response  (send client :post body nil header-list))
         (status    (send response :status)))
    (when (or (< status 200) (>= status 300))
      ;; Failure — drain content for the error message and close.
      (let ((content (send response :content)))
        (panic (format nil "post-json-stream: HTTP ~A from ~A: ~A"
                       status url content))))
    response))

(export 'post-json)
(export 'post-json-stream)
(export 'build-header-list)
