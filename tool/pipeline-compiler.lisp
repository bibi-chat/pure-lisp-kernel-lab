(defpackage #:compile-pure-lisp.kernel
  (:use #:cl)
  (:export #:define-pipeline-kernel))

(in-package #:compile-pure-lisp.kernel)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +forbidden-kernel-operators+
    '(setq setf psetq psetf incf decf rotatef shiftf
      push pushnew pop rplaca rplacd set makunbound fmakunbound
      eval compile load open close read read-byte read-char
      write write-byte write-char print pprint princ prin1 format terpri
      signal error warn break invoke-debugger throw go return-from
      unwind-protect progv multiple-value-prog1))

  (defun %operator-name (operator)
    (and (symbolp operator) (string-upcase (symbol-name operator))))

  (defun %stage-name (stage)
    (unless (and (consp stage) (symbolp (first stage)))
      (error "Malformed pipeline stage: ~S" stage))
    (%operator-name (first stage)))

  (defun %forbidden-operator (form)
    (cond
      ((atom form) nil)
      ((and (symbolp (first form))
            (find (%operator-name (first form))
                  +forbidden-kernel-operators+
                  :key #'%operator-name
                  :test #'string=))
       (first form))
      (t
       (some #'%forbidden-operator form))))

  (defun %assert-kernel-form (form)
    (let ((operator (%forbidden-operator form)))
      (when operator
        (error "Operator ~S is forbidden in a pure kernel expression ~S"
               operator form)))
    form)

  (defun %single-binding (binding stage)
    (unless (and (listp binding)
                 (= (length binding) 1)
                 (symbolp (first binding)))
      (error "~A requires one lexical binding, got ~S" stage binding))
    (first binding))

  (defun %double-binding (binding stage)
    (unless (and (listp binding)
                 (= (length binding) 2)
                 (every #'symbolp binding))
      (error "~A requires two lexical bindings, got ~S" stage binding))
    binding)

  (defun %emit-value-stages (stages value accumulator)
    (unless stages
      (error "A pipeline must terminate in FOLD"))
    (let ((stage (first stages))
          (remaining (rest stages)))
      (cond
        ((string= (%stage-name stage) "MAP")
         (unless (= (length stage) 3)
           (error "MAP syntax is (map (value) expression), got ~S" stage))
         (let* ((binding (%single-binding (second stage) "MAP"))
                (body (%assert-kernel-form (third stage)))
                (next-value (gensym "MAPPED-VALUE-")))
           `(let ((,next-value (let ((,binding ,value)) ,body)))
              ,(%emit-value-stages remaining next-value accumulator))))
        ((string= (%stage-name stage) "FILTER")
         (unless (= (length stage) 3)
           (error "FILTER syntax is (filter (value) predicate), got ~S" stage))
         (let ((binding (%single-binding (second stage) "FILTER"))
               (predicate (%assert-kernel-form (third stage))))
           `(let ((,binding ,value))
              (when ,predicate
                ,(%emit-value-stages remaining value accumulator)))))
        ((string= (%stage-name stage) "FOLD")
         (when remaining
           (error "FOLD must be the final pipeline stage"))
         (unless (= (length stage) 4)
           (error "FOLD syntax is (fold (state value) initial expression), got ~S"
                  stage))
         (destructuring-bind (state-binding value-binding)
             (%double-binding (second stage) "FOLD")
           (declare (ignore state-binding value-binding)))
         (destructuring-bind (state-binding value-binding)
             (second stage)
           (let ((body (%assert-kernel-form (fourth stage))))
             `(let ((,state-binding ,accumulator)
                    (,value-binding ,value))
                (setf ,accumulator ,body)))))
        (t
         (error "Unsupported pipeline stage ~S" stage)))))

  (defun %parse-source (stage)
    (unless (string= (%stage-name stage) "SOURCE")
      (error "The first pipeline stage must be SOURCE, got ~S" stage))
    (unless (member (length stage) '(3 5))
      (error "SOURCE syntax is (source (index start end step) expression [:element-type type]), got ~S"
             stage))
    (let ((binding (second stage)))
      (unless (and (listp binding)
                   (= (length binding) 4)
                   (symbolp (first binding)))
        (error "SOURCE binding must be (index start end step), got ~S" binding))
      (when (= (length stage) 5)
        (unless (and (keywordp (fourth stage))
                     (string= (symbol-name (fourth stage)) "ELEMENT-TYPE"))
          (error "Unknown SOURCE option in ~S" stage)))
      (values binding
              (%assert-kernel-form (third stage))
              (if (= (length stage) 5) (fifth stage) t))))

  (defun %fold-initial (stage)
    (unless (and stage (string= (%stage-name stage) "FOLD"))
      (error "The final pipeline stage must be FOLD"))
    (unless (= (length stage) 4)
      (error "FOLD syntax is (fold (state value) initial expression), got ~S"
             stage))
    (%assert-kernel-form (third stage))))

(defmacro define-pipeline-kernel (name signature &body stages)
  "Compile a pure SOURCE/MAP/FILTER/FOLD graph into one typed native loop."
  (unless (and (symbolp name)
               (listp signature)
               (= (length signature) 2))
    (error "Signature syntax is ((input input-type) result-type), got ~S"
           signature))
  (destructuring-bind (input-spec result-type) signature
    (unless (and (listp input-spec)
                 (= (length input-spec) 2)
                 (symbolp (first input-spec)))
      (error "Input signature must be (name type), got ~S" input-spec))
    (unless (>= (length stages) 2)
      (error "A pipeline requires SOURCE and FOLD stages"))
    (destructuring-bind (input input-type) input-spec
      (multiple-value-bind (source-binding source-form element-type)
          (%parse-source (first stages))
        (destructuring-bind (source-index source-start source-end source-step)
            source-binding
          (let* ((fold-stage (car (last stages)))
                 (initial (%fold-initial fold-stage))
                 (index (gensym "INDEX-"))
                 (start (gensym "START-"))
                 (end (gensym "END-"))
                 (step (gensym "STEP-"))
                 (source-value (gensym "SOURCE-VALUE-"))
                 (accumulator (gensym "ACCUMULATOR-"))
                 (body (%emit-value-stages (rest stages)
                                           source-value
                                           accumulator)))
            `(progn
               (declaim (ftype (function (,input-type) ,result-type) ,name))
               (defun ,name (,input)
                 (declare (type ,input-type ,input)
                          (optimize (speed 3) (safety 1) (debug 1)))
                 (let ((,start ,source-start)
                       (,end ,source-end)
                       (,step ,source-step)
                       (,accumulator ,initial))
                   (declare (type fixnum ,start ,end ,step)
                            (type ,result-type ,accumulator))
                   (unless (plusp ,step)
                     (error "Pipeline SOURCE step must be positive, got ~S" ,step))
                   (do ((,index ,start (the fixnum (+ ,index ,step))))
                       ((>= ,index ,end) ,accumulator)
                     (declare (type fixnum ,index))
                     (let* ((,source-index ,index)
                            (,source-value ,source-form))
                       (declare (type fixnum ,source-index)
                                (type ,element-type ,source-value))
                       ,body)))))))))))
