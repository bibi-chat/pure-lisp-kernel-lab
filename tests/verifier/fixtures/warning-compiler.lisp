(defpackage #:compile-pure-lisp.warning-compiler
  (:use #:cl))

(in-package #:compile-pure-lisp.warning-compiler)

;; Deliberately undefined: the verifier integration test requires one compiler
;; style warning and proves that the warning gate rejects the otherwise valid
;; identity case. Nothing calls this function.
(defun intentional-warning-probe (value)
  (missing-warning-probe value))
