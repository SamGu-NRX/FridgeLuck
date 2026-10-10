import json
import shutil
import sys
from pathlib import Path

import pytest

TOOL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL_DIR))

from sources import (  # noqa: E402
    SourceBundle,
    SourceError,
    inventory_revision_id,
    profile_revision_id,
    recipe_revision_id,
)


def test_revision_ids_are_content_addressed(bundle):
    h = bundle.states_sha256[:12]
    assert inventory_revision_id(bundle.states_sha256, 1) == f"states:{h}:state=1"
    assert profile_revision_id(bundle.states_sha256, 4, 2) == f"profile:{h}:state=4:apv=2"
    assert recipe_revision_id(bundle.catalog_sha256, 103) == (
        f"catalog:{bundle.catalog_sha256[:12]}:recipe=103"
    )


def test_manifest_pin_blocks_tampering(bundle, tmp_path):
    for name in ("states.jsonl", "catalog.json", "claims.jsonl", "manifest.json"):
        shutil.copy(TOOL_DIR / "fixtures" / name, tmp_path / name)
    rows = [json.loads(l) for l in (tmp_path / "claims.jsonl").read_text().splitlines() if l]
    rows[0]["makeable_ids"] = [999]
    (tmp_path / "claims.jsonl").write_text(
        "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    )
    with pytest.raises(SourceError):
        SourceBundle(tmp_path)


def test_unknown_allergen_group_is_dropped(bundle):
    profile = {
        "diet": "",
        "allergen_groups": ["fish", "shellfish_x"],
        "allergen_ingredient_ids": [],
        "allergen_preferences_version": 1,
    }
    exc = bundle.effective_exclusions(profile)
    assert exc[43] == ["allergen_group:fish"]
    assert not any(any("shellfish_x" in v for v in via) for via in exc.values())


def test_exclusion_provenances_union(bundle):
    profile = {
        "diet": "vegan",
        "allergen_groups": ["milk"],
        "allergen_ingredient_ids": [9],
        "allergen_preferences_version": 1,
    }
    exc = bundle.effective_exclusions(profile)
    assert exc[12] == ["allergen_group:milk", "diet:vegan"]
    assert exc[9] == ["allergen_ingredient"]


def test_estimated_lot_makes_quantity_unknown(bundle):
    truth = bundle.derive_all(1, 102)
    w = truth["required"][12]
    assert w["kind"] == "quantity_unknown"
    assert w["basis_lots"][0]["known_grams"] is None
    assert 12 in truth["unknown_ids"] and 12 in truth["satisfied_ids"]


def test_exact_boundary_counts_as_satisfied(bundle):
    truth = bundle.derive_all(2, 101)
    assert truth["required"][2]["kind"] == "required_satisfied"
    assert truth["required"][2]["available_grams"] == 400.0
    assert truth["required"][3]["available_grams"] == 30.0


def test_shortage_reports_available_and_required(bundle):
    truth = bundle.derive_all(2, 102)
    w = truth["required"][5]
    assert w["kind"] == "shortage"
    assert w["available_grams"] == 100.0 and w["required_grams"] == 300.0


def test_zero_remaining_known_lot_is_shortage(bundle):
    state = {
        "pantry": [{"ingredient_id": 2, "known_grams": 0.0, "is_estimate": False}],
        "profile": {
            "diet": "",
            "allergen_groups": [],
            "allergen_ingredient_ids": [],
            "allergen_preferences_version": 1,
        },
    }
    recipe = {"required": [[2, 100]], "optional": []}
    w = bundle.derive_required(state, recipe)[2]
    assert w["kind"] == "shortage" and w["available_grams"] == 0.0


def test_optional_rows_typed_apart_from_required(bundle):
    truth = bundle.derive_all(3, 103)
    assert truth["optional"][44]["kind"] == "optional_present"
    assert truth["optional"][22]["kind"] == "optional_excluded"
    assert truth["optional"][22]["excluded_via"] == ["allergen_ingredient"]
    assert truth["excluded_ids"] == [43]  # salmon blocked by the fish group


def test_tag_violation_uses_diet_mask(bundle):
    state = {
        "profile": {
            "diet": "keto",
            "allergen_groups": [],
            "allergen_ingredient_ids": [],
            "allergen_preferences_version": 1,
        }
    }
    assert bundle.tag_violation(state, bundle.catalog[101]) is True
    assert bundle.tag_violation(state, {"tags": 1 | 1024}) is False
