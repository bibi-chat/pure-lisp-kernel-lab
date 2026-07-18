(defpackage #:compile-pure-lisp.load-warning-compiler
  (:use #:cl))

(in-package #:compile-pure-lisp.load-warning-compiler)

;; Compile cleanly, then warn only when the FASL is loaded. The verifier test
;; proves that load-time warnings are included in the warning gate.
(eval-when (:load-toplevel)
  (warn "Intentional compile-pure-lisp load-warning fixture"))
