# Evidence model

The alpha.1 positioning separates representation arithmetic from bounded test
observations. Neither kind of evidence is generalized beyond its stated
premises.

## Exact storage deduction

The comparison fixes the value count at 2,048 and the block size at 32, so
there are exactly 64 blocks.

| Representation | Declared element payload | Bytes |
|---|---:|---:|
| binary32 | 2,048 values * 4 bytes | 8,192 |
| ordinary Q8 | 2,048 quant bytes + 64 binary32 scales * 4 bytes | 2,304 |
| RQ8/32/64 | 2,048 quant bytes + 64 numerator bytes + 1 exponent byte | 2,113 |

The fair Q8 comparison is therefore:

```text
2304 - 2113 = 191 bytes
191 / 2304 * 100 = 8.289930555555555 percent
```

The binary32 context comparison is:

```text
8192 - 2113 = 6079 bytes
6079 / 8192 * 100 = 74.20654296875 percent
```

These are element-payload deductions. They exclude Lisp object headers,
alignment, temporary storage, executable code, accuracy effects, and encoding
work. The representation count is not a stable serialization contract.

`reports/storage-evidence.json` records every component and exact fraction so a
machine reader can recompute both comparisons without relying on rounded
decimal text.

## Bounded release observations

`reports/test-evidence.json` records the following local alpha acceptance run:

- verifier integration: 8 positive and adversarial checks passed;
- lawful exact-integer e-graph: 13 checks passed;
- RQ8: 62 checks passed in direct mode and 62 in ASDF mode;
- mirror compiler: 37 checks passed in direct mode and 37 in ASDF mode;
- mirror differential gate: 12 cases passed in two fresh correctness profiles.

The report identifies SBCL 2.6.6 as the acceptance environment. These finite
observations establish only the checked files, fixtures, environment, and
domains. Alpha.1 does not relabel the recorded alpha run as new evidence.

## Claim policy

`reports/claims.json` classifies representation arithmetic as `deduced` and
finite differential results as `empirically-supported`. The release makes no
claim about execution speed, cross-runtime portability, model quality, a
general compiler, or stable serialization.
