(defpackage #:compile-pure-lisp.case
  (:use #:cl #:compile-pure-lisp.egraph))

(in-package #:compile-pure-lisp.case)

(defun reference-kernel (input)
  (destructuring-bind (x y z) input
    (+ (* x y) (* x z))))

(defun candidate-kernel (input)
  (destructuring-bind (x y z) input
    (declare (type integer x y z))
    (egraph-expression
        ((x integer) (y integer) (z integer))
        integer
        (:theory :exact-integer :round-limit 8 :node-limit 512)
      (+ (* x y) (* x z)))))

(defun boundary-case (request)
  (destructuring-bind (seed index) request
    (case (mod index 8)
      (0 (list 0 seed (- seed)))
      (1 (list most-positive-fixnum 1 -1))
      (2 (list most-negative-fixnum -1 1))
      (3 (list (1+ most-positive-fixnum) 2 -5))
      (4 (list (1- most-negative-fixnum) -7 11))
      (5 (list (ash 1 (+ 64 (mod seed 64))) -3 5))
      (6 (list (- seed 4096) (+ seed 17) (- 23 seed)))
      (otherwise
       (list (- (mod (* seed 104729) 1000003) 500001)
             (- (mod (* (+ seed 1) 130363) 100003) 50001)
             (- (mod (* (+ seed 2) 155921) 100019) 50009))))))

(defun cases (configuration)
  (destructuring-bind (seed count) configuration
    (loop for index below count
          collect (boundary-case (list (+ seed index) index)))))

(defun benchmark-input (configuration)
  (destructuring-bind (seed size) configuration
    (let ((magnitude (max 1 (mod size 1000000))))
      (list (+ seed magnitude)
            (+ 17 (mod seed 1000))
            (- (mod seed 997) 499)))))
