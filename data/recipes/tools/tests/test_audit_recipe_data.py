from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(TOOLS))

import audit_recipe_data as audit  # noqa: E402


def quantity(kind: str = "household", **values):
    return {"kind": kind, **values}


def recipe(lines, servings=2):
    return {"catalog_id": "rcp-test", "title": "Test recipe", "servings": servings, "ingredients": lines}


def bundle(recipes, ingredients):
    return {"ingredients": ingredients, "recipes": recipes}


def test_audit_flags_invalid_amount_missing_unit_duplicate_and_unit_mismatch():
    result = audit.audit_bundle(bundle(
        [recipe([
            {"key": "milk", "quantity": quantity(amount=1, unit="cup", grams=800)},
            {"key": "milk", "quantity": quantity(amount=0, unit="cup", grams=0)},
            {"key": "salt", "quantity": quantity(amount=1, unit="", grams=1)},
        ])],
        [
            {"key": "milk", "display_name": "Milk", "classes": ["dairy"]},
            {"key": "salt", "display_name": "Salt", "classes": ["mineral"]},
        ],
    ))
    assert len(result["duplicate_ingredients"]) == 1
    assert any("invalid amount" in row["reason"] for row in result["amounts"])
    assert len(result["missing_units"]) == 1
    assert len(result["unit_mismatches"]) == 1


def test_audit_flags_zero_negative_and_absurd_grams():
    result = audit.audit_bundle(bundle(
        [recipe([
            {"key": "rice", "quantity": quantity("grams", grams=-1)},
            {"key": "beans", "quantity": quantity("grams", grams=5000)},
        ], servings=1)],
        [
            {"key": "rice", "display_name": "Rice", "classes": ["plant"]},
            {"key": "beans", "display_name": "Beans", "classes": ["plant"]},
        ],
    ))
    reasons = [row["reason"] for row in result["amounts"]]
    assert any("invalid grams" in reason for reason in reasons)
    assert any("implausibly high" in reason for reason in reasons)


def test_unknown_allergen_lists_every_recipe_using_the_ingredient():
    result = audit.audit_bundle(bundle(
        [recipe([{ "key": "sauce", "quantity": quantity("unknown") }]),
         {**recipe([{ "key": "sauce", "quantity": quantity("unknown") }]), "catalog_id": "rcp-other"}],
        [{"key": "sauce", "display_name": "Sauce", "classes": ["plant", "unknown"]}],
    ))
    assert len(result["unknown_allergens"]) == 1
    assert [row["catalog_id"] for row in result["unknown_allergens"][0]["recipes"]] == ["rcp-test", "rcp-other"]


def test_corrections_require_a_citation():
    audit.validate_corrections(audit.CORRECTIONS)
    with pytest.raises(ValueError, match="lacks a citation"):
        audit.validate_corrections([{"recipe": "rcp-test", "field": "grams"}])


def test_each_corrected_value_carries_its_citation_in_the_report():
    report = (REPO / "data/recipe-bundle/recipe-data-audit.md").read_text(encoding="utf-8")
    for correction in audit.CORRECTIONS:
        assert correction["citation"] in report
        assert correction["recipe"] in report
        assert correction["ingredient"] in report


def test_cli_is_deterministic_and_reports_shipped_findings(tmp_path):
    first = tmp_path / "first.md"
    second = tmp_path / "second.md"
    command = [sys.executable, "-I", str(TOOLS / "audit_recipe_data.py"), str(audit.BUNDLE)]
    one = subprocess.run(command + ["--report", str(first)], cwd=REPO, capture_output=True, text=True)
    two = subprocess.run(command + ["--report", str(second)], cwd=REPO, capture_output=True, text=True)
    assert one.returncode == 1
    assert two.returncode == 1
    assert first.read_bytes() == second.read_bytes()
    assert "unknown_allergens:" in one.stdout
    assert "Unknown allergen state" in first.read_text(encoding="utf-8")
