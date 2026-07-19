# Pure Lisp Kernel Lab

Pure Lisp Kernel Lab is an experimental SBCL laboratory for small,
deterministic Common Lisp kernels. It keeps reference implementations beside
guarded specialized implementations and accepts changes through deterministic
semantic checks.

This project is not an SBCL fork and not a general Common Lisp or tensor
compiler. SBCL compiles the ordinary typed Common Lisp produced by the bounded
experiments.

## What is included

| Component | Bounded purpose | Accepted evidence |
|---|---|---|
| `tool/verify_kernel.py` | Fresh-process semantic verification for trusted pure Lisp cases | 8 positive and adversarial integration checks |
| Lawful e-graph | Guarded equality saturation for closed exact-integer `CL:+` and `CL:*` expressions | 13 deterministic checks |
| `rational-quant` | Experimental in-memory RQ8 representation and matrix-vector kernel with retained reference functions | 62 checks in direct and ASDF modes |
| `mirror-kernel` | One symbolic 24-node graph lowered through an exact target cover into typed Lisp | 37 checks plus 12 fresh differential cases in two profiles |

Kernel cases and compiler files are trusted executable Lisp. The verifier is
not a sandbox.

## Fair storage comparison

The alpha.1 storage result compares equal 2,048-value payloads. Ordinary Q8 is
defined here as one signed quant byte per value plus one binary32 scale for
each 32-value block. RQ8 uses one signed quant byte per value, one numerator
byte per block, and one exponent byte for the 64-block group.

| Representation | Element payload arithmetic | Total bytes |
|---|---:|---:|
| binary32 | `2,048 * 4` | 8,192 |
| ordinary Q8 | `2,048 + (64 * 4)` | 2,304 |
| RQ8/32/64 | `2,048 + 64 + 1` | 2,113 |

RQ8 therefore saves exactly 191 element-payload bytes over ordinary Q8:
`2304 - 2113 = 191`. The exact reduction is `191/2304`, or
8.289930555555555 percent.

The binary32 row is context, not the primary baseline. Against that row, RQ8
saves 6,079 bytes (`6079/8192`). All counts exclude Lisp object headers,
alignment, temporary storage, executable code, and accuracy effects. They do
not define a stable file or wire format.

No whole-system speed claim is made. These storage deductions do not measure
execution time or allocation behavior.

The complete derivation is machine-readable in
`reports/storage-evidence.json`; claim classes and boundaries are in
`reports/claims.json`.

## Run the complete gate

Requirements:

- SBCL; the recorded bounded acceptance run used SBCL 2.6.6.
- Python 3.10 or newer.
- Git, for the release-content audit.

```sh
export SBCL_BIN=/absolute/path/to/sbcl
python3 scripts/test-all.py
python3 scripts/audit-release.py
```

The runners derive the checkout path from their own files, start SBCL without
user or system init files, and place generated scratch data outside the
checkout.

## Verify one kernel

A case defines unary `REFERENCE-KERNEL`, `CANDIDATE-KERNEL`, `CASES`, and
`BENCHMARK-INPUT` functions in `COMPILE-PURE-LISP.CASE`:

```sh
export SBCL_BIN=/absolute/path/to/sbcl
python3 tool/verify_kernel.py \
  tests/verifier/fixtures/identity-case.lisp \
  --output /tmp/identity-verification.json \
  --require correctness \
  --no-disassembly
```

Read `references/kernel-contract.md` before creating a case and
`references/lawful-egraph-contract.md` before enabling equality saturation.
Floating-point reassociation is outside the lawful e-graph domain.

## Package boundaries

`packages/rational-quant/README.md` defines the RQ8 numeric, shape, fallback,
and storage contract. The implementation is intentionally SBCL-specific
through `SB-KERNEL` and `SB-SYS`.

`packages/mirror-kernel/README.md` defines the single supported symbolic graph:
2,048 columns, 64 blocks of 32 weights, and one denominator group per row. The
strict generated function fails closed; the documented public wrapper retains
the RQ8 fallback.

## Evidence and limits

- `reports/test-evidence.json` records bounded local acceptance counts.
- `reports/claims.json` separates deductions, empirical support, and excluded
  conclusions.
- `docs/EVIDENCE.md` explains the storage arithmetic and test boundaries.
- `docs/RELEASE_NOTES.md` contains the alpha.1 notes.

Do not generalize fixture results to a language, model, machine, or whole
system.

## License

Apache License 2.0. See `LICENSE`, `NOTICE`, and `CONTRIBUTING.md`.
