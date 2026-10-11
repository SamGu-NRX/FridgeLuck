"""Validation tests for the pinned FNDDS household-measure reference tables.

The committed tables under reference/household_measures/ are the evidence base
for household-measure-to-gram conversion. These tests bind them to the USDA
source edition they were extracted from and to known portion weights.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

from usda_core.households import (
    classify_preparation_state,
    derive_yield_pairs,
    normalize_description_stem,
    parse_portion_description,
    scan_packing_terms,
)

HOUSEHOLD_DIR = (
    Path(__file__).resolve().parents[1] / "reference" / "household_measures"
)
MANIFEST = HOUSEHOLD_DIR / "MANIFEST.json"
PORTIONS_CSV = HOUSEHOLD_DIR / "fndds_portions.csv"
UNITS_CSV = HOUSEHOLD_DIR / "fndds_household_units.csv"
CONVERSION_JSON = HOUSEHOLD_DIR / "mass_conversion_table.json"
CHECKS_JSON = HOUSEHOLD_DIR / "conversion_checks.json"
YIELD_JSON = HOUSEHOLD_DIR / "yield_sensitivity.json"
PACKING_JSON = HOUSEHOLD_DIR / "packing_scan.json"

requires_tables = pytest.mark.skipif(
    not MANIFEST.exists(),
    reason="household-measure tables not yet generated",
)

# Ground-truth spot checks: (food description, portion description, unit,
# magnitude, USDA gram weight). Values come from the FNDDS 2024-10-31 survey
# foods themselves; they encode well-known USDA portion weights (e.g. 1 tbsp
# oil = 14 g, 1 egg = 50 g, 1 cup whole milk = 244 g).
SPOT_CHECKS = [
    ("Olive oil", "1 tablespoon", "tbsp", 1.0, 14),
    ("Milk, whole", "1 cup", "cup", 1.0, 244),
    ("Egg, whole, raw", "1 egg", "egg", 1.0, 50),
    ("Cheese, Cheddar", "1 stick", "stick", 1.0, 28.35),
    ("Butter, NFS", "1 pat", "pat", 1.0, 7),
]


@requires_tables
class TestManifest:
    def test_manifest_binds_source_edition(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        assert manifest["source"]["edition"] == "2024-10-31"
        assert manifest["source"]["dataset"].startswith("USDA FoodData Central")
        assert manifest["source"]["survey_json_sha256"]

    def test_manifest_coverage_matches_source(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        coverage = manifest["coverage"]
        assert coverage["survey_foods"] >= 5000
        assert coverage["positive_portion_rows"] >= 20000
        assert coverage["parsed_household_rows"] >= 8000
        # At least a third of positive-weight portions must resolve to a
        # canonical household unit for the table to be worth pinning.
        assert (
            coverage["parsed_household_rows"]
            >= coverage["positive_portion_rows"] // 3
        )

    def test_manifest_declares_every_unit_family(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        inventory = manifest["unit_inventory"]
        for unit in ("cup", "tbsp", "tsp", "floz", "oz", "slice", "piece"):
            assert inventory.get(unit, 0) >= 8, f"unit {unit} underrepresented"


@requires_tables
class TestPortionsTable:
    def test_rows_have_positive_weights_and_ids(self) -> None:
        with PORTIONS_CSV.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        assert len(rows) >= 20000
        for row in rows[:200] + rows[-200:]:
            assert row["fdc_id"]
            assert float(row["gram_weight"]) > 0
            assert row["food_description"]

    def test_no_negative_or_zero_weights(self) -> None:
        with PORTIONS_CSV.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                assert float(row["gram_weight"]) > 0


@requires_tables
class TestHouseholdUnitsTable:
    def test_units_are_canonical(self) -> None:
        canonical = {
            "cup", "tbsp", "tsp", "floz", "oz", "lb", "quart", "pint",
            "gallon", "liter", "stick", "slice", "piece", "strip", "pat",
            "clove", "ear", "small", "medium", "large", "regular", "egg",
            "can", "package", "envelope",
        }
        with UNITS_CSV.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        assert len(rows) >= 8000
        for row in rows:
            assert row["unit"] in canonical
            assert float(row["magnitude"]) > 0
            assert float(row["grams_per_unit"]) > 0
            assert row["fdc_id"]

    def test_grams_per_unit_matches_gram_weight(self) -> None:
        with UNITS_CSV.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        for row in rows[:500] + rows[-500:]:
            magnitude = float(row["magnitude"])
            expected = float(row["gram_weight"]) / magnitude
            assert abs(float(row["grams_per_unit"]) - expected) < 5e-4

    @pytest.mark.parametrize(
        ("food", "portion", "unit", "magnitude", "grams"), SPOT_CHECKS
    )
    def test_usda_spot_checks(
        self, food: str, portion: str, unit: str, magnitude: float, grams: float
    ) -> None:
        matches = [
            row
            for row in _read_units_csv()
            if food in row["food_description"]
            and row["portion_description"] == portion
        ]
        assert matches, f"no row for {food} / {portion}"
        row = matches[0]
        assert row["unit"] == unit
        assert float(row["magnitude"]) == magnitude
        assert abs(float(row["gram_weight"]) - grams) < 1e-6


@requires_tables
class TestConversionTable:
    def test_resource_shape_and_dedup(self) -> None:
        table = json.loads(CONVERSION_JSON.read_text(encoding="utf-8"))
        assert table["source"]["edition"] == "2024-10-31"
        seen = set()
        for portion in table["portions"]:
            key = (portion["fdcId"], portion["unit"], portion["magnitude"])
            assert key not in seen
            seen.add(key)
            assert portion["grams"] > 0
            assert portion["food"]
        assert len(table["portions"]) >= 7000

    def test_every_entry_carries_wweia_category(self) -> None:
        table = json.loads(CONVERSION_JSON.read_text(encoding="utf-8"))
        assert all(
            portion.get("category") for portion in table["portions"]
        ), "every conversion entry must name its WWEIA category"
        categories = {portion["category"] for portion in table["portions"]}
        assert len(categories) >= 100  # WWEIA food-group inventory


class TestDescriptionStem:
    """Unit tests for normalize_description_stem (yield-pair matching)."""

    def test_strips_state_words(self) -> None:
        assert normalize_description_stem("Chard, raw") == ("chard",)
        assert normalize_description_stem("Chard, cooked") == ("chard",)
        assert normalize_description_stem("Apple, baked") == ("apple",)
        assert normalize_description_stem("Oats, cooked, boiled") == ("oats",)

    def test_keeps_non_state_words(self) -> None:
        # Packing words are not state words and survive stemming.
        assert normalize_description_stem("Sweet potatoes, canned") == (
            "sweet",
            "potatoes",
            "canned",
        )
        assert normalize_description_stem("Milk, whole") == ("milk", "whole")

    def test_empty_text(self) -> None:
        assert normalize_description_stem("") == ()


class TestDeriveYieldPairs:
    """Synthetic-corpus tests for the raw/cooked yield-pair derivation."""

    NUTRIENTS = {"kcal": 50.0, "proteinG": 1.0, "fatG": 0.2, "carbG": 12.0}

    @staticmethod
    def _food(fid: int, description: str, category: str) -> dict:
        return {
            "fdcId": fid,
            "description": description,
            "wweiaFoodCategory": {"wweiaFoodCategoryDescription": category},
        }

    def _run(self, foods, units, nutrients):
        return derive_yield_pairs(foods, units, nutrients)

    def test_pairs_same_stem_same_category_shared_unit(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, cooked", "Greens"),
        ]
        units = {1: {"cup": 36.0}, 2: {"cup": 150.0}}
        nutrients = {1: self.NUTRIENTS, 2: self.NUTRIENTS}
        pairs, missing = self._run(foods, units, nutrients)
        assert len(pairs) == 1 and not missing
        pair = pairs[0]
        assert pair["rawFdcId"] == 1 and pair["cookedFdcId"] == 2
        assert pair["unit"] == "cup"
        assert pair["rawGramsPerUnit"] == 36.0
        assert pair["cookedGramsPerUnit"] == 150.0
        assert pair["ratio"] == pytest.approx(150.0 / 36.0)

    def test_cross_category_candidates_are_not_pairs(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, cooked", "Other"),
        ]
        units = {1: {"cup": 36.0}, 2: {"cup": 150.0}}
        nutrients = {1: self.NUTRIENTS, 2: self.NUTRIENTS}
        pairs, missing = self._run(foods, units, nutrients)
        assert not pairs and not missing

    def test_no_shared_unit_counts_missing(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, cooked", "Greens"),
        ]
        units = {1: {"cup": 36.0}, 2: {"tbsp": 8.0}}
        nutrients = {1: self.NUTRIENTS, 2: self.NUTRIENTS}
        pairs, missing = self._run(foods, units, nutrients)
        assert not pairs
        assert len(missing) == 1
        assert missing[0]["reason"] == "no shared unit with differing grams"

    def test_identical_grams_per_unit_counts_missing(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, cooked", "Greens"),
        ]
        units = {1: {"cup": 36.0}, 2: {"cup": 36.0}}
        nutrients = {1: self.NUTRIENTS, 2: self.NUTRIENTS}
        pairs, missing = self._run(foods, units, nutrients)
        assert not pairs
        assert len(missing) == 1
        assert missing[0]["reason"] == "no shared unit with differing grams"

    def test_missing_nutrients_counts_missing_never_fills(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, cooked", "Greens"),
        ]
        units = {1: {"cup": 36.0}, 2: {"cup": 150.0}}
        broken = dict(self.NUTRIENTS)
        del broken["carbG"]
        pairs, missing = self._run(foods, units, {1: self.NUTRIENTS, 2: broken})
        assert not pairs
        assert len(missing) == 1
        assert missing[0]["reason"] == "missing nutrients"
        assert "carbG" not in missing[0]

    def test_same_state_never_pairs(self) -> None:
        foods = [
            self._food(1, "Chard, raw", "Greens"),
            self._food(2, "Chard, raw (washed)", "Greens"),
        ]
        units = {1: {"cup": 36.0}, 2: {"cup": 40.0}}
        nutrients = {1: self.NUTRIENTS, 2: self.NUTRIENTS}
        pairs, missing = self._run(foods, units, nutrients)
        assert not pairs and not missing


class TestPackingScanHelper:
    """Synthetic-corpus tests for the packing-term scan."""

    def test_counts_terms_and_qualifier_hits(self) -> None:
        foods = [
            {
                "fdcId": 1,
                "description": "Cheese spread",
                "wweiaFoodCategory": {"wweiaFoodCategoryDescription": "Cheese"},
                "foodPortions": [
                    {"portionDescription": "1 can (4.75 oz)", "modifier": ""},
                    {"portionDescription": "1 cup, canned", "modifier": ""},
                ],
            },
            {
                "fdcId": 2,
                "description": "Lemonade",
                "wweiaFoodCategory": {"wweiaFoodCategoryDescription": "Fruit drink"},
                "foodPortions": [
                    {"portionDescription": "1 bottle", "modifier": ""},
                ],
            },
        ]
        scan = scan_packing_terms(foods)
        assert scan["portionsScanned"] == 3
        assert scan["termCounts"]["can"] == 1
        assert scan["termCounts"]["canned"] == 1
        assert scan["termCounts"]["bottle"] == 1
        # "1 can ..." parses as a unit word; "1 cup, canned" parses as a cup.
        assert scan["parsedTermCounts"].get("can", 0) == 1
        assert scan["parsedTermCounts"].get("canned", 0) == 1
        assert len(scan["qualifierPackingHits"]) == 1
        hit = scan["qualifierPackingHits"][0]
        assert hit["fdcId"] == 1
        assert hit["classification"] == "canned"
        assert hit["unit"] == "cup"
        assert hit["magnitude"] == 1.0

    def test_boundary_words_do_not_leak(self) -> None:
        foods = [
            {
                "fdcId": 1,
                "description": "Scrambled eggs",
                "wweiaFoodCategory": {"wweiaFoodCategoryDescription": "Eggs"},
                "foodPortions": [
                    {"portionDescription": "1 cup", "modifier": "scrambled"},
                ],
            }
        ]
        scan = scan_packing_terms(foods)
        assert scan["termCounts"] == {}
        assert scan["qualifierPackingHits"] == []


@requires_tables
class TestConversionChecksReport:
    """Binds the committed conversion_checks.json to the
    leave-one-category-out protocol invariants."""

    def test_protocol_and_arm_structure(self) -> None:
        checks = json.loads(CHECKS_JSON.read_text(encoding="utf-8"))
        held = checks["heldout"]
        assert "leave-one" in held["protocol"].lower()
        arms = held["arms"]
        assert arms == sorted(arms, key=lambda arm: arm["category"])
        assert held["categoryCount"] == len(arms)
        aggregate = held["aggregate"]
        assert sum(arm["n"] for arm in arms) == aggregate["n"]
        assert sum(arm["matched"] for arm in arms) == aggregate["matched"]
        assert sum(arm["unknown"] for arm in arms) == aggregate["unknown"]
        assert sum(arm["exact"] for arm in arms) == aggregate["exact"]
        assert sum(arm["partial"] for arm in arms) == aggregate["partial"]
        assert aggregate["n"] >= 7000
        for arm in arms:
            assert arm["matched"] + arm["unknown"] == arm["n"]
            assert arm["exact"] + arm["partial"] == arm["matched"]
            assert arm["medianRelErrPct"] >= 0
            assert arm["meanRelErrPct"] >= 0
            assert arm["within25Pct"] <= arm["within50Pct"]

    def test_meals_check_is_labeled_plumbing(self) -> None:
        checks = json.loads(CHECKS_JSON.read_text(encoding="utf-8"))
        label = checks["meals"]["label"].lower()
        assert "plumbing" in label and "yield" in label


@requires_tables
class TestYieldSensitivityReport:
    """Binds the committed yield_sensitivity.json to its inputs."""

    def test_summary_matches_pairs(self) -> None:
        payload = json.loads(YIELD_JSON.read_text(encoding="utf-8"))
        pairs = payload["pairs"]
        summary = payload["summary"]
        assert summary["pairCount"] == len(pairs)
        assert summary["pairCount"] >= 20  # source-bound inputs exist
        assert summary["missingInputs"] == len(payload["missingInputs"])
        assert summary["categoriesCovered"] == len({p["category"] for p in pairs})
        for pair in pairs:
            expected = pair["cookedGramsPerUnit"] / pair["rawGramsPerUnit"]
            assert pair["ratio"] == pytest.approx(expected, abs=1e-6)
            for key in ("kcal", "proteinG", "fatG", "carbG"):
                delta = (
                    pair["per100gCooked"][key] * pair["cookedGramsPerUnit"] / 100
                    - pair["per100gRaw"][key] * pair["rawGramsPerUnit"] / 100
                )
                assert pair["perUnitDelta"][key] == pytest.approx(delta, abs=1e-3)

    def test_spot_pairs(self) -> None:
        payload = json.loads(YIELD_JSON.read_text(encoding="utf-8"))
        by_names = {(p["rawFood"], p["cookedFood"]): p for p in payload["pairs"]}
        chard = by_names[("Chard, raw", "Chard, cooked")]
        assert chard["unit"] == "cup"
        assert chard["rawGramsPerUnit"] == pytest.approx(36.0)
        assert chard["cookedGramsPerUnit"] == pytest.approx(150.0)
        apple = by_names[("Apple, raw", "Apple, baked")]
        assert apple["unit"] == "cup"
        assert apple["ratio"] == pytest.approx(190.0 / 125.0, abs=1e-6)


@requires_tables
class TestPackingScanReport:
    def test_table_carries_no_packing_and_says_unmeasured(self) -> None:
        payload = json.loads(PACKING_JSON.read_text(encoding="utf-8"))
        assert payload["conversionTableLabels"]["packing"] == 0
        assert payload["termCountsAllPortions"]  # raw counts exist
        assert "UNMEASURED" in payload["conclusion"]
        for hit in payload["qualifierPackingHits"]:
            assert hit["survivesIntoTable"] is False


class TestParser:
    @pytest.mark.parametrize(
        ("text", "unit", "magnitude"),
        [
            ("1 cup", "cup", 1.0),
            ("2 tbsp", "tbsp", 2.0),
            ("1/2 cup", "cup", 0.5),
            ("1-1/2 cups", "cup", 1.5),
            ("1 fl oz", "floz", 1.0),
            ("1 fl oz (no ice)", "floz", 1.0),
            ("1 oz yields", "oz", 1.0),
            ("1 cup, cooked, diced", "cup", 1.0),
            ("1 medium (2-1/2\" dia)", "medium", 1.0),
            ("1 egg", "egg", 1.0),
            ("1 slice", "slice", 1.0),
            ("1 stick", "stick", 1.0),
        ],
    )
    def test_parses(self, text: str, unit: str, magnitude: float) -> None:
        parsed = parse_portion_description(text)
        assert parsed is not None, text
        assert parsed.unit == unit
        assert abs(parsed.magnitude - magnitude) < 1e-9

    @pytest.mark.parametrize(
        "text",
        [
            "Quantity not specified",
            "Guideline amount per cup of hot cereal",
            "1 cubic inch",
            "1 large or thick slice",
            "1 miniature",
            "",
        ],
    )
    def test_rejects_non_modeled(self, text: str) -> None:
        assert parse_portion_description(text) is None

    def test_fl_oz_never_parses_as_weight_oz(self) -> None:
        parsed = parse_portion_description("1 fl oz")
        assert parsed is not None
        assert parsed.unit == "floz"


def _read_units_csv() -> list[dict]:
    with UNITS_CSV.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


class TestPreparationStateClassifier:
    """Unit tests for classify_preparation_state plus the state column's
    value domain in mass_conversion_table.json. State labels trace to the
    portion description/modifier (per-portion state), not the food name, so
    table-level tests assert the value domain only."""

    def test_cooked_keywords(self) -> None:
        assert classify_preparation_state("1 cup, cooked, diced") == "cooked"
        assert classify_preparation_state("roasted") == "cooked"
        assert classify_preparation_state("1 tbsp, reconstituted") == "cooked"

    def test_reconstituted_negation_means_dried(self) -> None:
        assert (
            classify_preparation_state("1 cup, not reconstituted") == "dried"
        )
        assert classify_preparation_state("1 cup, dry") == "dried"
        assert classify_preparation_state("dried") == "dried"

    def test_frozen_outprioritizes_cooking_words(self) -> None:
        assert (
            classify_preparation_state("prepared from frozen, heated")
            == "frozen"
        )
        assert classify_preparation_state("thawed, heated") == "thawed"

    def test_raw_and_unlabeled(self) -> None:
        assert classify_preparation_state("1 medium, raw") == "raw"
        assert classify_preparation_state("1 cup") is None
        assert classify_preparation_state("") is None

    def test_state_column_value_domain(self) -> None:
        table = json.loads(CONVERSION_JSON.read_text(encoding="utf-8"))
        labeled = [p for p in table["portions"] if p.get("state")]
        assert labeled, "expected some labeled entries"
        assert {p["state"] for p in labeled} <= {"cooked", "dried", "raw"}
