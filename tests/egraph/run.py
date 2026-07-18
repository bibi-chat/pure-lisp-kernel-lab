#!/usr/bin/env python3
"""Run the bounded lawful e-graph compiler test suite with an explicit SBCL."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
COMPILER = ROOT / "tool" / "lawful-egraph-compiler.lisp"
TESTS = Path(__file__).resolve().parent / "egraph-unit-tests.lisp"


def sbcl_path() -> Path:
    value = os.environ.get("SBCL_BIN")
    if not value:
        raise ValueError("SBCL_BIN must name an absolute SBCL executable")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ValueError("SBCL_BIN must name an absolute SBCL executable")
    resolved = path.resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError(f"SBCL_BIN is not an executable file: {resolved}")
    return resolved


def main() -> int:
    try:
        sbcl = sbcl_path()
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    command = [
        str(sbcl),
        "--noinform",
        "--no-userinit",
        "--no-sysinit",
        "--disable-debugger",
        "--load",
        str(COMPILER),
        "--load",
        str(TESTS),
        "--eval",
        "(unless (compile-pure-lisp.egraph.tests:run-tests) "
        "(sb-ext:exit :code 1))",
        "--quit",
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"lawful e-graph test runner failed: {error}", file=sys.stderr)
        return 1
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
