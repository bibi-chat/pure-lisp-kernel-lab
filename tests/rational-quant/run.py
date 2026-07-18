#!/usr/bin/env python3
"""Run direct or ASDF rational-quant gates with an explicit isolated SBCL."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "packages" / "rational-quant"
HARNESS = ROOT / "tests" / "rational-quant" / "harness.lisp"
SAFETY_ZERO = re.compile(r"\(\s*safety\s+0\s*\)", re.IGNORECASE)
REJECTED_DIAGNOSTIC = re.compile(
    r"\b(?:WARNING|SERIOUS-CONDITION)\b", re.IGNORECASE
)


def fail(message: str) -> int:
    print(f"rational-quant gate: {message}", file=sys.stderr)
    return 2


def source_boundary_is_safe() -> bool:
    sources = sorted(PACKAGE.glob("*.lisp"))
    return bool(sources) and all(
        SAFETY_ZERO.search(path.read_text(encoding="utf-8")) is None
        for path in sources
    )


def requested_mode(arguments: list[str]) -> str | None:
    if not arguments:
        return "direct"
    if arguments == ["--asdf-test-op"]:
        return "asdf"
    return None


def run_sbcl(sbcl: Path, mode: str, output_directory: Path) -> int:
    environment = os.environ.copy()
    environment["RQ8_TEST_MODE"] = mode
    environment["ASDF_OUTPUT_TRANSLATIONS"] = (
        "(:output-translations "
        f'(t "{output_directory.as_posix()}/") '
        ":ignore-inherited-configuration)"
    )
    result = subprocess.run(
        [
            str(sbcl),
            "--noinform",
            "--no-userinit",
            "--no-sysinit",
            "--disable-debugger",
            "--non-interactive",
            "--load",
            str(HARNESS),
        ],
        cwd=output_directory,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )
    combined = result.stdout + "\n" + result.stderr
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if REJECTED_DIAGNOSTIC.search(combined):
        return fail("SBCL emitted WARNING or SERIOUS-CONDITION output")
    return result.returncode


def main() -> int:
    mode = requested_mode(sys.argv[1:])
    if mode is None:
        return fail("usage: run.py [--asdf-test-op]")
    configured = os.environ.get("SBCL_BIN")
    if not configured:
        return fail("SBCL_BIN must name the SBCL executable")
    sbcl = Path(configured)
    if not sbcl.is_absolute():
        return fail("SBCL_BIN must be an absolute path")
    if not sbcl.is_file() or not os.access(sbcl, os.X_OK):
        return fail(f"SBCL_BIN is not executable: {sbcl}")
    if not source_boundary_is_safe():
        return fail("package sources are missing or contain (safety 0)")

    version = subprocess.run(
        [str(sbcl), "--version"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if version.returncode != 0 or not version.stdout.startswith("SBCL "):
        return fail("SBCL_BIN is not an identified SBCL runtime")

    with tempfile.TemporaryDirectory(prefix="rational-quant-asdf-") as scratch:
        status = run_sbcl(sbcl, mode, Path(scratch))
    if status != 0:
        return status
    print(
        f"rational-quant {mode} gate: passed "
        f"({version.stdout.strip()}; safety 3; no performance claim)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
