"""Tests for verify_report.py: the committed report refuses tampering."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent.parent
VERIFY = TOOL_DIR / "verify_report.py"


def run_verify(report: Path, production: Path, strict: Path, corpus: Path) -> int:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFY),
            "--corpus",
            str(corpus),
            "--production",
            str(production),
            "--strict",
            str(strict),
            "--report",
            str(report),
        ],
        capture_output=True,
        text=True,
    ).returncode


def committed_inputs(tmp_path: Path) -> dict[str, Path]:
    copies = {}
    for name, rel in (
        ("corpus", "corpus/labels.jsonl"),
        ("production", "reports/replay_predictions.jsonl"),
        ("strict", "reports/strict_predictions.jsonl"),
        ("report", "reports/report.json"),
    ):
        dst = tmp_path / rel.replace("/", "_")
        shutil.copy(TOOL_DIR / rel, dst)
        copies[name] = dst
    return copies


def test_verify_passes_on_committed_files():
    assert run_verify(
        TOOL_DIR / "reports" / "report.json",
        TOOL_DIR / "reports" / "replay_predictions.jsonl",
        TOOL_DIR / "reports" / "strict_predictions.jsonl",
        TOOL_DIR / "corpus" / "labels.jsonl",
    ) == 0


def test_tampered_report_fails(tmp_path):
    copies = committed_inputs(tmp_path)
    report = json.loads(copies["report"].read_text(encoding="utf-8"))
    report["arms"]["production"]["totals"]["match"] += 1
    copies["report"].write_text(json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    assert run_verify(copies["report"], copies["production"], copies["strict"], copies["corpus"]) == 1


def test_tampered_predictions_fail(tmp_path):
    copies = committed_inputs(tmp_path)
    text = copies["production"].read_text(encoding="utf-8")
    copies["production"].write_text(text.replace('"parsed":true', '"parsed":false', 1), encoding="utf-8")
    assert run_verify(copies["report"], copies["production"], copies["strict"], copies["corpus"]) == 1


def test_tampered_corpus_fails(tmp_path):
    copies = committed_inputs(tmp_path)
    text = copies["corpus"].read_text(encoding="utf-8")
    copies["corpus"].write_text(text.replace("LN-0001", "LN-9999", 1), encoding="utf-8")
    assert run_verify(copies["report"], copies["production"], copies["strict"], copies["corpus"]) == 1


def test_missing_input_fails_cleanly(tmp_path):
    copies = committed_inputs(tmp_path)
    copies["strict"].unlink()
    assert run_verify(copies["report"], copies["production"], copies["strict"], copies["corpus"]) == 2
