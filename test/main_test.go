// Copyright (c) 2026, Joe Duhamel, All rights reserved.

package test_test

import (
	"bytes"
	"fmt"
	"os/exec"
	"testing"

	"github.com/ohler55/ojg/tt"
)

// TestWithSlip drives the Lisp test suite by invoking the slip CLI from
// the slip repo root and pointing it at this plugin's tests.lisp.
//
// The test harness lives in Lisp (pkg/test framework: defsuite, deftest,
// assert-equal, etc.); this Go wrapper exists so `go test` is the entry
// point that CI and `make test` know how to invoke.
func TestWithSlip(t *testing.T) {
	// slip-agent lives nested inside slip/plugins/, so run slip from the
	// repo root (../../.. from this test directory) and reference the
	// tests.lisp via a plugins/-rooted path.
	cmd := exec.Command("go", "run", "cmd/slip/main.go",
		"-e", `(run-tests)`,
		"plugins/slip-agent/test/tests.lisp")

	cmd.Dir = "../../.."

	out, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Println(string(out))
		panic(err)
	}
	if testing.Verbose() || bytes.Contains(out, []byte("FAIL")) {
		fmt.Println(string(out))
	}
	tt.Equal(t, false, bytes.Contains(out, []byte("FAIL")))
}
