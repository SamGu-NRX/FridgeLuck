"""Contract-fixture check integration: check.py must pass and be deterministic."""

import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
REPO_ROOT = TOOLS.parents[1]
CONTRACTS = TOOLS / "fixtures" / "contracts.json"


def run_check():
    return subprocess.run(
        [sys.executable, str(TOOLS / "check.py"), "--fixture", str(CONTRACTS)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
    )


def test_check_fixture_passes():
    proc = run_check()
    assert proc.returncode == 0, f"check.py failed:\n{proc.stdout}\n{proc.stderr}"
    assert "PASS" in proc.stdout


def test_check_counts_are_committed_values():
    proc = run_check()
    out = proc.stdout
    assert "exact-duplicate=4" in out
    assert "renamed-url=3" in out
    assert "source-reuse=6" in out
    assert "transitive-source=1" in out
    assert "cross-manifest=5" in out
    assert "cross-group=7" in out
    assert "expectations: 8/8 satisfied" in out
    assert "false-positive controls: 0/15 flagged" in out


def test_check_is_deterministic():
    first = run_check()
    second = run_check()
    assert first.stdout == second.stdout
