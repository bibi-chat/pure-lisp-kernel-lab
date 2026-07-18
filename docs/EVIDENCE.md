# Evidence model

The release separates semantic correctness, compiler cleanliness, storage
arithmetic, performance measurement, and product claims.

## Fresh profiles

The standalone verifier compiles every accepted case twice in fresh SBCL
processes:

1. semantic profile: safety fixed at 3;
2. measured profile: speed 3, safety 1, debug 1.

Both profiles rerun deterministic differential cases and the benchmark input.
The verifier rejects mutation, nondeterministic case providers, signaled errors,
compiler warnings, changed source hashes, or unequal outcomes. A request for
performance additionally applies the declared speed and allocation thresholds.

## Bounded release observations

- Verifier integration: 8 positive and adversarial tests passed.
- Lawful exact-integer e-graph: 13 checks passed.
- RQ8: 62 checks passed in both direct and ASDF modes under a safety-3 minimum.
- Mirror compiler: 37 checks passed in both direct and ASDF modes.
- Mirror differential gate: 12 cases passed in semantic and measured
  correctness profiles.

These observations establish the behavior of the checked files, fixtures,
runtime, and domains. They do not establish portability, universal correctness,
accuracy fitness, model quality, end-to-end system speed, or superiority over
Mesh TensorFlow.

## Storage deduction

The RQ8 payload count follows directly from the representation: one quant byte
per value, one numerator byte per 32 values, and one exponent byte per at most
64 blocks. For 2,048 values, `2048 + 64 + 1 = 2113` bytes. Binary32 payload is
`2048 * 4 = 8192` bytes. The payload saving is therefore exactly 6,079 bytes.

This arithmetic does not measure Lisp object headers, alignment, temporary
storage, encoding latency, inference latency, or accuracy loss.

## Claim policy

`reports/claims.json` uses one of the evidence classes defined by the project:
`fact`, `deduced`, `empirically-supported`, or `unknown`. A claim is never made
stronger than its premises and warrant. Missing end-to-end evidence yields
`unknown`, not a favorable extrapolation.
