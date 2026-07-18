(require :asdf)

(defparameter *mirror-test-directory*
  (uiop:pathname-directory-pathname *load-truename*))

(defparameter *mirror-project-root*
  (uiop:ensure-directory-pathname
   (truename (merge-pathnames "../../" *mirror-test-directory*))))

(defun mirror-path (relative)
  (merge-pathnames relative *mirror-project-root*))

(defun initialize-mirror-systems ()
  (asdf:initialize-source-registry
   `(:source-registry
     (:tree ,(mirror-path "packages/"))
     :ignore-inherited-configuration))
  (asdf:load-asd (mirror-path "packages/rational-quant/rational-quant.asd"))
  (asdf:load-asd (mirror-path "packages/mirror-kernel/mirror-kernel.asd")))

(defun run-mirror-direct-gate ()
  (initialize-mirror-systems)
  (load (mirror-path "packages/rational-quant/package.lisp"))
  (load (mirror-path "packages/rational-quant/core.lisp"))
  (load (mirror-path "packages/mirror-kernel/compiler.lisp"))
  (load (mirror-path "packages/mirror-kernel/rq8-kernel.lisp"))
  (load (mirror-path "tests/mirror-kernel/tests.lisp"))
  (uiop:symbol-call "MIRROR-KERNEL.TESTS" "RUN-TESTS" nil))

(defun run-mirror-asdf-gate ()
  (initialize-mirror-systems)
  (asdf:test-system "mirror-kernel"))

(let ((mode (or (uiop:getenv "MIRROR_TEST_MODE") "direct")))
  (unless (member mode '("direct" "asdf") :test #'string=)
    (error "Unsupported MIRROR_TEST_MODE ~S." mode))
  (sb-ext:restrict-compiler-policy 'safety 3 3)
  (format t "MIRROR_POLICY {\"safety_minimum\":3,\"mode\":\"~A\"}~%" mode)
  (if (string= mode "direct")
      (run-mirror-direct-gate)
      (run-mirror-asdf-gate)))
