#!/usr/bin/env python3
"""Audit the exact publishable working-tree set and write a sanitized report."""

from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports" / "release-acceptance.json"
MAX_FILE_BYTES = 2 * 1024 * 1024
FORBIDDEN_SUFFIXES = {
    ".core",
    ".dfsl",
    ".dylib",
    ".dx64fsl",
    ".fas",
    ".fasl",
    ".key",
    ".lib",
    ".lx64fsl",
    ".o",
    ".pem",
    ".pyc",
    ".pyo",
    ".so",
    ".ufsl",
}
FORBIDDEN_PARTS = {
    ".release-inputs",
    ".toolchains",
    "__pycache__",
    "scratch",
}
PERSONAL_PREFIXES = (b"/" + b"Users/", b"/" + b"Volumes/")
SECRET_PATTERNS = (
    re.compile(("BEGIN " + r"(?:RSA |EC |OPENSSH )?PRIVATE KEY").encode()),
    re.compile(("github" + r"_pat_[A-Za-z0-9_]{20,}").encode()),
    re.compile(("gh" + r"[pousr]_[A-Za-z0-9]{20,}").encode()),
    re.compile(("sk" + r"-[A-Za-z0-9]{20,}").encode()),
    re.compile(
        (r"(?:OPENAI_API_KEY|GITHUB_TOKEN|PASSWORD)\s*[:=]\s*"
         r"[\"']?[^\s\"']{8,}").encode(),
        re.IGNORECASE,
    ),
)
SAFETY_ZERO = re.compile(r"\(\s*safety\s+0\s*\)", re.IGNORECASE)


def git_paths(arguments: list[str]) -> list[str]:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return sorted(
        item.decode("utf-8")
        for item in completed.stdout.split(b"\0")
        if item
    )


def candidate_paths() -> list[str]:
    return git_paths(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])


def add_error(errors: list[dict[str, str]], path: str, category: str) -> None:
    errors.append({"path": path, "category": category})


def audit_file(relative: str, errors: list[dict[str, str]]) -> bool:
    path = ROOT / relative
    pure = PurePosixPath(relative)
    if path.is_symlink():
        add_error(errors, relative, "symlink")
        return False
    if not path.is_file():
        add_error(errors, relative, "not-regular-file")
        return False
    if any(part in FORBIDDEN_PARTS for part in pure.parts):
        add_error(errors, relative, "forbidden-path")
    if path.suffix.lower() in FORBIDDEN_SUFFIXES:
        add_error(errors, relative, "forbidden-suffix")
    data = path.read_bytes()
    if len(data) > MAX_FILE_BYTES:
        add_error(errors, relative, "oversized-file")
    if b"\0" in data:
        add_error(errors, relative, "binary-nul")
        return False
    if any(prefix in data for prefix in PERSONAL_PREFIXES):
        add_error(errors, relative, "personal-absolute-path")
    if any(pattern.search(data) for pattern in SECRET_PATTERNS):
        add_error(errors, relative, "secret-marker")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        add_error(errors, relative, "non-utf8")
        return False
    if any(line.rstrip("\r\n").endswith((" ", "\t")) for line in text.splitlines(True)):
        add_error(errors, relative, "trailing-whitespace")
    if os.access(path, os.X_OK) and path.suffix not in {".py", ".sh"}:
        add_error(errors, relative, "unexpected-executable")
    if (
        (relative.startswith("tool/") or relative.startswith("packages/"))
        and path.suffix == ".lisp"
        and SAFETY_ZERO.search(text)
    ):
        add_error(errors, relative, "runtime-safety-zero")
    return True


def validate_contracts(errors: list[dict[str, str]]) -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for phrase in (
        "not an SBCL fork",
        "not a Mesh TensorFlow replacement",
        "No whole-system speed claim",
    ):
        if phrase not in readme:
            add_error(errors, "README.md", "missing-claim-boundary")
    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    if "Apache License" not in license_text or "Version 2.0" not in license_text:
        add_error(errors, "LICENSE", "invalid-license-text")
    for asd in (
        ROOT / "packages" / "rational-quant" / "rational-quant.asd",
        ROOT / "packages" / "mirror-kernel" / "mirror-kernel.asd",
    ):
        if ':license "Apache-2.0"' not in asd.read_text(encoding="utf-8"):
            add_error(errors, asd.relative_to(ROOT).as_posix(), "missing-asdf-license")
    metadata = (ROOT / "skill" / "agents" / "openai.yaml").read_text(encoding="utf-8")
    for key in ("display_name:", "short_description:", "default_prompt:"):
        if key not in metadata:
            add_error(errors, "skill/agents/openai.yaml", "invalid-skill-metadata")
    claims = json.loads((ROOT / "reports" / "claims.json").read_text(encoding="utf-8"))
    by_id = {item.get("id"): item for item in claims.get("claims", [])}
    whole = by_id.get("whole-system-faster")
    if not whole or whole.get("claimClass") != "unknown":
        add_error(errors, "reports/claims.json", "whole-system-claim-not-unknown")
    portfolio = json.loads(
        (ROOT / "reports" / "portfolio-treatment.json").read_text(encoding="utf-8")
    )
    if portfolio.get("primaryTreatment") != "keep":
        add_error(errors, "reports/portfolio-treatment.json", "unexpected-skill-treatment")


def write_report(
    *,
    status: str,
    files: list[str],
    json_count: int,
    errors: list[dict[str, str]],
) -> None:
    report = {
        "schema": "release-acceptance/v1",
        "release": "v0.1.0-alpha",
        "status": status,
        "scope": "tracked plus unignored working-tree files",
        "candidateFileCount": len(files),
        "parsedJsonDocumentCount": json_count,
        "checks": {
            "regularUtf8Files": status == "passed",
            "noPersonalAbsolutePaths": status == "passed",
            "noSecretOrPrivateKeyMarkers": status == "passed",
            "noBinaryOrGeneratedArtifacts": status == "passed",
            "noRuntimeSafetyZero": status == "passed",
            "licenseAndClaimBoundaries": status == "passed",
            "noIgnoredTrackedFiles": status == "passed",
        },
        "errors": errors,
        "performanceClaim": False,
    }
    REPORT.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    errors: list[dict[str, str]] = []
    try:
        files = candidate_paths()
        if not files:
            raise ValueError("candidate set is empty")
        ignored_tracked = git_paths(["ls-files", "-ci", "--exclude-standard", "-z"])
        for relative in ignored_tracked:
            add_error(errors, relative, "ignored-tracked-file")
        json_count = 0
        for relative in files:
            readable = audit_file(relative, errors)
            if readable and relative.endswith(".json"):
                json_count += 1
                try:
                    json.loads((ROOT / relative).read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    add_error(errors, relative, "invalid-json")
        validate_contracts(errors)
        status = "passed" if not errors else "rejected"
        write_report(status=status, files=files, json_count=json_count, errors=errors)
        print(
            "RELEASE_AUDIT_RESULT "
            + json.dumps(
                {
                    "status": status,
                    "candidateFileCount": len(files),
                    "parsedJsonDocumentCount": json_count,
                    "errorCount": len(errors),
                },
                separators=(",", ":"),
            )
        )
        return 0 if not errors else 1
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"release audit: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
