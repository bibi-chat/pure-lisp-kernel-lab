# rational-quant

`rational-quant` is an experimental SBCL-only in-memory RQ8 representation
with quantize, dequantize, and matrix-vector kernels. An `rq8-tensor` contains
one signed 8-bit quant per value, one biased unsigned 8-bit numerator per
32-value block, and one signed 8-bit power-of-two exponent per group of at
most 64 blocks.

The ASDF system author is `pure-lisp-kernel-lab contributors` and its license
metadata is `Apache-2.0`.

For group exponent `E` and block numerator code `C`, the decoded block scale
is `(C + 1) * 2^E`. The encoder chooses the scale upward so every supported
finite input fits in `[-127, 127]`, and quantization rounds ties away from
zero. The exported `reference-*` functions remain the semantic oracles.

## Quantize and dequantize

Run this example from the repository root with the checkout's ASDF system:

```lisp
(require :asdf)
(asdf:load-asd
 (truename "packages/rational-quant/rational-quant.asd"))
(asdf:load-system "rational-quant")

(let ((input
        (make-array rational-quant:+block-size+
                    :element-type 'single-float
                    :initial-element 0.0f0)))
  (setf (aref input 0) -127.0f0
        (aref input (1- (length input))) 127.0f0)
  (let* ((tensor (rational-quant:quantize-rq8 input))
         (decoded (rational-quant:dequantize-rq8 tensor)))
    (list tensor decoded)))
```

`quantize-rq8` returns a fresh `rq8-tensor`; `dequantize-rq8` returns a fresh
simple `single-float` array. Neither operation mutates its input.

## Serialization boundary

An `rq8-tensor` is an in-memory Common Lisp value, not a stable byte
serialization. This release defines no file format, wire format, byte order,
object layout, version marker, or cross-version compatibility contract.
`rq8-storage-bytes` reports the logical byte count of the three RQ8 payload
arrays; it does not serialize a tensor and does not include Lisp object
overhead.

Do not persist or transmit raw tensor storage as a public format. A future,
separately specified stable byte serializer may introduce an RQ8 codec.

## Supported domain

`quantize-rq8` specializes a non-empty simple one-dimensional
`single-float` array whose length is a multiple of 32 and is safe for native
byte offsets. Every value must be finite. Every nonzero block's required
scale must be a positive normal IEEE-754 binary32 value, and each selected
group exponent must be in `[-126, 119]`. Use `rq8-supported-input-p` at an
unproven call boundary.

`dequantize-rq8` accepts tensors with the exact RQ8 block/group shape.
`matvec-rq8` uses its typed path when rows are nonnegative, columns are a
positive multiple of 32, the element count is a fixnum, and vector/tensor
shapes match. Other shape-compatible widths use the reference fallback;
malformed requests signal an error.

Nonfinite values, empty or partial blocks, subnormal or underflowed block
scales, out-of-range group exponents, malformed tensors, and mismatched
matrix/vector shapes are outside the specialized domain. This package makes
no portability or performance claim: it deliberately uses `SB-KERNEL` for
binary32 inspection and `SB-SYS` for pinned storage access.

## Verification

```sh
SBCL_BIN=/absolute/path/to/sbcl python3 tests/rational-quant/run.py
```

The checkout-path-independent ASDF `test-op` uses the same suite:

```sh
SBCL_BIN=/absolute/path/to/sbcl \
  python3 tests/rational-quant/run.py --asdf-test-op
```

The deterministic suite covers exact power-of-two scaling, zero and
multi-group inputs, nonfinite and subnormal rejection, bit-exact agreement
with all three reference kernels, explicit input/tensor/vector nonmutation,
matvec fallback, storage accounting, and the prohibition on `(safety 0)`.
Both modes constrain fresh compilation with SBCL's safety-3 policy restriction,
reject warning or serious-condition diagnostics, and report no performance
result. ASDF outputs are isolated in a temporary directory outside the checkout.
