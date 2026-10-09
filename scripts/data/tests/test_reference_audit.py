"""Tests for the reference audit comparison policy (synthetic data)."""

from __future__ import annotations

from usda_core.nutrients import NutrientObservation
from usda_core.reference_audit import audit_catalog, published_tolerance


def _catalog_row(fdc_id, macros, description="Test Food", data_type="SR Legacy", category="Vegetables"):
    return {
        "fdc_id": fdc_id,
        "display_name": "Test Food",
        "source_description": description,
        "macros": macros,
        "source_meta": {"data_type": data_type, "food_category": category},
    }


def _extract_record(fdc_id, nutrients, description="Test Food", data_type="SR Legacy",
                    category="Vegetables", dataset="sr_legacy", edition="SR Legacy 2021-10-28"):
    return {
        "fdc_id": fdc_id,
        "data_type": data_type,
        "description": description,
        "food_category": category,
        "publication_date": "4/1/2019",
        "source_dataset": dataset,
        "source_edition": edition,
        "nutrients": [
            {"id": nid, "number": num, "name": name, "unit": unit, "amount": amount}
            for nid, num, name, unit, amount in nutrients
        ],
    }


def _full_macros(calories=100.0, protein=10.0, carbs=10.0, fat=5.0, fiber=1.0, sugar=2.0, sodium=0.3):
    return {
        "calories": calories, "protein_g": protein, "carbs_g": carbs, "fat_g": fat,
        "fiber_g": fiber, "sugar_g": sugar, "sodium_g": sodium,
    }


class TestTolerance:
    def test_three_sigfig_half_ulp(self):
        assert published_tolerance(27.0, "calories") == 0.05
        assert published_tolerance(336.0, "calories") == 0.5
        assert published_tolerance(0.896, "protein_g") == 0.0005
        assert published_tolerance(6.65, "carbs_g") == 0.005
        # Zero and tiny values fall to the our-rounding floor (half of the
        # catalog's round(v, 4) step), not a publishing-step floor.
        assert published_tolerance(0.0, "protein_g") == 5e-5
        assert published_tolerance(0.0, "calories") == 5e-5


class TestAudit:
    def test_verified_record(self):
        extract_record = _extract_record(
            1,
            [
                (1008, "208", "Energy", "kcal", 100.0),
                (1003, "203", "Protein", "g", 10.0),
                (1005, "205", "Carbohydrates", "g", 10.0),
                (1004, "204", "Fat", "g", 5.0),
                (1079, "291", "Fiber", "g", 1.0),
                (2000, "269", "Sugars", "g", 2.0),
                (1093, "307", "Sodium", "mg", 300.0),
            ],
        )
        result = audit_catalog(
            [_catalog_row(1, _full_macros())], {"records": [extract_record]}
        )
        record = result.records[0]
        assert record.verdict == "verified"
        sodium = next(f for f in record.findings if f.nutrient == "sodium_g")
        assert sodium.status == "verified"
        assert sodium.reference_value == 0.3
        assert sodium.converted_from == "mg"

    def test_atwater_energy_discrepancy_proposed(self):
        extract_record = _extract_record(
            2,
            [
                (2048, "958", "Energy (Atwater Specific Factors)", "kcal", 27.0),
                (1003, "203", "Protein", "g", 0.896),
                (1005, "205", "Carbohydrates", "g", 6.65),
                (1004, "204", "Fat", "g", 0.146),
            ],
        )
        result = audit_catalog(
            [_catalog_row(2, _full_macros(calories=0.0))], {"records": [extract_record]}
        )
        record = result.records[0]
        assert record.verdict == "discrepancy"
        energy = next(f for f in record.findings if f.nutrient == "calories")
        assert energy.status == "discrepancy_correctable"
        assert energy.reference_value == 27.0
        assert energy.estimate_kcal is not None  # diagnostic present
        assert result.proposals and result.proposals[0]["field"] == "calories"
        assert result.proposals[0]["new_value"] == 27.0

    def test_alternate_energy_observation_is_not_a_discrepancy(self):
        # 2048 (selected, 150.0) disagrees with the catalog by more than its
        # 3-sig half-ulp; the alternate 2047 row reproduces the catalog value
        # exactly, so the record verifies via the alternate observation.
        extract_record = _extract_record(
            3,
            [
                (2048, "958", "Energy (Atwater Specific Factors)", "kcal", 150.0),
                (2047, "957", "Energy (Atwater General Factors)", "kcal", 151.0),
                (1003, "203", "Protein", "g", 10.0),
                (1005, "205", "Carbohydrates", "g", 10.0),
                (1004, "204", "Fat", "g", 5.0),
                (1079, "291", "Fiber", "g", 1.0),
                (2000, "269", "Sugars", "g", 2.0),
                (1093, "307", "Sodium", "mg", 300.0),
            ],
        )
        result = audit_catalog(
            [_catalog_row(3, _full_macros(calories=151.0))], {"records": [extract_record]}
        )
        energy = next(f for f in result.records[0].findings if f.nutrient == "calories")
        assert energy.status == "verified_alternate_observation"
        assert energy.reference_value == 151.0
        assert result.records[0].verdict == "verified"

    def test_macro_gap_is_reported_not_refilled(self):
        extract_record = _extract_record(
            4,
            [
                (1008, "208", "Energy", "kcal", 100.0),
                (1003, "203", "Protein", "g", 10.0),
            ],
        )
        result = audit_catalog(
            [_catalog_row(4, _full_macros())], {"records": [extract_record]}
        )
        assert result.records[0].verdict == "verified_with_gaps"
        missing = [f for f in result.records[0].findings if f.status == "missing_in_reference"]
        assert {f.nutrient for f in missing} == {"carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_g"}
        assert not result.proposals

    def test_genuine_zero(self):
        extract_record = _extract_record(
            5, [(2000, "269", "Sugars", "g", 0.0), (1008, "208", "Energy", "kcal", 5.0)]
        )
        result = audit_catalog(
            [_catalog_row(5, _full_macros(calories=5.0, sugar=0.0))], {"records": [extract_record]}
        )
        sugar = next(f for f in result.records[0].findings if f.nutrient == "sugar_g")
        assert sugar.status == "genuine_zero"

    def test_identity_drift_flagged(self):
        extract_record = _extract_record(6, [(1008, "208", "Energy", "kcal", 100.0)],
                                         description="Something Else Entirely")
        result = audit_catalog(
            [_catalog_row(6, _full_macros())], {"records": [extract_record]}
        )
        record = result.records[0]
        assert record.verdict == "identity_drift"
        assert "identity_description_drift" in record.flags

    def test_missing_reference(self):
        result = audit_catalog(
            [_catalog_row(7, _full_macros())], {"records": []}
        )
        assert result.records[0].verdict == "missing_reference"
        assert result.missing_reference_ids == [7]

    def test_data_type_mismatch_flagged(self):
        extract_record = _extract_record(8, [(1008, "208", "Energy", "kcal", 100.0)],
                                         data_type="Foundation")
        result = audit_catalog(
            [_catalog_row(8, _full_macros(), data_type="SR Legacy")],
            {"records": [extract_record]},
        )
        assert "data_type_mismatch" in result.records[0].flags

    def test_negative_reference_carbs_correctable(self):
        extract_record = _extract_record(
            9, [(1005, "205", "Carbohydrates", "g", -0.18), (1008, "208", "Energy", "kcal", 100.0)]
        )
        result = audit_catalog(
            [_catalog_row(9, _full_macros(carbs=0.0))], {"records": [extract_record]}
        )
        carbs = next(f for f in result.records[0].findings if f.nutrient == "carbs_g")
        assert carbs.status == "discrepancy_correctable"
        proposal = result.proposals[0]
        assert proposal["field"] == "carbs_g"
        assert proposal["new_value"] == -0.18

    def test_estimate_stats_diagnostic_only(self):
        extract_record = _extract_record(
            10, [(1008, "208", "Energy", "kcal", 200.0)]
        )
        result = audit_catalog(
            [_catalog_row(10, _full_macros(calories=200.0))], {"records": [extract_record]}
        )
        # estimate from 10P/10C/5F = 125 kcal, USDA says 200
        assert result.estimate_stats["n_compared"] == 1
        assert result.estimate_stats["max_abs_estimate_vs_usda_kcal"] == 75.0
