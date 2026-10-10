import json
import subprocess
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL_DIR))

import expected_counts  # noqa: E402


def _run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def _build_and_verify():
    build = _run(sys.executable, str(TOOL_DIR / "build_records.py"))
    assert build.returncode == 0, build.stderr
    verify = _run(
        sys.executable,
        str(TOOL_DIR / "verify.py"),
        "--records",
        str(TOOL_DIR / "records.jsonl"),
        "--out",
        str(TOOL_DIR / "results"),
    )
    assert verify.returncode == 0, verify.stderr
    summary = json.loads((TOOL_DIR / "results" / "summary.json").read_text())
    verdicts = [
        json.loads(l)
        for l in (TOOL_DIR / "results" / "verdicts.jsonl").read_text().splitlines()
        if l
    ]
    return summary, {v["record_id"]: v for v in verdicts}


def test_summary_matches_expected_counts():
    summary, _ = _build_and_verify()
    errs = expected_counts.assert_expected_counts(summary)
    assert not errs, errs


def test_every_mutant_lands_in_its_designed_class():
    _, by_id = _build_and_verify()
    for mid, cls in expected_counts.EXPECTED_MUTANT_CLASSES.items():
        assert by_id[mid]["failure_class"] == cls, mid


def test_valids_accepted_and_supported():
    _, by_id = _build_and_verify()
    valids = [v for v in by_id.values() if v["record_id"].startswith("s")]
    assert len(valids) == expected_counts.TOTAL_VALIDS
    for v in valids:
        assert v["outcome"] == "accepted" and v["explanation_verdict"] == "supported"


def test_forged_basis_and_unknown_state_are_caught():
    _, by_id = _build_and_verify()
    m17 = by_id["m17"]
    assert m17["failure_class"] == "unsupported_witness"
    assert any("lot basis" in r for r in m17["reasons"])
    assert by_id["m11"]["failure_class"] == "claim_not_in_source"
