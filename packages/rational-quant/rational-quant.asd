(asdf:defsystem #:rational-quant
  :description "Typed shared-denominator rational quantization kernels for SBCL."
  :author "pure-lisp-kernel-lab contributors"
  :license "Apache-2.0"
  :version "0.1.0"
  :serial t
  :in-order-to ((test-op (test-op "rational-quant/tests")))
  :components ((:file "package")
               (:file "core")))

(asdf:defsystem #:rational-quant/tests
  :description "Deterministic semantic tests for rational-quant."
  :author "pure-lisp-kernel-lab contributors"
  :license "Apache-2.0"
  :depends-on (#:rational-quant)
  :pathname "../../tests/rational-quant/"
  :serial t
  :components ((:file "tests"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call "RATIONAL-QUANT-TESTS" "RUN-TESTS")))
