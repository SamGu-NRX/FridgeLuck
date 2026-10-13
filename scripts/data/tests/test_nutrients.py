"""Unit tests for the presence-aware nutrient selection policy."""

from __future__ import annotations

import math

from usda_core.nutrients import (
    NutrientObservation,
    collect_observations,
    estimate_energy_kcal,
    select_energy,
    select_macro,
)


def _obs(nutrient_id: int, amount: float | None, unit: str = "g", number: str = "") -> NutrientObservation:
    return NutrientObservation(
        nutrient_id=nutrient_id, nutrient_number=number, name="", unit=unit, amount=amount
    )


class TestCollectObservations:
    def test_abridged_shape(self):
        entries = [{"nutrientId": 1008, "nutrientNumber": "208", "unitName": "kcal", "amount": 31.0}]
        obs = collect_observations(entries)
        assert len(obs) == 1
        assert obs[0].nutrient_id == 1008
        assert obs[0].nutrient_number == "208"
        assert obs[0].unit == "kcal"
        assert obs[0].amount == 31.0

    def test_full_detail_shape_row_id_is_not_a_nutrient_id(self):
        # In full API detail the top-level "id" is a food_nutrient row id
        # (arbitrary); the nutrient id lives in the nested object.
        entries = [
            {
                "id": 987654,
                "nutrient": {"id": 1008, "number": "208", "name": "Energy", "unitName": "kcal"},
                "amount": 105.0,
            }
        ]
        obs = collect_observations(entries)
        assert obs[0].nutrient_id == 1008  # NOT 987654
        assert obs[0].unit == "kcal"

    def test_string_and_bool_amounts(self):
        obs = collect_observations(
            [
                {"nutrientId": 1003, "unitName": "g", "amount": "12.5"},
                {"nutrientId": 1004, "unitName": "g", "amount": True},
            ]
        )
        assert obs[0].amount == 12.5
        assert obs[1].amount is None

    def test_non_dict_entries_skipped(self):
        assert collect_observations([None, "x", 42, {"nutrientId": 1003, "amount": 1.0}])[-1].amount == 1.0


class TestEnergySelection:
    def test_prefers_1008_over_atwater(self):
        observations = [
            _obs(2047, 150.0, "kcal"),
            _obs(1008, 148.0, "kcal"),
        ]
        selection = select_energy(observations)
        assert selection.status == "ok"
        assert selection.nutrient_id == 1008
        assert selection.value == 148.0
        assert selection.converted_from is None

    def test_atwater_specific_used_when_1008_missing(self):
        # The Foundation Foods defect: energy published only under 2048.
        observations = [_obs(2048, 27.0, "kcal"), _obs(1003, 0.896, "g")]
        selection = select_energy(observations)
        assert selection.status == "ok"
        assert selection.nutrient_id == 2048
        assert selection.value == 27.0

    def test_atwater_general_fallback(self):
        observations = [_obs(2047, 150.0, "kcal")]
        selection = select_energy(observations)
        assert selection.status == "ok"
        assert selection.nutrient_id == 2047

    def test_kj_converted_with_factor(self):
        observations = [_obs(1062, 418.4, "kJ")]
        selection = select_energy(observations)
        assert selection.status == "ok"
        assert selection.converted_from == "kJ"
        assert selection.converted_factor is not None
        assert math.isclose(selection.value, 100.0, abs_tol=1e-6)

    def test_missing_energy(self):
        selection = select_energy([_obs(1003, 5.0, "g")])
        assert selection.status == "missing"
        assert selection.value is None

    def test_null_energy(self):
        selection = select_energy([_obs(1008, None, "kcal")])
        assert selection.status == "null_value"
        assert selection.value is None

    def test_unit_mismatch(self):
        selection = select_energy([_obs(1008, 5.0, "g")])
        assert selection.status == "unit_mismatch"

    def test_nonfinite_energy(self):
        selection = select_energy([_obs(1008, float("nan"), "kcal")])
        assert selection.status == "invalid_value"


class TestMacroSelection:
    def test_protein_modern_id(self):
        selection = select_macro("protein_g", [_obs(1003, 12.9, "g")])
        assert selection.status == "ok"
        assert selection.value == 12.9

    def test_protein_legacy_id(self):
        selection = select_macro("protein_g", [_obs(203, 12.9, "g")])
        assert selection.status == "ok"
        assert selection.value == 12.9

    def test_sodium_mg_to_grams(self):
        selection = select_macro("sodium_g", [_obs(1093, 350.0, "mg")])
        assert selection.status == "ok"
        assert selection.value == 0.35
        assert selection.converted_from == "mg"
        assert selection.converted_factor == 1.0 / 1000.0

    def test_sodium_wrong_unit_rejected(self):
        # FDC publishes 1093 in mg; anything else must not be silently used.
        selection = select_macro("sodium_g", [_obs(1093, 0.35, "oz")])
        assert selection.status == "unit_mismatch"

    def test_missing_macro(self):
        selection = select_macro("fiber_g", [_obs(1003, 1.0, "g")])
        assert selection.status == "missing"
        assert selection.value is None

    def test_negative_value_accepted_as_published(self):
        # Source-supported negatives (e.g. alcohol-adjusted carbohydrate
        # by difference) are data, not errors: the audit decides.
        selection = select_macro("carbs_g", [_obs(1005, -0.18, "g")])
        assert selection.status == "ok"
        assert selection.value == -0.18


class TestEstimate:
    def test_atwater_general(self):
        # 10 g protein + 20 g carbs + 5 g fat = 40 + 80 + 45 kcal
        assert estimate_energy_kcal(10.0, 20.0, 5.0) == 165.0
