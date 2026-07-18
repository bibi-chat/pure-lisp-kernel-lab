# v0.1.0-alpha

This alpha publishes the smallest community-useful subset recovered from the
benchmark work:

- a standalone SBCL kernel verifier with fail-closed adversarial fixtures;
- a lawful exact-integer equality-saturation compiler;
- an experimental guarded RQ8 package with reference implementations;
- one bounded 24-node symbolic mirror compiler for a 2,048-column RQ8 matvec;
- path-independent direct and ASDF gates, CI, machine-readable evidence, and a
  release-content audit.

The alpha proves a payload-storage reduction for the declared RQ8
representation and bounded semantic equivalence for the checked kernels. It
does not claim to replace SBCL or Mesh TensorFlow, compile arbitrary Lisp or
tensor graphs, improve model quality, support non-SBCL runtimes, or deliver a
material whole-system speedup.

Kernel cases and compiler extensions are trusted executable Lisp, not sandboxed
input. See `SECURITY.md` before running third-party cases.
