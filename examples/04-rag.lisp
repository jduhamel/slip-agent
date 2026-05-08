;;;; 04-rag.lisp — RAG with in-memory vector store and retriever.
;;;;
;;;; Indexes a small knowledge base, then asks a question that needs
;;;; the right document to answer correctly.  Uses fake-embeddings
;;;; (deterministic char-bucket hash) so the example runs offline.
;;;;
;;;; Usage (from the slip repo root):
;;;;
;;;;   ANTHROPIC_API_KEY=sk-ant-... \
;;;;     go run cmd/slip/main.go plugins/slip-agent/examples/04-rag.lisp
;;;;
;;;; With OPENAI_API_KEY set you could swap in openai-embeddings for
;;;; semantically meaningful retrieval; the rest of the chain is
;;;; unchanged.

(require 'agent "plugins/slip-agent")

(defun pick-model ()
  (cond ((getenv "ANTHROPIC_API_KEY")
         (init-chat-model "claude-haiku-4-5"))
        (t
         (fake-chat-model
          :scripted-responses
          (list (ai-message :content "Based on the retrieved context, the capital of France is Paris."))))))

(let* ((emb       (fake-embeddings))
       (store     (in-memory-vector-store
                   :embeddings emb
                   :documents
                   (list (document "The capital of France is Paris.")
                         (document "Pythons are large constricting snakes native to Africa, Asia, and Australia.")
                         (document "The mitochondrion is the powerhouse of the cell.")
                         (document "Common Lisp was standardised by ANSI in 1994.")
                         (document "Slip is a Lisp implementation in Go."))))
       (retriever (send store :as-retriever 2))
       (model     (pick-model))
       (prompt    (runnable-lambda
                   (lambda (alist)
                     (let ((docs (cdr (assoc :context alist)))
                           (q    (cdr (assoc :question alist))))
                       (let ((context-str
                               (with-output-to-string (out)
                                 (dolist (d docs)
                                   (format out "- ~A~%" (send d :page-content))))))
                         (list (system-message "Answer the question using the supplied context.")
                               (human-message
                                (format nil "Context:~%~A~%Question: ~A"
                                        context-str q))))))))
       (chain     (pipe (parallel (list (cons :context  retriever)
                                        (cons :question (passthrough))))
                        prompt
                        model
                        (string-output-parser))))
  (format t "Q: What is the capital of France?~%")
  (format t "A: ~A~%"
          (send chain :invoke "What is the capital of France?")))
