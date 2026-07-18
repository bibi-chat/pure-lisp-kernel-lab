(require :asdf)

(defparameter *rq8-test-directory*
  (uiop:pathname-directory-pathname *load-truename*))

(defparameter *rq8-project-root*
  (uiop:ensure-directory-pathname
   (truename (merge-pathnames "../../" *rq8-test-directory*))))

(defun rq8-path (relative)
  (merge-pathnames relative *rq8-project-root*))

(defvar *rq8-gate-conditions* nil)

(defun record-rq8-gate-condition (kind condition)
  (push (list kind condition) *rq8-gate-conditions*)
  (format *error-output* "RQ8_~A: ~A~%" kind condition))

(defun rq8-safety-three-p ()
  (let ((entry (assoc 'safety (sb-ext:restrict-compiler-policy))))
    (and entry (= (cdr entry) 3))))

(defun run-rq8-direct-gate ()
  (asdf:load-asd (rq8-path "packages/rational-quant/rational-quant.asd"))
  (load (rq8-path "packages/rational-quant/package.lisp"))
  (load (rq8-path "packages/rational-quant/core.lisp"))
  (load (rq8-path "tests/rational-quant/tests.lisp"))
  (uiop:symbol-call "RATIONAL-QUANT-TESTS" "RUN-TESTS"))

(defun run-rq8-asdf-gate ()
  (asdf:load-asd (rq8-path "packages/rational-quant/rational-quant.asd"))
  (asdf:test-system "rational-quant"))

(let ((mode (or (uiop:getenv "RQ8_TEST_MODE") "direct")))
  (unless (member mode '("direct" "asdf") :test #'string=)
    (error "Unsupported RQ8_TEST_MODE ~S." mode))
  (sb-ext:restrict-compiler-policy 'safety 3 3)
  (unless (rq8-safety-three-p)
    (error "SBCL did not establish the safety-3 compiler restriction."))
  (format t "RQ8_POLICY {\"safety_minimum\":3,\"mode\":\"~A\"}~%" mode)
  (let ((*rq8-gate-conditions* nil))
    ;; ASDF handles benign compile/load redefinition warnings internally.
    ;; The Python boundary rejects any WARNING text that actually escapes.
    (handler-bind
        ((serious-condition
           (lambda (condition)
             (record-rq8-gate-condition "SERIOUS-CONDITION" condition))))
      (if (string= mode "direct")
          (run-rq8-direct-gate)
          (run-rq8-asdf-gate)))
    (when *rq8-gate-conditions*
      (error "RQ8 gate observed ~D rejected condition~:P."
             (length *rq8-gate-conditions*)))))
