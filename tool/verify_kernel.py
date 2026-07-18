#!/usr/bin/env python3
"""Compile, differentially verify, benchmark, and inspect a pure Lisp kernel."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


VERIFIER = Path(__file__).resolve()
TOOL_DIR = VERIFIER.parent
WORKER = TOOL_DIR / "sbcl-worker.lisp"
DEFAULT_COMPILER = TOOL_DIR / "pipeline-compiler.lisp"
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return parsed


def report_variant(path: Path, label: str) -> Path:
    if path.suffix:
        return path.with_name(f"{path.stem}.{label}{path.suffix}")
    return path.with_name(f"{path.name}.{label}.json")


def truncate_artifact(path: Path) -> None:
    if not path.exists() or path.stat().st_size <= MAX_ARTIFACT_BYTES:
        return
    marker = b"\n[compile-pure-lisp: artifact truncated at 2 MiB]\n"
    with path.open("r+b") as stream:
        stream.truncate(MAX_ARTIFACT_BYTES)
        stream.seek(0, 2)
        stream.write(marker)


def read_json_report(path: Path, fallback: dict[str, Any]) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
        if not isinstance(value, dict):
            raise ValueError("report root is not an object")
        return value
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return {**fallback, "report_error": str(error)}


def run_profile(
    *,
    mode: str,
    sbcl: str,
    case: Path,
    compiler: Path,
    report: Path,
    fasl: Path,
    log: Path,
    args: argparse.Namespace,
) -> tuple[dict[str, Any], int]:
    command = [
        sbcl,
        "--noinform",
        "--no-userinit",
        "--no-sysinit",
        "--disable-debugger",
        "--load",
        str(WORKER),
        "--quit",
        "--end-toplevel-options",
        mode,
        str(case),
        str(report),
        str(fasl),
        str(compiler),
        str(args.iterations),
        str(args.warmup),
        str(args.samples),
        str(args.seed),
        str(args.case_count),
        str(args.benchmark_size),
        "false" if args.no_disassembly else "true",
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=case.parent,
            text=True,
            capture_output=True,
            timeout=args.timeout,
            check=False,
        )
        transcript = completed.stdout + completed.stderr
        log.write_text(transcript, encoding="utf-8")
        truncate_artifact(log)
        profile = read_json_report(
            report,
            {
                "status": "worker-error",
                "mode": mode,
                "error": "SBCL did not produce a readable report",
            },
        )
        profile["worker_returncode"] = completed.returncode
        profile["compiler_log"] = str(log)
        for artifact in profile.get("artifacts", {}).values():
            if artifact:
                truncate_artifact(Path(artifact))
        return profile, completed.returncode
    except subprocess.TimeoutExpired as error:
        transcript = (error.stdout or "") + (error.stderr or "")
        log.write_text(transcript, encoding="utf-8")
        truncate_artifact(log)
        profile = {
            "status": "worker-timeout",
            "mode": mode,
            "error": f"SBCL exceeded {args.timeout} seconds",
            "compiler_log": str(log),
            "worker_returncode": None,
        }
        report.write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")
        return profile, 1
    except OSError as error:
        log.write_text(str(error) + "\n", encoding="utf-8")
        profile = {
            "status": "worker-error",
            "mode": mode,
            "error": str(error),
            "compiler_log": str(log),
            "worker_returncode": None,
        }
        report.write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")
        return profile, 1


def metric(profile: dict[str, Any], *keys: str) -> Any:
    value: Any = profile
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_hashes(case: Path, compiler: Path) -> dict[str, str]:
    def observed_hash(path: Path) -> str:
        try:
            return sha256(path)
        except OSError as error:
            return f"unavailable:{type(error).__name__}:{error}"

    return {
        "case_sha256": observed_hash(case),
        "compiler_sha256": observed_hash(compiler),
        "worker_sha256": observed_hash(WORKER),
        "verifier_sha256": observed_hash(VERIFIER),
    }


def evaluate_gate(
    semantic: dict[str, Any],
    measured: dict[str, Any] | None,
    args: argparse.Namespace,
) -> dict[str, Any]:
    semantic_ok = semantic.get("status") == "verified"
    measured_ok = bool(measured and measured.get("status") == "verified")
    warnings_ok = bool(
        args.allow_compiler_warnings
        or (
            not semantic.get("compiler_warnings", True)
            and measured is not None
            and not measured.get("compiler_warnings", True)
        )
    )
    speedup = metric(measured or {}, "benchmark", "speedup")
    bytes_saved = metric(measured or {}, "benchmark", "bytes_saved_per_call")
    candidate_bytes = metric(
        measured or {}, "benchmark", "candidate", "median_bytes_per_call"
    )
    reference_ns = metric(
        measured or {}, "benchmark", "reference", "median_nanoseconds_per_call"
    )
    candidate_ns = metric(
        measured or {}, "benchmark", "candidate", "median_nanoseconds_per_call"
    )
    timing_conclusive = bool(
        reference_ns is not None
        and candidate_ns is not None
        and reference_ns * args.iterations >= args.minimum_sample_ns
        and candidate_ns * args.iterations >= args.minimum_sample_ns
    )
    speed_ok = bool(
        timing_conclusive and speedup is not None and speedup >= args.min_speedup
    )
    allocation_ok = bool(
        bytes_saved is not None and bytes_saved >= args.min_bytes_saved
    )
    max_bytes_ok = bool(
        args.max_candidate_bytes is None
        or (candidate_bytes is not None and candidate_bytes <= args.max_candidate_bytes)
    )
    requirements = {
        "correctness": True,
        "speed": speed_ok,
        "allocation": allocation_ok,
        "speed-or-allocation": speed_ok or allocation_ok,
        "both": speed_ok and allocation_ok,
    }
    passed = (
        semantic_ok
        and measured_ok
        and warnings_ok
        and requirements[args.require]
        and max_bytes_ok
    )
    return {
        "passed": passed,
        "requirement": args.require,
        "semantic_profile_verified": semantic_ok,
        "measured_profile_verified": measured_ok,
        "compiler_warnings_allowed": args.allow_compiler_warnings,
        "compiler_warnings_requirement_passed": warnings_ok,
        "minimum_speedup": args.min_speedup,
        "observed_speedup": speedup,
        "minimum_sample_nanoseconds": args.minimum_sample_ns,
        "timing_conclusive": timing_conclusive,
        "speed_requirement_passed": speed_ok,
        "minimum_bytes_saved_per_call": args.min_bytes_saved,
        "observed_bytes_saved_per_call": bytes_saved,
        "allocation_requirement_passed": allocation_ok,
        "maximum_candidate_bytes_per_call": args.max_candidate_bytes,
        "observed_candidate_bytes_per_call": candidate_bytes,
        "maximum_candidate_bytes_passed": max_bytes_ok,
    }


def sbcl_version(sbcl: str) -> str:
    try:
        completed = subprocess.run(
            [sbcl, "--version"],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        return (completed.stdout or completed.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {error}"


def parser() -> argparse.ArgumentParser:
    default_sbcl = os.environ.get("SBCL_BIN") or shutil.which("sbcl") or "sbcl"
    result = argparse.ArgumentParser(
        description=(
            "Verify a COMPILE-PURE-LISP.CASE file in full-safety and measured "
            "SBCL profiles, then gate the candidate on semantic and performance evidence."
        )
    )
    result.add_argument("case", type=Path, help="Common Lisp case file")
    result.add_argument(
        "--output",
        type=Path,
        default=Path("compile-pure-lisp-report.json"),
        help="merged JSON report path",
    )
    result.add_argument("--sbcl", default=default_sbcl, help="SBCL executable")
    result.add_argument(
        "--compiler",
        type=Path,
        default=DEFAULT_COMPILER,
        help="compiler source loaded before the case (defaults to pipeline-compiler.lisp)",
    )
    result.add_argument("--iterations", type=positive_integer, default=20)
    result.add_argument("--warmup", type=nonnegative_integer, default=3)
    result.add_argument("--samples", type=positive_integer, default=7)
    result.add_argument("--seed", type=int, default=1729)
    result.add_argument("--case-count", type=positive_integer, default=64)
    result.add_argument("--benchmark-size", type=positive_integer, default=100000)
    result.add_argument("--timeout", type=positive_integer, default=120)
    result.add_argument("--minimum-sample-ns", type=positive_integer, default=1000000)
    result.add_argument(
        "--require",
        choices=("correctness", "speed", "allocation", "speed-or-allocation", "both"),
        default="speed-or-allocation",
    )
    result.add_argument("--min-speedup", type=positive_float, default=1.05)
    result.add_argument("--min-bytes-saved", type=nonnegative_float, default=1.0)
    result.add_argument("--max-candidate-bytes", type=nonnegative_float)
    result.add_argument("--no-disassembly", action="store_true")
    result.add_argument("--allow-compiler-warnings", action="store_true")
    result.add_argument("--json", action="store_true", help="print merged JSON")
    return result


def main() -> int:
    args = parser().parse_args()
    case = args.case.expanduser().resolve()
    compiler = args.compiler.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not case.is_file():
        print(f"case file not found: {case}", file=sys.stderr)
        return 1
    if output == case:
        print("output report must not overwrite the case file", file=sys.stderr)
        return 1
    if not WORKER.is_file() or not compiler.is_file():
        print("verifier compiler resources are incomplete", file=sys.stderr)
        return 1
    semantic_report_path = report_variant(output, "semantic")
    measured_report_path = report_variant(output, "measured")
    semantic_log = report_variant(output, "semantic.sbcl").with_suffix(".log")
    measured_log = report_variant(output, "measured.sbcl").with_suffix(".log")
    source_paths = {case, compiler, WORKER.resolve(), VERIFIER}
    destination_paths = {
        output,
        semantic_report_path,
        measured_report_path,
        semantic_log,
        measured_log,
    }
    if not args.no_disassembly:
        destination_paths.update(
            {
                Path(f"{measured_report_path}.reference.disassembly.txt"),
                Path(f"{measured_report_path}.candidate.disassembly.txt"),
            }
        )
    collisions = sorted(source_paths & destination_paths)
    if collisions:
        rendered = ", ".join(str(path) for path in collisions)
        print(
            f"output artifacts must not overwrite source inputs: {rendered}",
            file=sys.stderr,
        )
        return 1
    baseline_hashes = source_hashes(case, compiler)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="compile-pure-lisp-") as temporary:
        temp = Path(temporary)
        semantic, semantic_code = run_profile(
            mode="semantic",
            sbcl=args.sbcl,
            case=case,
            compiler=compiler,
            report=semantic_report_path,
            fasl=temp / "semantic.fasl",
            log=semantic_log,
            args=args,
        )
        after_semantic_hashes = source_hashes(case, compiler)
        semantic_sources_stable = after_semantic_hashes == baseline_hashes
        measured: dict[str, Any] | None = None
        measured_code: int | None = None
        if (
            semantic.get("status") == "verified"
            and semantic_code == 0
            and semantic_sources_stable
        ):
            measured, measured_code = run_profile(
                mode="measured",
                sbcl=args.sbcl,
                case=case,
                compiler=compiler,
                report=measured_report_path,
                fasl=temp / "measured.fasl",
                log=measured_log,
                args=args,
            )
        final_hashes = source_hashes(case, compiler)

    sources_stable = semantic_sources_stable and final_hashes == baseline_hashes

    gate = evaluate_gate(semantic, measured, args)
    valid_profile_statuses = {"verified", "semantic-mismatch"}
    infrastructure_failed = (
        not sources_stable
        or semantic.get("status") not in valid_profile_statuses
        or (
            measured is not None
            and measured.get("status") not in valid_profile_statuses
        )
    )
    final_status = (
        "error"
        if infrastructure_failed
        else ("accepted" if gate["passed"] else "rejected")
    )
    merged = {
        "schema": "compile-pure-lisp-report/v1",
        "complete": True,
        "status": final_status,
        "case_file": str(case),
        "inputs": {
            **baseline_hashes,
            "compiler_file": str(compiler),
            **(
                {"pipeline_compiler_sha256": baseline_hashes["compiler_sha256"]}
                if compiler == DEFAULT_COMPILER.resolve()
                else {}
            ),
        },
        "source_integrity": {
            "passed": sources_stable,
            "after_semantic": after_semantic_hashes,
            "after_measured": final_hashes,
        },
        "configuration": {
            "seed": args.seed,
            "case_count": args.case_count,
            "benchmark_size": args.benchmark_size,
            "iterations": args.iterations,
            "warmup_iterations": args.warmup,
            "samples": args.samples,
            "timeout_seconds": args.timeout,
            "write_disassembly": not args.no_disassembly,
            "requirement": args.require,
            "minimum_speedup": args.min_speedup,
            "minimum_bytes_saved_per_call": args.min_bytes_saved,
            "maximum_candidate_bytes_per_call": args.max_candidate_bytes,
            "minimum_sample_nanoseconds": args.minimum_sample_ns,
            "allow_compiler_warnings": args.allow_compiler_warnings,
        },
        "backend": {
            "implementation": "SBCL",
            "executable": args.sbcl,
            "version": sbcl_version(args.sbcl),
            "machine": platform.machine(),
            "operating_system": platform.platform(),
        },
        "gate": gate,
        "profiles": {"semantic": semantic, "measured": measured},
        "worker_returncodes": {
            "semantic": semantic_code,
            "measured": measured_code,
        },
    }
    output.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(merged, indent=2, sort_keys=True))
    else:
        observed = gate.get("observed_speedup")
        speed = "n/a" if observed is None else f"{observed:.3f}x"
        print(f"{merged['status']}: speedup={speed}; report={output}")
    if infrastructure_failed:
        return 1
    return 0 if gate["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
