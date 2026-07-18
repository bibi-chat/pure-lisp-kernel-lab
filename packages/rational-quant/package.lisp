(defpackage #:rational-quant
  (:use #:cl)
  (:export
   #:+block-size+
   #:+blocks-per-group+
   #:rq8-tensor
   #:rq8-tensor-exponents
   #:rq8-tensor-numerators
   #:rq8-tensor-quants
   #:rq8-storage-bytes
   #:rq8-supported-input-p
   #:reference-quantize-rq8
   #:quantize-rq8
   #:reference-dequantize-rq8
   #:dequantize-rq8
   #:reference-matvec-rq8
   #:matvec-rq8))
