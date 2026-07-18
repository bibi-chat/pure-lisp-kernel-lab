#!/usr/bin/env python3
"""Run every deterministic release gate with one explicit SBCL runtime."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def find_sbcl() -> Path | None:
    configured = os.environ.get("SBCL_BIN")
    candidate = Path(configured) if configured else None
    if candidate is None:
        discovered = shutil.which("sbcl")
        candidate = Path(discovered) if discovered else None
    if candidate is None:
        return None
    resolved = candidate.expanduser().resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        return None
    return resolved


def run_gate(name: str, command: list[str], environment: dict[str, str]) -> dict[str, object]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, end="", file=sys.stderr)
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        raise RuntimeError(f"{name} failed with exit {completed.returncode}")
    print(f"release gate: {name} passed")
    return {"name": name, "status": "passed"}


def main() -> int:
    sbcl = find_sbcl()
    if sbcl is None:
        print("test-all: set SBCL_BIN or install sbcl on PATH", file=sys.stderr)
        return 2
    version = subprocess.run(
        [str(sbcl), "--version"],
        check=False,
        capture_output=True,
        text=True,
    )
    if version.returncode != 0 or not version.stdout.startswith("SBCL "):
        print("test-all: selected runtime is not identified as SBCL", file=sys.stderr)
        return 2
    environment = os.environ.copy()
    environment["SBCL_BIN"] = str(sbcl)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    python = sys.executable
    gates = [
        (
            "roadmap",
            [python, str(ROOT / "scripts" / "roadmap-check.py")],
        ),
        (
            "verifier-integration",
            [python, "-m", "unittest", "discover", "-s", "tests/verifier", "-v"],
        ),
        (
            "lawful-egraph",
            [python, str(ROOT / "tests" / "egraph" / "run.py")],
        ),
        (
            "rational-quant-direct",
            [python, str(ROOT / "tests" / "rational-quant" / "run.py")],
        ),
        (
            "rational-quant-asdf",
            [
                python,
                str(ROOT / "tests" / "rational-quant" / "run.py"),
                "--asdf-test-op",
            ],
        ),
        (
            "mirror-kernel",
            [python, str(ROOT / "tests" / "mirror-kernel" / "run.py")],
        ),
    ]
    results = []
    try:
        for name, command in gates:
            results.append(run_gate(name, command, environment))
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"test-all: {error}", file=sys.stderr)
        return 1
    print(
        "TEST_ALL_RESULT "
        + json.dumps(
            {
                "status": "passed",
                "runtime": version.stdout.strip(),
                "gates": results,
                "performance_claim": False,
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
