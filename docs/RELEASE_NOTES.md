# v0.1.0-alpha.1

Alpha.1 tightens the public evidence boundary and corrects the primary storage
comparison.

## Corrected positioning

- Adds ordinary Q8 as the fair baseline: 2,048 quant bytes plus 64 binary32
  scales, totaling 2,304 bytes.
- Records RQ8/32/64 as 2,048 quant bytes, 64 numerator bytes, and one exponent
  byte, totaling 2,113 bytes.
- Derives the exact RQ8 saving over ordinary Q8: 191 bytes, or `191/2304`
  (8.289930555555555 percent).
- Retains binary32 only as context: 8,192 bytes for the same 2,048 values.
- Publishes component-level machine-readable arithmetic in
  `reports/storage-evidence.json` and bounded claims in `reports/claims.json`.

## Included experimental surface

- standalone SBCL kernel verification with fail-closed adversarial fixtures;
- lawful exact-integer equality saturation;
- guarded RQ8 functions with retained reference implementations;
- one bounded 24-node symbolic mirror compiler for a 2,048-column RQ8 matvec;
- deterministic direct and ASDF acceptance gates.

## Evidence boundary

The recorded test counts come from the bounded alpha acceptance report and are
not presented as a new alpha.1 run. This release makes no claim about execution
speed, portability beyond the declared SBCL-specific implementation, model
quality, a general compiler, or stable serialization.

Kernel cases and compiler extensions are trusted executable Lisp, not sandboxed
input. See `SECURITY.md` before running third-party cases.
