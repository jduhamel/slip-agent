// Copyright (c) 2026, Joe Duhamel, All rights reserved.

// Package slipagent is the Go scaffolding for the slip-agent Slip plugin.
// All slip-agent functionality is defined in Lisp under lisp/; this file
// only registers the package, wires the Use chain, and loads the embedded
// Lisp source.
package slipagent

import (
	"github.com/ohler55/slip"
	"github.com/ohler55/slip/pkg/bag"
	"github.com/ohler55/slip/pkg/clos"
	"github.com/ohler55/slip/pkg/flavors"
	"github.com/ohler55/slip/pkg/generic"
	"github.com/ohler55/slip/pkg/gi"
	"github.com/ohler55/slip/pkg/net"
)

// Pkg is the slip-agent package.
var Pkg = slip.Package{
	Name:      "slip-agent",
	Nicknames: []string{"agent"},
	Doc:       "Home of symbols defined for slip-agent: messages, runnables, prompts, tools, chat-models, embeddings, vector stores, and the create-agent entry point.",
	PreSet:    slip.DefaultPreSet,
}

func init() {
	Pkg.Initialize(nil)
	slip.AddPackage(&Pkg)

	// The Lisp source uses functions from each of these packages, so the
	// plugin's package must Use them before the Lisp loads.
	Pkg.Use(&slip.CLPkg)
	Pkg.Use(&gi.Pkg)
	Pkg.Use(&bag.Pkg)
	Pkg.Use(&flavors.Pkg)
	Pkg.Use(&clos.Pkg)
	Pkg.Use(&generic.Pkg)
	Pkg.Use(&net.Pkg)

	loadLisp()

	slip.UserPkg.Use(&Pkg)
}
