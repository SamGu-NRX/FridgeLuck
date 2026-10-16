"""Planted-failure tests for the pantry-2026-10 packet checker.

Each test plants exactly one defect in an in-memory copy of the built
corpus or its rights manifest and asserts the packet wrapper
(src/check_packet.py) catches it. The fixtures never touch the files on
disk, so the suite doubles as a record of which gates the wrapper is
expected to enforce: rights coverage, original-rights basis, the
pantry-signal gate (name anchoring AND signature-ingredient stocking),
the FSIS thermometer/colour-time doneness lint, the vegetarian floor,
and the recipe-name to bundle-key mapping that reach measurement
depends on. The green control runs the unmodified corpus first.
"""

import copy
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "src"
sys.path.insert(0, str(SRC))

import check_packet as cp  # noqa: E402  (pantry wrapper, distinct module)
import run_reach  # noqa: E402

PKG = HERE.parent


@pytest.fixture(scope="module")
def records() -> list[dict]:
    return cp.load_records(PKG / "originals.jsonl")


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(
        (PKG / "evidence" / "originals-rights-manifest.json").read_text())


@pytest.fixture(scope="module")
def pantries() -> dict:
    entries = json.loads(cp.REACH_FIXTURES.read_text())["pantries"]
    return {str(e.get("name", i)): (cp.all_pantry_names(e),
                                    cp.pantry_names(e))
            for i, e in enumerate(entries)}


def run(records_, manifest_, pantries_) -> list[str]:
    return cp.run_pantry_check(records_, manifest_, pantries_)


def by_title(records_, title: str) -> int:
    return next(i for i, r in enumerate(records_) if r["title"] == title)


def test_green_control(records, manifest, pantries):
    """The unmodified built corpus is clean — plants below cause the
    failures, not the harness."""
    assert run(records, manifest, pantries) == []


def test_missing_rights_entry_is_caught(records, manifest, pantries):
    broken = copy.deepcopy(manifest)
    ref = records[0]["source_ref"]
    del broken[ref]
    violations = run(records, broken, pantries)
    assert violations, "missing rights entry must fail the packet"
    assert ref in " ".join(violations)


def test_non_original_rights_entry_is_caught(records, manifest, pantries):
    broken = copy.deepcopy(manifest)
    ref = records[0]["source_ref"]
    entry = dict(broken[ref])
    entry["basis"] = "adapted from a published cookbook excerpt"
    entry["rights_status"] = "third-party"
    broken[ref] = entry
    violations = run(records, broken, pantries)
    assert violations, "non-original rights basis must fail the packet"
    assert records[0]["id"] in " ".join(violations)


def test_unanchored_dish_is_caught(records, manifest, pantries):
    """Regression: a dish no pantry item names (the original 'Aloo
    Raita' failure) must be flagged, and the violation must carry the
    packet id, not the adapted fl-world id."""
    broken = copy.deepcopy(records)
    i = by_title(broken, "Potato Raita")
    broken[i]["title"] = "Aloo Raita"
    violations = run(broken, manifest, pantries)
    assert any("no pantry fixture names the dish" in x for x in violations)
    assert broken[i]["id"] in " ".join(violations)


def test_unstocked_signature_is_caught(records, manifest, pantries):
    """A dish anchored by name whose only non-staple lines are stocked
    by no pantry fixture must be flagged (signature-ingredient half of
    the pantry-signal gate)."""
    broken = copy.deepcopy(records)
    i = by_title(broken, "Potato Raita")
    qty = broken[i]["ingredients"][0]["qty"]
    broken[i]["ingredients"] = [
        {"name": "potatoes", "qty": qty},
        {"name": "raspberries", "qty": qty},
    ]
    violations = run(broken, manifest, pantries)
    assert any("no pantry fixture names the dish" in x for x in violations)


def test_colour_time_doneness_step_is_caught(records, manifest, pantries):
    """Replacing the FSIS thermometer check on a poultry step with a
    colour-and-time judgement must fail the doneness lint."""
    broken = copy.deepcopy(records)
    i = by_title(broken, "Chicken and Corn Pasta")
    for s in broken[i]["steps"]:
        if "165 °F" in s["text"]:
            s["text"] = s["text"].replace(
                "until an instant-read thermometer reads 165 °F "
                "in the thickest piece of chicken",
                "until golden brown, about 6 minutes")
            s.pop("safety", None)
    violations = run(broken, manifest, pantries)
    assert violations, "colour/time doneness on poultry must fail the packet"
    assert broken[i]["id"] in " ".join(violations)


def test_vegetarian_share_below_floor(records, manifest, pantries):
    """A packet slice with no vegetarian recipes must fail the
    one-third vegetarian floor."""
    flesh = [r for r in records if r["title"] in {
        "Chicken and Corn Pasta", "Lemon Salmon Rice Bowl"}]
    assert len(flesh) == 2
    violations = run(flesh, manifest, pantries)
    assert any("vegetarian" in x.lower() for x in violations)


def test_all_ingredient_names_mapped_for_reach(records):
    """Every ingredient name in the built corpus resolves to a bundle
    key in the reach runner's mapping — run_reach.main would fail loud
    on a miss, so the mapping must cover the corpus exactly."""
    missing = sorted({line["name"] for r in records
                      for line in (r.get("lines") or r.get("ingredients"))
                      if line["name"] not in run_reach.NAME_TO_KEY})
    assert missing == []
