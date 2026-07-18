(defpackage #:compile-pure-lisp.egraph.tests
  (:use #:cl)
  (:import-from #:compile-pure-lisp.egraph
                #:define-egraph-kernel
                #:egraph-request-error
                #:optimization-result-application-count
                #:optimization-result-cost
                #:optimization-result-form
                #:optimization-result-inferred-range
                #:optimization-result-node-count
                #:optimization-result-original-cost
                #:optimization-result-status
                #:optimize-egraph-expression)
  (:export #:run-tests))

(in-package #:compile-pure-lisp.egraph.tests)

(define-egraph-kernel generated-identity-kernel
    ((input integer) integer)
    (:theory :exact-integer :round-limit 8 :node-limit 512)
  (+ (* input 1) 0))

(defun base-request (expression)
  (list :expression expression
        :variables '((x integer) (y integer) (z integer))
        :result-type 'integer
        :theory :exact-integer
        :round-limit 8
        :node-limit 512))

(defun evaluate-form (request)
  (destructuring-bind (form environment) request
    (cond
      ((integerp form) form)
      ((symbolp form) (cdr (assoc form environment :test #'eq)))
      ((eq (first form) 'cl:+)
       (+ (evaluate-form (list (second form) environment))
          (evaluate-form (list (third form) environment))))
      ((eq (first form) 'cl:*)
       (* (evaluate-form (list (second form) environment))
          (evaluate-form (list (third form) environment))))
      (t (error "Unsupported test form ~S" form)))))

(defun request-error-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (egraph-request-error () t)))

(defun any-error-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (error () t)))

(defun compiler-failure-p (form)
  (let ((sink (make-broadcast-stream)))
    (let ((*standard-output* sink)
          (*error-output* sink)
          (*trace-output* sink)
          (*compile-verbose* nil)
          (*compile-print* nil))
      (multiple-value-bind (function warnings-p failure-p)
          (compile nil form)
        (declare (ignore function warnings-p))
        failure-p))))

(defun check (request)
  (destructuring-bind (condition control &rest arguments) request
    (unless condition
      (error (apply #'format nil control arguments)))
    t))

(defun test-identities ()
  (let ((result
          (optimize-egraph-expression
           (base-request '(+ (* x 1) (+ 0 y))))))
    (check (list (eq (optimization-result-status result) :optimized)
                 "Identity expression was not optimized: ~S"
                 (optimization-result-status result)))
    (check (list (equal (optimization-result-form result) '(+ x y))
                 "Unexpected identity extraction ~S"
                 (optimization-result-form result)))
    (check (list (< (optimization-result-cost result)
                    (optimization-result-original-cost result))
                 "Identity extraction did not reduce static cost"))
    (check (list (plusp (optimization-result-application-count result))
                 "No rewrite application was recorded"))
    (check (list (<= (optimization-result-node-count result) 512)
                 "Node limit was exceeded")))
  (dolist (expression '((* x 0) (* 0 x)))
    (let ((result (optimize-egraph-expression (base-request expression))))
      (check
       (list (eq (optimization-result-status result) :optimized)
             "Zero absorption did not optimize ~S: ~S"
             expression (optimization-result-status result)))
      (check
       (list (eql (optimization-result-form result) 0)
             "Zero absorption returned ~S for ~S"
             (optimization-result-form result) expression)))))

(defun test-factoring-and-semantics ()
  (let* ((expression '(+ (* x y) (* x z)))
         (result (optimize-egraph-expression (base-request expression)))
         (form (optimization-result-form result))
         (values
           (list
            (list (cons 'x -3) (cons 'y -2) (cons 'z 1))
            (list (cons 'x 0) (cons 'y most-positive-fixnum)
                  (cons 'z most-negative-fixnum))
            (list (cons 'x (1+ most-positive-fixnum))
                  (cons 'y 2) (cons 'z -5))
            (list (cons 'x (1- most-negative-fixnum))
                  (cons 'y -7) (cons 'z 11)))))
    (check (list (eq (optimization-result-status result) :optimized)
                 "Factor expression was not optimized: ~S"
                 (optimization-result-status result)))
    (check (list (< (optimization-result-cost result)
                    (optimization-result-original-cost result))
                 "Factoring did not reduce static cost"))
    (dolist (environment values)
      (check
       (list (= (evaluate-form (list expression environment))
                (evaluate-form (list form environment)))
             "Factored form differs for ~S: ~S"
             environment form)))))

(defun test-determinism-and-immutability ()
  (let* ((request (base-request '(+ (* x y) (* x z))))
         (before (copy-tree request))
         (first (optimize-egraph-expression request))
         (second (optimize-egraph-expression request)))
    (check (list (equal request before) "Optimizer mutated its request"))
    (check
     (list (equal (optimization-result-form first)
                  (optimization-result-form second))
           "Repeated extraction was nondeterministic: ~S vs ~S"
           (optimization-result-form first)
           (optimization-result-form second)))
    (check
     (list (= (optimization-result-node-count first)
              (optimization-result-node-count second))
           "Repeated saturation changed node count"))))

(defun test-range-analysis ()
  (let* ((request
           '(:expression (+ (* x y) (* x z))
             :variables ((x (integer -5 10))
                         (y (integer 2 3))
                         (z (integer 4 6)))
             :result-type integer
             :theory :exact-integer
             :round-limit 8
             :node-limit 512))
         (result (optimize-egraph-expression request)))
    (check
     (list (equal (optimization-result-inferred-range result) '(-45 90))
           "Unexpected inferred range ~S"
           (optimization-result-inferred-range result)))))

(defun test-fail-closed-grammar ()
  (let ((invalid-expressions
          (list
           '(random 10)
           '(progn x y)
           '(setf x 1)
           '(- x y)
           '(/ 1 0)
           '(+ x y z)
           '(+ x)
           '(+ x 0.0d0)
           '(+ x 1/2)
           '(+ x #c(1 2))
           '(+ x #\a)
           (list (make-symbol "+") 'x 0)
           '(* 0 (/ 1 0)))))
    (dolist (expression invalid-expressions)
      (check
       (list (request-error-p
              (lambda ()
                (optimize-egraph-expression (base-request expression))))
             "Unsafe expression was accepted: ~S"
             expression)))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression (+ x 0)
                 :variables ((x double-float))
                 :result-type double-float))))
           "Floating-point theory was accepted"))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression (+ x 0)
                 :variables ((x integer))
                 :result-type integer
                 :theory :unknown))))
           "Unknown theory was accepted"))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression (+ x 0)
                 :variables ((x integer))
                 :result-type integer
                 :unknown-option t))))
           "Unknown option was accepted"))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression (+ x 0)
                 :variables ((x integer))
                 :result-type integer
                 :round-limit 8
                 :round-limit 8))))
           "Duplicate option was accepted"))
    (let ((uninterned (make-symbol "X")))
      (check
       (list (request-error-p
              (lambda ()
                (optimize-egraph-expression
                 (list :expression uninterned
                       :variables (list (list uninterned 'integer))
                       :result-type 'integer))))
             "Uninterned variable was accepted")))))

(defun test-result-range-proof ()
  (let ((accepted
          (optimize-egraph-expression
           '(:expression (+ x y)
             :variables ((x (integer 0 10)) (y (integer 0 20)))
             :result-type (integer 0 30)))))
    (check
     (list (equal (optimization-result-inferred-range accepted) '(0 30))
           "Bounded result proof was not retained")))
  (check
   (list (request-error-p
          (lambda ()
            (optimize-egraph-expression
             '(:expression x
               :variables ((x integer))
               :result-type fixnum))))
         "Unbounded result was accepted as FIXNUM"))
  (check
   (list (request-error-p
          (lambda ()
            (optimize-egraph-expression
             '(:expression (+ x y)
               :variables ((x (integer 0 10)) (y (integer 0 20)))
               :result-type (integer 0 29)))))
         "Too-narrow result type was accepted")))

(defun test-constant-bit-limit ()
  (let ((large (ash 1 4096))
        (fold-result
          (optimize-egraph-expression
           (base-request
            (list '* (ash 1 3000) (ash 1 3000))))))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression (base-request large))))
           "Oversized integer literal was accepted"))
    (check
     (list (eq (optimization-result-status fold-result) :limit)
           "Oversized constant fold did not fail at a resource limit"))
    (check
     (list (null (optimization-result-form fold-result))
           "Oversized constant fold exposed a partial form"))))

(defun test-shared-and-circular-graphs ()
  (let ((shared 'x))
    (loop repeat 28
          do (setf shared (list '+ shared shared)))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression (base-request shared))))
           "Shared expression graph was accepted")))
  (let ((circular (list '+ 'x nil)))
    (setf (third circular) circular)
    (handler-case
        (progn
          (optimize-egraph-expression (base-request circular))
          (error "Circular expression graph was accepted"))
      (egraph-request-error (condition)
        (let ((message (princ-to-string condition)))
          (check
           (list (< (length message) 4200)
                 "Circular diagnostic was not bounded: ~D characters"
                 (length message))))))))

(defun test-limits ()
  (let ((round-result
          (optimize-egraph-expression
           '(:expression (+ x 0)
             :variables ((x integer))
             :result-type integer
             :round-limit 1
             :node-limit 512)))
        (node-result
          (optimize-egraph-expression
           '(:expression (+ x y)
             :variables ((x integer) (y integer))
             :result-type integer
             :round-limit 8
             :node-limit 1))))
    (check (list (eq (optimization-result-status round-result) :limit)
                 "Round limit did not fail closed"))
    (check (list (null (optimization-result-form round-result))
                 "Round-limit result exposed a partial form"))
    (check (list (eq (optimization-result-status node-result) :limit)
                 "Node limit did not fail closed"))
    (check (list (null (optimization-result-form node-result))
                 "Node-limit result exposed a partial form"))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression x :variables ((x integer))
                 :result-type integer :round-limit 9))))
           "Hard round maximum was not enforced"))
    (check
     (list (request-error-p
            (lambda ()
              (optimize-egraph-expression
               '(:expression x :variables ((x integer))
                 :result-type integer :node-limit 513))))
           "Hard node maximum was not enforced"))))

(defun test-macro-and-generated-kernel ()
  (let ((large (1+ most-positive-fixnum)))
    (check (list (= (generated-identity-kernel large) large)
                 "Generated kernel changed a bignum")))
  (check
   (list (compiler-failure-p
          '(lambda (x)
             (compile-pure-lisp.egraph:egraph-expression
                 ((x integer)) integer
                 (:round-limit 1 :node-limit 512)
               (+ x 0))))
         "Macro emitted a partial result after a round limit")))

(defun test-macro-requires-lexical-variables ()
  (check
   (list (compiler-failure-p
          '(lambda (y z)
             (symbol-macrolet
                 ((x (progn (error "must not run") 3)))
               (compile-pure-lisp.egraph:egraph-expression
                   ((x integer) (y integer) (z integer))
                   integer
                   (:theory :exact-integer)
                 (+ (* x y) (* x z))))))
         "Effectful SYMBOL-MACROLET variable was accepted"))
  (check
   (list (compiler-failure-p
          '(lambda (x)
             (declare (special x))
             (compile-pure-lisp.egraph:egraph-expression
                 ((x integer)) integer
                 (:theory :exact-integer)
               (+ x 0))))
         "Special variable was accepted")))

(defun test-macro-requires-standard-arithmetic-bindings ()
  (unwind-protect
       (progn
         (sb-ext:unlock-package :cl)
         (check
          (list
           (compiler-failure-p
            '(lambda (x)
               (flet ((cl:+ (left right) (- left right)))
                 (compile-pure-lisp.egraph:egraph-expression
                     ((x integer)) integer
                     (:theory :exact-integer)
                   (+ 0 x)))))
           "Local CL:+ function binding was accepted")))
    (sb-ext:lock-package :cl)))

(defun test-macro-rejects-circular-variables ()
  (let ((variables (list (list 'x 'integer))))
    (setf (cdr variables) variables)
    (check
     (list
      (request-error-p
       (lambda ()
         (macroexpand-1
          (list 'compile-pure-lisp.egraph:egraph-expression
                variables 'integer '(:theory :exact-integer) '(+ x 0)))))
      "Circular macro variable declarations were accepted")))
  (let ((options (list :theory)))
    (setf (cdr options) options)
    (check
     (list
      (request-error-p
       (lambda ()
         (macroexpand-1
          (list 'compile-pure-lisp.egraph:egraph-expression
                '((x integer)) 'integer options '(+ x 0)))))
      "Circular EGRAPH-EXPRESSION options were accepted")))
  (let ((signature (list '(x integer) 'integer)))
    (setf (cdr signature) signature)
    (check
     (list
      (request-error-p
       (lambda ()
         (macroexpand-1
          (list 'compile-pure-lisp.egraph:define-egraph-kernel
                'circular-kernel signature '(:theory :exact-integer)
                '(+ x 0)))))
      "Circular DEFINE-EGRAPH-KERNEL signature was accepted"))))

(defun run-tests ()
  (let ((tests
          (list #'test-identities
                #'test-factoring-and-semantics
                #'test-determinism-and-immutability
                #'test-range-analysis
                #'test-fail-closed-grammar
                #'test-result-range-proof
                #'test-constant-bit-limit
                #'test-shared-and-circular-graphs
                #'test-limits
                #'test-macro-and-generated-kernel
                #'test-macro-requires-lexical-variables
                #'test-macro-requires-standard-arithmetic-bindings
                #'test-macro-rejects-circular-variables)))
    (dolist (test tests)
      (funcall test))
    (format t "~&lawful e-graph tests passed: ~D~%" (length tests))
    t))
