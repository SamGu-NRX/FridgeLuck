"""Tests for scripts/substitutions/convert.py — the pairs.json → app JSON bridge.

Run with: python3 -m pytest scripts/substitutions/ -q
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

import convert  # noqa: E402

COMMIT = "4b5895409cb1c990a5e8251f490fe80ccd35c295"


def make_table() -> dict:
    """A miniature pairs.json exercising every converter rule."""
    return {
        "schema_version": "1.1.0",
        "created": "2026-10-11",
        "roles": ["fat", "protein", "umami"],
        "allergen_classes": ["gluten", "dairy", "soy", "fish"],
        "restrictions": {
            "gluten-free": {"forbids": ["gluten"]},
            "vegan": {"forbids": ["fish", "flesh_fish", "dairy", "egg"]},
        },
        "ingredients": {
            "butter": {
                "display": "butter",
                "fdc_id": 717,
                "classes": ["dairy", "animal_product"],
                "aliases": ["sweet butter"],
                "facts_key": "butter",
            },
            "olive_oil": {
                "display": "olive oil",
                "fdc_id": 884,
                "classes": [],
                "aliases": [],
                "facts_key": "olive-oil",
            },
            "soy_sauce": {
                "display": "soy sauce",
                "fdc_id": 174277,
                # Compound closure: brewed shoyu carries soy AND gluten.
                "classes": ["soy", "gluten"],
                "aliases": ["shoyu"],
                "facts_key": "soy-sauce",
            },
            "fish_sauce": {
                "display": "fish sauce",
                "fdc_id": None,
                # Diet extension class the vegan restriction forbids.
                "classes": ["fish", "flesh_fish"],
                "aliases": [],
                "facts_key": "fish-sauce",
            },
            "generic_tamari": {
                "display": "tamari",
                "fdc_id": None,
                "classes": ["soy"],
                "aliases": [],
                # No canonical record: fails closed to ask-the-user.
                "facts_key": None,
            },
            "mystery_powder": {
                "display": "mystery powder",
                "fdc_id": None,
                "classes": [],
                "aliases": [],
                "facts_key": None,
            },
        },
        "pairs": [
            {
                "id": "butter-fat-to-olive-oil",
                "original": "butter",
                "substitute": "olive_oil",
                "role": "fat",
                "ratio": {"value": 0.75, "basis": "weight", "status": "sourced", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Fruity and lighter; browns differently.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
            {
                "id": "binder-fat-to-mystery-powder",
                "original": "butter",
                "substitute": "mystery_powder",
                "role": "fat",
                "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Completely different.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
        ],
    }


def make_app_data() -> dict:
    return {
        "ingredients": {
            "1": ["butter", 717, 717.0, 0.9, 0.1, 0.0, 0.1, 0.643, "1 tbsp (14g)", "keep cold"],
            "16": ["olive oil", 884, 884.0, 0.0, 0.0, 100.0, 0.0, 0.002, "1 tbsp (14g)", "pantry"],
            "3": ["soy sauce", 53, 53.0, 8.1, 4.9, 0.6, 0.0, 5.493, "1 tbsp (16g)", "pantry"],
            "21": ["tamari", 155928, 60.0, 10.5, 5.6, 0.8, 0.0, 5.586, "1 tbsp (16g)", "pantry"],
            "22": ["fish sauce", 175159, 42.0, 5.3, 3.4, 0.0, 0.6, 4.32, "1 tbsp (16g)", "pantry"],
        }
    }


def run_convert(table: dict, app_data: dict) -> dict:
    return convert.convert(table, app_data, COMMIT, "overhaul/substitution-table")


def shipped_ids(document: dict) -> set[str]:
    return {s["pairId"] for s in document["swaps"]}


class TestMapping:
    def test_maps_by_name(self):
        doc = run_convert(make_table(), make_app_data())
        # butter, olive_oil, mystery_powder are the referenced ingredients;
        # only mystery_powder fails to map.
        assert doc["audit"]["referencedIngredients"] == 3
        assert doc["audit"]["mappedIngredients"] == 2

    def test_maps_by_fdc_when_names_differ(self):
        table = make_table()
        # Rename everything textual; the fdc id is the only remaining evidence.
        butter = table["ingredients"]["butter"]
        butter["display"] = "churned cream product"
        butter["aliases"] = []
        table["ingredients"]["sweet_cream_butter"] = table["ingredients"].pop("butter")
        for pair in table["pairs"]:
            if pair["original"] == "butter":
                pair["original"] = "sweet_cream_butter"
        doc = run_convert(table, make_app_data())
        assert "butter-fat-to-olive-oil" in shipped_ids(doc)
        swap = next(s for s in doc["swaps"] if s["pairId"] == "butter-fat-to-olive-oil")
        assert swap["originalId"] == 1

    def test_ambiguous_fdc_fails_closed(self):
        table = make_table()
        butter = table["ingredients"]["butter"]
        butter["display"] = "churned cream product"
        butter["aliases"] = []
        table["ingredients"]["sweet_cream_butter"] = table["ingredients"].pop("butter")
        for pair in table["pairs"]:
            if pair["original"] == "butter":
                pair["original"] = "sweet_cream_butter"
        app = make_app_data()
        # Two catalog entries claim the same fdc id: no unique evidence left.
        # (App 99's display deliberately matches nothing in the table, so the
        # only remaining evidence is the ambiguous fdc id.)
        app["ingredients"]["99"] = ["cream product two", 717, 1.0, 0, 0, 0, 0, 0, "x", "x"]
        doc = run_convert(table, app)
        assert shipped_ids(doc) == set()
        assert "sweet_cream_butter" in doc["audit"]["unmappedKeys"]

    def test_no_fuzzy_matching(self):
        table = make_table()
        butter = table["ingredients"]["butter"]
        butter["display"] = "butter, unsalted salted"
        butter["aliases"] = []
        butter["fdc_id"] = None
        table["ingredients"]["unsalted_butter"] = table["ingredients"].pop("butter")
        for pair in table["pairs"]:
            if pair["original"] == "butter":
                pair["original"] = "unsalted_butter"
        doc = run_convert(table, make_app_data())
        assert "unsalted_butter" in doc["audit"]["unmappedKeys"]
        assert shipped_ids(doc) == set()

    def test_unmapped_ingredient_drops_only_its_pairs(self):
        doc = run_convert(make_table(), make_app_data())
        # mystery_powder is unmapped: its pair is dropped, butter→olive-oil ships.
        assert shipped_ids(doc) == {"butter-fat-to-olive-oil"}
        assert doc["audit"]["pairsDropped"] == 1
        assert doc["audit"]["unmappedKeys"] == ["mystery_powder"]
        assert doc["audit"]["pairsShipped"] == 1

    def test_strict_mode_exits_nonzero_on_unmapped(self, tmp_path):
        table_path = tmp_path / "pairs.json"
        app_path = tmp_path / "data.json"
        out_path = tmp_path / "out.json"
        table_path.write_text(json.dumps(make_table()))
        app_path.write_text(json.dumps(make_app_data()))
        code = convert.main(
            [
                "--table", str(table_path),
                "--app-data", str(app_path),
                "--out", str(out_path),
                "--source-commit", COMMIT,
                "--strict",
            ]
        )
        assert code == 2
        assert not out_path.exists()


class TestVerdicts:
    def base_pair(self, **overrides):
        pair = {
            "id": "butter-fat-to-olive-oil",
            "original": "butter",
            "substitute": "olive_oil",
            "role": "fat",
            "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
            "function_status": "sourced",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Lighter.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }
        pair.update(overrides)
        return pair

    def convert_single(self, pair: dict) -> dict:
        table = make_table()
        table["pairs"] = [pair]
        return run_convert(table, make_app_data())

    def fit(self, doc: dict) -> dict:
        return doc["swaps"][0]["fits"][0]

    def test_sourced_function_and_ratio_is_verified(self):
        doc = self.convert_single(self.base_pair())
        assert self.fit(doc)["verdict"] == "verified"

    def test_convention_ratio_is_plausible(self):
        pair = self.base_pair()
        pair["ratio"]["status"] = "convention"
        doc = self.convert_single(pair)
        assert self.fit(doc)["verdict"] == "plausible"

    def test_unknown_stays_unknown(self):
        doc = self.convert_single(self.base_pair(function_status="unknown"))
        assert self.fit(doc)["verdict"] == "unknown"

    def test_conflict_ratio_is_plausible_never_verified(self):
        pair = self.base_pair(ratio={"value": 0.6, "basis": "weight", "status": "conflict", "note": None})
        doc = self.convert_single(pair)
        assert self.fit(doc)["verdict"] == "plausible"

    def test_unsupported_ratio_is_unsupported(self):
        pair = self.base_pair(ratio={"value": 1.0, "basis": "weight", "status": "unsupported", "note": None})
        doc = self.convert_single(pair)
        assert self.fit(doc)["verdict"] == "unsupported"

    def test_functional_fail_on_only_role_drops_the_pair(self):
        pair = self.base_pair(fails=[{"role": "fat", "kind": "functional", "why": "cannot cream"}])
        doc = self.convert_single(pair)
        assert shipped_ids(doc) == set()

    def test_functional_fail_excludes_the_role_but_other_roles_ship(self):
        pair = self.base_pair(
            fails=[{"role": "fat", "kind": "functional", "why": "cannot cream"}],
            supported_also=[{"role": "umami", "status": "convention"}],
        )
        doc = self.convert_single(pair)
        swap = doc["swaps"][0]
        assert [f["role"] for f in swap["fits"]] == ["umami"]
        assert swap["excludedRoles"] == [{"role": "fat", "kind": "functional", "why": "cannot cream"}]

    def test_conditional_fail_keeps_verdict_and_scopes_restrictions(self):
        pair = self.base_pair(
            fails=[{"role": "fat", "kind": "conditional", "restrictions": ["gluten-free"], "why": "x"}]
        )
        doc = self.convert_single(pair)
        assert self.fit(doc)["verdict"] == "verified"
        assert self.fit(doc)["conditionalFor"] == ["gluten-free"]

    def test_supported_also_never_inherits_primary_ratio(self):
        pair = self.base_pair(supported_also=[{"role": "umami", "status": "convention"}])
        doc = self.convert_single(pair)
        fits = {f["role"]: f for f in doc["swaps"][0]["fits"]}
        assert fits["fat"]["ratio"]["value"] == 1.0
        assert fits["umami"]["ratio"] is None  # no recorded ratio: scaling refused
        assert fits["umami"]["verdict"] == "unknown"  # missing ratio row stays unknown


class TestRecheckPayload:
    def compound_pair(self) -> dict:
        """A pair whose SUBSTITUTE is soy sauce: the recheck screens the
        substitute's compound closure (brewed shoyu carries soy AND gluten)."""
        return {
            "id": "umami-tamari-to-soy-sauce",
            "original": "generic_tamari",
            "substitute": "soy_sauce",
            "role": "umami",
            "ratio": {"value": 1.0, "basis": "weight", "status": "convention", "note": None},
            "function_status": "convention",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Wheatier edge; check the label for gluten.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }

    def fish_pair(self) -> dict:
        """A pair whose SUBSTITUTE is fish sauce: vegan-screening diet classes."""
        return {
            "id": "umami-tamari-to-fish-sauce",
            "original": "generic_tamari",
            "substitute": "fish_sauce",
            "role": "umami",
            "ratio": {"value": 1.0, "basis": "weight", "status": "convention", "note": None},
            "function_status": "convention",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Funkier, sharper salt.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }

    def unknown_facts_pair(self) -> dict:
        """A pair whose SUBSTITUTE has a null facts_key (generic tamari)."""
        return {
            "id": "umami-soy-sauce-to-tamari",
            "original": "soy_sauce",
            "substitute": "generic_tamari",
            "role": "umami",
            "ratio": {"value": 1.0, "basis": "weight", "status": "convention", "note": None},
            "function_status": "convention",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Less wheaty edge; check the label.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }

    def test_unknown_composition_fails_closed_on_a_mapped_ingredient(self):
        table = make_table()
        table["pairs"] = [self.unknown_facts_pair()]
        doc = run_convert(table, make_app_data())
        recheck = doc["swaps"][0]["recheck"]
        # tamari maps to app id 21 but has no canonical record (facts_key null):
        # compositionKnown is false even though the ingredient itself mapped.
        assert doc["swaps"][0]["substituteId"] == 21
        assert recheck["compositionKnown"] is False

    def test_compound_closure_ships_full_classes(self):
        table = make_table()
        table["pairs"] = [self.compound_pair()]
        doc = run_convert(table, make_app_data())
        recheck = doc["swaps"][0]["recheck"]
        # Brewed shoyu carries soy AND gluten — the compound closure.
        assert recheck["allergenClasses"] == ["soy", "gluten"]

    def test_fish_sauce_carries_diet_classes(self):
        table = make_table()
        table["pairs"] = [self.fish_pair()]
        doc = run_convert(table, make_app_data())
        recheck = doc["swaps"][0]["recheck"]
        assert recheck["dietClasses"] == ["flesh_fish"]
        assert recheck["allergenClasses"] == ["fish"]


class TestGuards:
    def test_difference_promising_no_change_is_rejected(self):
        table = make_table()
        table["pairs"][0]["difference"] = "There is no change in flavour."
        with pytest.raises(convert.ConvertError):
            run_convert(table, make_app_data())

    def test_pair_without_sources_is_rejected(self):
        table = make_table()
        table["pairs"][0]["source_ids"] = []
        with pytest.raises(convert.ConvertError):
            run_convert(table, make_app_data())

    def test_source_commit_is_recorded(self):
        doc = run_convert(make_table(), make_app_data())
        assert doc["source"]["sourceCommit"] == COMMIT
        assert doc["source"]["table"] == "data/substitutions/pairs.json"

    def test_output_is_deterministic(self):
        first = convert.dump(run_convert(make_table(), make_app_data()))
        second = convert.dump(run_convert(make_table(), make_app_data()))
        assert first == second

    def test_schema_version_gate(self, tmp_path):
        table_path = tmp_path / "pairs.json"
        app_path = tmp_path / "data.json"
        table = make_table()
        table["schema_version"] = "1.0.0"
        table_path.write_text(json.dumps(table))
        app_path.write_text(json.dumps(make_app_data()))
        with pytest.raises(convert.ConvertError):
            convert.main(
                [
                    "--table", str(table_path),
                    "--app-data", str(app_path),
                    "--out", str(tmp_path / "out.json"),
                    "--source-commit", COMMIT,
                ]
            )

    def test_restrictions_ship_their_forbids(self):
        doc = run_convert(make_table(), make_app_data())
        assert doc["restrictions"]["vegan"]["forbids"] == ["dairy", "egg", "fish", "flesh_fish"]
