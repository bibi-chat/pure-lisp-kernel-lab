# Security policy

## Trusted-code boundary

Kernel cases, compiler extensions, and Common Lisp test fixtures are executable
code. The verifier starts fresh SBCL processes with user and system init files
disabled, but it does not sandbox filesystem, process, or network access. Run
only cases and compiler files you trust, preferably inside an operating-system
isolation boundary when reviewing third-party code.

The project does not need credentials for local verification. Never place
tokens, passwords, private keys, model data, or confidential fixtures in a case
or report.

## Reporting a vulnerability

For a public repository, use GitHub's private security-advisory workflow rather
than a public issue when disclosure would create immediate risk. Include the
affected commit, supported runtime, minimal reproduction, expected boundary,
and observed impact. Do not include real secrets or private datasets.

This alpha supports the checked SBCL-specific boundary documented in the root
README. Portability and hostile-code isolation are not security claims.
