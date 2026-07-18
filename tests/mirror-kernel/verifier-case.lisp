(eval-when (:compile-toplevel :load-toplevel :execute)
  (let* ((root-text
           (or (sb-ext:posix-getenv "PURE_LISP_KERNEL_LAB_ROOT")
               (error "PURE_LISP_KERNEL_LAB_ROOT is required.")))
         (root
           (make-pathname :name nil :type nil
                          :defaults (pathname (concatenate 'string root-text "/")))))
    (load (merge-pathnames "packages/rational-quant/package.lisp" root))
    (load (merge-pathnames "packages/rational-quant/core.lisp" root))))

(defpackage #:compile-pure-lisp.case
  (:use #:cl))

(in-package #:compile-pure-lisp.case)

(mirror-kernel:define-rq8-matvec-kernel candidate-kernel
  (:columns 2048
   :block-size 32
   :blocks-per-group 64
   :reduction-order :left-to-right-single-float
   :target :sbcl-typed-common-lisp/v0
   :fallback nil))

(defun reference-kernel (input)
  (rational-quant:reference-matvec-rq8 input))

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
  (destructuring-bind (seed rows) request
    (let ((columns 2048))
      (list
       (rational-quant:reference-quantize-rq8
        (case-array (list seed (* rows columns))))
       (case-vector (list seed columns))
       rows
       columns))))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (case-request
                   (list (+ seed index) (1+ (mod index 3)))))))

(defun benchmark-input (configuration)
  (destructuring-bind (seed size) configuration
    (case-request (list (+ seed (mod size 997)) 1))))

(defun float-vector-bits= (request)
  (destructuring-bind (left right) request
    (and (= (length left) (length right))
         (loop for index below (length left)
               always
               (= (sb-kernel:single-float-bits (aref left index))
                  (sb-kernel:single-float-bits (aref right index)))))))

(defun equivalent-p (outcomes)
  (destructuring-bind (left right) outcomes
    (float-vector-bits=
     (list (first (second left)) (first (second right))))))
