#!/usr/bin/env python3
"""Tests for check.py — the named-suite runner.

Runs the runner as a subprocess against the real repository, so the tests
exercise the real CLI contract: known suites run green, unknown/empty
suites are rejected with exit code 2, and --list names every suite.

    python3 scripts/overhaul-checks/test_check.py
"""

import subprocess
import sys
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parent / "check.py"
REPO_ROOT = CHECK.parents[2]


def run_check(*args):
    return subprocess.run(
        [sys.executable, str(CHECK), *args],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )


class SuiteRejectionTests(unittest.TestCase):
    """The rejection contract: unknown or empty suites fail with exit 2."""

    def test_unknown_suite_is_rejected(self):
        result = run_check("--suite", "bogus")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown suite: bogus", result.stderr)

    def test_empty_suite_is_rejected(self):
        result = run_check("--suite", "")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--suite is required", result.stderr)

    def test_missing_suite_flag_is_rejected(self):
        result = run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("--suite is required", result.stderr)

    def test_list_names_every_suite(self):
        result = run_check("--list")
        self.assertEqual(result.returncode, 0)
        listed = result.stdout.split()
        for expected in (
            "all", "backend", "core", "data", "domain", "fixtures",
            "imports", "paired-write", "persistence", "round2-validation",
            "sharing",
        ):
            self.assertIn(expected, listed, f"--list is missing suite '{expected}'")


class SuiteRunsTests(unittest.TestCase):
    """Known suites run green against the real repository (slower)."""

    def test_data_suite_runs_the_fixture_check(self):
        result = run_check("--suite", "data")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK 6 fixtures conform to fldomain.v1", result.stdout)

    def test_core_suite_runs_tests_and_fixture_check(self):
        result = run_check("--suite", "core")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Executed", result.stdout)
        self.assertIn("OK 6 fixtures conform to fldomain.v1", result.stdout)

    def test_backend_suite_runs_bun_tests(self):
        result = run_check("--suite", "backend")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # bun writes its pass/fail summary to stderr; assert on the combined
        # output so the assertion holds regardless of stream interleaving.
        self.assertIn("pass", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
