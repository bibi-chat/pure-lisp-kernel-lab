(defpackage #:rational-quant-tests
  (:use #:cl)
  (:export #:run-tests)
  (:import-from #:rational-quant
                #:+block-size+ #:+blocks-per-group+ #:rq8-tensor
                #:rq8-tensor-exponents #:rq8-tensor-numerators
                #:rq8-tensor-quants #:rq8-storage-bytes
                #:rq8-supported-input-p #:reference-quantize-rq8
                #:quantize-rq8 #:reference-dequantize-rq8 #:dequantize-rq8
                #:reference-matvec-rq8 #:matvec-rq8))

(in-package #:rational-quant-tests)

(defvar *check-count* 0)

(defmacro check (condition &optional (label nil label-p))
  `(progn
     (incf *check-count*)
     (unless ,condition
       (error "Check failed~@[ (~A)~]: ~S"
              ,(if label-p label nil)
              ',condition))))

(defun signals-error-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defun same-float-bits-p (left right)
  (= (sb-kernel:single-float-bits left)
     (sb-kernel:single-float-bits right)))

(defun same-float-vector-p (left right)
  (and (= (length left) (length right))
       (loop for index below (length left)
             always (same-float-bits-p (aref left index)
                                       (aref right index)))))

(defun float-vector-snapshot (vector)
  (loop for value across vector
        collect (sb-kernel:single-float-bits value)))

(defun same-tensor-p (left right)
  (and (typep left 'rq8-tensor)
       (typep right 'rq8-tensor)
       (equalp (rq8-tensor-exponents left)
               (rq8-tensor-exponents right))
       (equalp (rq8-tensor-numerators left)
               (rq8-tensor-numerators right))
       (equalp (rq8-tensor-quants left)
               (rq8-tensor-quants right))))

(defun tensor-snapshot (tensor)
  (list (copy-seq (rq8-tensor-exponents tensor))
        (copy-seq (rq8-tensor-numerators tensor))
        (copy-seq (rq8-tensor-quants tensor))))

(defun tensor-matches-snapshot-p (tensor snapshot)
  (destructuring-bind (exponents numerators quants) snapshot
    (and (equalp (rq8-tensor-exponents tensor) exponents)
         (equalp (rq8-tensor-numerators tensor) numerators)
         (equalp (rq8-tensor-quants tensor) quants))))

(defun make-single-vector (count function)
  (let ((result (make-array count :element-type 'single-float)))
    (dotimes (index count result)
      (setf (aref result index)
            (coerce (funcall function index) 'single-float)))))

(defun make-deterministic-input (count)
  (make-single-vector
   count
   (lambda (index)
     (if (zerop (mod index 19))
         0
         (/ (- (mod (+ (* index 37) 11) 251) 125) 8)))))

(defun make-exact-scale-input ()
  (let ((result
          (make-single-vector +block-size+ (lambda (index) (- index 16)))))
    (setf (aref result 0) -127.0f0
          (aref result (1- +block-size+)) 127.0f0)
    result))

(defun test-system-contract ()
  (let ((system (asdf:find-system "rational-quant" nil)))
    (check system "registered ASDF system")
    (check (string= (asdf:component-version system) "0.1.0")
           "ASDF version")
    (check (string= (asdf:system-author system)
                    "pure-lisp-kernel-lab contributors")
           "ASDF author")
    (check (string= (asdf:system-license system) "Apache-2.0")
           "ASDF license"))
  (check (asdf:find-system "rational-quant/tests" nil)
         "registered ASDF test system")
  (check (string= (lisp-implementation-type) "SBCL")
         "SBCL-only claim boundary")
  (let ((restriction
          (assoc 'safety (sb-ext:restrict-compiler-policy))))
    (check (and restriction (= (cdr restriction) 3))
           "active safety-3 compiler restriction"))
  (check (= +block-size+ 32) "RQ8 block size")
  (check (= +blocks-per-group+ 64) "RQ8 group size"))

(defun test-exact-power-of-two-scale ()
  (let* ((input (make-exact-scale-input))
         (reference (reference-quantize-rq8 input))
         (candidate (quantize-rq8 input))
         (decoded-reference (reference-dequantize-rq8 reference))
         (decoded-candidate (dequantize-rq8 candidate)))
    (check (rq8-supported-input-p input) "exact scale supported")
    (check (same-tensor-p reference candidate) "exact-scale oracle equality")
    (check (equalp (rq8-tensor-exponents candidate) #(-8))
           "exact exponent")
    (check (equalp (rq8-tensor-numerators candidate) #(255))
           "exact numerator")
    (check (= (rq8-storage-bytes candidate) 34) "storage accounting")
    (check (same-float-vector-p decoded-reference decoded-candidate)
           "exact-scale decode oracle equality")
    (check (same-float-vector-p input decoded-candidate)
           "unit-scale round trip")))

(defun test-zero-block ()
  (let* ((input (make-array +block-size+ :element-type 'single-float
                            :initial-element 0.0f0))
         (reference (reference-quantize-rq8 input))
         (candidate (quantize-rq8 input)))
    (check (rq8-supported-input-p input) "zero block supported")
    (check (same-tensor-p reference candidate) "zero block oracle equality")
    (check (equalp (rq8-tensor-exponents candidate) #(0))
           "zero exponent")
    (check (equalp (rq8-tensor-numerators candidate) #(0))
           "zero numerator")
    (check (every #'zerop (rq8-tensor-quants candidate)) "zero quants")))

(defun test-differential-fixtures ()
  (dolist (count '(32 64 2048 2080))
    (let* ((input (make-deterministic-input count))
           (reference (reference-quantize-rq8 input))
           (candidate (quantize-rq8 input)))
      (check (rq8-supported-input-p input)
             (format nil "supported fixture ~D" count))
      (check (same-tensor-p reference candidate)
             (format nil "quantize oracle equality ~D" count))
      (check (same-float-vector-p (reference-dequantize-rq8 reference)
                                  (dequantize-rq8 candidate))
             (format nil "dequantize oracle equality ~D" count)))))

(defun test-unsupported-inputs ()
  (let ((empty (make-array 0 :element-type 'single-float))
        (partial (make-array 31 :element-type 'single-float
                            :initial-element 1.0f0))
        (wrong-type (make-array 32 :element-type 'double-float
                               :initial-element 1.0d0)))
    (check (not (rq8-supported-input-p empty)) "empty input")
    (check (not (rq8-supported-input-p partial)) "partial block")
    (check (not (rq8-supported-input-p wrong-type)) "wrong element type")
    (check (signals-error-p (lambda () (reference-quantize-rq8 partial)))
           "reference partial rejection")
    (check (signals-error-p (lambda () (quantize-rq8 partial)))
           "candidate partial rejection"))
  (dolist (bits '(#x7fc00000 #x7f800000 #xff800000))
    (let ((input (make-array +block-size+ :element-type 'single-float
                             :initial-element 0.0f0)))
      (setf (aref input 0)
            (sb-kernel:make-single-float
             (if (logbitp 31 bits) (- bits #x100000000) bits)))
      (check (not (rq8-supported-input-p input))
             (format nil "nonfinite unsupported ~8,'0X" bits))
      (check (signals-error-p (lambda () (reference-quantize-rq8 input)))
             (format nil "reference nonfinite rejection ~8,'0X" bits))
      (check (signals-error-p (lambda () (quantize-rq8 input)))
             (format nil "candidate nonfinite rejection ~8,'0X" bits))))
  (let ((input (make-array +block-size+ :element-type 'single-float
                           :initial-element 0.0f0)))
    (setf (aref input 0) (sb-kernel:make-single-float 1))
    (check (not (rq8-supported-input-p input)) "subnormal unsupported")
    (check (signals-error-p (lambda () (reference-quantize-rq8 input)))
           "reference subnormal rejection")
    (check (signals-error-p (lambda () (quantize-rq8 input)))
           "candidate subnormal rejection")))

(defun test-matvec ()
  (let* ((rows 2) (columns 32)
         (tensor (quantize-rq8 (make-deterministic-input (* rows columns))))
         (vector (make-deterministic-input columns))
         (request (list tensor vector rows columns)))
    (check (same-float-vector-p (reference-matvec-rq8 request)
                                (matvec-rq8 request))
           "typed matvec oracle equality"))
  (let* ((rows 2) (columns 16)
         (tensor (quantize-rq8 (make-deterministic-input (* rows columns))))
         (vector (make-deterministic-input columns))
         (request (list tensor vector rows columns)))
    (check (same-float-vector-p (reference-matvec-rq8 request)
                                (matvec-rq8 request))
           "shape-compatible reference fallback")
    (check (signals-error-p
            (lambda ()
              (matvec-rq8
               (list tensor (make-deterministic-input (1- columns))
                     rows columns))))
           "mismatched vector rejection")))

(defun test-nonmutation ()
  (let* ((input (make-deterministic-input 64))
         (input-before (float-vector-snapshot input)))
    (rq8-supported-input-p input)
    (check (equal input-before (float-vector-snapshot input))
           "support predicate preserves input")
    (reference-quantize-rq8 input)
    (check (equal input-before (float-vector-snapshot input))
           "reference quantize preserves input")
    (quantize-rq8 input)
    (check (equal input-before (float-vector-snapshot input))
           "candidate quantize preserves input"))
  (let* ((rows 2)
         (columns 32)
         (tensor (quantize-rq8
                  (make-deterministic-input (* rows columns))))
         (vector (make-deterministic-input columns))
         (tensor-before (tensor-snapshot tensor))
         (vector-before (float-vector-snapshot vector))
         (request (list tensor vector rows columns)))
    (reference-dequantize-rq8 tensor)
    (check (tensor-matches-snapshot-p tensor tensor-before)
           "reference dequantize preserves tensor")
    (dequantize-rq8 tensor)
    (check (tensor-matches-snapshot-p tensor tensor-before)
           "candidate dequantize preserves tensor")
    (reference-matvec-rq8 request)
    (check (tensor-matches-snapshot-p tensor tensor-before)
           "reference matvec preserves tensor")
    (check (equal vector-before (float-vector-snapshot vector))
           "reference matvec preserves vector")
    (matvec-rq8 request)
    (check (tensor-matches-snapshot-p tensor tensor-before)
           "candidate matvec preserves tensor")
    (check (equal vector-before (float-vector-snapshot vector))
           "candidate matvec preserves vector")))

(defun run-tests ()
  (setf *check-count* 0)
  (test-system-contract)
  (test-exact-power-of-two-scale)
  (test-zero-block)
  (test-differential-fixtures)
  (test-unsupported-inputs)
  (test-matvec)
  (test-nonmutation)
  (format t
          "RQ8_TEST_RESULT {\"status\":\"passed\",\"implementation\":\"SBCL\",\"checks\":~D,\"performance_claim\":false}~%"
          *check-count*))
