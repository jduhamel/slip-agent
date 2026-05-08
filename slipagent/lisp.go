// Copyright (c) 2026, Joe Duhamel, All rights reserved.

package slipagent

import (
	"embed"
	"io"

	"github.com/ohler55/slip"
)

//go:embed lisp
var lispFS embed.FS

// loadLisp evaluates each embedded Lisp source file under the slip-agent
// package, in dependency order. The order is hand-maintained — new files
// must be added here.
func loadLisp() {
	cp := slip.CurrentPackage
	defer func() {
		slip.CurrentPackage = cp
	}()
	slip.CurrentPackage = &Pkg

	scope := slip.NewScope()
	for _, path := range []string{
		"lisp/messages.lisp",
		"lisp/callbacks.lisp",
		"lisp/runnable.lisp",
		"lisp/composition.lisp",
		"lisp/prompts.lisp",
		"lisp/output-parsers.lisp",
		"lisp/tools.lisp",
		"lisp/chat-models.lisp",
		"lisp/fake-chat-model.lisp",
		"lisp/sse.lisp",
		"lisp/http-helpers.lisp",
		"lisp/providers/anthropic.lisp",
		"lisp/providers/openai.lisp",
		"lisp/providers/ollama.lisp",
		"lisp/init-chat-model.lisp",
		"lisp/documents.lisp",
		"lisp/chat-history.lisp",
		"lisp/embeddings/base.lisp",
		"lisp/embeddings/fake.lisp",
		"lisp/embeddings/openai.lisp",
		"lisp/embeddings/voyage.lisp",
		"lisp/vector-stores.lisp",
		"lisp/agents.lisp",
	} {
		f, err := lispFS.Open(path)
		if err != nil {
			panic(err)
		}
		var code []byte
		code, err = io.ReadAll(f)
		_ = f.Close()
		if err != nil {
			panic(err)
		}
		_ = slip.Read(code, scope).Eval(scope, nil)
	}
}
