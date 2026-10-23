"""Tests for the corpus integrity checker.

The checker must pass on the canonical generated corpus and must actually
catch the defect classes it claims to verify: fabricated values, missing
observability justifications, broken arithmetic, and missing basis markers.
"""

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVAL_DIR = HERE.parent
sys.path.insert(0, str(EVAL_DIR))

import generate_corpus as gen  # noqa: E402
import check_corpus as checker  # noqa: E402


def _corpus_path(tmp_path):
    recs = gen.build(20261010)
    out = tmp_path / "labels.jsonl"
    out.write_text("\n".join(json.dumps(r) for r in recs) + "\n", encoding="utf-8")
    return out


def test_checker_passes_on_generated_corpus(tmp_path):
    _, errors = checker.check_corpus(str(_corpus_path(tmp_path)))
    assert errors == []


def test_checker_cli_passes(tmp_path):
    corpus = _corpus_path(tmp_path)
    proc = subprocess.run(
        [sys.executable, str(EVAL_DIR / "check_corpus.py"), str(corpus)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr


def _one_record():
    return gen.build(20261010)[0]  # first record is clean US dual-column


def _write(records, tmp_path):
    out = tmp_path / "mutated.jsonl"
    out.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
    return str(out)


def test_checker_catches_fabricated_value(tmp_path):
    rec = _one_record()
    fid, basis = "fat_g", "per_serving"
    rec["fields"][f"{fid}@{basis}"]["value"] = "9999"
    rec["fields"][f"{fid}@{basis}"]["evidence_line"] = rec["fields"][f"{fid}@{basis}"]["evidence_line"]
    _, errors = checker.check_corpus(_write([rec], tmp_path))
    assert any("value" in e.lower() for e in errors)


def test_checker_catches_broken_kj_kcal(tmp_path):
    records = gen.build(20261010)
    rec = next(
        r
        for r in records
        for basis in gen.BASES
        if r["fields"].get(f"energy_kj@{basis}", {}).get("observable")
        and r["fields"].get(f"energy_kcal@{basis}", {}).get("observable")
    )
    basis = next(
        b
        for b in gen.BASES
        if rec["fields"].get(f"energy_kj@{b}", {}).get("observable")
        and rec["fields"].get(f"energy_kcal@{b}", {}).get("observable")
    )
    d = rec["fields"][f"energy_kcal@{basis}"]
    d["value"] = str(int(d["value"]) + 500)
    _, errors = checker.check_corpus(_write([rec], tmp_path))
    assert any("kcal" in e and "kJ" in e for e in errors), errors


def test_checker_catches_missing_basis_marker(tmp_path):
    import re

    records = gen.build(20261010)
    # EU families put the basis marker on a single header line ("per 100 g",
    # "per portion"); damaging it must invalidate the observable claims
    rec = next(
        r
        for r in records
        if r["family"] in ("eu_per100g", "eu_per_portion") and r["variant_kind"] == "clean"
        and r["fields"].get("energy_kcal@per_100g", {}).get("observable")
    )
    header = next(
        i for i, l in enumerate(rec["lines"]) if re.search(gen.BASIS_MARKERS["per_100g"], l)
    )
    rec["lines"][header] = rec["lines"][header].replace("per 100 g", "per 1xx g")
    _, errors = checker.check_corpus(_write([rec], tmp_path))
    assert any("basis" in e.lower() for e in errors), errors


def test_checker_catches_observable_without_evidence(tmp_path):
    rec = _one_record()
    d = rec["fields"]["fat_g@per_package"]
    d["evidence_line"] = 99
    _, errors = checker.check_corpus(_write([rec], tmp_path))
    assert any("evidence" in e.lower() for e in errors)


def test_checker_catches_unclaimed_unobservable(tmp_path):
    rec = _one_record()
    d = rec["fields"]["salt_g@per_serving"]
    d["observable"] = False
    d["unobservability_reason"] = None
    _, errors = checker.check_corpus(_write([rec], tmp_path))
    assert any("justification" in e.lower() for e in errors)
