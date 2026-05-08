;;;; documents.lisp — document flavor.
;;;;
;;;; A document is the unit that vector stores and retrievers (D11)
;;;; operate on.  Two slots: page-content (the text), metadata (an
;;;; alist of arbitrary tags).  Trivially simple in v0.1; later
;;;; versions may add embedding caching, source tracking, etc.

(defflavor document ((page-content "") (metadata nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "A unit of text plus arbitrary metadata, for ingestion into
vector stores and retrieval.  page-content is a string;
metadata is an alist of (key . value) tags such as :source,
:created, :chunk-id, etc."))

(defun document (page-content &key metadata)
  "Construct a document."
  (make-instance 'document :page-content page-content :metadata metadata))

(export 'document)
