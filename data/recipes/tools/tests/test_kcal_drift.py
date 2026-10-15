"""Kcal-drift validation: a per-serving kcal move of more than 40 percent
against the previously published bundle must be recorded in
data/recipe-bundle/nutrition-changes-2026-10.json naming the vocabulary change
that caused it. Planted violations prove the check fails closed.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

from validate_bundle import check_kcal_drift, kcal_swing  # noqa: E402

BUNDLE = REPO / "data/recipes/build/recipes-v2.json"
CHANGES = REPO / "data/recipe-bundle/nutrition-changes-2026-10.json"


def recipe(rid: str, kcal: float) -> dict:
    return {"catalog_id": rid, "nutrition_per_serving": {"kcal": kcal}}


def doc(*recipes: dict) -> dict:
    return {"recipes": list(recipes)}


def entry(rid: str, old: float, new: float,
          cause: str = "gochujang resolved to per-100g rows") -> dict:
    return {"catalog_id": rid, "old_kcal": old, "new_kcal": new,
            "vocabulary_change": cause}


# ---- 1. swing math and the no-previous skip --------------------------------

def test_kcal_swing_math_and_no_previous_skip():
    assert kcal_swing(100, 150) == pytest.approx(0.5)
    assert kcal_swing(100, 60) == pytest.approx(0.4)  # exactly 40% is allowed
    assert kcal_swing(100, 59) == pytest.approx(0.41)  # over 40% is not
    assert kcal_swing(0, 0) == 0.0
    assert kcal_swing(0, 10) == float("inf")
    # no previous bundle: nothing to compare against
    assert check_kcal_drift(doc(recipe("rcp-1", 500.0)), None, None) == []


# ---- 2. planted violations around exemptions --------------------------------

def test_drift_requires_matching_exemption_with_cause():
    new, prev = doc(recipe("rcp-1", 180.0)), doc(recipe("rcp-1", 100.0))
    # unrecorded move fails, naming the recipe
    errs = check_kcal_drift(new, prev, None)
    assert len(errs) == 1 and "rcp-1" in errs[0]
    # matching exemption with a cause passes
    ok = {"entries": [entry("rcp-1", 100.0, 180.0)]}
    assert check_kcal_drift(new, prev, ok) == []
    # stale kcal values in the exemption fail
    stale = {"entries": [entry("rcp-1", 100.0, 150.0)]}
    assert any("stale exemption" in e for e in check_kcal_drift(new, prev, stale))
    # blank cause fails
    blank = {"entries": [entry("rcp-1", 100.0, 180.0, cause="   ")]}
    assert any("vocabulary change" in e for e in check_kcal_drift(new, prev, blank))


# ---- 3. zero-kcal and new-recipe edges ---------------------------------------

def test_zero_kcal_and_new_recipe_edges():
    # a recipe that previously shipped kcal 0 and now has energy needs an entry
    errs = check_kcal_drift(doc(recipe("rcp-1", 50.0)), doc(recipe("rcp-1", 0.0)), None)
    assert len(errs) == 1 and "rcp-1" in errs[0]
    assert check_kcal_drift(doc(recipe("rcp-1", 0.0)), doc(recipe("rcp-1", 0.0)), None) == []
    # a brand-new recipe has no previous line to compare against
    assert check_kcal_drift(
        doc(recipe("rcp-new", 900.0)), doc(recipe("rcp-old", 100.0)), None) == []


# ---- 4. real bundles: seeded violation caught, committed file consistent ----

def test_seeded_drift_violation_and_real_changes_file_consistency():
    bundle = json.load(BUNDLE.open())
    rid = bundle["recipes"][0]["catalog_id"]
    n = bundle["recipes"][0]["nutrition_per_serving"]
    n["kcal"] = round(n["kcal"] * 3, 1)  # a 200% move with no exemption
    bad = REPO / "data/recipes/build/_seeded-drift.json"
    bad.write_text(json.dumps(bundle))
    try:
        out = subprocess.run(
            [sys.executable, str(TOOLS / "validate_bundle.py"), str(bad),
             "--previous", str(BUNDLE), "--changes", str(CHANGES)],
            capture_output=True, text=True, cwd=REPO)
        assert out.returncode == 1
        assert rid in out.stdout
        assert "against the previous published" in out.stdout
    finally:
        bad.unlink()

    # the committed changes file must reproduce the shipped bundle's kcal for
    # every exemption and name a vocabulary change (no stale entries)
    changes = json.load(CHANGES.open())
    assert changes["entries"], "changes file must not be empty"
    kcal = {r["catalog_id"]: r["nutrition_per_serving"]["kcal"] for r in bundle["recipes"]}
    for e in changes["entries"]:
        assert abs(e["new_kcal"] - kcal[e["catalog_id"]]) <= 0.05
        assert (e["vocabulary_change"] or "").strip()
