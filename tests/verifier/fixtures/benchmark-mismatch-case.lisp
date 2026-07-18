(defpackage #:compile-pure-lisp.case
  (:use #:cl))

(in-package #:compile-pure-lisp.case)

(defun reference-kernel (input)
  (if (= input 9999) 0 input))

(defun candidate-kernel (input)
  (if (= input 9999) 1 input))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (+ seed index))))

(defun benchmark-input (configuration)
  (declare (ignore configuration))
  9999)
