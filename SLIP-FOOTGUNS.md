# Slip footguns

Quirks of Slip Lisp that bit during slip-agent development.  Slip is "mostly Common Lisp" — these are the places where it diverges from the CL spec or from intuition built on full-CL implementations.

Each entry includes the symptom that surfaced it and the workaround.

## Reader / syntax

### `#\{` is a parse error
`{` is reader-special in Slip (used by `#{...}` swallow syntax and similar).  Character literals for `{` and `}` cannot be written.

```lisp
;; Wrong
(position #\{ template :start 0)

;; Right
(position (char "{" 0) template :start 0)
```

### Backquote does not substitute through a dotted-cdr

```lisp
;; Wrong — ,history reads as the literal symbol ,history
`((:history . ,history))   ;; (cdr ...) is the symbol ,history, not the value

;; Right — use cons explicitly
(list (cons :history history))
```

This bites any user code that builds alists with backquote.

### `',foo` inside backquote produces an unreadable marker

```lisp
;; Wrong — produces an unreadable marker, not (quote <value-of-foo>)
`(register ',foo)

;; Right
`(register (quote ,foo))
```

### `'foo` passed to a macro is a "macro" marker, not a cons

A macro receives `'foo` as a single object of type `macro`, not as a `(quote foo)` cons cell.  When re-emitting it in the expansion, substitute as `,value` directly — wrapping it again as `(quote ,value)` double-quotes when the input is `'foo`.

```lisp
;; User writes:
(def-tool calc (a b) "..." :schema 'calc-args (+ a b))

;; Wrong — double-quotes when user wrote 'sym
`(register-tool ... (quote ,schema) ...)

;; Right — schema already evaluates to the symbol at runtime
`(register-tool ... ,schema ...)
```

This asymmetry is irritating: `lambda-list` (a bare `(a b)` list) still needs `(quote ,lambda-list)`, but `schema` (already user-quoted) does not.

## Identifiers / scoping

### Function-name resolution happens at call-site package

When a function defined in package `A` calls another function `helper` (also in `A`), the lookup happens in **the package the user was in when `A`'s function was first called**, not in `A`.  If the user is in `cl-user`, intra-package helper calls fail with "Function helper is not defined in common-lisp-user."

Workaround: `(export 'helper)` for any helper called across defun boundaries from another defun.  This is purely a workaround for the binding-resolution model — it doesn't really expose a public API.  See `slip-agent/slipagent/lisp/messages.lisp` for the canonical comment.

### `defparameter` from a plugin file isn't visible cross-package either

Same root cause as the above.  Avoid plugin-private special variables that user code (or plugin code called from user-package context) needs to read.  Either inline the value at each use site or export the parameter.

### `e` is a bound constant (Euler's number)

```lisp
;; Wrong — "e is a constant and thus can't be set"
(dolist (e events) ...)

;; Right
(dolist (evt events) ...)
```

Other CL-style "free" short variable names that are taken in Slip have not been audited; rename rather than fight if a "constant" panic appears.

## Control flow / iteration

### `loop` is the bare infinite-loop primitive

Slip's `loop` is **not** CL's full extended-loop macro.  It is the bare iterate-until-`return` form.  None of `for`, `in`, `when`, `collect`, `while`, `append`, etc. are recognised.

```lisp
;; Wrong — "Variable for is unbound."
(loop for block in content when (typep block 'tool-use-block) collect block)

;; Right
(let ((result nil))
  (dolist (block content)
    (when (typep block 'tool-use-block)
      (push block result)))
  (nreverse result))
```

The `dolist` + `push` + `nreverse` pattern is the slip-agent default.

### The goroutine spawner is `run`, not `routine`

```lisp
;; Wrong — "Function routine is not defined."
(routine (do-thing))

;; Right
(run (do-thing))

;; Multi-form body — wrap in progn (run is a single-form macro)
(run (progn (a) (b) (c)))
```

## Strings / printing

### `princ ""` emits the literal `""`, not nothing

A real footgun for any code that builds a string by appending substrings, some of which may be empty.

```lisp
;; Wrong — produces ""prefix""middle""suffix"" when empty parts get princ'd
(with-output-to-string (out)
  (princ "" out)
  (princ "X" out)
  (princ "" out))
;; => "\"\"X\"\""

;; Right
(with-output-to-string (out)
  (format out "~A" "")
  (format out "~A" "X")
  (format out "~A" ""))
;; => "X"
```

Use `(format stream "~A" value)` everywhere `princ` would be tempting in a build-a-string loop.

## Bags / JSON / nil

### `bag-set` normalises nested values to native alists

When you put a bag-instance value into another bag (e.g. `(bag-set parent-bag child-bag "key")`), the child gets simplified to a Go-native alist.  Reading it back via `(send parent :get "key")` returns an alist, **not** a bag instance.

```lisp
;; This:
(bag-set parent (list child-bag-1 child-bag-2) "items")

;; Then:
(send parent :get "items")
;; => list of alists, not list of bags

;; Use assoc for nested access:
(cdr (assoc "name" (car (send parent :get "items")) :test #'equal))
```

The wire format (`bag-write`) still emits correct JSON; the loss of the bag-instance type is purely an in-memory representation thing.

### `bag-parse` requires an existing bag as first arg

```lisp
;; Wrong — "Too few arguments to bag-parse. At least 2 expected but got 1."
(bag-parse json-string)

;; Right — use make-bag for a fresh bag
(make-bag json-string)

;; bag-parse is for setting parsed JSON into an existing bag at a path
(bag-parse existing-bag json-string "path.to.field")
```

### Empty list ≠ Go-nil

Slip distinguishes between Go-level `nil` and a Slip empty list `'()` even though both print as `nil`.

```lisp
(eq nil nil)            ;; t
(eq nil '())            ;; nil   <-- !
(eq nil (list))         ;; nil   <-- !
```

This means `assert-nil` (a strict Go-nil check) panics on an empty list:

```lisp
;; Wrong if (foo) might return an empty list
(assert-nil (foo))

;; Right
(assert-equal 0 (length (foo)))
```

`null` does the right thing (returns `t` for both nil and empty list), so for runtime predicates use `(null x)`.

---

## Table of contents

- Reader / syntax
  - `#\{` parse error
  - Backquote dotted-cdr
  - `',foo` in backquote
  - `'foo` as macro argument
- Identifiers / scoping
  - Function lookup at call-site package
  - `defparameter` cross-package
  - `e` is a constant
- Control flow / iteration
  - `loop` is bare
  - `run` not `routine`
- Strings / printing
  - `princ ""` emits `""`
- Bags / JSON / nil
  - `bag-set` of nested bags
  - `bag-parse` needs existing bag
  - Empty list ≠ Go-nil
