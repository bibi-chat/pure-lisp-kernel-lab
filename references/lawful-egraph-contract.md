# Lawful E-Graph Contract

## Purpose

Use `tool/lawful-egraph-compiler.lisp` only to simplify one pure algebraic
expression before SBCL compiles it. This is an experimental, opt-in compiler
path. It does not replace `pipeline-compiler.lisp`, and it does not rewrite an
existing production kernel automatically.

The public request is one property list in and one `OPTIMIZATION-RESULT` out.
The public macros are declarative front ends. Internal union-find mutation is
ephemeral, local to one request, and cannot escape into kernel behavior.

## Accepted language

Every expression must be a finite tree containing only:

- exact Common Lisp integer literals;
- interned lexical variables declared as `INTEGER`, `FIXNUM`, or inclusive
  `(INTEGER lower upper)` types, where either bound may be `*`;
- binary calls whose operator object is exactly `CL:+` or `CL:*`.

The declared result type must use the same exact-integer type grammar. The only
theory is `:EXACT-INTEGER`. Options are literal and closed:

```lisp
(:theory :exact-integer :round-limit 8 :node-limit 512)
```

Unknown or duplicate options are errors. The implementation hard-caps requests
at 8 saturation rounds, 512 e-nodes, expression depth 64, 4096 successful
rewrite applications, and 16384 rewrite attempts. Validation visits at most
512 unique expression cons cells. Shared or circular cons graphs reject with
bounded, circle-aware diagnostics; the accepted syntax is a tree. Integer
literals, declared integer bounds, and folded constants are capped at 4096
bits. A caller may lower the round or node limits but may not raise the hard
caps.

## Closed law set

The compiler has no custom-law interface. Its entire theory is:

- `x + 0 = x` and `0 + x = x`;
- `x * 1 = x` and `1 * x = x`;
- `x * 0 = 0` and `0 * x = 0`;
- exact constant evaluation for binary `CL:+` and `CL:*`;
- commutativity and associativity of exact integer addition and multiplication;
- one-way common-factor discovery, such as
  `(x * y) + (x * z) = x * (y + z)`.

These laws are sound here because every accepted primitive is total over
Common Lisp integers and Common Lisp integers do not overflow. Do not transfer
that conclusion to floating point, bounded machine arithmetic, foreign numeric
types, overloaded operators, or forms that may signal conditions or perform
effects.

## Deterministic extraction

E-nodes keep ordered child identifiers. Union winners, rebuild order, rewrite
order, factor order, and extraction tie-breaking are deterministic. Extraction
minimizes, in order:

1. static operator cost (`CL:+` costs 1 and `CL:*` costs 2);
2. expression node count;
3. non-original node count;
4. expression depth;
5. a package-qualified structural key.

The original form is retained unless the extracted form has a strictly lower
static operator cost. The implementation then asserts that the emitted form is
still in the root e-class and proves that its inferred range is contained in
the declared result type. An unbounded result is accepted only by an unbounded
integer result type. Static cost is only a search heuristic; it is never
performance evidence.

## Failure behavior

`OPTIMIZE-EGRAPH-EXPRESSION` returns `:LIMIT` with no candidate form when a
resource cap is exhausted. `EGRAPH-EXPRESSION` and `DEFINE-EGRAPH-KERNEL` turn
that result into a macro-expansion error. Invalid grammar, types, theory, or
options signal `EGRAPH-REQUEST-ERROR`. There is no partial or best-effort code
emission on these paths.

Rejected forms include:

- floats, ratios, complex values, characters, strings, arrays, and cons data;
- unary or n-ary arithmetic calls;
- `-`, `/`, comparisons, conditionals, loops, `PROGN`, `SETF`, random state,
  I/O, special-variable access, and nonlocal control;
- symbols merely named `+` or `*` in another package;
- symbol macros, special variables, and other non-lexical variable bindings;
- local, macro, or replaced bindings of `CL:+` or `CL:*`, and an unlocked
  `COMMON-LISP` package;
- Q8/RQ8 operations, SAP access, and user-provided rewrite rules.

`EGRAPH-EXPRESSION` uses SBCL's CLTL2 environment introspection to enforce the
lexical-variable and global-function binding rules at macro expansion. It also
requires SBCL's `COMMON-LISP` package lock and the same global arithmetic
function objects observed when the compiler loaded. This is intentionally
SBCL-specific; redefining Common Lisp standard functions remains outside the
supported execution model.

## Required verification

Keep a handwritten reference kernel and expose the normal staging ABI. Verify
the candidate with the selected compiler explicitly:

```bash
python3 /absolute/path/to/pure-lisp-kernel-lab/tool/verify_kernel.py \
  /absolute/path/to/case.lisp \
  --compiler /absolute/path/to/pure-lisp-kernel-lab/tool/lawful-egraph-compiler.lisp \
  --output /absolute/path/to/report.json \
  --require correctness
```

Cases must cover zeros, signs, declared bounds, `MOST-NEGATIVE-FIXNUM`,
`MOST-POSITIVE-FIXNUM`, and integers immediately outside the fixnum range when
the declared domain permits them. A performance claim additionally requires a
conclusive timing gate on representative inputs. Integrate only behind the
declared domain guard or retain the reference fallback.
