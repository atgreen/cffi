# CFFI on EGCL

This fork adds a CFFI-SYS backend for [EGCL](https://github.com/atgreen/evergreen),
a Common Lisp implementation whose bootstrap system is written in Rust. Nothing
outside the EGCL-conditional parts changes, so every other implementation
behaves as it did upstream.

| File | What it is |
|---|---|
| `src/cffi-egcl.lisp` | The CFFI-SYS backend: pointers, foreign memory, calls, callbacks, libraries |
| `src/cffi-egcl-fsbv.lisp` | Structures by value, through EGCL's own ABI layer |
| `cffi.asd` | Accepts `:egcl` and loads those two files |
| `cffi-tests.asd` | Does not pull in `cffi-libffi` on EGCL |

## How it calls C

EGCL's foreign interface is the `EGCL-FFI` package. A call names its return
type, a list of argument types and a list of arguments — so this backend builds
those lists instead of emitting a distinct alien stub per call site, the way the
ECL backend's dynamic FFI path does. A variadic call also passes the number of
fixed arguments, which the runtime needs to apply the ABI's rules to the
variable part.

Aggregates go through `EGCL-FFI:FOREIGN-CALL-BUFFERED`, which takes the address
of each argument and of the result, and applies the target ABI's aggregate rules
itself. **EGCL therefore needs neither libffi nor a C compiler to pass or
return a structure by value.** `cffi-libffi` does load on EGCL, and loading it
replaces this native path with libffi's; there is no reason to on this
implementation.

The runtime lays a structure out from a description of its fields, so
`src/cffi-egcl-fsbv.lisp` checks that description against the layout CFFI
computed — same size, same alignment, same field offsets — and reports a
structure it cannot describe rather than calling it. Padding fields are not
invented to make offsets agree: that would change how the ABI classifies the
structure and would call it wrongly rather than not at all.

Two further notes on fidelity:

- A foreign symbol is resolved through the platform loader's default scope, so
  a call is not scoped to the `:library` of its call site. That is what the SBCL
  backend does too, and why this backend pushes `cffi-sys::flat-namespace`.
  Closing a library empties the resolved-symbol cache.
- Redefining a callback keeps the pointer C already holds: a name's foreign
  entry is created once and dispatches through the function currently registered
  for that name. A redefinition that changes the *signature* needs a new entry,
  and the old entry is deliberately not freed — C may still hold it, and freeing
  it under C is not recoverable.

## Status

CFFI's own suite runs on EGCL x86-64 Linux: **342 of 344 tests pass**, with two
failures, neither of them a gap in this backend:

| Failing test | Why |
|---|---|
| `FUNCALL.NIL-SKIP` | EGCL's `COMPILE` does not macroexpand the lambda expression it is given, so the test cannot observe an argument translator running at expansion time (`bliss-bd6r2`). |
| `STRING.ENCODINGS.ALL.BASIC` | Babel's `:ksc_5601` encoder calls `handle-error` outside the macrolet that defines it, and `utf8-to-ksc-5601` answers NIL even for ASCII. **This fails on SBCL too** with the same Babel release, so it is not an EGCL issue. |

Getting there took seven EGCL conformance fixes, each found by a failing CFFI
test and each checked against SBCL's answer for the same form:

| EGCL issue | What it was | Tests it accounted for |
|---|---|---|
| `bliss-nj6id` | `:argument-precedence-order` was ignored, and method specificity summed the per-argument distances instead of comparing them one at a time | 13 — every `FSBV.*` and `STRUCT-VALUES.*` |
| `bliss-cb3c7` | `define-symbol-macro` through `eval` was written into a table that was then discarded, so a `defcvar` made that way came back unbound | 9 |
| `bliss-msyk` | a `setf` place was walked as an expression, so a compiler macro on the accessor rewrote it into something that was no longer a place | 2 |
| `bliss-hfn71` | `deftype` was expanded only one level, and not at all in an element-type position | 2 |
| `bliss-jre1u` | a `defun`/`defmacro` docstring was never recorded | 2 |
| `bliss-06l4z` | `foreign-free` refused a tracked allocation reached through a pointer read back out of memory | 2 |
| `bliss-bpjw6` | `loop` left its iteration variable one short in `finally`, so Babel's octet counters truncated every string encoded into a caller-sized buffer | 1 |

The other `cffi*` systems load on EGCL unchanged: `cffi-grovel`,
`cffi-toolchain` (the C compiler and linker it drives need no EGCL-specific
parameters), `cffi-libffi`, `cffi-uffi-compat`, `uffi` and `cffi-examples` —
whose examples run, variadic `sprintf` and enum translation included.

Foreign calls and callbacks are architecture-specific in EGCL: this backend is
tested on x86-64 Linux, and dynamic library loading requires a dynamic EGCL
build (`--features egcl-rt/c-ffi`).

## Running the tests

```lisp
(asdf:load-system :cffi-tests)
(asdf:test-system :cffi-tests)
```

## Notes for whoever maintains this next

- A signature's EGCL descriptors are cached by the signature itself, so
  redefining a `defcstruct` after calling a function that takes it by value
  leaves the old layout in the cache (`cffi::*egcl-call-plans*`). Upstream's
  libffi path caches its `ffi_cif` per call site and has the same property.
- Nothing here caches a *call site*, so a `defcfun` resolves its symbol on each
  call through a name→pointer hash table that a `close-foreign-library` empties.
  EGCL re-evaluates `load-time-value` on every call (bliss-jz86), so a
  load-time cache would not have worked anyway.
