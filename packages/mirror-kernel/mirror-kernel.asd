(asdf:defsystem #:mirror-kernel
  :description "Bounded semantic-graph to typed Common Lisp compiler experiment for SBCL."
  :author "pure-lisp-kernel-lab contributors"
  :license "Apache-2.0"
  :version "0.1.0"
  :depends-on (#:rational-quant)
  :serial t
  :in-order-to ((test-op (test-op "mirror-kernel/tests")))
  :components ((:file "compiler")
               (:file "rq8-kernel")))

(asdf:defsystem #:mirror-kernel/tests
  :description "Deterministic exact-cover and semantic tests for mirror-kernel."
  :author "pure-lisp-kernel-lab contributors"
  :license "Apache-2.0"
  :depends-on (#:mirror-kernel)
  :pathname "../../tests/mirror-kernel/"
  :serial t
  :components ((:file "tests"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call "MIRROR-KERNEL.TESTS" "RUN-TESTS" nil)))
