# mirror-kernel 0.1 alpha

`mirror-kernel` is one bounded compiler experiment. It lowers a 24-node RQ8
matrix-vector semantic graph into a guarded, typed Common Lisp function that
SBCL compiles normally. It is not an SBCL fork, an SBCL replacement, a general
Common Lisp compiler, or a compiler for arbitrary tensor graphs.

The ASDF system author is `pure-lisp-kernel-lab contributors` and its license
metadata is `Apache-2.0`.

## Exact contract

The specialized batch has exactly 2,048 columns: 64 blocks of 32 RQ8 weights,
with one shared denominator group per row. `make-rq8-matvec-graph` creates the
24 immutable semantic nodes in dependency order. A closed target vocabulary
covers every node exactly once or returns no entries and no partial schedule.
Only the complete, expected emitter sequence can produce source.

The generated kernel guards the request length, tensor type, vector type,
positive fixnum row count, exact 2,048-column width, fixnum element count,
tensor/vector lengths, and exponent range `[-126, 119]` before entering its
typed loop. A strict generated function with no fallback signals an error for
an unsupported runtime shape. The documented public entry point keeps a
fallback instead:

```lisp
(mirror-kernel.rq8:matvec-rq8 (list tensor vector rows columns))
```

A supported 2,048-column request executes generated code. Other requests are
delegated to `rational-quant:matvec-rq8`, which either handles its own declared
domain or signals its normal shape error. `compile-rq8-matvec` itself fails
closed for an unsupported graph or incomplete target and emits no source.

## Evidence boundary

The deterministic suite checks the 24-node exact cover, missing-pattern
failure without a partial plan, stable source emission, strict runtime guards,
public fallback, ordered binary32 accumulation, and bit-exact agreement with
the retained `rational-quant:reference-matvec-rq8` oracle.

The standalone verifier compiles the strict candidate in fresh safety-3
semantic and speed-3/safety-1 measured SBCL profiles. The measured profile is
used as a second correctness environment with `--require correctness`. This
alpha records no material-speedup, allocation, performance-equivalence,
disassembly, whole-system, cross-runtime, or portability claim.

## Verification

From any working directory:

```sh
SBCL_BIN=/absolute/path/to/sbcl python3 /absolute/path/to/checkout/tests/mirror-kernel/run.py
```

The runner executes direct source tests, the ASDF `test-op`, and the public
`tool/verify_kernel.py` correctness gate. It uses absolute paths derived from
the checkout, starts subprocesses in a disposable directory, and directs ASDF
compiled outputs and verifier reports outside the repository.
