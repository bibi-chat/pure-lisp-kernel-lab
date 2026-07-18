(defpackage #:compile-pure-lisp.case
  (:use #:cl))

(in-package #:compile-pure-lisp.case)

(defun reference-kernel (input)
  (+ input 1))

(defun candidate-kernel (input)
  (+ input 1))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (- (+ seed index) (floor count 2)))))

(defun benchmark-input (configuration)
  (destructuring-bind (seed size) configuration
    (+ seed size)))
