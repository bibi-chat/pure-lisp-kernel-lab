from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
VERIFIER = ROOT / "tool" / "verify_kernel.py"
PIPELINE_COMPILER = ROOT / "tool" / "pipeline-compiler.lisp"
EGRAPH_COMPILER = ROOT / "tool" / "lawful-egraph-compiler.lisp"
IDENTITY_CASE = FIXTURES / "identity-case.lisp"
EGRAPH_CASE = FIXTURES / "egraph-expression-case.lisp"
WARNING_COMPILER = FIXTURES / "warning-compiler.lisp"
LOAD_WARNING_COMPILER = FIXTURES / "load-warning-compiler.lisp"
REDEFINITION_COMPILER = FIXTURES / "unrelated-redefinition-compiler.lisp"
BENCHMARK_MISMATCH_CASE = FIXTURES / "benchmark-mismatch-case.lisp"
MUTATING_CANDIDATE_CASE = FIXTURES / "mutating-candidate-case.lisp"


class VerifyKernelIntegrationTests(unittest.TestCase):
    def run_verifier(
        self, case: Path, compiler: Path | None = None
    ) -> tuple[subprocess.CompletedProcess[str], dict]:
        with tempfile.TemporaryDirectory(prefix="verify-kernel-test-") as directory:
            report = Path(directory) / "report.json"
            command = [
                sys.executable,
                str(VERIFIER),
                str(case),
                "--output",
                str(report),
                "--require",
                "correctness",
                "--case-count",
                "16",
                "--benchmark-size",
                "32",
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
            if compiler is not None:
                command.extend(("--compiler", str(compiler)))
            environment = os.environ.copy()
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            completed = subprocess.run(
                command,
                text=True,
                capture_output=True,
                timeout=60,
                check=False,
                env=environment,
            )
            payload = json.loads(report.read_text(encoding="utf-8"))
            return completed, payload

    def assert_verified_without_warnings(self, payload: dict) -> None:
        self.assertEqual(payload["status"], "accepted")
        self.assertTrue(payload["source_integrity"]["passed"])
        self.assertIn("verifier_sha256", payload["inputs"])
        self.assertTrue(payload["gate"]["compiler_warnings_requirement_passed"])
        for profile in payload["profiles"].values():
            self.assertEqual(profile["status"], "verified")
            self.assertFalse(profile["compiler_warnings"])
            self.assertTrue(profile["benchmark_correctness"]["passed"])

    def test_default_pipeline_compiler_remains_accepted(self) -> None:
        completed, payload = self.run_verifier(IDENTITY_CASE)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_verified_without_warnings(payload)
        self.assertEqual(
            Path(payload["inputs"]["compiler_file"]), PIPELINE_COMPILER
        )
        self.assertIn("pipeline_compiler_sha256", payload["inputs"])

    def test_egraph_compiler_is_explicit_and_accepted(self) -> None:
        completed, payload = self.run_verifier(EGRAPH_CASE, EGRAPH_COMPILER)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_verified_without_warnings(payload)
        self.assertEqual(Path(payload["inputs"]["compiler_file"]), EGRAPH_COMPILER)
        self.assertNotIn("pipeline_compiler_sha256", payload["inputs"])
        self.assertEqual(payload["configuration"]["case_count"], 16)

    def test_selected_compiler_warning_is_rejected(self) -> None:
        completed, payload = self.run_verifier(IDENTITY_CASE, WARNING_COMPILER)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(payload["status"], "rejected")
        self.assertTrue(payload["source_integrity"]["passed"])
        self.assertFalse(payload["gate"]["compiler_warnings_requirement_passed"])
        for profile in payload["profiles"].values():
            self.assertEqual(profile["status"], "verified")
            self.assertTrue(profile["compiler_warnings"])

    def test_selected_compiler_load_warning_is_rejected(self) -> None:
        completed, payload = self.run_verifier(IDENTITY_CASE, LOAD_WARNING_COMPILER)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(payload["status"], "rejected")
        self.assertTrue(payload["source_integrity"]["passed"])
        self.assertFalse(payload["gate"]["compiler_warnings_requirement_passed"])
        for profile in payload["profiles"].values():
            self.assertEqual(profile["status"], "verified")
            self.assertTrue(profile["compiler_warnings"])

    def test_unrelated_redefinition_warning_is_rejected(self) -> None:
        completed, payload = self.run_verifier(IDENTITY_CASE, REDEFINITION_COMPILER)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(payload["status"], "rejected")
        self.assertFalse(payload["gate"]["compiler_warnings_requirement_passed"])
        for profile in payload["profiles"].values():
            self.assertEqual(profile["status"], "verified")
            self.assertTrue(profile["compiler_warnings"])

    def test_benchmark_input_mismatch_is_rejected_before_timing(self) -> None:
        completed, payload = self.run_verifier(BENCHMARK_MISMATCH_CASE)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(payload["status"], "rejected")
        semantic = payload["profiles"]["semantic"]
        self.assertTrue(semantic["correctness"]["passed"])
        self.assertFalse(semantic["benchmark_correctness"]["passed"])
        self.assertIsNone(payload["profiles"]["measured"])
        self.assertFalse(payload["gate"]["passed"])

    def test_candidate_input_mutation_is_rejected_before_timing(self) -> None:
        completed, payload = self.run_verifier(MUTATING_CANDIDATE_CASE)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(payload["status"], "rejected")
        semantic = payload["profiles"]["semantic"]
        self.assertEqual(semantic["status"], "semantic-mismatch")
        for section in ("correctness", "benchmark_correctness"):
            verification = semantic[section]
            self.assertFalse(verification["passed"])
            self.assertIn(
                "A kernel mutated its input",
                {failure["reason"] for failure in verification["failures"]},
            )
        self.assertIsNone(payload["profiles"]["measured"])
        self.assertIsNone(payload["worker_returncodes"]["measured"])
        self.assertFalse(payload["gate"]["timing_conclusive"])
        self.assertFalse(payload["gate"]["passed"])

    def test_derived_output_cannot_overwrite_a_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="verify-kernel-collision-") as directory:
            root = Path(directory)
            case = root / "identity.semantic.lisp"
            compiler = root / "compiler.lisp"
            output = root / "identity.lisp"
            shutil.copyfile(IDENTITY_CASE, case)
            shutil.copyfile(PIPELINE_COMPILER, compiler)
            before = case.read_bytes()
            completed = subprocess.run(
                [
                    sys.executable,
                    str(VERIFIER),
                    str(case),
                    "--compiler",
                    str(compiler),
                    "--output",
                    str(output),
                    "--require",
                    "correctness",
                    "--no-disassembly",
                ],
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(completed.returncode, 1)
            self.assertIn(
                "output artifacts must not overwrite source inputs",
                completed.stderr,
            )
            self.assertEqual(case.read_bytes(), before)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
