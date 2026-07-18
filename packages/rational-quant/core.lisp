(in-package #:rational-quant)

(declaim (optimize (speed 3) (safety 1) (debug 1)))

(defconstant +block-size+ 32)
(defconstant +blocks-per-group+ 64)
(defconstant +single-float-bytes+ 4)
(defconstant +single-below-half+
  #.(sb-kernel:make-single-float #x3effffff))

(defparameter +numerator-floats+
  (coerce (loop for numerator from 1 to 256
                collect (coerce numerator 'single-float))
          '(simple-array single-float (*))))

(declaim (type (simple-array single-float (256)) +numerator-floats+))

(defstruct (rq8-tensor
            (:constructor make-rq8-tensor (exponents numerators quants)))
  (exponents #() :type (simple-array (signed-byte 8) (*)) :read-only t)
  (numerators #() :type (simple-array (unsigned-byte 8) (*)) :read-only t)
  (quants #() :type (simple-array (signed-byte 8) (*)) :read-only t))

(declaim (inline finite-single-p normal-positive-single-p
                 round-away bounded-round-away clamp-q8 group-exponent
                 numerator-code decoded-scale))

(defmacro block-required-scale* (input block)
  `(let ((start (the fixnum (* ,block +block-size+)))
         (maximum 0.0f0))
     (declare (type fixnum start)
              (type single-float maximum))
     (dotimes (offset +block-size+)
       (declare (type fixnum offset))
       (let ((value (the single-float
                         (aref ,input (the fixnum (+ start offset))))))
         (declare (type single-float value))
         (unless (finite-single-p value)
           (error "RQ8 accepts only finite IEEE-754 binary32 values."))
         (setf maximum (max maximum (abs value)))))
     (let ((scale (if (zerop maximum) 0.0f0 (/ maximum 127.0f0))))
       (declare (type single-float scale))
       (when (and (plusp maximum)
                  (not (normal-positive-single-p scale)))
         (error "RQ8 encountered an unsupported underflowed or subnormal block scale."))
       scale)))

(defmacro numerator-code* (required-scale quantum)
  `(if (zerop ,required-scale)
       0
       (let* ((initial (ceiling (/ ,required-scale ,quantum)))
              (initial-scale (* (coerce initial 'single-float) ,quantum))
              (numerator
                (if (and (< initial-scale ,required-scale) (< initial 256))
                    (1+ initial)
                    initial)))
         (declare (type integer initial numerator)
                  (type single-float initial-scale))
         (unless (<= 1 numerator 256)
           (error "RQ8 numerator ~D is outside 1..256." numerator))
         (the (unsigned-byte 8) (1- numerator)))))

(defmacro decoded-scale* (numerator-code exponent)
  `(scale-from-quantum*
    ,numerator-code (the single-float (scale-float 1.0f0 ,exponent))))

(defmacro scale-from-quantum* (numerator-code quantum)
  `(* (the single-float (aref +numerator-floats+ ,numerator-code))
      ,quantum))

(defun finite-single-p (value)
  (declare (type single-float value))
  (/= (ldb (byte 8 23) (sb-kernel:single-float-bits value)) #xff))

(defun normal-positive-single-p (value)
  (declare (type single-float value))
  (let* ((bits (sb-kernel:single-float-bits value))
         (exponent (ldb (byte 8 23) bits)))
    (declare (type (unsigned-byte 32) bits)
             (type (unsigned-byte 8) exponent))
    (and (zerop (logand bits #x80000000))
         (<= 1 exponent 254))))

(defun round-away (value)
  (declare (type single-float value))
  (multiple-value-bind (integer remainder) (truncate value)
    (declare (type integer integer)
             (type single-float remainder))
    (the integer
         (if (>= (abs remainder) 0.5f0)
             (+ integer (if (minusp remainder) -1 1))
             integer))))

(defun bounded-round-away (value)
  "Round an RQ8 ratio already proven to be inside (-127.5, 127.5)."
  (declare (type single-float value))
  (let ((bounded
          (sb-ext:truly-the
           (single-float (-127.5f0) (127.5f0))
           value)))
    (values
     (the (signed-byte 8)
          (if (= (abs bounded) +single-below-half+)
              0
              (truncate (+ bounded (float-sign bounded 0.5f0))))))))

(defun clamp-q8 (value)
  (declare (type integer value))
  (the (signed-byte 8) (max -127 (min 127 value))))

(defun group-exponent (maximum-scale)
  "Return the smallest E for which MAXIMUM-SCALE <= 256 * 2^E."
  (declare (type single-float maximum-scale))
  (if (zerop maximum-scale)
      0
      (let* ((bits (sb-kernel:single-float-bits maximum-scale))
             (encoded (ldb (byte 8 23) bits))
             (fraction (ldb (byte 23 0) bits))
             (floor-log2 (- encoded 127)))
        (declare (type (unsigned-byte 32) bits)
                 (type (unsigned-byte 8) encoded)
                 (type (unsigned-byte 23) fraction)
                 (type integer floor-log2))
        (unless (normal-positive-single-p maximum-scale)
          (error "RQ8 requires zero or positive normal block scales."))
        (the integer
             (- (+ floor-log2 (if (zerop fraction) 0 1)) 8)))))

(defun numerator-code (request)
  "Encode REQUIRED-SCALE/QUANTUM upward as a biased byte in 0..255."
  (destructuring-bind (required-scale quantum) request
    (declare (type single-float required-scale quantum))
    (numerator-code* required-scale quantum)))

(defun decoded-scale (request)
  (destructuring-bind (numerator-code exponent) request
    (declare (type (unsigned-byte 8) numerator-code)
             (type (signed-byte 8) exponent))
    (the single-float (decoded-scale* numerator-code exponent))))

(defun rq8-storage-bytes (tensor)
  (declare (type rq8-tensor tensor))
  (+ (length (rq8-tensor-exponents tensor))
     (length (rq8-tensor-numerators tensor))
     (length (rq8-tensor-quants tensor))))

(defun valid-input-shape-p (input)
  (and (typep input '(simple-array single-float (*)))
       (plusp (length input))
       (zerop (mod (length input) +block-size+))))

(defun block-required-scale (request)
  (destructuring-bind (input block) request
    (declare (type (simple-array single-float (*)) input)
             (type fixnum block))
    (block-required-scale* input block)))

(defun rq8-supported-input-p (input)
  "True when INPUT is inside the guarded RQ8 specialization domain."
  (and (valid-input-shape-p input)
       (<= (length input) most-positive-fixnum)
       (handler-case
           (let* ((block-count (truncate (length input) +block-size+))
                  (group-count (ceiling block-count +blocks-per-group+)))
             (declare (type fixnum block-count group-count))
             (dotimes (group group-count t)
               (declare (type fixnum group))
               (let* ((start (the fixnum (* group +blocks-per-group+)))
                      (stop (the fixnum
                                  (min block-count
                                       (+ start +blocks-per-group+))))
                      (maximum-scale 0.0f0))
                 (declare (type fixnum start stop)
                          (type single-float maximum-scale))
                 (loop for block fixnum from start below stop
                       for scale single-float =
                         (block-required-scale (list input block))
                       do (when (and (plusp scale)
                                     (not (normal-positive-single-p scale)))
                            (return-from rq8-supported-input-p nil))
                          (setf maximum-scale (max maximum-scale scale)))
                 (let ((exponent (group-exponent maximum-scale)))
                   (unless (<= -126 exponent 119)
                     (return-from rq8-supported-input-p nil)))))
             t)
         (error () nil))))

(defun reference-block-scale (request)
  (destructuring-bind (input block) request
    (let* ((start (* block +block-size+))
           (values (subseq input start (+ start +block-size+))))
      (unless (every #'finite-single-p values)
        (error "RQ8 accepts only finite IEEE-754 binary32 values."))
      (let* ((maximum (reduce #'max values :key #'abs))
             (scale (if (zerop maximum) 0.0f0 (/ maximum 127.0f0))))
        (when (and (plusp maximum)
                   (not (normal-positive-single-p scale)))
          (error "RQ8 encountered an unsupported underflowed or subnormal block scale."))
        scale))))

(defun reference-quantize-rq8 (input)
  "Semantic oracle using generic sequences and fresh intermediate lists."
  (unless (valid-input-shape-p input)
    (error "RQ8 input must be a non-empty simple single-float vector divisible by 32."))
  (let* ((count (length input))
         (block-count (truncate count +block-size+))
         (group-count (ceiling block-count +blocks-per-group+))
         (exponents (make-array group-count :element-type '(signed-byte 8)))
         (numerators (make-array block-count :element-type '(unsigned-byte 8)))
         (quants (make-array count :element-type '(signed-byte 8))))
    (dotimes (group group-count)
      (let* ((start (* group +blocks-per-group+))
             (stop (min block-count (+ start +blocks-per-group+)))
             (scales (loop for block from start below stop
                           collect (reference-block-scale (list input block))))
             (maximum-scale (reduce #'max scales :initial-value 0.0f0))
             (exponent (group-exponent maximum-scale)))
        (unless (<= -126 exponent 119)
          (error "RQ8 exponent ~D is outside the safe -126..119 domain." exponent))
        (setf (aref exponents group) exponent)
        (let ((quantum (scale-float 1.0f0 exponent)))
          (loop for block from start below stop
                for required-scale in scales
                for code = (numerator-code (list required-scale quantum))
                for scale = (decoded-scale (list code exponent))
                for value-start = (* block +block-size+)
                do (setf (aref numerators block) code)
                   (dotimes (offset +block-size+)
                     (let ((index (+ value-start offset)))
                       (setf (aref quants index)
                             (if (zerop required-scale)
                                 0
                                 (clamp-q8
                                  (round-away (/ (aref input index) scale)))))))))))
    (make-rq8-tensor exponents numerators quants)))

(defun quantize-rq8 (input)
  "Typed RQ8/32/64 encoder for the guarded finite-normal scale domain."
  (declare (type (simple-array single-float (*)) input))
  (unless (valid-input-shape-p input)
    (error "RQ8 input length must be a positive multiple of 32."))
  (let* ((count (length input))
         (block-count (truncate count +block-size+))
         (group-count (ceiling block-count +blocks-per-group+))
         (exponents (make-array group-count :element-type '(signed-byte 8)))
         (numerators (make-array block-count :element-type '(unsigned-byte 8)))
         (quants (make-array count :element-type '(signed-byte 8)))
         (required-scales
           (make-array +blocks-per-group+ :element-type 'single-float)))
    (declare (type fixnum count block-count group-count)
             (type (simple-array (signed-byte 8) (*)) exponents quants)
             (type (simple-array (unsigned-byte 8) (*)) numerators)
             (type (simple-array single-float (*)) required-scales))
    (when (> count (truncate most-positive-fixnum +single-float-bytes+))
      (error "RQ8 input is too large for native byte offsets."))
    (sb-sys:with-pinned-objects (input quants)
      (let ((input-sap (sb-sys:vector-sap input))
            (quant-sap (sb-sys:vector-sap quants)))
        (declare (type sb-sys:system-area-pointer input-sap quant-sap))
        (macrolet
            ((input-at (index)
               `(sb-sys:sap-ref-single
                 input-sap
                 (the fixnum (* ,index +single-float-bytes+))))
             (write-quant (index value)
               `(setf (sb-sys:signed-sap-ref-8 quant-sap ,index) ,value))
             (block-scale (block)
               `(let* ((value-start (the fixnum (* ,block +block-size+)))
                       (maximum-0 0.0f0)
                       (maximum-1 0.0f0)
                       (maximum-2 0.0f0)
                       (maximum-3 0.0f0)
                       (maximum-4 0.0f0)
                       (maximum-5 0.0f0)
                       (maximum-6 0.0f0)
                       (maximum-7 0.0f0))
                  (declare (type fixnum value-start)
                           (type single-float
                                 maximum-0 maximum-1 maximum-2 maximum-3
                                 maximum-4 maximum-5 maximum-6 maximum-7))
                  (macrolet
                      ((update-maximum (place lane)
                         `(let ((value
                                  (input-at
                                   (the fixnum (+ value-start base ,lane)))))
                            (declare (type single-float value))
                            (unless (finite-single-p value)
                              (error "RQ8 accepts only finite IEEE-754 binary32 values."))
                            (setf ,place (max ,place (abs value)))))
                       (update-eight (base-value)
                         `(let ((base ,base-value))
                            (declare (type fixnum base))
                            (update-maximum maximum-0 0)
                            (update-maximum maximum-1 1)
                            (update-maximum maximum-2 2)
                            (update-maximum maximum-3 3)
                            (update-maximum maximum-4 4)
                            (update-maximum maximum-5 5)
                            (update-maximum maximum-6 6)
                            (update-maximum maximum-7 7))))
                    (update-eight 0)
                    (update-eight 8)
                    (update-eight 16)
                    (update-eight 24))
                  (let* ((maximum
                           (max (max maximum-0 maximum-1)
                                (max maximum-2 maximum-3)
                                (max maximum-4 maximum-5)
                                (max maximum-6 maximum-7)))
                         (scale
                           (if (zerop maximum) 0.0f0 (/ maximum 127.0f0))))
                    (declare (type single-float maximum scale))
                    (when (and (plusp maximum)
                               (not (normal-positive-single-p scale)))
                      (error "RQ8 encountered an unsupported underflowed or subnormal block scale."))
                    scale)))
             (encode-lane (delta)
               `(let* ((index (the fixnum (+ value-start base ,delta)))
                       (ratio (/ (input-at index) scale)))
                  (declare (type fixnum index)
                           (type single-float ratio))
                  (write-quant index (bounded-round-away ratio))))
             (encode-eight (base-value)
               `(let ((base ,base-value))
                  (declare (type fixnum base))
                  (encode-lane 0)
                  (encode-lane 1)
                  (encode-lane 2)
                  (encode-lane 3)
                  (encode-lane 4)
                  (encode-lane 5)
                  (encode-lane 6)
                  (encode-lane 7))))
          (dotimes (group group-count)
            (declare (type fixnum group))
            (let* ((start (the fixnum (* group +blocks-per-group+)))
                   (stop
                     (the fixnum
                          (min block-count (+ start +blocks-per-group+))))
                   (blocks (the fixnum (- stop start)))
                   (maximum-scale 0.0f0))
              (declare (type fixnum start stop blocks)
                       (type single-float maximum-scale))
              (dotimes (offset blocks)
                (declare (type fixnum offset))
                (let ((scale
                        (block-scale (the fixnum (+ start offset)))))
                  (declare (type single-float scale))
                  (setf (aref required-scales offset) scale
                        maximum-scale (max maximum-scale scale))))
              (let ((exponent (group-exponent maximum-scale)))
                (declare (type integer exponent))
                (unless (<= -126 exponent 119)
                  (error "RQ8 exponent ~D is outside the safe -126..119 domain."
                         exponent))
                (let ((typed-exponent (the (signed-byte 8) exponent))
                      (quantum
                        (the single-float (scale-float 1.0f0 exponent))))
                  (declare (type (signed-byte 8) typed-exponent)
                           (type single-float quantum))
                  (setf (aref exponents group) typed-exponent)
                  (dotimes (offset blocks)
                    (declare (type fixnum offset))
                    (let* ((block (the fixnum (+ start offset)))
                           (value-start
                             (the fixnum (* block +block-size+)))
                           (required-scale (aref required-scales offset))
                           (code
                             (numerator-code* required-scale quantum))
                           (scale (scale-from-quantum* code quantum)))
                      (declare (type fixnum block value-start)
                               (type single-float required-scale scale)
                               (type (unsigned-byte 8) code))
                      (setf (aref numerators block) code)
                      (if (zerop required-scale)
                          (dotimes (lane +block-size+)
                            (declare (type fixnum lane))
                            (write-quant (the fixnum (+ value-start lane)) 0))
                          (progn
                            (encode-eight 0)
                            (encode-eight 8)
                            (encode-eight 16)
                            (encode-eight 24))))))))))))
    (make-rq8-tensor exponents numerators quants)))

(defun valid-tensor-shape-p (tensor)
  (let* ((quants (rq8-tensor-quants tensor))
         (numerators (rq8-tensor-numerators tensor))
         (exponents (rq8-tensor-exponents tensor))
         (count (length quants))
         (block-count (truncate count +block-size+)))
    (and (zerop (mod count +block-size+))
         (= (length numerators) block-count)
         (= (length exponents) (ceiling block-count +blocks-per-group+)))))

(defun reference-dequantize-rq8 (tensor)
  (declare (type rq8-tensor tensor))
  (unless (valid-tensor-shape-p tensor)
    (error "Malformed RQ8 tensor shape."))
  (let* ((exponents (rq8-tensor-exponents tensor))
         (numerators (rq8-tensor-numerators tensor))
         (quants (rq8-tensor-quants tensor))
         (output (make-array (length quants) :element-type 'single-float)))
    (dotimes (index (length quants) output)
      (let* ((block (truncate index +block-size+))
             (group (truncate block +blocks-per-group+))
             (scale (decoded-scale
                     (list (aref numerators block) (aref exponents group)))))
        (setf (aref output index)
              (* (coerce (aref quants index) 'single-float) scale))))))

(defun dequantize-rq8 (tensor)
  (declare (type rq8-tensor tensor))
  (unless (valid-tensor-shape-p tensor)
    (return-from dequantize-rq8 (reference-dequantize-rq8 tensor)))
  (let* ((exponents (rq8-tensor-exponents tensor))
         (numerators (rq8-tensor-numerators tensor))
         (quants (rq8-tensor-quants tensor))
         (count (length quants))
         (block-count (truncate count +block-size+))
         (output (make-array count :element-type 'single-float)))
    (declare (type (simple-array (signed-byte 8) (*)) exponents quants)
             (type (simple-array (unsigned-byte 8) (*)) numerators)
             (type (simple-array single-float (*)) output)
             (type fixnum count block-count))
    (sb-sys:with-pinned-objects (quants output)
      (let ((quant-sap (sb-sys:vector-sap quants))
            (output-sap (sb-sys:vector-sap output)))
        (declare (type sb-sys:system-area-pointer quant-sap output-sap))
        (macrolet
            ((write-lane (delta)
               `(let ((index (the fixnum (+ base ,delta))))
                  (declare (type fixnum index))
                  (setf (sb-sys:sap-ref-single
                         output-sap
                         (the fixnum (* index +single-float-bytes+)))
                        (* (coerce
                            (sb-sys:signed-sap-ref-8 quant-sap index)
                            'single-float)
                           scale)))))
          (dotimes (group (length exponents) output)
            (declare (type fixnum group))
            (let* ((block-start (the fixnum (* group +blocks-per-group+)))
                   (block-stop
                     (the fixnum
                          (min block-count
                               (+ block-start +blocks-per-group+))))
                   (quantum
                     (the single-float
                          (scale-float 1.0f0 (aref exponents group)))))
              (declare (type fixnum block-start block-stop)
                       (type single-float quantum))
              (loop for block fixnum from block-start below block-stop
                    do (let* ((start (the fixnum (* block +block-size+)))
                              (scale
                                (scale-from-quantum*
                                 (aref numerators block) quantum)))
                         (declare (type fixnum start)
                                  (type single-float scale))
                         (dotimes (lane-group 8)
                           (declare (type fixnum lane-group))
                           (let ((base
                                   (the fixnum
                                        (+ start (* lane-group 4)))))
                             (declare (type fixnum base))
                             (write-lane 0)
                             (write-lane 1)
                             (write-lane 2)
                             (write-lane 3))))))))))))

(defun reference-matvec-rq8 (request)
  (destructuring-bind (tensor vector rows columns) request
    (declare (type rq8-tensor tensor)
             (type (simple-array single-float (*)) vector)
             (type fixnum rows columns))
    (unless (and (= (length vector) columns)
                 (= (length (rq8-tensor-quants tensor)) (* rows columns))
                 (valid-tensor-shape-p tensor))
      (error "RQ8 matrix/vector shape mismatch."))
    (let ((output (make-array rows :element-type 'single-float)))
      (dotimes (row rows output)
        (let ((total 0.0f0))
          (dotimes (column columns)
            (let* ((index (+ (* row columns) column))
                   (block (truncate index +block-size+))
                   (group (truncate block +blocks-per-group+))
                   (scale
                     (decoded-scale
                      (list (aref (rq8-tensor-numerators tensor) block)
                            (aref (rq8-tensor-exponents tensor) group))))
                   (dequantized
                     (* (coerce (aref (rq8-tensor-quants tensor) index)
                                'single-float)
                        scale))
                   (product (* dequantized (aref vector column))))
              (setf total (+ total product))))
          (setf (aref output row) total))))))

(defun matvec-rq8 (request)
  (destructuring-bind (tensor vector rows columns) request
    (declare (type rq8-tensor tensor)
             (type (simple-array single-float (*)) vector)
             (type fixnum rows columns))
    (let* ((exponents (rq8-tensor-exponents tensor))
           (numerators (rq8-tensor-numerators tensor))
           (quants (rq8-tensor-quants tensor))
           (element-count (* rows columns)))
      (declare (type (simple-array (signed-byte 8) (*)) exponents quants)
               (type (simple-array (unsigned-byte 8) (*)) numerators)
               (type integer element-count))
      (unless (and (not (minusp rows))
                   (plusp columns)
                   (zerop (mod columns +block-size+))
                   (typep element-count 'fixnum)
                   (= (length vector) columns)
                   (= (length quants) element-count)
                   (valid-tensor-shape-p tensor))
        (return-from matvec-rq8 (reference-matvec-rq8 request)))
      (let* ((blocks-per-row (truncate columns +block-size+))
             (output (make-array rows :element-type 'single-float)))
        (declare (type fixnum blocks-per-row)
                 (type (simple-array single-float (*)) output))
        (dotimes (row rows output)
          (declare (type fixnum row))
          (let ((row-start (the fixnum (* row columns)))
                (row-block-start (the fixnum (* row blocks-per-row)))
                (active-group -1)
                (quantum 1.0f0)
                (total 0.0f0))
            (declare (type fixnum row-start row-block-start)
                     (type (integer -1 #.most-positive-fixnum) active-group)
                     (type single-float quantum total))
            (dotimes (block blocks-per-row)
              (declare (type fixnum block))
              (let* ((absolute-block (the fixnum (+ row-block-start block)))
                     (column-start (the fixnum (* block +block-size+)))
                     (group (the fixnum
                                 (truncate absolute-block
                                           +blocks-per-group+)))
                     (scale
                       (progn
                         (unless (= group active-group)
                           (setf active-group group
                                 quantum
                                   (scale-float 1.0f0
                                                (aref exponents group))))
                         (scale-from-quantum*
                          (aref numerators absolute-block) quantum))))
                (declare (type fixnum absolute-block column-start group)
                         (type single-float scale))
                (dotimes (offset +block-size+)
                  (declare (type fixnum offset))
                  (let* ((column (the fixnum (+ column-start offset)))
                         (index (the fixnum (+ row-start column)))
                         (dequantized
                           (* (coerce (the (signed-byte 8)
                                              (aref quants index))
                                      'single-float)
                              scale))
                         (product
                           (* dequantized
                              (the single-float (aref vector column)))))
                    (declare (type fixnum column index)
                             (type single-float dequantized product))
                    (setf total (+ total product))))))
            (setf (aref output row) total)))))))
