# CFFI on TorCL

This fork adds a CFFI-SYS backend for [TorCL](https://github.com/atgreen/torcl),
a Common Lisp implementation whose bootstrap system is written in Rust. Nothing
outside the TorCL-conditional parts changes, so every other implementation
behaves as it did upstream.

| File | What it is |
|---|---|
| `src/cffi-torcl.lisp` | The CFFI-SYS backend: pointers, foreign memory, calls, callbacks, libraries |
| `src/cffi-torcl-fsbv.lisp` | Structures by value, through TorCL's own ABI layer |
| `cffi.asd` | Accepts `:torcl` and loads those two files |
| `cffi-tests.asd` | Does not pull in `cffi-libffi` on TorCL |

## How it calls C

TorCL's foreign interface is the `TORCL-FFI` package. A call names its return
type, a list of argument types and a list of arguments — so this backend builds
those lists instead of emitting a distinct alien stub per call site, the way the
ECL backend's dynamic FFI path does. A variadic call also passes the number of
fixed arguments, which the runtime needs to apply the ABI's rules to the
variable part.

Aggregates go through `TORCL-FFI:FOREIGN-CALL-BUFFERED`, which takes the address
of each argument and of the result, and applies the target ABI's aggregate rules
itself. **TorCL therefore needs neither libffi nor a C compiler to pass or
return a structure by value.** `cffi-libffi` does load on TorCL, and loading it
replaces this native path with libffi's; there is no reason to on this
implementation.

The runtime lays a structure out from a description of its fields, so
`src/cffi-torcl-fsbv.lisp` checks that description against the layout CFFI
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

CFFI's own suite runs on TorCL x86-64 Linux: **316 of 344 tests pass.** The 28
that fail are TorCL conformance bugs, each filed with a reproducer, not gaps in
this backend:

| TorCL issue | Failing tests |
|---|---|
| `bliss-nj6id` — `:argument-precedence-order` ignored when ordering methods | 13 (all `FSBV.*`, `STRUCT-VALUES.*`, `SET-AGGREGATE-STRUCT-SLOT`, `STRUCT.STRING.1`) |
| `bliss-cb3c7` — `define-symbol-macro` through `eval` is invisible afterwards | 9 (`FOREIGN-GLOBALS` symbol-case and `SET.STRING`) |
| `bliss-hfn71` — `deftype` not expanded in nested/aliasing type positions | 2 (`STRING.ENCODING*`) |
| `bliss-jre1u` — `documentation` of a function is never recorded | 2 (`DEFCFUN.*DOCSTRING*`) |
| `bliss-bpjw6` — `loop` leaves its iteration variable one short in `finally` | 1 (`FUNCALL.STRING.3`) |
| `bliss-bd6r2` — `compile` does not macroexpand its lambda expression | 1 (`FUNCALL.NIL-SKIP`) |

The other `cffi*` systems load on TorCL unchanged: `cffi-grovel`,
`cffi-toolchain` (the C compiler and linker it drives need no TorCL-specific
parameters), `cffi-libffi`, `cffi-uffi-compat`, `uffi` and `cffi-examples` —
whose examples run, variadic `sprintf` and enum translation included.

Foreign calls and callbacks are architecture-specific in TorCL: this backend is
tested on x86-64 Linux, and dynamic library loading requires a dynamic TorCL
build.

## Running the tests

```lisp
(asdf:load-system :cffi-tests)
(asdf:test-system :cffi-tests)
```
