(defpackage #:compile-pure-lisp.case
  (:use #:cl))

(in-package #:compile-pure-lisp.case)

(defun reference-kernel (input)
  (reduce #'+ input))

(defun candidate-kernel (input)
  (let ((result (reduce #'+ input)))
    (incf (first input))
    result))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (list (+ seed index)
                        (- seed index)
                        index))))

(defun benchmark-input (configuration)
  (destructuring-bind (seed size) configuration
    (list seed size (- seed size))))
