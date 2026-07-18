(defpackage #:compile-pure-lisp.harness
  (:use #:cl))

(in-package #:compile-pure-lisp.harness)

(defvar *benchmark-sink* nil)

(defstruct (json-object (:constructor json-object (&rest pairs)))
  pairs)

(defstruct (json-array (:constructor json-array (items)))
  items)

(defstruct measurement
  nanoseconds-per-call
  bytes-per-call)

(defparameter +json-true+ (gensym "JSON-TRUE"))
(defparameter +json-false+ (gensym "JSON-FALSE"))

(defun json-boolean (value)
  (if value +json-true+ +json-false+))

(defun write-json-string (value stream)
  (write-char #\" stream)
  (loop for character across value
        for code = (char-code character)
        do (case character
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (otherwise
              (if (< code 32)
                  (format stream "\\u~4,'0X" code)
                  (write-char character stream)))))
  (write-char #\" stream))

(defun json-float-string (value)
  (let ((text (string-trim '(#\Space #\Tab #\Newline)
                           (format nil "~,17E" (coerce value 'double-float)))))
    (substitute #\e #\d (substitute #\E #\D text))))

(defun write-json (value stream)
  (cond
    ((eq value +json-true+) (write-string "true" stream))
    ((eq value +json-false+) (write-string "false" stream))
    ((null value) (write-string "null" stream))
    ((json-object-p value)
     (write-char #\{ stream)
     (loop for pair in (json-object-pairs value)
           for first = t then nil
           do (unless first (write-char #\, stream))
              (write-json-string (car pair) stream)
              (write-char #\: stream)
              (write-json (cdr pair) stream))
     (write-char #\} stream))
    ((json-array-p value)
     (write-char #\[ stream)
     (loop for item in (json-array-items value)
           for first = t then nil
           do (unless first (write-char #\, stream))
              (write-json item stream))
     (write-char #\] stream))
    ((stringp value) (write-json-string value stream))
    ((pathnamep value) (write-json-string (namestring value) stream))
    ((integerp value) (format stream "~D" value))
    ((realp value) (write-string (json-float-string value) stream))
    ((symbolp value) (write-json-string (symbol-name value) stream))
    (t (error "Cannot encode ~S as JSON" value))))

(defun write-json-file (report path)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (write-json report stream)
    (terpri stream)))

(defun bounded-prin1 (value)
  (let ((*print-length* 24)
        (*print-level* 8)
        (*print-array* t)
        (*print-circle* t)
        (*print-pretty* nil))
    (with-standard-io-syntax
      (prin1-to-string value))))

(defun resolve-function (package name &key optional)
  (multiple-value-bind (symbol status)
      (find-symbol name package)
    (declare (ignore status))
    (cond
      ((and symbol (fboundp symbol)) (symbol-function symbol))
      (optional nil)
      (t (error "Required function ~A::~A is missing" (package-name package) name)))))

(defun call-outcome (function input)
  (handler-case
      (list :values (multiple-value-list (funcall function input)))
    (error (condition)
      (list :condition
            (princ-to-string (class-name (class-of condition)))
            (princ-to-string condition)))))

(defun successful-outcome-p (outcome)
  (eq (first outcome) :values))

(defun default-equivalent-p (pair)
  (equalp (second (first pair))
          (second (second pair))))

(defun outcomes-equivalent-p (left right comparator)
  (and (successful-outcome-p left)
       (successful-outcome-p right)
       (funcall comparator (list left right))))

(defun coerce-cases (value expected-count)
  (unless (typep value 'sequence)
    (error "CASES must return a sequence, got ~S" value))
  (let ((cases (coerce value 'list)))
    (unless (= (length cases) expected-count)
      (error "CASES returned ~D inputs; expected ~D"
             (length cases) expected-count))
    cases))

(defun failure-record (index input reason &optional reference candidate)
  (json-object
   (cons "index" index)
   (cons "input" (bounded-prin1 input))
   (cons "reason" reason)
   (cons "reference" (and reference (bounded-prin1 reference)))
   (cons "candidate" (and candidate (bounded-prin1 candidate)))))

(defun verify-cases (reference candidate cases-function comparator seed count)
  (let* ((configuration (list seed count))
         (banks
           (loop repeat 5
                 collect (coerce-cases
                          (funcall cases-function configuration)
                          count)))
         (reference-one-bank (first banks))
         (reference-two-bank (second banks))
         (candidate-one-bank (third banks))
         (candidate-two-bank (fourth banks))
         (baseline-bank (fifth banks))
         (failures '())
         (passed 0))
    (unless (every (lambda (bank) (equalp reference-one-bank bank))
                   (rest banks))
      (push (failure-record -1 configuration "CASES is nondeterministic") failures))
    (loop for reference-one-input in reference-one-bank
          for reference-two-input in reference-two-bank
          for candidate-one-input in candidate-one-bank
          for candidate-two-input in candidate-two-bank
          for baseline-input in baseline-bank
          for index from 0
          while (< (length failures) 20)
          do (let* ((reference-one
                      (call-outcome reference reference-one-input))
                    (reference-two
                      (call-outcome reference reference-two-input))
                    (candidate-one
                      (call-outcome candidate candidate-one-input))
                    (candidate-two
                      (call-outcome candidate candidate-two-input)))
               (cond
                 ((not (and (equalp reference-one-input baseline-input)
                            (equalp reference-two-input baseline-input)
                            (equalp candidate-one-input baseline-input)
                            (equalp candidate-two-input baseline-input)))
                  (push (failure-record index baseline-input
                                        "A kernel mutated its input")
                        failures))
                 ((or (not (successful-outcome-p reference-one))
                      (not (successful-outcome-p candidate-one)))
                  (push (failure-record index baseline-input
                                        "A kernel signaled a condition"
                                        reference-one candidate-one)
                        failures))
                 ((not (outcomes-equivalent-p reference-one reference-two comparator))
                  (push (failure-record index baseline-input
                                        "Reference kernel is nondeterministic"
                                        reference-one reference-two)
                        failures))
                 ((not (outcomes-equivalent-p candidate-one candidate-two comparator))
                  (push (failure-record index baseline-input
                                        "Candidate kernel is nondeterministic"
                                        candidate-one candidate-two)
                        failures))
                 ((not (outcomes-equivalent-p reference-one candidate-one comparator))
                  (push (failure-record index baseline-input
                                        "Reference and candidate differ"
                                        reference-one candidate-one)
                        failures))
                 (t
                  (incf passed)))))
    (json-object
     (cons "passed" (json-boolean (null failures)))
     (cons "case_count" count)
     (cons "passed_count" passed)
     (cons "failures" (json-array (nreverse failures))))))

(defun verification-passed-p (verification)
  (eq (cdr (assoc "passed" (json-object-pairs verification)
                  :test #'string=))
      +json-true+))

(defun verify-benchmark-input
    (reference candidate benchmark-input-function comparator seed size)
  (flet ((one-benchmark-case (configuration)
           (declare (ignore configuration))
           (list (funcall benchmark-input-function (list seed size)))))
    (verify-cases reference candidate #'one-benchmark-case comparator seed 1)))

(defun warm-function (function input count)
  (loop repeat count do
    (setf *benchmark-sink* (funcall function input))))

(defun measure-once (function input iterations)
  (sb-ext:gc :full t)
  (let ((bytes-before (sb-ext:get-bytes-consed))
        (time-before (get-internal-real-time)))
    (loop repeat iterations do
      (setf *benchmark-sink* (funcall function input)))
    (let* ((elapsed (- (get-internal-real-time) time-before))
           (bytes (- (sb-ext:get-bytes-consed) bytes-before))
           (seconds (/ (coerce elapsed 'double-float)
                       (coerce internal-time-units-per-second 'double-float))))
      (make-measurement
       :nanoseconds-per-call (/ (* seconds 1d9) iterations)
       :bytes-per-call (/ (coerce bytes 'double-float) iterations)))))

(defun median (numbers)
  (let* ((sorted (sort (copy-list numbers) #'<))
         (length (length sorted))
         (middle (floor length 2)))
    (if (oddp length)
        (nth middle sorted)
        (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2d0))))

(defun measurement-json (measurements)
  (let ((times (mapcar #'measurement-nanoseconds-per-call measurements))
        (bytes (mapcar #'measurement-bytes-per-call measurements)))
    (json-object
     (cons "median_nanoseconds_per_call" (median times))
     (cons "median_bytes_per_call" (median bytes))
     (cons "nanoseconds_per_call" (json-array times))
     (cons "bytes_per_call" (json-array bytes)))))

(defun benchmark-functions (reference candidate input iterations warmup samples)
  (warm-function reference input warmup)
  (warm-function candidate input warmup)
  (let ((reference-measurements '())
        (candidate-measurements '()))
    (dotimes (sample samples)
      (if (evenp sample)
          (progn
            (push (measure-once reference input iterations) reference-measurements)
            (push (measure-once candidate input iterations) candidate-measurements))
          (progn
            (push (measure-once candidate input iterations) candidate-measurements)
            (push (measure-once reference input iterations) reference-measurements))))
    (setf reference-measurements (nreverse reference-measurements)
          candidate-measurements (nreverse candidate-measurements))
    (let* ((reference-time
             (median (mapcar #'measurement-nanoseconds-per-call
                             reference-measurements)))
           (candidate-time
             (median (mapcar #'measurement-nanoseconds-per-call
                             candidate-measurements)))
           (reference-bytes
             (median (mapcar #'measurement-bytes-per-call
                             reference-measurements)))
           (candidate-bytes
             (median (mapcar #'measurement-bytes-per-call
                             candidate-measurements))))
      (json-object
       (cons "iterations" iterations)
       (cons "warmup_iterations" warmup)
       (cons "samples" samples)
       (cons "reference" (measurement-json reference-measurements))
       (cons "candidate" (measurement-json candidate-measurements))
       (cons "speedup" (and (plusp candidate-time)
                            (/ reference-time candidate-time)))
       (cons "bytes_saved_per_call" (- reference-bytes candidate-bytes))
       (cons "candidate_faster" (json-boolean (< candidate-time reference-time)))
       (cons "candidate_allocates_less"
             (json-boolean (< candidate-bytes reference-bytes)))))))

(defun artifact-path (report-path suffix)
  (concatenate 'string report-path suffix))

(defun write-disassembly (function path)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (let ((*standard-output* stream)
          (*trace-output* stream))
      (disassemble function)))
  path)

(defun apply-policy (mode)
  (cond
    ((string= mode "semantic")
     (sb-ext:restrict-compiler-policy 'safety 3 3)
     (json-object
      (cons "speed" "unrestricted")
      (cons "safety" 3)
      (cons "debug" "unrestricted")))
    ((string= mode "measured")
     (sb-ext:restrict-compiler-policy 'speed 3 3)
     (sb-ext:restrict-compiler-policy 'safety 1 1)
     (sb-ext:restrict-compiler-policy 'debug 1 1)
     (json-object
      (cons "speed" 3)
      (cons "safety" 1)
      (cons "debug" 1)))
    (t
     (error "Unknown worker mode ~S" mode))))

(defun load-with-warning-observation (path)
  (let ((warnings-p nil))
    (handler-bind
        ((warning
           (lambda (condition)
             (unless (typep condition
                            'sb-kernel::uninteresting-redefinition)
               (setf warnings-p t)))))
      (load path))
    warnings-p))

(defun compile-and-load-case (case-path fasl-path compiler-path)
  (let ((compiler-fasl-path
          (concatenate 'string (namestring (pathname fasl-path))
                       ".compiler.fasl")))
    (multiple-value-bind
        (compiler-output compiler-warnings-p compiler-failure-p)
        (compile-file compiler-path
                      :output-file compiler-fasl-path
                      :verbose t
                      :print nil)
      (when compiler-failure-p
        (error "COMPILE-FILE reported failure for compiler ~A" compiler-path))
      (let ((compiler-load-warnings-p
              (load-with-warning-observation compiler-output)))
        (multiple-value-bind (output case-warnings-p case-failure-p)
            (compile-file case-path :output-file fasl-path :verbose t :print nil)
          (when case-failure-p
            (error "COMPILE-FILE reported failure for case ~A" case-path))
          (let ((case-load-warnings-p
                  (load-with-warning-observation output)))
            (values (or compiler-warnings-p
                        compiler-load-warnings-p
                        case-warnings-p
                        case-load-warnings-p)
                    (or compiler-failure-p case-failure-p)
                    output)))))))

(defun run-worker (arguments)
  (unless (= (length arguments) 12)
    (error "Expected 12 worker arguments, got ~D: ~S"
           (length arguments) arguments))
  (destructuring-bind
      (mode case-path report-path fasl-path compiler-path iterations-text
       warmup-text samples-text seed-text case-count-text benchmark-size-text
       disassembly-text)
      arguments
    (let* ((iterations (parse-integer iterations-text))
           (warmup (parse-integer warmup-text))
           (samples (parse-integer samples-text))
           (seed (parse-integer seed-text))
           (case-count (parse-integer case-count-text))
           (benchmark-size (parse-integer benchmark-size-text))
           (write-disassembly-p (string= disassembly-text "true"))
           (policy (apply-policy mode)))
      (multiple-value-bind (warnings-p failure-p loaded-fasl)
          (compile-and-load-case case-path fasl-path compiler-path)
        (declare (ignore failure-p loaded-fasl))
        (let ((package (or (find-package "COMPILE-PURE-LISP.CASE")
                           (error "Case file must define COMPILE-PURE-LISP.CASE"))))
          (let* ((reference (resolve-function package "REFERENCE-KERNEL"))
                 (candidate (resolve-function package "CANDIDATE-KERNEL"))
                 (cases-function (resolve-function package "CASES"))
                 (benchmark-input-function
                   (resolve-function package "BENCHMARK-INPUT"))
                 (comparator (or (resolve-function package "EQUIVALENT-P"
                                                    :optional t)
                                 #'default-equivalent-p)))
            (when (eq reference candidate)
              (error "Reference and candidate entrypoints must be distinct"))
            (let* ((correctness
                     (verify-cases reference candidate cases-function comparator
                                   seed case-count))
                   (benchmark-correctness
                     (verify-benchmark-input
                      reference candidate benchmark-input-function comparator
                      seed benchmark-size))
                   (correct-p
                     (and (verification-passed-p correctness)
                          (verification-passed-p benchmark-correctness)))
                   (benchmark nil)
                   (reference-disassembly nil)
                   (candidate-disassembly nil))
              (when (and correct-p (string= mode "measured"))
                (let* ((configuration (list seed benchmark-size))
                       (input-one (funcall benchmark-input-function configuration))
                       (input-two (funcall benchmark-input-function configuration)))
                  (unless (equalp input-one input-two)
                    (error "BENCHMARK-INPUT is nondeterministic"))
                  (setf benchmark
                        (benchmark-functions reference candidate input-one
                                             iterations warmup samples)))
                (when write-disassembly-p
                  (setf reference-disassembly
                        (write-disassembly
                         reference
                         (artifact-path report-path
                                        ".reference.disassembly.txt"))
                        candidate-disassembly
                        (write-disassembly
                         candidate
                         (artifact-path report-path
                                        ".candidate.disassembly.txt")))))
              (write-json-file
               (json-object
                (cons "status" (if correct-p "verified" "semantic-mismatch"))
                (cons "mode" mode)
                (cons "case_file" case-path)
                (cons "compiler_warnings" (json-boolean warnings-p))
                (cons "policy" policy)
                (cons "correctness" correctness)
                (cons "benchmark_correctness" benchmark-correctness)
                (cons "benchmark" benchmark)
                (cons "artifacts"
                      (json-object
                       (cons "reference_disassembly" reference-disassembly)
                       (cons "candidate_disassembly" candidate-disassembly))))
               report-path)
              (unless correct-p
                (sb-ext:exit :code 2)))))))))

(defun main ()
  (let* ((arguments (rest sb-ext:*posix-argv*))
         (report-path (and (>= (length arguments) 3) (third arguments))))
    (handler-case
        (run-worker arguments)
      (error (condition)
        (when report-path
          (ignore-errors
            (write-json-file
             (json-object
              (cons "status" "worker-error")
              (cons "error_type"
                    (princ-to-string (class-name (class-of condition))))
              (cons "error" (princ-to-string condition)))
             report-path)))
        (format *error-output* "compile-pure-lisp worker failed: ~A~%" condition)
        (sb-ext:exit :code 1)))))

(main)
