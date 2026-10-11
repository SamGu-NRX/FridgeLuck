"""Smoke test: the scaffold CLI parses and exposes the pinned contract."""

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "sqlite_state_diff" / "cli.py"


def test_help_exit_zero_and_lists_contract():
    proc = subprocess.run(
        [sys.executable, str(CLI), "--help"],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    for token in ("A", "B", "--table", "--key", "--max-rows-per-table", "--time-budget-seconds"):
        assert token in proc.stdout, f"missing {token!r} in --help output"
