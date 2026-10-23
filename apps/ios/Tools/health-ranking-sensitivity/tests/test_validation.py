"""Validation-gate tests: unknown/zero macro handling, bounds consistency, lock."""

import copy
import json

import check_inputs as ci


def test_real_matrix_and_bounds_pass_clean(matrix, bounds, assumptions):
    assert ci.validate_matrix(matrix) == []
    assert ci.validate_bounds_vs_assumptions(bounds, assumptions) == []


def test_missing_macro_key_fails_loudly(matrix):
    bad = copy.deepcopy(matrix)
    del bad["recipes"][0]["macros_per_serving"]["sugar_g"]
    problems = ci.validate_matrix(bad)
    assert any("MISSING" in p and "sugar_g" in p for p in problems)


def test_null_macro_value_fails_loudly(matrix):
    bad = copy.deepcopy(matrix)
    bad["recipes"][0]["macros_per_serving"]["fiber_g"] = None
    problems = ci.validate_matrix(bad)
    assert any("fiber_g" in p and "expected a number" in p for p in problems)


def test_unknown_macro_field_fails_loudly(matrix):
    bad = copy.deepcopy(matrix)
    bad["recipes"][0]["macros_per_serving"]["vitamin_d_iu"] = 12.0
    problems = ci.validate_matrix(bad)
    assert any("UNKNOWN macro field" in p and "vitamin_d_iu" in p for p in problems)


def test_string_unknown_macro_value_fails_loudly(matrix):
    bad = copy.deepcopy(matrix)
    bad["recipes"][0]["macros_per_serving"]["protein_g"] = "unknown"
    problems = ci.validate_matrix(bad)
    assert any("protein_g" in p and "expected a number" in p for p in problems)


def test_zeros_are_real_measured_zeros_and_pass(matrix):
    zero_recipes = [r for r in matrix["recipes"]
                    if any(r["macros_per_serving"][k] == 0.0
                           for k in ("fiber_g", "sugar_g", "sodium_mg", "protein_g"))]
    assert zero_recipes, "matrix must include real-zero recipes"
    ids = {r["id"] for r in zero_recipes}
    problems = ci.validate_matrix(matrix)
    offending = [p for p in problems if any(i in p for i in ids)]
    assert not offending, f"zeros must not be treated as missing: {offending}"


def test_bounds_must_equal_assumption_values(bounds, assumptions):
    bad = copy.deepcopy(bounds)
    bad["plausible"]["nutrients_pct"]["calories"] = 25.0  # not what the citation supports
    problems = ci.validate_bounds_vs_assumptions(bad, assumptions)
    assert any("MISMATCH" in p and "plausible.calories" in p for p in problems)


def test_sourced_without_citation_reports_problem(bounds, assumptions):
    bad = copy.deepcopy(assumptions)
    bad["nutrients"]["calories"]["plausible_citation"] = ""
    problems = ci.validate_bounds_vs_assumptions(bounds, bad)
    assert any("claims sourced but has no citation" in p and "calories" in p for p in problems)


def test_judgment_call_requires_basis(bounds, assumptions):
    bad = copy.deepcopy(assumptions)
    bad["nutrients"]["fiber"]["plausible_basis"] = ""
    problems = ci.validate_bounds_vs_assumptions(bounds, bad)
    assert any("judgment_call" in p and "fiber" in p for p in problems)


def test_stress_arms_must_be_stress_labeled(bounds):
    bad = copy.deepcopy(bounds)
    for arm in bad["arms"]:
        if arm.get("stress"):
            arm["id"] = "renamed_without_label"
            break
    problems = ci.validate_bounds_vs_assumptions(bad, {})
    assert any("stress bounds without the stress label" in p for p in problems)


def test_lock_deferred_without_manifest(tmp_path):
    problems, notes = ci.validate_lock(tmp_path / "manifest.json")
    assert problems == []
    assert any("deferred" in n for n in notes)


def test_lock_detects_post_output_edit_of_bounds(tmp_path, monkeypatch):
    fake_inputs = tmp_path / "inputs"
    fake_inputs.mkdir()
    for name in ("perturbation_bounds.json", "uncertainty_assumptions.json",
                 "frozen_matrix.json"):
        (fake_inputs / name).write_text("{}\n", encoding="utf-8")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({
        "inputs_checksums": {
            "perturbation_bounds.json": "0" * 64,
            "uncertainty_assumptions.json": ci.canonical_sha256(fake_inputs / "uncertainty_assumptions.json"),
            "frozen_matrix.json": ci.canonical_sha256(fake_inputs / "frozen_matrix.json"),
        }
    }), encoding="utf-8")

    real_inputs = ci.INPUTS
    monkeypatch.setattr(ci, "INPUTS", fake_inputs)
    try:
        problems, _ = ci.validate_lock(manifest)
    finally:
        monkeypatch.setattr(ci, "INPUTS", real_inputs)
    assert any("LOCK VIOLATION" in p and "perturbation_bounds.json" in p for p in problems)


def test_lock_passes_when_checksums_match(tmp_path, monkeypatch):
    fake_inputs = tmp_path / "inputs"
    fake_inputs.mkdir()
    for name in ("perturbation_bounds.json", "uncertainty_assumptions.json",
                 "frozen_matrix.json"):
        (fake_inputs / name).write_text("content\n", encoding="utf-8")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({
        "inputs_checksums": {
            name: ci.canonical_sha256(fake_inputs / name)
            for name in ("perturbation_bounds.json", "uncertainty_assumptions.json",
                         "frozen_matrix.json")
        }
    }), encoding="utf-8")

    real_inputs = ci.INPUTS
    monkeypatch.setattr(ci, "INPUTS", fake_inputs)
    try:
        problems, notes = ci.validate_lock(manifest)
    finally:
        monkeypatch.setattr(ci, "INPUTS", real_inputs)
    assert problems == []
    assert len(notes) == 3
