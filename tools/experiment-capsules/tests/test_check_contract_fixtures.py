"""End-to-end checker tests: run the CLI the way a reviewer does.

Every test invokes the checker as a subprocess from the repository root and
asserts literal exit codes and rejection counts.
"""

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CHECKER = "tools/experiment-capsules/check_contract.py"
FIXTURES = "tools/experiment-capsules/fixtures/contracts"


def run_checker(*args):
    return subprocess.run(
        [sys.executable, CHECKER, *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_fixture_suite_passes_with_exact_counts():
    result = run_checker()
    assert result.returncode == 0, result.stdout
    assert "case valid: findings {} expected {} PASS" in result.stdout
    assert 'case missing-import: findings {"missing-import": 1}' in result.stdout
    assert 'case source-mismatch: findings {"source-mismatch": 1}' in result.stdout
    assert (
        'case self-referential: findings {"self-referential-hash": 1}' in result.stdout
    )
    assert "case dynamic-gap-declared: findings {} expected {} PASS" in result.stdout
    assert (
        "SUMMARY rejections: missing-import=1, self-referential-hash=1, "
        "source-mismatch=1" in result.stdout
    )
    assert "fixture expectations: all met" in result.stdout


def test_valid_fixture_binding_is_clean():
    result = run_checker("--binding", f"{FIXTURES}/valid/binding.json")
    assert result.returncode == 0, result.stdout
    assert result.stdout.strip().endswith("rejections: none")


def test_missing_import_fixture_is_rejected():
    result = run_checker("--binding", f"{FIXTURES}/missing-import/binding.json")
    assert result.returncode == 1
    assert "missing-import: " in result.stdout
    assert result.stdout.count("missing-import: ") == 1


def test_source_mismatch_fixture_is_rejected():
    result = run_checker("--binding", f"{FIXTURES}/source-mismatch/binding.json")
    assert result.returncode == 1
    assert result.stdout.count("source-mismatch: ") == 1


def test_self_referential_fixture_is_rejected_once():
    result = run_checker("--binding", f"{FIXTURES}/self-referential/binding.json")
    assert result.returncode == 1
    # Exactly one finding: the self-reference root cause, no double-count.
    assert result.stdout.count("self-referential-hash: ") == 1
    assert "source-mismatch: " not in result.stdout


def test_absent_binding_is_a_usage_error():
    result = run_checker("--binding", f"{FIXTURES}/does-not-exist.json")
    assert result.returncode == 2
