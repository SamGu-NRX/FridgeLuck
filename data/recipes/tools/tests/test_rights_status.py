"""Rights-label validation: the shipped status must say what the release gate
vouches for. A status outside the schema enum, or an `original` whose rights
record the gate does not clear, is a defect. Planted violations prove the
check fails closed; the committed bundle proves it passes on the real thing.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

from validate_bundle import check_rights_statuses, gate_cleared_catalog_ids  # noqa: E402

BUNDLE = REPO / "data/recipes/build/recipes-v2.json"


def recipe(rid: str, status: str) -> dict:
    return {"catalog_id": rid, "rights": {"status": status, "evidence": "e"}}


# ---- 1. planted enum violations --------------------------------------------

def test_status_outside_the_schema_enum_is_refused():
    bundle = {"recipes": [recipe("rcp-000167", "licensed"),
                          recipe("rcp-000168", "attribution_only")]}
    errs = check_rights_statuses(bundle, {"rcp-000167", "rcp-000168"})
    assert len(errs) == 2
    assert all("outside the schema enum" in e for e in errs)


# ---- 2. original without a cleared record is refused ------------------------

def test_original_without_a_cleared_record_is_refused():
    bundle = {"recipes": [recipe("rcp-000167", "original")]}
    errs = check_rights_statuses(bundle, set())  # gate clears nothing
    assert len(errs) == 1
    assert "rcp-000167" in errs[0]
    assert "does not clear" in errs[0]


def test_quarantined_never_needs_a_cleared_record():
    bundle = {"recipes": [recipe("rcp-000167", "quarantined")]}
    assert check_rights_statuses(bundle, set()) == []


def test_original_with_a_cleared_record_passes():
    bundle = {"recipes": [recipe("rcp-000167", "original")]}
    assert check_rights_statuses(bundle, {"rcp-000167"}) == []


# ---- 3. the committed bundle against the real gate verdict ------------------

def test_committed_bundle_labels_match_the_release_gate():
    import json
    bundle = json.loads(BUNDLE.read_text(encoding="utf-8"))
    cleared = gate_cleared_catalog_ids()
    assert check_rights_statuses(bundle, cleared) == []
    # The corpus is all FL originals/original-rewrites the gate clears, so the
    # shipped labels must be original throughout and nothing may be quarantined.
    statuses = {r["rights"]["status"] for r in bundle["recipes"]}
    assert statuses == {"original"}
    assert len(cleared) == len(bundle["recipes"])
