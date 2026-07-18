(defpackage #:mirror-kernel.tests
  (:use #:cl)
  (:export #:run-tests))

(in-package #:mirror-kernel.tests)

(defvar *check-count* 0)

(defun check (request)
  (destructuring-bind (condition message) request
    (incf *check-count*)
    (unless condition
      (error "Mirror-kernel test failed: ~A" message))))

(defun canonical-options (request)
  (declare (ignore request))
  '(:columns 2048
    :block-size 32
    :blocks-per-group 64
    :reduction-order :left-to-right-single-float
    :target :sbcl-typed-common-lisp/v0
    :fallback nil))

(defun case-value (request)
  (destructuring-bind (seed index) request
    (let* ((block (truncate index 32))
           (position (mod index 32))
           (power (- (mod (+ (* seed 37) (* block 19)) 20) 16))
           (scale (scale-float 1.0f0 power))
           (quant
             (if (zerop position)
                 (if (oddp (+ seed block)) -127 127)
                 (- (mod (+ seed (* block 17) (* position 31)) 253) 126))))
      (* (coerce quant 'single-float) scale))))

(defun case-array (request)
  (destructuring-bind (seed size) request
    (let ((values (make-array size :element-type 'single-float)))
      (dotimes (index size values)
        (setf (aref values index) (case-value (list seed index)))))))

(defun case-vector (request)
  (destructuring-bind (seed columns) request
    (let ((values (make-array columns :element-type 'single-float)))
      (dotimes (index columns values)
        (setf (aref values index)
              (coerce (/ (- (mod (+ seed (* index 13)) 17) 8) 8)
                      'single-float))))))

(defun case-request (request)
  (destructuring-bind (seed rows columns) request
    (list
     (rational-quant:reference-quantize-rq8
      (case-array (list seed (* rows columns))))
     (case-vector (list seed columns))
     rows
     columns)))

(defun float-vector-bits= (request)
  (destructuring-bind (left right) request
    (and (= (length left) (length right))
         (loop for index below (length left)
               always (= (sb-kernel:single-float-bits (aref left index))
                         (sb-kernel:single-float-bits (aref right index)))))))

(defun tree-contains-p (request)
  (destructuring-bind (needle tree) request
    (cond
      ((equal needle tree) t)
      ((consp tree)
       (or (tree-contains-p (list needle (car tree)))
           (tree-contains-p (list needle (cdr tree)))))
      (t nil))))

(defun printed-form (form)
  (with-standard-io-syntax
    (let ((*print-readably* t)
          (*print-pretty* nil))
      (write-to-string form))))

(defun signals-error-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (error () t)))

(mirror-kernel:define-rq8-matvec-kernel generated-matvec-rq8
  (:columns 2048
   :block-size 32
   :blocks-per-group 64
   :reduction-order :left-to-right-single-float
   :target :sbcl-typed-common-lisp/v0
   :fallback nil))

(defun test-system-contract (request)
  (declare (ignore request))
  (let ((system (asdf:find-system "mirror-kernel" nil)))
    (check (list system "mirror-kernel ASDF system is missing"))
    (check (list (string= (asdf:component-version system) "0.1.0")
                 "mirror-kernel ASDF version changed"))
    (check (list (string= (asdf:system-author system)
                          "pure-lisp-kernel-lab contributors")
                 "mirror-kernel ASDF author changed"))
    (check (list (string= (asdf:system-license system) "Apache-2.0")
                 "mirror-kernel ASDF license changed")))
  (check (list (asdf:find-system "mirror-kernel/tests" nil)
               "mirror-kernel test system is missing")))

(defun test-graph-and-target-determinism (request)
  (declare (ignore request))
  (let* ((options (canonical-options nil))
         (graph-one (mirror-kernel:make-rq8-matvec-graph options))
         (graph-two (mirror-kernel:make-rq8-matvec-graph options))
         (target-one (mirror-kernel:make-sbcl-scalar-target options))
         (target-two (mirror-kernel:make-sbcl-scalar-target options)))
    (check (list (equalp graph-one graph-two)
                 "semantic graph construction is not deterministic"))
    (check (list (equalp target-one target-two)
                 "machine target construction is not deterministic"))
    (check
     (list
      (equal
       (mapcar #'mirror-kernel:mirror-node-id
               (mirror-kernel:semantic-graph-nodes graph-one))
       (mapcar #'mirror-kernel:mirror-node-id
               (mirror-kernel:semantic-graph-nodes graph-two)))
      "semantic node order changed"))))

(defun test-exact-cover (request)
  (declare (ignore request))
  (let* ((options (canonical-options nil))
         (graph (mirror-kernel:make-rq8-matvec-graph options))
         (target (mirror-kernel:make-sbcl-scalar-target options))
         (cover (mirror-kernel:cover-semantic-graph (list graph target)))
         (semantic-ids
           (mapcar #'mirror-kernel:mirror-node-id
                   (mirror-kernel:semantic-graph-nodes graph)))
         (covered-ids
           (mapcar #'mirror-kernel:cover-entry-node-id
                   (mirror-kernel:cover-result-entries cover))))
    (check (list (eq (mirror-kernel:cover-result-status cover) :covered)
                 "the complete target did not cover the graph"))
    (check (list (= (length semantic-ids) 24)
                 "the bounded semantic graph is not exactly 24 nodes"))
    (check (list (equal semantic-ids covered-ids)
                 "cover is not total and topological"))
    (check (list (= (length covered-ids)
                    (length (remove-duplicates covered-ids :test #'eq)))
                 "a semantic node was covered more than once"))
    (check (list (equal semantic-ids
                        (mirror-kernel:cover-result-schedule cover))
                 "schedule differs from dependency order"))))

(defun test-cover-fails-closed (request)
  (declare (ignore request))
  (let* ((options (canonical-options nil))
         (graph (mirror-kernel:make-rq8-matvec-graph options))
         (target
           (mirror-kernel:make-sbcl-scalar-target
            '(:disabled-patterns (:ordered-f32-fold))))
         (cover (mirror-kernel:cover-semantic-graph (list graph target))))
    (check (list (eq (mirror-kernel:cover-result-status cover) :unsupported)
                 "an incomplete target was accepted"))
    (check (list (member :total
                         (mirror-kernel:cover-result-uncovered cover)
                         :test #'eq)
                 "the missing ordered fold was not reported"))
    (check (list (null (mirror-kernel:cover-result-entries cover))
                 "an unsupported cover retained partial entries"))
    (check (list (null (mirror-kernel:cover-result-schedule cover))
                 "an unsupported cover retained a partial schedule"))))

(defun test-emission-is-stable (request)
  (declare (ignore request))
  (let* ((options (canonical-options nil))
         (first
           (mirror-kernel:compile-rq8-matvec
            (list 'stable-candidate options))))
    (loop repeat 100 do (gensym))
    (let* ((second
             (mirror-kernel:compile-rq8-matvec
              (list 'stable-candidate options)))
           (first-form (mirror-kernel:compilation-result-form first))
           (second-form (mirror-kernel:compilation-result-form second))
           (printed (printed-form first-form)))
      (check (list (eq (mirror-kernel:compilation-result-status first)
                       :compiled)
                   "supported graph did not compile"))
      (check (list (equal first-form second-form)
                   "emitted form depends on global gensym state"))
      (check (list (string= printed (printed-form second-form))
                   "printed emission is not byte-stable"))
      (check (list (equal first-form (read-from-string printed))
                   "emitted form is not readably round-trippable"))
      (check (list (not (tree-contains-p (list '(safety 0) first-form)))
                   "emitted form contains SAFETY 0")))))

(defun test-unsupported-compilation (request)
  (declare (ignore request))
  (let ((result
          (mirror-kernel:compile-rq8-matvec
           '(unsupported-candidate
             (:columns 64
              :block-size 32
              :blocks-per-group 64
              :reduction-order :left-to-right-single-float
              :fallback nil)))))
    (check (list (eq (mirror-kernel:compilation-result-status result)
                     :unsupported)
                 "a non-batch shape compiled"))
    (check (list (null (mirror-kernel:compilation-result-form result))
                 "unsupported compilation emitted source"))
    (check (list (null (mirror-kernel:compilation-result-certificate result))
                 "unsupported compilation emitted a certificate"))))

(defun test-option-and-certificate-contract (request)
  (declare (ignore request))
  (check
   (list
    (signals-error-p
     (lambda ()
       (mirror-kernel:compile-rq8-matvec
        '(invalid-fallback (:fallback 42)))))
    "a non-symbol fallback was accepted"))
  (let* ((result
           (mirror-kernel:compile-rq8-matvec
            (list 'certificate-candidate (canonical-options nil))))
         (certificate
           (mirror-kernel:compilation-result-certificate result))
         (domain (getf certificate :domain))
         (rows (getf domain :rows)))
    (check (list (eq (getf certificate :batch-emitter)
                     :rq8-one-group-per-row)
                 "certificate omitted the selected batch emitter"))
    (check (list (equal (getf domain :exponent-inclusive-range)
                        '(-126 119))
                 "certificate omitted the exponent guard"))
    (check (list (equal (getf rows :inclusive-range)
                        (list 1 most-positive-fixnum))
                 "certificate rows bound is not numeric"))
    (check (list (equal (getf domain :tensor-lengths)
                        '(:quants (:rows-times 2048)
                          :numerators (:rows-times 64)
                          :exponents :rows))
                 "certificate omitted the tensor length guards"))
    (check (list (null (getf certificate :performance-claim))
                 "certificate asserted an unsupported performance claim"))))

(defun test-semantic-equivalence (request)
  (declare (ignore request))
  (dolist (configuration '((1 1 2048) (41 2 2048) (20260715 3 2048)))
    (let* ((input (case-request configuration))
           (reference (rational-quant:reference-matvec-rq8 input))
           (candidate (generated-matvec-rq8 input)))
      (check
       (list (float-vector-bits= (list reference candidate))
             (format nil "generated kernel differs for ~S" configuration)))))
  (let* ((matrix (make-array 2048 :element-type 'single-float
                             :initial-element 0.0f0))
         (vector (make-array 2048 :element-type 'single-float
                             :initial-element 0.0f0)))
    (setf (aref matrix 0) 1.0f0
          (aref matrix 1) 1.0f0
          (aref matrix 2) 1.0f0
          (aref vector 0) 1.0e20
          (aref vector 1) 1.0f0
          (aref vector 2) -1.0e20)
    (let* ((input
             (list (rational-quant:reference-quantize-rq8 matrix)
                   vector 1 2048))
           (reference (rational-quant:reference-matvec-rq8 input))
           (candidate (generated-matvec-rq8 input)))
      (check
       (list (float-vector-bits= (list reference candidate))
             "left-to-right single-float accumulation changed")))))

(defun test-public-fallback (request)
  (declare (ignore request))
  (let* ((input (case-request '(7 2 64)))
         (reference (rational-quant:reference-matvec-rq8 input))
         (candidate (mirror-kernel.rq8:matvec-rq8 input)))
    (check
     (list (float-vector-bits= (list reference candidate))
           "public wrapper did not preserve the fallback semantics"))))

(defun test-strict-runtime-fails-closed (request)
  (declare (ignore request))
  (let ((unsupported (case-request '(17 1 64))))
    (check
     (list
      (signals-error-p (lambda () (generated-matvec-rq8 unsupported)))
      "strict generated code accepted an unsupported runtime shape"))))

(defun run-tests (request)
  (declare (ignore request))
  (setf *check-count* 0)
  (mapc
   (lambda (test) (funcall test nil))
   (list #'test-system-contract
         #'test-graph-and-target-determinism
         #'test-exact-cover
         #'test-cover-fails-closed
         #'test-emission-is-stable
         #'test-unsupported-compilation
         #'test-option-and-certificate-contract
         #'test-semantic-equivalence
         #'test-public-fallback
         #'test-strict-runtime-fails-closed))
  (format t
          "MIRROR_TEST_RESULT {\"status\":\"passed\",\"implementation\":\"SBCL\",\"checks\":~D,\"performance_claim\":false}~%"
          *check-count*)
  t)
