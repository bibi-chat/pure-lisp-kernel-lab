---
name: compile-pure-lisp
description: Translate, specialize, and verify performance-critical pure Common Lisp kernels as faster SBCL native code. Use when Codex needs to optimize a deterministic Lisp hot path, fuse functional sequence pipelines, eliminate intermediate allocation or boxing, apply guarded exact-integer algebraic equality saturation, specialize code for explicit types and shapes, compare reference and generated implementations, inspect SBCL compiler output or disassembly, or build a guarded native specialization without changing semantics.
---

# Compile Pure Lisp

Translate an explicit pure subset into typed Common Lisp and let SBCL produce
native machine code. Preserve the original function as the semantic oracle.

## Enforce the Boundary

- Optimize only deterministic unary kernels with structured inputs.
- Require an explicit specialization domain and representative inputs.
- Reject I/O, mutation, dynamic state, nonlocal control, `eval`, and unknown effects.
- Never emit raw assembly or LLVM in version 1; use SBCL's runtime and ABI.
- Never generate `(safety 0)`.
- Apply algebraic laws only inside the exact domain named by their contract.
  Never infer that a law valid for mathematical integers is valid for floats,
  modular arithmetic, user-defined operators, conditions, or effects.
- Never modify production source during a review-only or diagnostic request.
- Treat compiled source as trusted executable code, not sandboxed data.

Read [../references/kernel-contract.md](../references/kernel-contract.md) before
creating a case, translating a kernel, or interpreting a report. Also read
[../references/lawful-egraph-contract.md](../references/lawful-egraph-contract.md)
before using equality saturation.

## Follow the Workflow

1. Locate a measured hot function. Establish its input/output semantics, side
   effects, multiple values, numeric behavior, and valid domain.
2. Express its dataflow as typed nodes and edges. Prefer pure unary passes:
   parse, normalize, infer, specialize, fuse, lower, and emit.
3. Keep the original implementation unchanged. Create a staging case exposing
   `REFERENCE-KERNEL`, `CANDIDATE-KERNEL`, `CASES`, and `BENCHMARK-INPUT` under
   `COMPILE-PURE-LISP.CASE`.
4. Choose one small compiler for the kernel shape:
   - linear indexable pipeline: `../tool/pipeline-compiler.lisp` and
     `DEFINE-PIPELINE-KERNEL`;
   - closed binary `CL:+`/`CL:*` expression over exact integers:
     `../tool/lawful-egraph-compiler.lisp` and `EGRAPH-EXPRESSION` or
     `DEFINE-EGRAPH-KERNEL`;
   - otherwise emit a small typed Common Lisp candidate directly.
5. Run `../tool/verify_kernel.py` with explicit correctness and performance
   gates. Pass the selected compiler with `--compiler` when it is not the
   default pipeline compiler. Scale the workload until timing noise is
   materially below the gain.
6. Inspect both compiler logs and candidate disassembly. Use disassembly only
   to explain measured boxing, generic dispatch, allocation, or loop structure.
7. Integrate only after the merged report says `accepted`. Preserve a domain
   guard or reference fallback and rerun the project's own tests and benchmarks.

## Require Independent Evidence

The verifier must compile and test two fresh profiles:

- semantic: force safety 3 and run deterministic differential tests;
- measured: force speed 3, safety 1, debug 1, repeat the tests, benchmark paired
  samples, collect bytes consed, and disassemble both functions.

Reject the candidate when either profile differs, either case provider is
nondeterministic, a kernel signals an error, compiler warnings remain, or the
requested speed/allocation gate fails. Require source hashes to remain stable
across both profiles. Do not infer success from source shape, macro expansion,
compiler notes, static extraction cost, or shorter machine code alone.

## Report the Result

Return:

- the exact specialization domain and unsupported inputs;
- the dataflow transformation and generated-source location;
- semantic case count and both compiler policies;
- median speedup and bytes saved per call;
- the merged JSON report and advisory disassembly paths;
- the retained guard or fallback used for integration.

Call the result “generated typed Common Lisp compiled to native code by SBCL,”
not a new general-purpose Common Lisp compiler.
