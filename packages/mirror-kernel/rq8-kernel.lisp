(defpackage #:mirror-kernel.rq8
  (:use #:cl)
  (:export #:matvec-rq8 #:matvec-plan-certificate))

(in-package #:mirror-kernel.rq8)

(mirror-kernel:define-rq8-matvec-kernel matvec-rq8
  (:columns 2048
   :block-size 32
   :blocks-per-group 64
   :reduction-order :left-to-right-single-float
   :target :sbcl-typed-common-lisp/v0
   :fallback rational-quant:matvec-rq8))

(defparameter +matvec-compilation+
  (mirror-kernel:compile-rq8-matvec
   '(matvec-rq8
     (:columns 2048
      :block-size 32
      :blocks-per-group 64
      :reduction-order :left-to-right-single-float
      :target :sbcl-typed-common-lisp/v0
      :fallback rational-quant:matvec-rq8))))

(defun matvec-plan-certificate (request)
  (declare (ignore request))
  (copy-tree
   (mirror-kernel:compilation-result-certificate +matvec-compilation+)))
