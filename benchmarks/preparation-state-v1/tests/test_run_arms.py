"""Tests for run.py: classification logic, baseline behavior, and report
integrity (hashes and arm statuses) against the committed results.

Run: python3 -m pytest benchmarks/preparation-state-v1/tests -q
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parent.parent
REPO_ROOT = BENCH.parents[1]
sys.path.insert(0, str(BENCH))

import run as run_mod  # noqa: E402

RESULTS = BENCH / "results"
CATALOG_PATH = REPO_ROOT / "apps" / "ios" / "Resources" / "usda_ingredient_catalog.sqlite"
MANIFEST = json.loads((BENCH / "manifest.json").read_text())

USDA_IDS = {m["catalog_id"] for g in MANIFEST["groups"] for m in g["members"]}
ID_TO_GROUP = {
    m["catalog_id"]: g["group_id"]
    for g in MANIFEST["groups"]
    for m in g["members"]
}


# ---------------------------------------------------------------- classify
def _probe(family="state", rid=170157, state="raw"):
    return {"family": family, "target": {"record_id": rid, "state": state}}


def test_classify_correct():
    assert run_mod.classify(170157, _probe(), "acorns", ID_TO_GROUP, USDA_IDS) == "correct"


def test_classify_wrong_state_stays_in_group():
    # 170565 = Acorns (Dried), same group as the raw record.
    assert run_mod.classify(170565, _probe(), "acorns", ID_TO_GROUP, USDA_IDS) == "wrong_state"


def test_classify_wrong_identity_across_groups():
    assert run_mod.classify(167782, _probe(), "acorns", ID_TO_GROUP, USDA_IDS) == "wrong_identity"


def test_classify_abstain():
    assert run_mod.classify(None, _probe(), "acorns", ID_TO_GROUP, USDA_IDS) == "abstain"


def test_classify_unknown_state_abstain_is_correct():
    p = _probe(family="unknown_state", rid=None, state="cooked")
    assert run_mod.classify(None, p, "acorns", ID_TO_GROUP, USDA_IDS) == "correct_abstain"
    assert run_mod.classify(170157, p, "acorns", ID_TO_GROUP, USDA_IDS) == "wrong_state"


def test_classify_curated_cross():
    # Curated lexicon ids (1-50) are not USDA record ids.
    p = _probe(family="state", rid=168877, state="raw")
    assert run_mod.classify(2, p, "white rice", ID_TO_GROUP, USDA_IDS) == "curated_cross"


# ---------------------------------------------------------------- baseline
@pytest.fixture(scope="module")
def baseline():
    return run_mod.BaselineCatalog(run_mod.catalog_rows())


def test_baseline_is_state_blind_on_unique_match(baseline):
    # "Beef Chuck Roast (Raw)" is the only record of its group; stripping the
    # state word and prefix-matching must find it.
    rid = baseline.resolve("beef chuck roast")
    assert rid is not None and ID_TO_GROUP[rid] == "beef chuck roast"


def test_baseline_abstains_on_ambiguous_state_group(baseline):
    # acorns has raw and dried records; state-blind prefix matching sees two
    # hits and must abstain (unique-or-nil, like production).
    assert baseline.resolve("acorns") is None


# ------------------------------------------------------------- committed run
TEXT_RESULTS = RESULTS / "text_arms"
IMAGE_RESULTS = RESULTS / "image_inference"


def test_committed_results_exist():
    assert (TEXT_RESULTS / "report.json").exists()
    assert (TEXT_RESULTS / "predictions.jsonl").exists()
    # image arm and nutrient-consequence artifacts are committed alongside
    assert (IMAGE_RESULTS / "image_report.json").exists()
    assert (IMAGE_RESULTS / "image_predictions.jsonl").exists()
    assert (IMAGE_RESULTS / "observations.jsonl.gz").exists()
    assert (RESULTS / "nutrient_consequences.json").exists()


def test_report_predictions_hash_matches_committed_file():
    report = json.loads((TEXT_RESULTS / "report.json").read_text())
    digest = hashlib.sha256((TEXT_RESULTS / "predictions.jsonl").read_bytes()).hexdigest()
    assert report["predictions_sha256"] == digest
    assert report["manifest_sha256"] == hashlib.sha256(
        (BENCH / "manifest.json").read_bytes()
    ).hexdigest()


def test_report_records_unrun_swift_arm():
    report = json.loads((TEXT_RESULTS / "report.json").read_text())
    swift = report["arms"]["swift_replay"]
    assert swift["ran"] is False
    assert "unrun" in swift["status"]


def test_predictions_cover_every_probe_per_ran_arm():
    report = json.loads((TEXT_RESULTS / "report.json").read_text())
    lines = (TEXT_RESULTS / "predictions.jsonl").read_text().splitlines()
    by_arm: dict[str, int] = {}
    for line in lines:
        rec = json.loads(line)
        by_arm[rec["arm"]] = by_arm.get(rec["arm"], 0) + 1
    for arm, data in report["arms"].items():
        if data.get("ran"):
            assert by_arm.get(arm) == data["probe_count"]


def test_heldout_alternative_arm_is_committed_with_summary():
    report = json.loads((TEXT_RESULTS / "report.json").read_text())
    held = report["arms"]["heldout_alternative"]
    assert held["ran"] is True
    assert "alternative_selection" in held
    # unknown-state probes on multi-member test groups must not all be
    # counted as exact matches; the wrong-state mass is the finding
    sel = held["alternative_selection"]
    assert sel["unknown_state_wrong_state"] > 0


def test_run_is_deterministic(tmp_path):
    """Re-running the baseline arm over a probe subset reproduces outcomes."""
    ctx = {"baseline": run_mod.BaselineCatalog(run_mod.catalog_rows())}
    outcomes_a = [
        run_mod.run_probe("pinned_cpu_baseline", p["text"], ctx)[0] for p in MANIFEST["probes"][:50]
    ]
    outcomes_b = [
        run_mod.run_probe("pinned_cpu_baseline", p["text"], ctx)[0] for p in MANIFEST["probes"][:50]
    ]
    assert outcomes_a == outcomes_b
