(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-cltl2))

(defpackage #:compile-pure-lisp.egraph
  (:use #:cl)
  (:export
   #:define-egraph-kernel
   #:egraph-expression
   #:egraph-request-error
   #:optimization-result
   #:optimization-result-application-count
   #:optimization-result-attempt-count
   #:optimization-result-class-count
   #:optimization-result-cost
   #:optimization-result-form
   #:optimization-result-inferred-range
   #:optimization-result-node-count
   #:optimization-result-original-cost
   #:optimization-result-original-form
   #:optimization-result-reason
   #:optimization-result-rounds
   #:optimization-result-status
   #:optimize-egraph-expression))

(in-package #:compile-pure-lisp.egraph)

(defconstant +maximum-rounds+ 8)
(defconstant +maximum-nodes+ 512)
(defconstant +maximum-expression-depth+ 64)
(defconstant +maximum-input-conses+ 512)
(defconstant +maximum-rewrite-applications+ 4096)
(defconstant +maximum-rewrite-attempts+ 16384)
(defconstant +maximum-constant-bits+ 4096)
(defconstant +maximum-error-message-characters+ 4096)

(defparameter +expected-cl-plus-function+ (symbol-function 'cl:+))
(defparameter +expected-cl-times-function+ (symbol-function 'cl:*))

(define-condition egraph-request-error (error)
  ((message :initarg :message :reader egraph-request-error-message))
  (:report
   (lambda (condition stream)
     (write-string (egraph-request-error-message condition) stream))))

(define-condition egraph-resource-limit (error)
  ((kind :initarg :kind :reader egraph-resource-limit-kind)
   (limit :initarg :limit :reader egraph-resource-limit-value))
  (:report
   (lambda (condition stream)
     (format stream "E-graph ~A limit reached (~D)"
             (egraph-resource-limit-kind condition)
             (egraph-resource-limit-value condition)))))

(defstruct validated-request
  expression
  variables
  result-type
  theory
  round-limit
  node-limit)

(defstruct (e-node
            (:constructor make-e-node (kind value children original-p)))
  kind
  value
  children
  original-p)

(defstruct choice
  form
  cost
  node-count
  nonoriginal-count
  depth
  key)

(defstruct optimization-result
  status
  original-form
  form
  original-cost
  cost
  rounds
  node-count
  class-count
  application-count
  attempt-count
  inferred-range
  theory
  reason)

(defstruct e-graph
  (parents (make-array 16
                       :element-type 'fixnum
                       :adjustable t
                       :fill-pointer 0))
  (classes (make-array 16 :adjustable t :fill-pointer 0))
  (memo (make-hash-table :test #'equal))
  (node-count 0 :type fixnum)
  (union-count 0 :type fixnum)
  (application-count 0 :type fixnum)
  (attempt-count 0 :type fixnum)
  (node-limit +maximum-nodes+ :type fixnum)
  root)

(defun bounded-error-message (control-and-arguments)
  (destructuring-bind (control &rest arguments) control-and-arguments
    (with-standard-io-syntax
      (let* ((*print-circle* t)
             (*print-level* 8)
             (*print-length* 24)
             (*print-pretty* nil)
             (message (apply #'format nil control arguments)))
        (if (<= (length message) +maximum-error-message-characters+)
            message
            (concatenate
             'string
             (subseq message 0 +maximum-error-message-characters+)
             " [diagnostic truncated]"))))))

(defun request-error (control-and-arguments)
  (error 'egraph-request-error
         :message (bounded-error-message control-and-arguments)))

(defun proper-list-length (value)
  (and (listp value) (list-length value)))

(defun validate-plist (request)
  (let ((length (proper-list-length request)))
    (unless (and length (evenp length))
      (request-error (list "Optimizer request must be a proper property list, got ~S"
                           request))))
  (let ((allowed '(:expression :variables :result-type :theory
                   :round-limit :node-limit))
        (seen '()))
    (loop for tail on request by #'cddr
          for key = (first tail)
          do (unless (member key allowed :test #'eq)
               (request-error (list "Unknown optimizer option ~S" key)))
             (when (member key seen :test #'eq)
               (request-error (list "Duplicate optimizer option ~S" key)))
             (push key seen))
    request))

(defun option-value (request)
  (destructuring-bind (plist key default) request
    (let* ((missing (gensym "MISSING-"))
           (value (getf plist key missing)))
      (if (eq value missing) default value))))

(defun inclusive-bound-p (value)
  (or (eq value '*)
      (and (integerp value)
           (<= (integer-length value) +maximum-constant-bits+))))

(defun integer-type-p (type)
  (or (eq type 'integer)
      (eq type 'fixnum)
      (and (consp type)
           (= (or (proper-list-length type) -1) 3)
           (eq (first type) 'integer)
           (inclusive-bound-p (second type))
           (inclusive-bound-p (third type))
           (or (eq (second type) '*)
               (eq (third type) '*)
               (<= (second type) (third type))))))

(defun validate-variable (variable)
  (unless (and (consp variable)
               (= (or (proper-list-length variable) -1) 2)
               (symbolp (first variable))
               (symbol-package (first variable))
               (not (keywordp (first variable)))
               (not (member (first variable) '(nil t) :test #'eq))
               (integer-type-p (second variable)))
    (request-error
     (list "Variable declarations must be (interned-symbol integer-type), got ~S"
           variable)))
  variable)

(defun validate-variables (variables)
  (unless (proper-list-length variables)
    (request-error (list "Variables must be a proper list, got ~S" variables)))
  (let ((validated (mapcar #'validate-variable variables))
        (seen '()))
    (dolist (variable validated)
      (when (member (first variable) seen :test #'eq)
        (request-error (list "Duplicate variable ~S" (first variable))))
      (push (first variable) seen))
    validated))

(defun validate-limit (request)
  (destructuring-bind (name value hard-maximum) request
    (unless (and (integerp value) (plusp value) (<= value hard-maximum))
      (request-error
       (list "~S must be an integer in 1..~D, got ~S"
             name hard-maximum value)))
    value))

(defun variable-declared-p (request)
  (destructuring-bind (symbol variables) request
    (not (null (assoc symbol variables :test #'eq)))))

(defun validate-expression-node (request)
  (destructuring-bind (expression variables depth states unique-conses) request
    (when (> depth +maximum-expression-depth+)
      (request-error
       (list "Expression depth exceeds ~D" +maximum-expression-depth+)))
    (cond
      ((integerp expression)
       (when (> (integer-length expression) +maximum-constant-bits+)
         (request-error
          (list "Integer literal exceeds the ~D-bit optimizer limit"
                +maximum-constant-bits+)))
       expression)
      ((symbolp expression)
       (unless (variable-declared-p (list expression variables))
         (request-error (list "Undeclared or unsupported atom ~S" expression)))
       expression)
      ((consp expression)
       (case (gethash expression states)
         (:visiting
           (request-error
            (list "Circular expression graph is unsupported: ~S" expression)))
         (:done
          (request-error
           (list "Shared expression cons cells are unsupported: ~S"
                 expression))))
       (setf (gethash expression states) :visiting)
       (incf (car unique-conses))
       (when (> (car unique-conses) +maximum-input-conses+)
         (request-error
          (list "Expression graph exceeds ~D unique cons cells"
                +maximum-input-conses+)))
       (unless (= (or (proper-list-length expression) -1) 3)
         (request-error
          (list "Only binary CL:+ and CL:* forms are supported, got ~S"
                expression)))
       (let ((operator (first expression)))
         (unless (or (eq operator 'cl:+) (eq operator 'cl:*))
           (request-error
            (list "Unsupported operator ~S; only the actual CL:+ and CL:* symbols are allowed"
                  operator))))
       (validate-expression-node
        (list (second expression) variables (1+ depth) states unique-conses))
       (validate-expression-node
        (list (third expression) variables (1+ depth) states unique-conses))
       (setf (gethash expression states) :done)
       expression)
      (t
       (request-error
        (list "Only exact integer literals and declared variables are supported, got ~S"
              expression))))))

(defun validate-expression (request)
  (destructuring-bind (expression variables) request
    (validate-expression-node
     (list expression variables 0 (make-hash-table :test #'eq) (list 0)))))

(defun validate-request (request)
  (validate-plist request)
  (let* ((missing (gensym "MISSING-"))
         (expression (getf request :expression missing))
         (variables (validate-variables
                     (option-value (list request :variables '()))))
         (result-type (getf request :result-type missing))
         (theory (option-value (list request :theory :exact-integer)))
         (round-limit
           (validate-limit
            (list :round-limit
                  (option-value
                   (list request :round-limit +maximum-rounds+))
                  +maximum-rounds+)))
         (node-limit
           (validate-limit
            (list :node-limit
                  (option-value
                   (list request :node-limit +maximum-nodes+))
                  +maximum-nodes+))))
    (when (eq expression missing)
      (request-error (list "Optimizer request is missing :EXPRESSION")))
    (when (eq result-type missing)
      (request-error (list "Optimizer request is missing :RESULT-TYPE")))
    (unless (eq theory :exact-integer)
      (request-error
       (list "Only :EXACT-INTEGER theory is supported, got ~S" theory)))
    (unless (integer-type-p result-type)
      (request-error
       (list "Result type must be an exact integer type, got ~S" result-type)))
    (validate-expression (list expression variables))
    (make-validated-request
     :expression expression
     :variables variables
     :result-type result-type
     :theory theory
     :round-limit round-limit
     :node-limit node-limit)))

(defun graph-find (request)
  (destructuring-bind (graph identifier) request
    (let ((parent (aref (e-graph-parents graph) identifier)))
      (if (= parent identifier)
          identifier
          (let ((root (graph-find (list graph parent))))
            (setf (aref (e-graph-parents graph) identifier) root)
            root)))))

(defun canonical-node (request)
  (destructuring-bind (graph node) request
    (if (eq (e-node-kind node) :call)
        (make-e-node
         :call
         (e-node-value node)
         (mapcar (lambda (child) (graph-find (list graph child)))
                 (e-node-children node))
         (e-node-original-p node))
        node)))

(defun node-key (node)
  (list (e-node-kind node)
        (e-node-value node)
        (e-node-children node)))

(defun symbol-key (symbol)
  (let ((package (symbol-package symbol)))
    (format nil "~A::~A"
            (if package (package-name package) "#")
            (symbol-name symbol))))

(defun node-order-key (node)
  (case (e-node-kind node)
    (:constant (format nil "0:~D" (e-node-value node)))
    (:variable (format nil "1:~A" (symbol-key (e-node-value node))))
    (:call
     (format nil "2:~A:~{~D~^,~}"
             (symbol-key (e-node-value node))
             (e-node-children node)))
    (otherwise (format nil "9:~S" (node-key node)))))

(defun class-identifiers (graph)
  (loop for identifier below (length (e-graph-parents graph))
        when (and (= identifier (graph-find (list graph identifier)))
                  (aref (e-graph-classes graph) identifier))
          collect identifier))

(defun class-nodes (request)
  (destructuring-bind (graph identifier) request
    (copy-list
     (aref (e-graph-classes graph)
           (graph-find (list graph identifier))))))

(defun mark-existing-original (request)
  (destructuring-bind (graph identifier key) request
    (let ((root (graph-find (list graph identifier))))
      (dolist (node (aref (e-graph-classes graph) root))
        (when (equal key (node-key (canonical-node (list graph node))))
          (setf (e-node-original-p node) t))))))

(defun add-enode (request)
  (destructuring-bind (graph raw-node) request
    (let* ((node (canonical-node (list graph raw-node)))
           (key (node-key node))
           (existing (gethash key (e-graph-memo graph))))
      (if existing
          (progn
            (when (e-node-original-p node)
              (mark-existing-original (list graph existing key)))
            (cons (graph-find (list graph existing)) nil))
          (progn
            (when (>= (e-graph-node-count graph)
                      (e-graph-node-limit graph))
              (error 'egraph-resource-limit
                     :kind :node
                     :limit (e-graph-node-limit graph)))
            (let ((identifier (length (e-graph-parents graph))))
              (vector-push-extend identifier (e-graph-parents graph))
              (vector-push-extend (list node) (e-graph-classes graph))
              (setf (gethash key (e-graph-memo graph)) identifier)
              (incf (e-graph-node-count graph))
              (cons identifier t)))))))

(defun graph-union (request)
  (destructuring-bind (graph left right) request
    (let ((left-root (graph-find (list graph left)))
          (right-root (graph-find (list graph right))))
      (if (= left-root right-root)
          (cons left-root nil)
          (let* ((winner (min left-root right-root))
                 (loser (max left-root right-root))
                 (winner-nodes (aref (e-graph-classes graph) winner))
                 (loser-nodes (aref (e-graph-classes graph) loser)))
            (setf (aref (e-graph-parents graph) loser) winner
                  (aref (e-graph-classes graph) winner)
                  (append winner-nodes loser-nodes)
                  (aref (e-graph-classes graph) loser) nil)
            (incf (e-graph-union-count graph))
            (cons winner t))))))

(defun note-application (request)
  (destructuring-bind (graph changed-p) request
    (when changed-p
      (when (>= (e-graph-application-count graph)
                +maximum-rewrite-applications+)
        (error 'egraph-resource-limit
               :kind :rewrite-application
               :limit +maximum-rewrite-applications+))
      (incf (e-graph-application-count graph)))
    changed-p))

(defun note-attempt (graph)
  (when (>= (e-graph-attempt-count graph) +maximum-rewrite-attempts+)
    (error 'egraph-resource-limit
           :kind :rewrite-attempt
           :limit +maximum-rewrite-attempts+))
  (incf (e-graph-attempt-count graph))
  t)

(defun equate-class (request)
  (destructuring-bind (graph left right) request
    (note-application
     (list graph (cdr (graph-union (list graph left right)))))))

(defun equate-node (request)
  (destructuring-bind (graph identifier node) request
    (let* ((added (add-enode (list graph node)))
           (merged (graph-union (list graph identifier (car added))))
           (changed (or (cdr added) (cdr merged))))
      (note-application (list graph changed)))))

(defun deduplicate-nodes (request)
  (destructuring-bind (graph nodes) request
    (let ((by-key (make-hash-table :test #'equal)))
      (dolist (raw-node nodes)
        (let* ((node (canonical-node (list graph raw-node)))
               (key (node-key node))
               (existing (gethash key by-key)))
          (if existing
              (when (e-node-original-p node)
                (setf (e-node-original-p existing) t))
              (setf (gethash key by-key) node))))
      (sort (loop for node being the hash-values of by-key collect node)
            #'string< :key #'node-order-key))))

(defun rebuild-graph (graph)
  (let ((changed-any nil))
    (loop
      (let ((changed nil)
            (memo (make-hash-table :test #'equal)))
        (dolist (identifier (class-identifiers graph))
          (setf (aref (e-graph-classes graph) identifier)
                (deduplicate-nodes
                 (list graph (aref (e-graph-classes graph) identifier)))))
        (dolist (identifier (class-identifiers graph))
          (dolist (node (aref (e-graph-classes graph) identifier))
            (let* ((canonical (canonical-node (list graph node)))
                   (key (node-key canonical))
                   (existing (gethash key memo)))
              (if existing
                  (let ((merged (graph-union
                                 (list graph identifier existing))))
                    (when (cdr merged)
                      (setf changed t
                            changed-any t)
                      (note-application (list graph t))))
                  (setf (gethash key memo) identifier)))))
        (unless changed
          (setf (e-graph-memo graph) memo)
          (return changed-any))))))

(defun add-term-node (request)
  (destructuring-bind (graph expression original-p cache) request
    (cond
      ((integerp expression)
       (add-enode
        (list graph (make-e-node :constant expression nil original-p))))
      ((symbolp expression)
       (add-enode
        (list graph (make-e-node :variable expression nil original-p))))
      (t
       (let ((cached (gethash expression cache)))
         (if cached
             (cons cached nil)
             (let* ((left
                      (add-term-node
                       (list graph (second expression) original-p cache)))
                    (right
                      (add-term-node
                       (list graph (third expression) original-p cache)))
                    (added
                      (add-enode
                       (list graph
                             (make-e-node :call
                                          (first expression)
                                          (list (car left) (car right))
                                          original-p)))))
               (setf (gethash expression cache) (car added))
               added)))))))

(defun add-term (request)
  (destructuring-bind (graph expression original-p) request
    (add-term-node
     (list graph expression original-p (make-hash-table :test #'eq)))))

(defun make-call-node (request)
  (destructuring-bind (operator left right) request
    (make-e-node :call operator (list left right) nil)))

(defun class-constant (request)
  (destructuring-bind (graph identifier) request
    (let ((values
            (remove-duplicates
             (loop for node in (class-nodes (list graph identifier))
                   when (eq (e-node-kind node) :constant)
                     collect (e-node-value node))
             :test #'eql)))
      (when (> (length values) 1)
        (request-error
         (list "Conflicting constants were merged into one e-class: ~S" values)))
      (and values (cons t (first values))))))

(defun call-nodes (request)
  (destructuring-bind (graph identifier operator) request
    (remove-if-not
     (lambda (node)
       (and (eq (e-node-kind node) :call)
            (eq (e-node-value node) operator)))
     (class-nodes (list graph identifier)))))

(defun class-has-leaf-p (request)
  (destructuring-bind (graph identifier) request
    (some (lambda (node)
            (not (eq (e-node-kind node) :call)))
          (class-nodes (list graph identifier)))))

(defun add-derived-call (request)
  (destructuring-bind (graph operator left right) request
    (car (add-enode
          (list graph (make-call-node (list operator left right)))))))

(defun apply-identity-rules (request)
  (destructuring-bind (graph identifier operator left right) request
    (note-attempt graph)
    (let ((changed nil)
          (left-constant (class-constant (list graph left)))
          (right-constant (class-constant (list graph right))))
      (when (and (eq operator 'cl:+)
                 left-constant (eql (cdr left-constant) 0))
        (setf changed
              (or (equate-class (list graph identifier right)) changed)))
      (when (and (eq operator 'cl:+)
                 right-constant (eql (cdr right-constant) 0))
        (setf changed
              (or (equate-class (list graph identifier left)) changed)))
      (when (and (eq operator 'cl:*)
                 left-constant (eql (cdr left-constant) 1))
        (setf changed
              (or (equate-class (list graph identifier right)) changed)))
      (when (and (eq operator 'cl:*)
                 right-constant (eql (cdr right-constant) 1))
        (setf changed
              (or (equate-class (list graph identifier left)) changed)))
      (when (and (eq operator 'cl:*)
                 (or (and left-constant (eql (cdr left-constant) 0))
                     (and right-constant (eql (cdr right-constant) 0))))
        (setf changed
              (or (equate-node
                   (list graph identifier
                         (make-e-node :constant 0 nil nil)))
                  changed)))
      changed)))

(defun apply-constant-rule (request)
  (destructuring-bind (graph identifier operator left right) request
    (note-attempt graph)
    (let ((left-constant (class-constant (list graph left)))
          (right-constant (class-constant (list graph right))))
      (if (and left-constant right-constant)
          (let ((value
                  (funcall operator
                           (cdr left-constant)
                           (cdr right-constant))))
            (when (> (integer-length value) +maximum-constant-bits+)
              (error 'egraph-resource-limit
                     :kind :constant-bit-length
                     :limit +maximum-constant-bits+))
            (equate-node
             (list graph identifier
                   (make-e-node :constant value nil nil))))
          nil))))

(defun apply-commutative-rule (request)
  (destructuring-bind (graph identifier operator left right) request
    (note-attempt graph)
    (equate-node
     (list graph identifier (make-call-node (list operator right left))))))

(defun apply-associative-rules (request)
  (destructuring-bind (graph identifier operator left right) request
    (note-attempt graph)
    (let ((changed nil))
      (dolist (nested (call-nodes (list graph left operator)))
        (note-attempt graph)
        (destructuring-bind (first second) (e-node-children nested)
          (let* ((inner (add-derived-call (list graph operator second right)))
                 (outer (make-call-node (list operator first inner))))
            (setf changed
                  (or (equate-node (list graph identifier outer)) changed)))))
      (dolist (nested (call-nodes (list graph right operator)))
        (note-attempt graph)
        (destructuring-bind (second third) (e-node-children nested)
          (let* ((inner (add-derived-call (list graph operator left second)))
                 (outer (make-call-node (list operator inner third))))
            (setf changed
                  (or (equate-node (list graph identifier outer)) changed)))))
      changed)))

(defun shared-factors (request)
  (destructuring-bind (graph left-node right-node) request
    (let ((left (mapcar (lambda (identifier)
                          (graph-find (list graph identifier)))
                        (e-node-children left-node)))
          (right (mapcar (lambda (identifier)
                           (graph-find (list graph identifier)))
                         (e-node-children right-node)))
          (result '()))
      (dolist (left-factor left)
        (dolist (right-factor right)
          (when (= left-factor right-factor)
            (let ((left-rest (if (= left-factor (first left))
                                 (second left)
                                 (first left)))
                  (right-rest (if (= right-factor (first right))
                                  (second right)
                                  (first right))))
              (pushnew (list left-factor left-rest right-rest)
                       result :test #'equal)))))
      (sort result
            (lambda (left-triple right-triple)
              (loop for left in left-triple
                    for right in right-triple
                    when (< left right) return t
                    when (> left right) return nil
                    finally (return nil)))))))

(defun apply-factor-rule (request)
  (destructuring-bind (graph identifier left right) request
    (note-attempt graph)
    (let ((changed nil))
      (dolist (left-node (call-nodes (list graph left 'cl:*)))
        (dolist (right-node (call-nodes (list graph right 'cl:*)))
          (note-attempt graph)
          (dolist (factor (shared-factors (list graph left-node right-node)))
            (note-attempt graph)
            (destructuring-bind (common left-rest right-rest) factor
              (let* ((sum (add-derived-call
                           (list graph 'cl:+ left-rest right-rest)))
                     (product (make-call-node (list 'cl:* common sum))))
                (setf changed
                      (or (equate-node (list graph identifier product))
                          changed)))))))
      changed)))

(defun apply-node-rules (request)
  (destructuring-bind (graph identifier raw-node) request
    (let ((node (canonical-node (list graph raw-node))))
      (if (not (eq (e-node-kind node) :call))
          nil
          (destructuring-bind (left right) (e-node-children node)
            (let ((operator (e-node-value node))
                  (changed nil))
              (setf changed
                    (or (apply-identity-rules
                         (list graph identifier operator left right))
                        changed))
              (setf changed
                    (or (apply-constant-rule
                         (list graph identifier operator left right))
                        changed))
              (unless (class-has-leaf-p (list graph identifier))
                (setf changed
                      (or (apply-commutative-rule
                           (list graph identifier operator left right))
                          changed))
                (setf changed
                      (or (apply-associative-rules
                           (list graph identifier operator left right))
                          changed))
                (when (eq operator 'cl:+)
                  (setf changed
                        (or (apply-factor-rule
                             (list graph identifier left right))
                            changed))))
              changed))))))

(defun graph-snapshot (graph)
  (loop for identifier in (class-identifiers graph)
        append
        (loop for node in (class-nodes (list graph identifier))
              collect (list identifier node))))

(defun saturate-graph (request)
  (destructuring-bind (graph round-limit) request
    (loop for round from 1 to round-limit
          do (let ((nodes-before (e-graph-node-count graph))
                   (unions-before (e-graph-union-count graph))
                   (applications-before (e-graph-application-count graph)))
               (dolist (entry (graph-snapshot graph))
                 (apply-node-rules (list graph (first entry) (second entry))))
               (rebuild-graph graph)
               (when (and (= nodes-before (e-graph-node-count graph))
                          (= unions-before (e-graph-union-count graph))
                          (= applications-before
                             (e-graph-application-count graph)))
                 (return round)))
          finally
             (error 'egraph-resource-limit
                    :kind :round
                    :limit round-limit))))

(defun form-key (form)
  (cond
    ((integerp form) (format nil "0:~D" form))
    ((symbolp form) (format nil "1:~A" (symbol-key form)))
    (t (format nil "2:~A(~A,~A)"
               (symbol-key (first form))
               (form-key (second form))
               (form-key (third form))))))

(defun operator-cost (operator)
  (cond
    ((eq operator 'cl:+) 1)
    ((eq operator 'cl:*) 2)
    (t (request-error (list "No cost for unsupported operator ~S" operator)))))

(defun choice-score (choice)
  (list (choice-cost choice)
        (choice-node-count choice)
        (choice-nonoriginal-count choice)
        (choice-depth choice)
        (choice-key choice)))

(defun score-less-p (request)
  (destructuring-bind (left right) request
    (labels ((walk (left-items right-items)
               (cond
                 ((null left-items) nil)
                 ((and (numberp (first left-items))
                       (numberp (first right-items)))
                  (cond
                    ((< (first left-items) (first right-items)) t)
                    ((> (first left-items) (first right-items)) nil)
                    (t (walk (rest left-items) (rest right-items)))))
                 (t (string< (first left-items) (first right-items))))))
      (walk left right))))

(defun better-choice-p (request)
  (destructuring-bind (candidate current) request
    (or (null current)
        (score-less-p
         (list (choice-score candidate) (choice-score current))))))

(defun choice-for-node (request)
  (destructuring-bind (graph node choices) request
    (case (e-node-kind node)
      (:constant
       (let ((form (e-node-value node)))
         (make-choice :form form :cost 0 :node-count 1
                      :nonoriginal-count
                      (if (e-node-original-p node) 0 1)
                      :depth 1 :key (form-key form))))
      (:variable
       (let ((form (e-node-value node)))
         (make-choice :form form :cost 0 :node-count 1
                      :nonoriginal-count
                      (if (e-node-original-p node) 0 1)
                      :depth 1 :key (form-key form))))
      (:call
       (let* ((children
                (mapcar
                 (lambda (identifier)
                   (gethash (graph-find (list graph identifier)) choices))
                 (e-node-children node))))
         (when (every #'identity children)
           (let* ((left (first children))
                  (right (second children))
                  (form (list (e-node-value node)
                              (choice-form left)
                              (choice-form right))))
             (make-choice
              :form form
              :cost (+ (operator-cost (e-node-value node))
                       (choice-cost left)
                       (choice-cost right))
              :node-count (+ 1 (choice-node-count left)
                             (choice-node-count right))
              :nonoriginal-count
              (+ (if (e-node-original-p node) 0 1)
                 (choice-nonoriginal-count left)
                 (choice-nonoriginal-count right))
              :depth (1+ (max (choice-depth left) (choice-depth right)))
              :key (form-key form))))))
      (otherwise nil))))

(defun extract-choice (graph)
  (let* ((identifiers (class-identifiers graph))
         (choices (make-hash-table :test #'eql))
         (maximum-passes (1+ (length identifiers))))
    (loop repeat maximum-passes
      do
      (let ((changed nil))
        (dolist (identifier identifiers)
          (let ((current (gethash identifier choices)))
            (dolist (node (class-nodes (list graph identifier)))
              (let ((candidate (choice-for-node (list graph node choices))))
                (when (and candidate
                           (better-choice-p (list candidate current)))
                  (setf current candidate
                        (gethash identifier choices) candidate
                        changed t))))))
        (unless changed (return))))
    (gethash (graph-find (list graph (e-graph-root graph))) choices)))

(defun form-cost (form)
  (if (atom form)
      0
      (+ (operator-cost (first form))
         (form-cost (second form))
         (form-cost (third form)))))

(defun type-range (type)
  (cond
    ((eq type 'fixnum) (list most-negative-fixnum most-positive-fixnum))
    ((eq type 'integer) (list '* '*))
    ((and (consp type) (eq (first type) 'integer))
     (list (second type) (third type)))
    (t (list '* '*))))

(defun bounded-range-p (range)
  (and (integerp (first range)) (integerp (second range))))

(defun add-ranges (request)
  (destructuring-bind (left right) request
    (if (and (bounded-range-p left) (bounded-range-p right))
        (list (+ (first left) (first right))
              (+ (second left) (second right)))
        (list '* '*))))

(defun multiply-ranges (request)
  (destructuring-bind (left right) request
    (if (and (bounded-range-p left) (bounded-range-p right))
        (let ((products
                (list (* (first left) (first right))
                      (* (first left) (second right))
                      (* (second left) (first right))
                      (* (second left) (second right)))))
          (list (apply #'min products) (apply #'max products)))
        (list '* '*))))

(defun infer-range (request)
  (destructuring-bind (form variables) request
    (cond
      ((integerp form) (list form form))
      ((symbolp form)
       (type-range (second (assoc form variables :test #'eq))))
      ((eq (first form) 'cl:+)
       (add-ranges
        (list (infer-range (list (second form) variables))
              (infer-range (list (third form) variables)))))
      ((eq (first form) 'cl:*)
       (multiply-ranges
        (list (infer-range (list (second form) variables))
              (infer-range (list (third form) variables)))))
      (t (list '* '*)))))

(defun range-within-type-p (request)
  (destructuring-bind (range type) request
    (let ((declared (type-range type)))
      (and
       (or (eq (first declared) '*)
           (and (integerp (first range))
                (>= (first range) (first declared))))
       (or (eq (second declared) '*)
           (and (integerp (second range))
                (<= (second range) (second declared))))))))

(defun make-limit-result (request)
  (destructuring-bind (validated graph condition) request
    (make-optimization-result
     :status :limit
     :original-form (validated-request-expression validated)
     :form nil
     :original-cost (form-cost (validated-request-expression validated))
     :cost nil
     :rounds nil
     :node-count (e-graph-node-count graph)
     :class-count (length (class-identifiers graph))
     :application-count (e-graph-application-count graph)
     :attempt-count (e-graph-attempt-count graph)
     :inferred-range nil
     :theory (validated-request-theory validated)
     :reason (format nil "~A limit ~D"
                     (egraph-resource-limit-kind condition)
                     (egraph-resource-limit-value condition)))))

(defun optimize-egraph-expression (request)
  "Optimize one closed exact-integer expression without mutating REQUEST."
  (let* ((validated (validate-request request))
         (graph (make-e-graph
                 :node-limit (validated-request-node-limit validated))))
    (handler-case
        (let* ((seed
                 (add-term
                  (list graph
                        (validated-request-expression validated)
                        t)))
               (root (car seed)))
          (setf (e-graph-root graph) root)
          (let* ((rounds
                   (saturate-graph
                    (list graph (validated-request-round-limit validated))))
                 (choice (extract-choice graph)))
            (unless choice
              (return-from optimize-egraph-expression
                (make-optimization-result
                 :status :no-acyclic-extraction
                 :original-form (validated-request-expression validated)
                 :form nil
                 :original-cost
                 (form-cost (validated-request-expression validated))
                 :cost nil :rounds rounds
                 :node-count (e-graph-node-count graph)
                 :class-count (length (class-identifiers graph))
                 :application-count (e-graph-application-count graph)
                 :attempt-count (e-graph-attempt-count graph)
                 :theory (validated-request-theory validated)
                 :reason "Root e-class has no finite acyclic expression")))
            (let* ((original (validated-request-expression validated))
                   (original-cost (form-cost original))
                   (choice-cost (choice-cost choice))
                   (improved-p (< choice-cost original-cost))
                   (form (if improved-p (choice-form choice) original))
                   (membership (add-term (list graph form nil)))
                   (inferred-range
                     (infer-range
                      (list form (validated-request-variables validated)))))
              (unless (= (graph-find (list graph (car membership)))
                         (graph-find (list graph (e-graph-root graph))))
                (request-error
                 (list "Extracted form is not a member of the root e-class: ~S"
                       form)))
              (unless (range-within-type-p
                       (list inferred-range
                             (validated-request-result-type validated)))
                (request-error
                 (list "Inferred result range ~S is not contained in declared type ~S"
                       inferred-range
                       (validated-request-result-type validated))))
              (make-optimization-result
               :status (if improved-p :optimized :unchanged)
               :original-form original
               :form form
               :original-cost original-cost
               :cost (if improved-p choice-cost original-cost)
               :rounds rounds
               :node-count (e-graph-node-count graph)
               :class-count (length (class-identifiers graph))
               :application-count (e-graph-application-count graph)
               :attempt-count (e-graph-attempt-count graph)
               :inferred-range inferred-range
               :theory (validated-request-theory validated)
               :reason nil))))
      (egraph-resource-limit (condition)
        (make-limit-result (list validated graph condition))))))

(defun macro-result-form (result)
  (case (optimization-result-status result)
    ((:optimized :unchanged) (optimization-result-form result))
    (otherwise
     (error "E-graph optimization failed (~A): ~A"
            (optimization-result-status result)
            (optimization-result-reason result)))))

(defun ensure-lexical-macro-variables (request)
  (destructuring-bind (variables environment) request
    (dolist (variable variables)
      (multiple-value-bind (kind local-p declarations)
          (sb-cltl2:variable-information (first variable) environment)
        (declare (ignore local-p declarations))
        (unless (eq kind :lexical)
          (request-error
           (list "EGRAPH-EXPRESSION variable ~S must be lexical, got ~S"
                 (first variable) kind)))))
    variables))

(defun ensure-standard-arithmetic-bindings (environment)
  (unless (sb-ext:package-locked-p (find-package :cl))
    (request-error
     (list "EGRAPH-EXPRESSION requires the COMMON-LISP package to be locked")))
  (dolist (binding
            (list (cons 'cl:+ +expected-cl-plus-function+)
                  (cons 'cl:* +expected-cl-times-function+)))
    (multiple-value-bind (kind local-p declarations)
        (sb-cltl2:function-information (car binding) environment)
      (declare (ignore declarations))
      (unless (and (eq kind :function)
                   (not local-p)
                   (eq (symbol-function (car binding)) (cdr binding)))
        (request-error
         (list "EGRAPH-EXPRESSION requires the standard global function binding for ~S"
               (car binding))))))
  t)

(defmacro egraph-expression
    (variables result-type options &environment environment &body body)
  "Optimize one exact-integer expression at macro-expansion time."
  (unless (= (or (proper-list-length body) -1) 1)
    (request-error
     (list "EGRAPH-EXPRESSION requires exactly one expression, got ~S" body)))
  (unless (proper-list-length options)
    (request-error
     (list "EGRAPH-EXPRESSION options must be a literal proper list, got ~S"
           options)))
  (let* ((validated-variables (validate-variables variables))
         (request
           (append
            (list :expression (first body)
                  :variables validated-variables
                  :result-type result-type)
            options)))
    (ensure-lexical-macro-variables
     (list validated-variables environment))
    (ensure-standard-arithmetic-bindings environment)
    (let* ((result (optimize-egraph-expression request))
           (form (macro-result-form result)))
      `(locally
         (declare
          ,@(mapcar (lambda (variable)
                      `(type ,(second variable) ,(first variable)))
                    validated-variables))
         (the ,result-type ,form)))))

(defmacro define-egraph-kernel (name signature options &body body)
  "Define one unary exact-integer kernel from a saturated expression graph."
  (unless (and (symbolp name)
               (= (or (proper-list-length signature) -1) 2))
    (request-error
     (list "Signature syntax is ((input input-type) result-type), got ~S"
           signature)))
  (unless (proper-list-length options)
    (request-error
     (list "DEFINE-EGRAPH-KERNEL options must be a literal proper list, got ~S"
           options)))
  (destructuring-bind (input-spec result-type) signature
    (unless (and (= (or (proper-list-length input-spec) -1) 2)
                 (symbolp (first input-spec)))
      (request-error
       (list "Input signature must be (name type), got ~S" input-spec)))
    (unless (= (or (proper-list-length body) -1) 1)
      (error "DEFINE-EGRAPH-KERNEL requires exactly one expression"))
    (destructuring-bind (input input-type) input-spec
      `(progn
         (declaim (ftype (function (,input-type) ,result-type) ,name))
         (defun ,name (,input)
           (declare (type ,input-type ,input)
                    (optimize (speed 3) (safety 1) (debug 1)))
           (egraph-expression ((,input ,input-type))
               ,result-type ,options
             ,(first body)))))))
