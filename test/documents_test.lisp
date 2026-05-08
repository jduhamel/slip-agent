;;;; documents_test.lisp — document flavor.

(let ((suite (defsuite "documents" agent-suite)))

  (deftest "document constructor stores page-content" suite
    (let ((d (document "the quick brown fox")))
      (assert-equal "the quick brown fox" (send d :page-content))
      (assert-nil (send d :metadata))))

  (deftest "document carries metadata alist" suite
    (let ((d (document "page text"
                       :metadata '((:source . "wiki")
                                   (:lang   . "en")))))
      (assert-equal "wiki" (cdr (assoc :source (send d :metadata))))
      (assert-equal "en"   (cdr (assoc :lang   (send d :metadata))))))

  (deftest "document slots are settable" suite
    (let ((d (document "old")))
      (setf (send d :page-content) "new")
      (assert-equal "new" (send d :page-content)))))
