# Kernel Contract

## Contents

1. Trust boundary
2. Case ABI
3. Pipeline compiler
4. Lawful e-graph compiler
5. Supported transformations
6. Rejected transformations
7. Evidence and integration

## Trust boundary

Treat every case file as executable code. SBCL reader forms, macro expansion,
`compile-file`, and `load` can execute code. The subprocess isolates compiler
state but is not a security sandbox. Run only code the user placed in scope.

Target SBCL in version 1. Do not claim portability of measured machine code.
The generated Common Lisp may be portable, but policy restrictions,
allocation counters, and disassembly collection are SBCL-specific.

## Case ABI

Create a staging file that defines `COMPILE-PURE-LISP.CASE` and these unary
functions:

- `REFERENCE-KERNEL input`: preserve the original semantics.
- `CANDIDATE-KERNEL input`: contain the generated specialization.
- `CASES (seed count)`: return exactly `count` deterministic inputs.
- `BENCHMARK-INPUT (seed size)`: return one deterministic representative input.
- `EQUIVALENT-P (reference-outcome candidate-outcome)`: optional comparator.

The actual configurations and comparator arguments are two-element lists. The
harness captures all returned values as `(:values values)`. The default
comparator uses `equalp` on the value lists. Version 1 rejects signaled errors;
do not include expected-error cases.

Use distinct function symbols. Keep the reference and candidate pure. Generate
fresh case collections for each call. Do not read clocks, random global state,
files, sockets, special variables, or mutable caches.

Minimal shape:

```lisp
(defpackage #:compile-pure-lisp.case
  (:use #:cl #:compile-pure-lisp.kernel))

(in-package #:compile-pure-lisp.case)

(defun reference-kernel (input)
  ...)

(define-pipeline-kernel candidate-kernel
    ((input (integer 0 1000000)) fixnum)
  (source (index 0 input 1) index :element-type fixnum)
  (map (value) (the fixnum (* value value)))
  (filter (value) (oddp value))
  (fold (total value) 0 (the fixnum (+ total value))))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (mod (+ seed (* index 104729)) 1000001))))

(defun benchmark-input (configuration)
  (second configuration))
```

## Pipeline compiler

`tool/pipeline-compiler.lisp` implements a small embedded language:

```text
SOURCE -> zero or more MAP/FILTER stages -> FOLD
```

Use this syntax:

```lisp
(define-pipeline-kernel name
    ((input input-type) result-type)
  (source (index start end positive-step)
          source-expression
          :element-type element-type)
  (map (value) expression)
  (filter (value) predicate)
  (fold (state value) initial-state expression))
```

The macro emits one typed `do` loop. Source bounds and step are evaluated once.
The step must be positive. Add `the` forms where an intermediate type cannot be
inferred. The macro rejects obvious effects, but it cannot prove that an
arbitrary called function is pure; audit every call manually.

Use a handwritten candidate when the kernel does not fit this linear graph.
Keep the same case ABI and verification gates.

## Lawful e-graph compiler

`tool/lawful-egraph-compiler.lisp` is an opt-in, bounded algebraic optimizer
for one deliberately small semantic domain. It accepts only exact integer
literals, explicitly declared integer variables, and binary forms whose
operator is the actual `CL:+` or `CL:*` symbol. It rejects all other calls,
floats, effects, and custom rewrite laws.

Use either macro:

```lisp
(egraph-expression
    ((x integer) (y integer) (z integer))
    integer
    (:theory :exact-integer :round-limit 8 :node-limit 512)
  (+ (* x y) (* x z)))

(define-egraph-kernel factor-kernel
    ((input integer) integer)
    (:theory :exact-integer)
  (+ (* input 7) (* input 11)))
```

The optimizer saturates a local e-graph with exact-integer identity,
annihilation, constant-folding, commutativity, associativity, and common-factor
laws. It then extracts deterministically using a static operation cost. Ordered
children are retained; only explicit commutativity rules may exchange them.
Exhausting any hard resource limit rejects macro expansion instead of emitting
an unverified partial result.

This path does not optimize Q8/RQ8 arithmetic, SAP access, loops, floating-point
forms, arbitrary function calls, or user-supplied theories. Read
`references/lawful-egraph-contract.md` for the complete boundary.

## Supported transformations

- Specialize an explicit, tested input domain.
- Inline small pure functions.
- Fuse maps, filters, folds, and indexable sources.
- Eliminate intermediate lists, arrays, slices, closures, and generic dispatch.
- Unbox arithmetic using proven Common Lisp types.
- Hoist loop-invariant pure expressions.
- Replace sparse stream-ID tables with proven dense indexing.
- Reuse caller-owned storage behind an explicit effect boundary.

Represent the optimizer as pure graph passes: parse, normalize, infer,
specialize, fuse, lower, and emit. Give each pass one graph input and one graph
output.

## Rejected transformations

- Never generate `(safety 0)` in version 1.
- Never trust a type declaration without testing every declared boundary.
- Never change integer overflow, multiple-value, condition, or equality semantics.
- Never reassociate floating-point operations without an explicit tolerance contract.
- Never optimize I/O, mutation, special-variable access, nonlocal control, or `eval`
  as a pure kernel.
- Never hardcode benchmark outputs or derive a closed form merely to win one case.
- Never accept code because its disassembly is shorter.

Use a guarded public wrapper or the reference implementation for inputs outside
the specialized domain.

## Evidence and integration

Run:

```bash
python3 /absolute/path/to/pure-lisp-kernel-lab/tool/verify_kernel.py \
  /absolute/path/to/case.lisp \
  --compiler /absolute/path/to/pure-lisp-kernel-lab/tool/pipeline-compiler.lisp \
  --output /absolute/path/to/report.json \
  --require both \
  --min-speedup 1.10 \
  --min-bytes-saved 1 \
  --minimum-sample-ns 1000000
```

The harness hashes the case, selected compiler, worker, and Python verifier,
then starts two fresh SBCL processes:

1. Force safety 3, compile, and run deterministic differential tests.
2. Force speed 3, safety 1, debug 1, compile again, repeat tests, benchmark, and disassemble.

Each profile compiles the selected compiler before compiling the case. Warnings
raised while compiling or loading either source are part of the warning gate.
A source hash change between profiles is an infrastructure error, not a
candidate result. Output and derived artifact paths may not collide with the
case, selected compiler, worker, or verifier. The merged report records all
verification configuration needed to reproduce the run.

`BENCHMARK-INPUT` is not trusted merely because `CASES` passed. Before any
timing, both profiles call its provider repeatedly and run the same mutation,
condition, determinism, and differential checks on that representative input.
The profile records this separately as `benchmark_correctness`; a failure stops
the measured profile before timing.

Treat raw timings as paired local evidence. Increase input size and iterations
until both timed batches exceed the minimum sample duration and timer noise is
small relative to the claimed gain. Reject compiler warnings unless the user
explicitly accepts and documents them.

Integrate only when the merged report says `accepted`. Preserve the reference
or a domain guard, link the JSON report, state the specialization domain, and
report the exact SBCL and machine used. Disassembly is advisory evidence for
boxing, allocation calls, and generic arithmetic; it is not the semantic oracle.
