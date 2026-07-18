#!/usr/bin/env python3
"""Run bounded mirror-kernel semantic and verifier gates."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "packages" / "mirror-kernel"
HARNESS = ROOT / "tests" / "mirror-kernel" / "harness.lisp"
CASE = ROOT / "tests" / "mirror-kernel" / "verifier-case.lisp"
COMPILER = PACKAGE / "compiler.lisp"
VERIFIER = ROOT / "tool" / "verify_kernel.py"
SAFETY_ZERO = re.compile(r"\(\s*safety\s+0\s*\)", re.IGNORECASE)
REJECTED_DIAGNOSTIC = re.compile(r"\b(?:WARNING|SERIOUS-CONDITION)\b", re.IGNORECASE)


def fail(message: str) -> int:
    print(f"mirror-kernel gate: {message}", file=sys.stderr)
    return 2


def configured_sbcl() -> Path | None:
    value = os.environ.get("SBCL_BIN")
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        return None
    return path


def source_boundary_is_safe() -> bool:
    sources = sorted(PACKAGE.glob("*.lisp"))
    return bool(sources) and all(
        SAFETY_ZERO.search(path.read_text(encoding="utf-8")) is None
        for path in sources
    )


def run_lisp_gate(sbcl: Path, mode: str, scratch: Path) -> int:
    scratch.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["MIRROR_TEST_MODE"] = mode
    environment["ASDF_OUTPUT_TRANSLATIONS"] = (
        "(:output-translations "
        f'(t "{scratch.as_posix()}/") '
        ":ignore-inherited-configuration)"
    )
    completed = subprocess.run(
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
        cwd=scratch,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    transcript = completed.stdout + "\n" + completed.stderr
    if REJECTED_DIAGNOSTIC.search(transcript):
        if transcript.strip():
            print(transcript, file=sys.stderr)
        return fail(f"{mode} gate emitted a rejected diagnostic")
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, end="")
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        return completed.returncode
    for line in completed.stdout.splitlines():
        if line.startswith("MIRROR_"):
            print(line)
    return completed.returncode


def run_verifier(sbcl: Path, scratch: Path) -> int:
    scratch.mkdir(parents=True, exist_ok=True)
    report = scratch / "mirror-verification.json"
    environment = os.environ.copy()
    environment["PURE_LISP_KERNEL_LAB_ROOT"] = str(ROOT)
    command = [
        sys.executable,
        str(VERIFIER),
        str(CASE),
        "--compiler",
        str(COMPILER),
        "--output",
        str(report),
        "--sbcl",
        str(sbcl),
        "--require",
        "correctness",
        "--case-count",
        "12",
        "--benchmark-size",
        "2048",
        "--iterations",
        "2",
        "--warmup",
        "1",
        "--samples",
        "3",
        "--minimum-sample-ns",
        "1",
        "--no-disassembly",
    ]
    completed = subprocess.run(
        command,
        cwd=scratch,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, end="")
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        return completed.returncode
    payload = json.loads(report.read_text(encoding="utf-8"))
    profiles = payload.get("profiles", {})
    accepted = (
        payload.get("status") == "accepted"
        and payload.get("gate", {}).get("passed") is True
        and payload.get("gate", {}).get("compiler_warnings_requirement_passed") is True
        and all(
            profiles.get(mode, {}).get("status") == "verified"
            and profiles.get(mode, {}).get("correctness", {}).get("passed") is True
            and profiles.get(mode, {}).get("benchmark_correctness", {}).get("passed") is True
            for mode in ("semantic", "measured")
        )
    )
    if not accepted:
        return fail("fresh verifier profiles did not satisfy the correctness gate")
    print(
        "MIRROR_VERIFIER_RESULT "
        + json.dumps(
            {
                "status": "passed",
                "case_count": 12,
                "profiles": ["semantic", "measured"],
                "requirement": "correctness",
                "performance_claim": False,
            },
            separators=(",", ":"),
        )
    )
    return 0


def main() -> int:
    sbcl = configured_sbcl()
    if sbcl is None:
        return fail("SBCL_BIN must be an absolute executable path")
    if not source_boundary_is_safe():
        return fail("package Lisp sources are missing or contain (safety 0)")
    version = subprocess.run(
        [str(sbcl), "--version"],
        check=False,
        capture_output=True,
        text=True,
    )
    if version.returncode != 0 or not version.stdout.startswith("SBCL "):
        return fail("SBCL_BIN is not an identified SBCL runtime")
    with tempfile.TemporaryDirectory(prefix="mirror-kernel-") as directory:
        scratch = Path(directory)
        for mode in ("direct", "asdf"):
            status = run_lisp_gate(sbcl, mode, scratch / mode)
            if status != 0:
                return status
        status = run_verifier(sbcl, scratch / "verifier")
        if status != 0:
            return status
    print(
        "mirror-kernel gate: passed "
        f"({version.stdout.strip()}; semantic scope only; no performance claim)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
