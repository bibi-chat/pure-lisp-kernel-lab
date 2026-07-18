(in-package #:compile-pure-lisp.harness)

;; Redefines a worker function from a different source file. This is not the
;; harmless same-file redefinition SBCL emits when a COMPILE-TOPLEVEL helper is
;; loaded from its own FASL, so the warning gate must observe it.
(defun bounded-prin1 (value)
  (let ((*print-circle* t))
    (prin1-to-string value)))
