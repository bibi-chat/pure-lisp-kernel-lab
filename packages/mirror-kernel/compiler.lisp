(defpackage #:mirror-kernel
  (:use #:cl)
  (:export
   #:mirror-node
   #:mirror-node-id
   #:mirror-node-operator
   #:mirror-node-inputs
   #:mirror-node-output-type
   #:mirror-node-shape
   #:mirror-node-effect
   #:mirror-node-attributes
   #:semantic-graph
   #:semantic-graph-id
   #:semantic-graph-nodes
   #:semantic-graph-output
   #:semantic-graph-domain
   #:machine-pattern
   #:machine-pattern-id
   #:machine-target
   #:machine-target-id
   #:machine-target-patterns
   #:cover-entry
   #:cover-entry-node-id
   #:cover-entry-pattern-id
   #:cover-entry-cost
   #:cover-result
   #:cover-result-status
   #:cover-result-entries
   #:cover-result-schedule
   #:cover-result-uncovered
   #:cover-result-reason
   #:batch-plan
   #:batch-plan-schedule
   #:batch-plan-total-cost
   #:batch-plan-certificate
   #:compilation-result
   #:compilation-result-status
   #:compilation-result-graph
   #:compilation-result-target
   #:compilation-result-cover
   #:compilation-result-plan
   #:compilation-result-form
   #:compilation-result-certificate
   #:compilation-result-reason
   #:make-rq8-matvec-graph
   #:make-sbcl-scalar-target
   #:compatibility-matrix
   #:cover-semantic-graph
   #:compile-rq8-matvec
   #:define-rq8-matvec-kernel))

(in-package #:mirror-kernel)

(declaim (optimize (speed 2) (safety 3) (debug 2)))

(defparameter +contract+ "mirror-kernel/v0")
(defconstant +semantic-id+ :rq8-matvec-32x64-row/v0)
(defconstant +target-id+ :sbcl-typed-common-lisp/v0)
(defparameter +rq8-batch-emitter-sequence+
  '(:argument
    :project :project :project :project
    :fresh-output :row-loop :load-exponent :scale-float-one
    :block-loop :row-block-index :load-numerator :numerator-f32 :mul-f32
    :lane-loop :block-column-index :row-column-index
    :load-quant :signed-byte-to-f32 :load-f32 :mul-f32 :mul-f32
    :ordered-fold :store-row))

(defstruct (mirror-node
            (:constructor %make-mirror-node
                (id operator inputs output-type shape effect attributes)))
  (id nil :read-only t)
  (operator nil :read-only t)
  (inputs nil :type list :read-only t)
  (output-type nil :read-only t)
  (shape nil :read-only t)
  (effect nil :read-only t)
  (attributes nil :type list :read-only t))

(defstruct (semantic-graph
            (:constructor %make-semantic-graph
                (id nodes output domain)))
  (id nil :read-only t)
  (nodes nil :type list :read-only t)
  (output nil :read-only t)
  (domain nil :type list :read-only t))

(defstruct (machine-pattern
            (:constructor %make-machine-pattern
                (id operator input-types output-type shape effect
                 required-attributes cost emitter)))
  (id nil :read-only t)
  (operator nil :read-only t)
  (input-types nil :type list :read-only t)
  (output-type nil :read-only t)
  (shape nil :read-only t)
  (effect nil :read-only t)
  (required-attributes nil :type list :read-only t)
  (cost 0 :type (integer 0 *) :read-only t)
  (emitter nil :read-only t))

(defstruct (machine-target
            (:constructor %make-machine-target (id patterns policy)))
  (id nil :read-only t)
  (patterns nil :type list :read-only t)
  (policy nil :type list :read-only t))

(defstruct (validation-result
            (:constructor %make-validation-result (status reason)))
  (status nil :read-only t)
  (reason nil :read-only t))

(defstruct (cover-entry
            (:constructor %make-cover-entry (node-id pattern-id cost emitter)))
  (node-id nil :read-only t)
  (pattern-id nil :read-only t)
  (cost 0 :type (integer 0 *) :read-only t)
  (emitter nil :read-only t))

(defstruct (cover-result
            (:constructor %make-cover-result
                (status entries schedule uncovered reason)))
  (status nil :read-only t)
  (entries nil :type list :read-only t)
  (schedule nil :type list :read-only t)
  (uncovered nil :type list :read-only t)
  (reason nil :read-only t))

(defstruct (batch-plan
            (:constructor %make-batch-plan
                (graph target entries schedule total-cost certificate)))
  (graph nil :type semantic-graph :read-only t)
  (target nil :type machine-target :read-only t)
  (entries nil :type list :read-only t)
  (schedule nil :type list :read-only t)
  (total-cost 0 :type (integer 0 *) :read-only t)
  (certificate nil :type list :read-only t))

(defstruct (compilation-result
            (:constructor %make-compilation-result
                (status graph target cover plan form certificate reason)))
  (status nil :read-only t)
  (graph nil :read-only t)
  (target nil :read-only t)
  (cover nil :read-only t)
  (plan nil :read-only t)
  (form nil :read-only t)
  (certificate nil :read-only t)
  (reason nil :read-only t))

(defun proper-even-plist-p (value)
  (cond
    ((null value) t)
    ((and (consp value) (consp (cdr value)))
     (proper-even-plist-p (cddr value)))
    (t nil)))

(defun option-value (request)
  (destructuring-bind (options key default) request
    (getf options key default)))

(defun normalize-options (options)
  (unless (proper-even-plist-p options)
    (error "Mirror options must be a proper even property list, got ~S." options))
  (let ((allowed '(:columns :block-size :blocks-per-group :reduction-order
                   :target :fallback :disabled-patterns))
        (seen '()))
    (loop for tail on options by #'cddr
          for key = (first tail)
          do (unless (member key allowed :test #'eq)
               (error "Unknown mirror option ~S." key))
             (when (member key seen :test #'eq)
               (error "Duplicate mirror option ~S." key))
             (push key seen))
    (let ((normalized
            (list
             :columns (option-value (list options :columns 2048))
             :block-size (option-value (list options :block-size 32))
             :blocks-per-group
             (option-value (list options :blocks-per-group 64))
             :reduction-order
             (option-value
              (list options :reduction-order
                    :left-to-right-single-float))
             :target (option-value (list options :target +target-id+))
             :fallback (option-value (list options :fallback nil))
             :disabled-patterns
             (copy-list
              (option-value (list options :disabled-patterns nil))))))
      (unless (or (null (getf normalized :fallback))
                  (symbolp (getf normalized :fallback)))
        (error "Mirror fallback must be NIL or a function-name symbol, got ~S."
               (getf normalized :fallback)))
      normalized)))

(defun make-node (request)
  (destructuring-bind
      (id operator inputs output-type shape effect &optional attributes)
      request
    (%make-mirror-node
     id operator (copy-list inputs) output-type shape effect
     (copy-tree attributes))))

(defun domain-from-options (options)
  (let ((columns (getf options :columns))
        (blocks-per-group (getf options :blocks-per-group)))
    (list
     :columns columns
     :block-size (getf options :block-size)
     :blocks-per-group blocks-per-group
     :reduction-order (getf options :reduction-order)
     :input :rq8-matvec-request
     :request-length 4
     :tensor :rq8-tensor
     :vector (list :type '(:simple-array :single-float) :length columns)
     :tensor-lengths
     (list :quants (list :rows-times columns)
           :numerators (list :rows-times blocks-per-group)
           :exponents :rows)
     :exponent-inclusive-range '(-126 119)
     :element-count :fixnum
     :output '(:fresh-simple-vector :single-float)
     :rows
     (list :type :fixnum
           :inclusive-range (list 1 most-positive-fixnum)))))

(defun make-rq8-matvec-graph (configuration)
  "Build the canonical semantic graph for one RQ8 denominator group per row."
  (let* ((options (normalize-options configuration))
         (columns (getf options :columns))
         (block-size (getf options :block-size))
         (blocks-per-group (getf options :blocks-per-group))
         (order (getf options :reduction-order))
         (batch-attributes
           (list :columns columns
                 :block-size block-size
                 :blocks-per-group blocks-per-group
                 :reduction-order order))
         (nodes
           (list
            (make-node '(:request :argument () :rq8-request :scalar :pure
                         (:position 0)))
            (make-node '(:tensor :project (:request) :rq8-tensor :scalar :pure
                         (:field :tensor)))
            (make-node '(:vector :project (:request) :f32-vector :columns :pure
                         (:field :vector)))
            (make-node '(:rows :project (:request) :fixnum :scalar :pure
                         (:field :rows)))
            (make-node '(:columns :project (:request) :fixnum :scalar :pure
                         (:field :columns)))
            (make-node
             (list :output :fresh-map-f32 '(:rows) :f32-vector :rows
                   :local-write batch-attributes))
            (make-node
             (list :row :fold-index '(:rows) :fixnum :rows :control
                   (list :region :rows :lower 0 :order :ascending)))
            (make-node '(:exponent :load-s8 (:tensor :row) :signed-byte-8
                         :scalar :pure (:source :exponents)))
            (make-node '(:quantum :scale-float-one (:exponent) :single-float
                         :scalar :pure))
            (make-node
             (list :block :fold-index '(:row) :fixnum :blocks :control
                   (list :region :blocks :lower 0 :upper blocks-per-group
                         :order :ascending)))
            (make-node
             (list :absolute-block :index-linearize '(:row :block) :fixnum
                   :scalar :pure (list :stride blocks-per-group)))
            (make-node '(:numerator :load-u8 (:tensor :absolute-block)
                         :unsigned-byte-8 :scalar :pure
                         (:source :numerators)))
            (make-node '(:numerator-float :u8-plus-one-to-f32 (:numerator)
                         :single-float :scalar :pure))
            (make-node '(:scale :mul-f32-ordered
                         (:numerator-float :quantum)
                         :single-float :scalar :pure (:order :left-to-right)))
            (make-node
             (list :lane :fold-index '(:block) :fixnum :lanes :control
                   (list :region :lanes :lower 0 :upper block-size
                         :order :ascending)))
            (make-node
             (list :column :index-linearize '(:block :lane) :fixnum
                   :scalar :pure (list :stride block-size)))
            (make-node
             (list :index :index-linearize '(:row :column) :fixnum
                   :scalar :pure (list :stride columns)))
            (make-node '(:quant :load-s8 (:tensor :index) :signed-byte-8
                         :scalar :pure (:source :quants)))
            (make-node '(:quant-float :s8-to-f32 (:quant) :single-float
                         :scalar :pure))
            (make-node '(:activation :load-f32 (:vector :column) :single-float
                         :scalar :pure (:source :vector)))
            (make-node '(:dequantized :mul-f32-ordered
                         (:quant-float :scale)
                         :single-float :scalar :pure (:order :left-to-right)))
            (make-node '(:product :mul-f32-ordered
                         (:dequantized :activation)
                         :single-float :scalar :pure (:order :left-to-right)))
            (make-node
             (list :total :fold-add-f32
                   '(:product :row :block :lane)
                   :single-float :row :control
                   (list :initial 0.0f0 :order order)))
            (make-node '(:store :store-f32 (:output :row :total) :f32-vector
                         :rows :local-write (:destination :output))))))
    (%make-semantic-graph
     +semantic-id+ nodes :store (domain-from-options options))))

(defun make-pattern (request)
  (destructuring-bind
      (id operator input-types output-type shape effect required-attributes
       cost emitter)
      request
    (%make-machine-pattern
     id operator (copy-list input-types) output-type shape effect
     (copy-tree required-attributes) cost emitter)))

(defun base-sbcl-patterns (configuration)
  (let ((disabled (getf configuration :disabled-patterns)))
    (remove-if
     (lambda (pattern)
       (member (machine-pattern-id pattern) disabled :test #'eq))
     (list
      (make-pattern '(:argument-list :argument () :rq8-request :scalar :pure
                      (:position 0) 0 :argument))
      (make-pattern '(:project-tensor :project (:rq8-request) :rq8-tensor
                      :scalar :pure (:field :tensor) 0 :project))
      (make-pattern '(:project-vector :project (:rq8-request) :f32-vector
                      :columns :pure (:field :vector) 0 :project))
      (make-pattern '(:project-rows :project (:rq8-request) :fixnum
                      :scalar :pure (:field :rows) 0 :project))
      (make-pattern '(:project-columns :project (:rq8-request) :fixnum
                      :scalar :pure (:field :columns) 0 :project))
      (make-pattern
       '(:fresh-output-2048 :fresh-map-f32 (:fixnum) :f32-vector :rows
         :local-write
         (:columns 2048 :block-size 32 :blocks-per-group 64
          :reduction-order :left-to-right-single-float)
         2 :fresh-output))
      (make-pattern '(:ascending-row-index :fold-index (:fixnum) :fixnum
                      :rows :control
                      (:region :rows :lower 0 :order :ascending)
                      1 :row-loop))
      (make-pattern '(:load-row-exponent :load-s8 (:rq8-tensor :fixnum)
                      :signed-byte-8 :scalar :pure (:source :exponents)
                      1 :load-exponent))
      (make-pattern '(:single-quantum :scale-float-one (:signed-byte-8)
                      :single-float :scalar :pure () 1 :scale-float-one))
      (make-pattern '(:ascending-64-block-index :fold-index (:fixnum) :fixnum
                      :blocks :control
                      (:region :blocks :lower 0 :upper 64 :order :ascending)
                      1 :block-loop))
      (make-pattern '(:row-block-index :index-linearize (:fixnum :fixnum)
                      :fixnum :scalar :pure (:stride 64)
                      1 :row-block-index))
      (make-pattern '(:load-block-numerator :load-u8
                      (:rq8-tensor :fixnum) :unsigned-byte-8 :scalar :pure
                      (:source :numerators) 1 :load-numerator))
      (make-pattern '(:numerator-f32 :u8-plus-one-to-f32
                      (:unsigned-byte-8) :single-float :scalar :pure ()
                      1 :numerator-f32))
      (make-pattern '(:ordered-scale-multiply :mul-f32-ordered
                      (:single-float :single-float) :single-float :scalar
                      :pure (:order :left-to-right) 1 :mul-f32))
      (make-pattern '(:ascending-32-lane-index :fold-index (:fixnum) :fixnum
                      :lanes :control
                      (:region :lanes :lower 0 :upper 32 :order :ascending)
                      1 :lane-loop))
      (make-pattern '(:block-column-index :index-linearize
                      (:fixnum :fixnum) :fixnum :scalar :pure (:stride 32)
                      1 :block-column-index))
      (make-pattern '(:row-column-index :index-linearize
                      (:fixnum :fixnum) :fixnum :scalar :pure (:stride 2048)
                      1 :row-column-index))
      (make-pattern '(:load-quant :load-s8 (:rq8-tensor :fixnum)
                      :signed-byte-8 :scalar :pure (:source :quants)
                      1 :load-quant))
      (make-pattern '(:signed-byte-to-f32 :s8-to-f32 (:signed-byte-8)
                      :single-float :scalar :pure () 1 :signed-byte-to-f32))
      (make-pattern '(:load-activation :load-f32 (:f32-vector :fixnum)
                      :single-float :scalar :pure (:source :vector)
                      1 :load-f32))
      (make-pattern '(:ordered-f32-fold :fold-add-f32
                      (:single-float :fixnum :fixnum :fixnum)
                      :single-float :row :control
                      (:initial 0.0f0 :order :left-to-right-single-float)
                      2 :ordered-fold))
      (make-pattern '(:store-row :store-f32
                      (:f32-vector :fixnum :single-float)
                      :f32-vector :rows :local-write (:destination :output)
                      1 :store-row))))))

(defun make-sbcl-scalar-target (configuration)
  "Lift the closed SBCL scalar capability vocabulary into exact IR patterns."
  (let ((options (normalize-options configuration)))
    (%make-machine-target
     +target-id+
     (base-sbcl-patterns options)
     '((speed 3) (safety 1) (debug 1)
       (:emission :typed-common-lisp)
       (:raw-assembly nil)))))

(defun node-by-id (request)
  (destructuring-bind (graph id) request
    (find id (semantic-graph-nodes graph)
          :key #'mirror-node-id :test #'eq)))

(defun node-input-types (request)
  (destructuring-bind (graph node) request
    (mapcar
     (lambda (input-id)
       (let ((input (node-by-id (list graph input-id))))
         (and input (mirror-node-output-type input))))
     (mirror-node-inputs node))))

(defun validate-graph (graph)
  (let ((seen '()))
    (dolist (node (semantic-graph-nodes graph))
      (let ((id (mirror-node-id node)))
        (when (member id seen :test #'eq)
          (return-from validate-graph
            (%make-validation-result
             :invalid (format nil "Duplicate semantic node ~S." id))))
        (dolist (input (mirror-node-inputs node))
          (unless (member input seen :test #'eq)
            (return-from validate-graph
              (%make-validation-result
               :invalid
               (format nil "Node ~S depends on unknown or later node ~S."
                       id input)))))
        (unless (member (mirror-node-effect node)
                        '(:pure :control :local-write) :test #'eq)
          (return-from validate-graph
            (%make-validation-result
             :invalid
             (format nil "Node ~S has unsupported effect ~S."
                     id (mirror-node-effect node)))))
        (push id seen)))
    (unless (member (semantic-graph-output graph) seen :test #'eq)
      (return-from validate-graph
        (%make-validation-result :invalid "The graph output is not a node.")))
    (%make-validation-result :valid nil)))

(defun attributes-contain-p (request)
  (destructuring-bind (attributes required) request
    (loop for (key value) on required by #'cddr
          always
          (loop for (actual-key actual-value) on attributes by #'cddr
                thereis (and (eq key actual-key)
                             (equal value actual-value))))))

(defun pattern-compatible-p (request)
  (destructuring-bind (graph node pattern) request
    (and (eq (mirror-node-operator node)
             (machine-pattern-operator pattern))
         (equal (node-input-types (list graph node))
                (machine-pattern-input-types pattern))
         (equal (mirror-node-output-type node)
                (machine-pattern-output-type pattern))
         (equal (mirror-node-shape node)
                (machine-pattern-shape pattern))
         (eq (mirror-node-effect node)
             (machine-pattern-effect pattern))
         (attributes-contain-p
          (list (mirror-node-attributes node)
                (machine-pattern-required-attributes pattern))))))

(defun pattern-less-p (left right)
  (or (< (machine-pattern-cost left) (machine-pattern-cost right))
      (and (= (machine-pattern-cost left) (machine-pattern-cost right))
           (string< (symbol-name (machine-pattern-id left))
                    (symbol-name (machine-pattern-id right))))))

(defun compatibility-matrix (request)
  "Return rows of (semantic-node-id . compatible-pattern-ids)."
  (destructuring-bind (graph target) request
    (mapcar
     (lambda (node)
       (let* ((matches
                (remove-if-not
                 (lambda (pattern)
                   (pattern-compatible-p (list graph node pattern)))
                 (machine-target-patterns target)))
              (ordered (sort (copy-list matches) #'pattern-less-p)))
         (cons (mirror-node-id node)
               (mapcar #'machine-pattern-id ordered))))
     (semantic-graph-nodes graph))))

(defun pattern-by-id (request)
  (destructuring-bind (target id) request
    (find id (machine-target-patterns target)
          :key #'machine-pattern-id :test #'eq)))

(defun cover-semantic-graph (request)
  "Cover every semantic node exactly once or fail without a partial plan."
  (destructuring-bind (graph target) request
    (let ((validation (validate-graph graph)))
      (unless (eq (validation-result-status validation) :valid)
        (return-from cover-semantic-graph
          (%make-cover-result
           :invalid nil nil nil (validation-result-reason validation))))
    (let* ((matrix (compatibility-matrix (list graph target)))
           (uncovered
             (loop for row in matrix
                   unless (rest row)
                     collect (first row))))
      (when uncovered
        (return-from cover-semantic-graph
          (%make-cover-result
           :unsupported nil nil uncovered
           (format nil "No exact target pattern covers ~{~S~^, ~}."
                   uncovered))))
      (let* ((entries
               (mapcar
                (lambda (row)
                  (let* ((pattern-id (second row))
                         (pattern (pattern-by-id (list target pattern-id))))
                    (%make-cover-entry
                     (first row) pattern-id
                     (machine-pattern-cost pattern)
                     (machine-pattern-emitter pattern))))
                matrix))
             (schedule (mapcar #'mirror-node-id
                               (semantic-graph-nodes graph))))
        (%make-cover-result :covered entries schedule nil nil))))))

(defun batch-emitter-for-cover (cover)
  (and
   (equal (mapcar #'cover-entry-emitter (cover-result-entries cover))
          +rq8-batch-emitter-sequence+)
   :rq8-one-group-per-row))

(defun plan-certificate (request)
  (destructuring-bind (graph target cover fallback) request
    (list
     :contract +contract+
     :semantic-id (semantic-graph-id graph)
     :target (machine-target-id target)
     :domain (copy-tree (semantic-graph-domain graph))
     :floating-order :left-to-right-single-float
     :cover
     (mapcar
      (lambda (entry)
        (list (cover-entry-node-id entry)
              (cover-entry-pattern-id entry)
              (cover-entry-cost entry)))
      (cover-result-entries cover))
     :schedule (copy-list (cover-result-schedule cover))
     :batch-emitter (batch-emitter-for-cover cover)
     :fallback fallback
     :performance-claim nil)))

(defun make-plan (request)
  (destructuring-bind (graph target cover fallback) request
    (let ((certificate
            (plan-certificate (list graph target cover fallback))))
      (%make-batch-plan
       graph target
       (copy-list (cover-result-entries cover))
       (copy-list (cover-result-schedule cover))
       (reduce #'+ (cover-result-entries cover)
               :key #'cover-entry-cost :initial-value 0)
       certificate))))

(defun external-symbol (request)
  (destructuring-bind (package-name symbol-name) request
    (let ((package (find-package package-name)))
      (unless package
        (error "Required package ~A is not loaded." package-name))
      (multiple-value-bind (symbol status) (find-symbol symbol-name package)
        (unless (and symbol (eq status :external))
          (error "Required external symbol ~A::~A is unavailable."
                 package-name symbol-name))
        symbol))))

(defun unsupported-form (request)
  (destructuring-bind (name fallback input reason) request
    (if fallback
        `(return-from ,name (,fallback ,input))
        `(error "Mirror kernel input is outside the compiled domain: ~A"
                ,reason))))

(defun emit-rq8-matvec-form (request)
  (destructuring-bind (name options plan) request
    (let* ((certificate (batch-plan-certificate plan))
           (batch-emitter (getf certificate :batch-emitter))
           (domain (semantic-graph-domain (batch-plan-graph plan)))
           (fallback (getf options :fallback))
           (columns (getf domain :columns))
           (block-size (getf domain :block-size))
           (blocks-per-group (getf domain :blocks-per-group))
           (tensor-type
             (external-symbol (list "RATIONAL-QUANT" "RQ8-TENSOR")))
           (exponents-of
             (external-symbol
              (list "RATIONAL-QUANT" "RQ8-TENSOR-EXPONENTS")))
           (numerators-of
             (external-symbol
              (list "RATIONAL-QUANT" "RQ8-TENSOR-NUMERATORS")))
           (quants-of
             (external-symbol
              (list "RATIONAL-QUANT" "RQ8-TENSOR-QUANTS")))
           (input 'mirror-kernel::input)
           (tensor 'mirror-kernel::tensor)
           (vector 'mirror-kernel::vector)
           (rows 'mirror-kernel::rows)
           (runtime-columns 'mirror-kernel::columns)
           (exponents 'mirror-kernel::exponents)
           (numerators 'mirror-kernel::numerators)
           (quants 'mirror-kernel::quants)
           (element-count 'mirror-kernel::element-count)
           (output 'mirror-kernel::output)
           (row 'mirror-kernel::row)
           (row-start 'mirror-kernel::row-start)
           (row-block-start 'mirror-kernel::row-block-start)
           (quantum 'mirror-kernel::quantum)
           (total 'mirror-kernel::total)
           (block 'mirror-kernel::block)
           (absolute-block 'mirror-kernel::absolute-block)
           (column-start 'mirror-kernel::column-start)
           (code 'mirror-kernel::code)
           (numerator 'mirror-kernel::numerator)
           (scale 'mirror-kernel::scale)
           (lane 'mirror-kernel::lane)
           (column 'mirror-kernel::column)
           (index 'mirror-kernel::index)
           (quant 'mirror-kernel::quant)
           (dequantized 'mirror-kernel::dequantized)
           (activation 'mirror-kernel::activation)
           (product 'mirror-kernel::product)
           (shape-fallback
             (unsupported-form
              (list name fallback input "request shape")))
           (domain-fallback
             (unsupported-form
              (list name fallback input "RQ8 32x64 one-group-per-row"))))
      (unless (eq batch-emitter :rq8-one-group-per-row)
        (error "The exact cover has no compact RQ8 batch emitter."))
      `(defun ,name (,input)
         (declare (optimize (speed 3) (safety 1) (debug 1)))
         (unless (and (consp ,input)
                      (consp (cdr ,input))
                      (consp (cddr ,input))
                      (consp (cdddr ,input))
                      (null (cddddr ,input)))
           ,shape-fallback)
         (destructuring-bind (,tensor ,vector ,rows ,runtime-columns) ,input
           (unless (and (typep ,tensor ',tensor-type)
                        (typep ,vector '(simple-array single-float (*)))
                        (typep ,rows 'fixnum)
                        (plusp ,rows)
                        (typep ,runtime-columns 'fixnum)
                        (= ,runtime-columns ,columns)
                        (typep (* ,rows ,columns) 'fixnum))
             ,domain-fallback)
           (let* ((,exponents (,exponents-of ,tensor))
                  (,numerators (,numerators-of ,tensor))
                  (,quants (,quants-of ,tensor))
                  (,element-count (the fixnum (* ,rows ,columns))))
             (declare
              (type (simple-array (signed-byte 8) (*)) ,exponents ,quants)
              (type (simple-array (unsigned-byte 8) (*)) ,numerators)
              (type fixnum ,element-count))
             (unless (and (= (length ,vector) ,columns)
                          (= (length ,quants) ,element-count)
                          (= (length ,numerators)
                             (the fixnum (* ,rows ,blocks-per-group)))
                          (= (length ,exponents) ,rows)
                          (loop for mirror-kernel::exponent
                                  across ,exponents
                                always (<= -126 mirror-kernel::exponent 119)))
               ,domain-fallback)
             (let ((,output
                     (make-array ,rows :element-type 'single-float)))
               (declare (type (simple-array single-float (*)) ,output))
               (dotimes (,row ,rows ,output)
                 (declare (type fixnum ,row))
                 (let ((,row-start (the fixnum (* ,row ,columns)))
                       (,row-block-start
                         (the fixnum (* ,row ,blocks-per-group)))
                       (,quantum
                         (the single-float
                              (scale-float 1.0f0
                                           (aref ,exponents ,row))))
                       (,total 0.0f0))
                   (declare (type fixnum ,row-start ,row-block-start)
                            (type single-float ,quantum ,total))
                   (dotimes (,block ,blocks-per-group)
                     (declare (type fixnum ,block))
                     (let* ((,absolute-block
                              (the fixnum (+ ,row-block-start ,block)))
                            (,column-start
                              (the fixnum (* ,block ,block-size)))
                            (,code (aref ,numerators ,absolute-block))
                            (,numerator
                              (the (integer 1 256) (1+ ,code)))
                            (,scale
                              (the single-float
                                   (* (coerce ,numerator 'single-float)
                                      ,quantum))))
                       (declare (type fixnum ,absolute-block ,column-start)
                                (type (unsigned-byte 8) ,code)
                                (type (integer 1 256) ,numerator)
                                (type single-float ,scale))
                       (dotimes (,lane ,block-size)
                         (declare (type fixnum ,lane))
                         (let* ((,column
                                  (the fixnum (+ ,column-start ,lane)))
                                (,index
                                  (the fixnum (+ ,row-start ,column)))
                                (,quant (aref ,quants ,index))
                                (,dequantized
                                  (the single-float
                                       (* (coerce ,quant 'single-float)
                                          ,scale)))
                                (,activation
                                  (the single-float
                                       (aref ,vector ,column)))
                                (,product
                                  (the single-float
                                       (* ,dequantized ,activation))))
                           (declare (type fixnum ,column ,index)
                                    (type (signed-byte 8) ,quant)
                                    (type single-float
                                          ,dequantized ,activation ,product))
                           (setf ,total
                                 (the single-float (+ ,total ,product)))))))
                   (setf (aref ,output ,row) ,total))))))))))

(defun compile-rq8-matvec (request)
  "Compile (NAME OPTIONS) into one guarded typed Common Lisp kernel form."
  (destructuring-bind (name raw-options) request
    (unless (symbolp name)
      (error "Mirror kernel name must be a symbol, got ~S." name))
    (let* ((options (normalize-options raw-options))
           (graph (make-rq8-matvec-graph options))
           (target (make-sbcl-scalar-target options))
           (cover (cover-semantic-graph (list graph target))))
      (unless (eq (getf options :target) +target-id+)
        (return-from compile-rq8-matvec
          (%make-compilation-result
           :unsupported graph target cover nil nil nil
           (format nil "Unknown mirror target ~S." (getf options :target)))))
      (unless (eq (cover-result-status cover) :covered)
        (return-from compile-rq8-matvec
          (%make-compilation-result
           :unsupported graph target cover nil nil nil
           (cover-result-reason cover))))
      (let* ((fallback (getf options :fallback))
             (plan (make-plan (list graph target cover fallback)))
             (batch-emitter
               (getf (batch-plan-certificate plan) :batch-emitter)))
        (unless batch-emitter
          (return-from compile-rq8-matvec
            (%make-compilation-result
             :unsupported graph target cover plan nil nil
             "The exact cover has no compact batch emitter.")))
        (let ((form (emit-rq8-matvec-form (list name options plan)))
              (certificate (copy-tree (batch-plan-certificate plan))))
          (%make-compilation-result
           :compiled graph target cover plan form certificate nil))))))

(defmacro define-rq8-matvec-kernel (name options)
  (let ((result (compile-rq8-matvec (list name options))))
    (unless (eq (compilation-result-status result) :compiled)
      (error "RQ8 mirror compilation failed: ~A"
             (compilation-result-reason result)))
    (compilation-result-form result)))
