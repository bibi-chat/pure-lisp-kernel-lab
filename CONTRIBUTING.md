# Contributing

Contributions are welcome when they preserve the laboratory's evidence and
scope boundaries.

## Design rules

- Keep the semantic reference implementation beside every candidate.
- Prefer deterministic unary functions over structured immutable inputs.
- Isolate process, filesystem, clock, random, global-state, and network effects.
- State the exact numeric, shape, dtype, overflow, NaN, infinity, signed-zero,
  mutation, and fallback contract for every specialization.
- Never add `(safety 0)`.
- Keep the lawful e-graph inside closed exact-integer `CL:+` and `CL:*`
  expressions unless a new law has its own proved domain and countertests.
- Make unsupported compiler shapes fail closed. Public runtime wrappers may use
  only a documented reference fallback.

## Required evidence

Run before opening a pull request:

```sh
export SBCL_BIN=/absolute/path/to/sbcl
python3 scripts/test-all.py
python3 scripts/audit-release.py
```

A performance or allocation claim also requires a fresh merged verifier report
that records the exact case, baseline, input domain, runtime, machine, sample
configuration, semantic profile, measured profile, and acceptance thresholds.
Disassembly can explain a measurement but cannot prove equivalence or speed.

Do not commit FASLs, binaries, toolchains, keys, credentials, personal absolute
paths, timing scratch data, or reports containing local paths. Keep changes
small enough that one commit establishes one observable outcome.
