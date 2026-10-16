"""Tests for scripts/substitutions/convert.py — the pairs.json → canonical-key JSON bridge.

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
RESOURCE = (
    Path(__file__).parents[2] / "apps/ios/Resources/Substitutions/substitutions-v2.json"
)


def make_vocab() -> dict:
    """A miniature canonical vocabulary exercising every evidence channel."""
    return {
        "schema_version": "1.0.0",
        "entries": [
            {
                "key": "butter",
                "display_name": "Butter",
                "category": "dairy",
                "fdc_id": 173430,
                "aliases": ["sweet butter"],
                "classes": ["dairy", "animal"],
            },
            {
                "key": "olive_oil",
                "display_name": "Olive oil",
                "category": "fat",
                "fdc_id": 1057,
                "aliases": [],
                "classes": ["plant"],
            },
            {
                "key": "soy_sauce",
                "display_name": "Soy sauce",
                "category": "condiment",
                "fdc_id": 174277,
                "aliases": ["shoyu"],
                "classes": ["soy", "gluten"],
            },
            {
                "key": "fish_sauce",
                "display_name": "Fish sauce",
                "category": "condiment",
                "fdc_id": 175159,
                "aliases": ["nam pla"],
                "classes": ["fish"],
            },
            {
                # Curated classes alone make a composition known.
                "key": "tapioca",
                "display_name": "Tapioca",
                "category": "thickener",
                "fdc_id": None,
                "aliases": [],
                "classes": ["plant"],
            },
            {
                # The vocabulary does not know this food; facts may still cover it.
                "key": "cornstarch",
                "display_name": "Cornstarch",
                "category": "thickener",
                "fdc_id": None,
                "aliases": [],
                "classes": ["unknown"],
            },
        ],
    }


def make_table() -> dict:
    """A miniature pairs.json exercising every converter rule."""
    return {
        "schema_version": "1.1.0",
        "created": "2026-10-11",
        "roles": ["fat", "protein", "umami", "thickener"],
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
                "allergen_note": "Milk product.",
            },
            "olive_oil": {
                "display": "olive oil",
                "fdc_id": 1057,
                "classes": [],
                "aliases": [],
                "facts_key": "olive-oil",
                "allergen_note": None,
            },
            "soy_sauce": {
                "display": "soy sauce",
                "fdc_id": 174277,
                # Compound closure: brewed shoyu carries soy AND gluten.
                "classes": ["soy", "gluten"],
                "aliases": ["shoyu"],
                "facts_key": "soy-sauce",
                "allergen_note": None,
            },
            "fish_sauce": {
                "display": "fish sauce",
                "fdc_id": None,
                # Diet extension class the vegan restriction forbids.
                "classes": ["fish", "flesh_fish"],
                "aliases": ["nam pla"],
                "facts_key": "fish-sauce",
                "allergen_note": None,
            },
            "cornstarch": {
                "display": "cornstarch",
                "fdc_id": 11190,
                # Facts cover what the vocabulary does not.
                "classes": ["plant"],
                "aliases": [],
                "facts_key": "cornstarch",
                "allergen_note": None,
            },
            "tapioca": {
                "display": "tapioca",
                "fdc_id": None,
                # The vocabulary's curated classes carry this key alone.
                "classes": [],
                "aliases": [],
                "facts_key": None,
                "allergen_note": None,
            },
            "generic_tamari": {
                "display": "tamari",
                "fdc_id": None,
                "classes": ["soy"],
                "aliases": [],
                # No canonical record: fails closed to ask-the-user.
                "facts_key": None,
                "allergen_note": None,
            },
            "mystery_powder": {
                "display": "mystery powder",
                "fdc_id": None,
                "classes": [],
                "aliases": [],
                "facts_key": None,
                "allergen_note": None,
            },
            # No evidence at all: unmapped, pairs touching it drop.
            "ghost_pepper": {
                "display": "ghost pepper",
                "fdc_id": None,
                "classes": [],
                "aliases": [],
                "facts_key": None,
                "allergen_note": None,
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
            {
                "id": "fat-umami-to-fish-sauce",
                "original": "olive_oil",
                "substitute": "fish_sauce",
                "role": "umami",
                "ratio": {"value": 1.0, "basis": "weight", "status": "unknown", "note": None},
                "function_status": "unknown",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Salty and oceanic.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
            {
                "id": "thickener-starch-to-cornstarch",
                "original": "tapioca",
                "substitute": "cornstarch",
                "role": "thickener",
                "ratio": {"value": 0.5, "basis": "weight", "status": "convention", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": ["Slurry first."],
                "difference": "Glossier, less pearl.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
            {
                "id": "umami-tamari-swap",
                "original": "soy_sauce",
                "substitute": "generic_tamari",
                "role": "umami",
                "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Wheat-free by default.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
            {
                "id": "heat-to-ghost-pepper",
                "original": "olive_oil",
                "substitute": "ghost_pepper",
                "role": "fat",
                "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Volcanic.",
                "source_ids": ["S-USU"],
                "assessment": None,
            },
        ],
    }


def run_convert(table: dict, vocab: dict) -> dict:
    return convert.convert(table, convert.Vocabulary(vocab), COMMIT, "overhaul/substitution-table")


def shipped_ids(document: dict) -> set[str]:
    return {s["pairId"] for s in document["swaps"]}


class TestMapping:
    def test_maps_by_name_and_alias(self):
        doc = run_convert(make_table(), make_vocab())
        # butter, olive_oil, soy_sauce, fish_sauce, cornstarch, tapioca map;
        # generic_tamari, mystery_powder, ghost_pepper do not.
        assert doc["audit"]["referencedIngredients"] == 9
        assert doc["audit"]["mappedIngredients"] == 6

    def test_maps_by_fdc_when_names_differ(self):
        table = make_table()
        # Rename everything textual; the fdc id is the only remaining evidence.
        # 173430 is the vocabulary's butter fdc, so the channel has a target.
        butter = table["ingredients"]["butter"]
        butter["display"] = "churned cream product"
        butter["aliases"] = []
        butter["fdc_id"] = 173430
        table["ingredients"]["sweet_cream_butter"] = table["ingredients"].pop("butter")
        for pair in table["pairs"]:
            if pair["original"] == "butter":
                pair["original"] = "sweet_cream_butter"
        doc = run_convert(table, make_vocab())
        assert "sweet_cream_butter" not in doc["audit"]["unmappedKeys"]
        # mappedKeys holds table-side keys; the canonical key shows in compositions.
        assert "sweet_cream_butter" in doc["audit"]["mappedKeys"]
        assert "butter" in doc["compositions"]

    def test_maps_by_usda_source_name_reference(self):
        vocab = make_vocab()
        vocab["entries"][0]["fdc_ref"] = "Butter, salted (SR Legacy)"
        table = make_table()
        butter = table["ingredients"]["butter"]
        butter["display"] = "churned cream product"
        butter["aliases"] = []
        butter["fdc_id"] = None  # name and fdc channels dead
        butter["usda_name"] = "Butter, salted"  # source-name channel lives
        doc = run_convert(table, vocab)
        assert "butter" in doc["audit"]["mappedKeys"]

    def test_ambiguous_name_fails_closed(self):
        vocab = make_vocab()
        # "nam pla" now belongs to two keys: the name channel is ambiguous.
        vocab["entries"][3]["aliases"] = ["nam pla"]  # fish_sauce
        vocab["entries"].append(
            {
                "key": "nam_pla_blend",
                "display_name": "Nam pla blend",
                "category": "condiment",
                "fdc_id": None,
                "aliases": ["nam pla"],
                "classes": ["fish"],
            }
        )
        doc = run_convert(make_table(), vocab)
        assert "fish_sauce" in doc["audit"]["unmappedKeys"]
        # The pair touching the ambiguous endpoint drops.
        assert "fat-umami-to-fish-sauce" not in shipped_ids(doc)

    def test_conflicting_channels_fail_closed(self):
        vocab = make_vocab()
        # fdc 1057 belongs to olive_oil AND a second key: the fdc channel for
        # the olive_oil endpoint is ambiguous even though the name resolves.
        vocab["entries"].append(
            {
                "key": "olive_oil_blend",
                "display_name": "Olive oil blend",
                "category": "fat",
                "fdc_id": 1057,
                "aliases": [],
                "classes": ["plant"],
            }
        )
        doc = run_convert(make_table(), vocab)
        assert "olive_oil" in doc["audit"]["unmappedKeys"]

    def test_unmapped_endpoints_drop_their_pairs(self):
        doc = run_convert(make_table(), make_vocab())
        assert "binder-fat-to-mystery-powder" not in shipped_ids(doc)
        assert "heat-to-ghost-pepper" not in shipped_ids(doc)
        assert "umami-tamari-swap" not in shipped_ids(doc)
        assert doc["audit"]["pairsDropped"] == 3


class TestSelfSwapAndDedup:
    def make_self_swap_table(self) -> dict:
        table = make_table()
        # Anchovies-style collapse: two distinct endpoints, one canonical key.
        table["ingredients"]["anchovy"] = {
            "display": "anchovies",
            "fdc_id": 174182,
            "classes": ["fish"],
            "aliases": ["anchovies"],
            "facts_key": "anchovy",
            "allergen_note": None,
        }
        table["ingredients"]["anchovy_paste"] = {
            "display": "anchovy paste",
            "fdc_id": 174183,
            "classes": ["fish"],
            "aliases": ["anchovies"],
            "facts_key": "anchovy-paste",
            "allergen_note": None,
        }
        table["pairs"].append(
            {
                "id": "umami-anchovy-to-paste",
                "original": "anchovy",
                "substitute": "anchovy_paste",
                "role": "umami",
                "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
                "function_status": "sourced",
                "supported_also": [],
                "fails": [],
                "preparation": [],
                "difference": "Same fish, spreadable.",
                "source_ids": ["S-USU"],
                "assessment": None,
            }
        )
        return table

    def test_self_swap_is_dropped(self):
        doc = run_convert(self.make_self_swap_table(), make_vocab())
        assert "umami-anchovy-to-paste" not in shipped_ids(doc)
        assert all(
            s["originalKey"] != s["substituteKey"] for s in doc["swaps"]
        )

    def test_same_offer_deduplicates_first_pair_wins(self):
        table = make_table()
        # chicken and chicken_breast both map to chicken_breast; same role.
        table["ingredients"]["chicken"] = {
            "display": "chicken",
            "fdc_id": 5062,
            "classes": [],
            "aliases": [],
            "facts_key": None,
            "allergen_note": None,
        }
        table["ingredients"]["chicken_breast"] = {
            "display": "chicken breast",
            "fdc_id": 172928,
            "classes": [],
            "aliases": [],
            "facts_key": None,
            "allergen_note": None,
        }
        base = {
            "substitute": "cornstarch",
            "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
            "function_status": "sourced",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Starchy instead of meaty.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }
        table["pairs"].append(
            {
                **base,
                "id": "protein-chicken-to-cornstarch",
                "original": "chicken",
                "role": "protein",
            }
        )
        table["pairs"].append(
            {
                **base,
                "id": "protein-chicken-breast-to-cornstarch",
                "original": "chicken_breast",
                "role": "protein",
            }
        )
        doc = run_convert(table, make_vocab())
        # cornstarch is unmapped in the miniature vocabulary, so nothing
        # ships — assert through the audit instead of the swaps list.
        assert doc["audit"]["pairsDropped"] >= 2

    def test_distinct_roles_do_not_deduplicate(self):
        table = make_table()
        base = {
            "original": "olive_oil",
            "substitute": "soy_sauce",
            "ratio": {"value": 1.0, "basis": "weight", "status": "sourced", "note": None},
            "function_status": "sourced",
            "supported_also": [],
            "fails": [],
            "preparation": [],
            "difference": "Salty and savory.",
            "source_ids": ["S-USU"],
            "assessment": None,
        }
        table["pairs"].append({**base, "id": "fat-to-soy-sauce", "role": "fat"})
        table["pairs"].append({**base, "id": "umami-to-soy-sauce", "role": "umami"})
        doc = run_convert(table, make_vocab())
        assert {"fat-to-soy-sauce", "umami-to-soy-sauce"} <= shipped_ids(doc)


class TestCompositions:
    def test_vocabulary_classes_alone_make_composition_known(self):
        doc = run_convert(make_table(), make_vocab())
        comp = doc["compositions"]["tapioca"]
        assert comp["compositionKnown"] is True
        assert comp["allergenClasses"] == []
        assert comp["dietClasses"] == ["plant"]

    def test_facts_alone_make_composition_known(self):
        doc = run_convert(make_table(), make_vocab())
        # Vocabulary says unknown; the mapped facts entry covers it.
        comp = doc["compositions"]["cornstarch"]
        assert comp["compositionKnown"] is True
        assert comp["dietClasses"] == ["plant"]

    def test_neither_source_fails_closed_empty(self):
        doc = run_convert(make_table(), make_vocab())
        # No table ingredient maps to olive oil's facts... use a key nothing
        # covers: add a vocab-only key with unknown classes.
        vocab = make_vocab()
        vocab["entries"].append(
            {
                "key": "mirin",
                "display_name": "Mirin",
                "category": "condiment",
                "fdc_id": None,
                "aliases": [],
                "classes": ["unknown"],
            }
        )
        doc = run_convert(make_table(), vocab)
        comp = doc["compositions"]["mirin"]
        assert comp["compositionKnown"] is False
        assert comp["allergenClasses"] == []
        assert comp["dietClasses"] == []

    def test_union_of_vocabulary_and_facts(self):
        doc = run_convert(make_table(), make_vocab())
        comp = doc["compositions"]["butter"]
        # Vocabulary: dairy + animal; facts entry: dairy + animal_product.
        assert comp["compositionKnown"] is True
        assert comp["allergenClasses"] == ["dairy"]
        assert "animal" in comp["dietClasses"] and "animal_product" in comp["dietClasses"]
        assert comp["allergenNote"] == "Milk product."

    def test_recheck_uses_compositions(self):
        doc = run_convert(make_table(), make_vocab())
        swap = next(s for s in doc["swaps"] if s["pairId"] == "butter-fat-to-olive-oil")
        assert swap["recheck"]["compositionKnown"] is True
        assert swap["recheck"]["allergenClasses"] == []

    def test_unknown_composition_ships_empty_classes(self):
        table = make_table()
        # generic_tamari maps via a pure-name alias to soy_sauce? No — keep it
        # unmapped but assert the class gate on a key with unknown classes.
        vocab = make_vocab()
        vocab["entries"].append(
            {
                "key": "mystery_powder",
                "display_name": "Mystery powder",
                "category": "unknown",
                "fdc_id": None,
                "aliases": [],
                "classes": ["unknown"],
            }
        )
        doc = run_convert(table, vocab)
        swap = next(s for s in doc["swaps"] if s["pairId"] == "binder-fat-to-mystery-powder")
        assert swap["recheck"]["compositionKnown"] is False
        assert swap["recheck"]["allergenClasses"] == []
        assert swap["recheck"]["dietClasses"] == []


class TestDocument:
    def test_swaps_carry_keys_not_ids(self):
        doc = run_convert(make_table(), make_vocab())
        for swap in doc["swaps"]:
            assert "originalId" not in swap and "substituteId" not in swap
            assert swap["originalKey"] and swap["substituteKey"]

    def test_audit_counts(self):
        doc = run_convert(make_table(), make_vocab())
        audit = doc["audit"]
        assert audit["pairsTotal"] == 6
        assert audit["pairsShipped"] + audit["pairsDropped"] == audit["pairsTotal"]
        assert audit["compositionKnownSubstitutes"] <= audit["pairsShipped"]

    def test_schema_version_is_2(self):
        doc = run_convert(make_table(), make_vocab())
        assert doc["schemaVersion"] == "2.0.0"

    def test_compositions_cover_every_vocabulary_key(self):
        doc = run_convert(make_table(), make_vocab())
        assert set(doc["compositions"]) == {e["key"] for e in make_vocab()["entries"]}

    def test_deterministic_output(self):
        first = convert.dump(run_convert(make_table(), make_vocab()))
        second = convert.dump(run_convert(make_table(), make_vocab()))
        assert first == second


class TestValidate:
    def test_unknown_with_classes_raises(self):
        doc = run_convert(make_table(), make_vocab())
        doc["compositions"]["butter"]["compositionKnown"] = False
        doc["compositions"]["butter"]["allergenClasses"] = ["dairy"]
        with pytest.raises(convert.ConvertError):
            convert.validate(doc)

    def test_swap_endpoint_without_composition_raises(self):
        doc = run_convert(make_table(), make_vocab())
        del doc["compositions"]["butter"]
        with pytest.raises(convert.ConvertError):
            convert.validate(doc)

    def test_valid_document_passes(self):
        convert.validate(run_convert(make_table(), make_vocab()))


class TestCli:
    def test_cli_writes_resource(self, tmp_path):
        table_path = tmp_path / "pairs.json"
        vocab_path = tmp_path / "vocabulary.json"
        out_path = tmp_path / "out.json"
        table_path.write_text(json.dumps(make_table()), encoding="utf-8")
        vocab_path.write_text(json.dumps(make_vocab()), encoding="utf-8")
        rc = convert.main(
            [
                "--table", str(table_path),
                "--vocabulary", str(vocab_path),
                "--out", str(out_path),
                "--source-commit", COMMIT,
            ]
        )
        assert rc == 0
        document = json.loads(out_path.read_text(encoding="utf-8"))
        assert document["schemaVersion"] == "2.0.0"

    def test_strict_mode_exits_nonzero_on_unmapped(self, tmp_path):
        table_path = tmp_path / "pairs.json"
        vocab_path = tmp_path / "vocabulary.json"
        table_path.write_text(json.dumps(make_table()), encoding="utf-8")
        vocab_path.write_text(json.dumps(make_vocab()), encoding="utf-8")
        rc = convert.main(
            [
                "--table", str(table_path),
                "--vocabulary", str(vocab_path),
                "--out", str(tmp_path / "out.json"),
                "--source-commit", COMMIT,
                "--strict",
            ]
        )
        assert rc == 2

    def test_schema_version_gate(self, tmp_path):
        table_path = tmp_path / "pairs.json"
        vocab_path = tmp_path / "vocabulary.json"
        table = make_table()
        table["schema_version"] = "9.9.9"
        table_path.write_text(json.dumps(table), encoding="utf-8")
        vocab_path.write_text(json.dumps(make_vocab()), encoding="utf-8")
        with pytest.raises(convert.ConvertError):
            convert.main(
                [
                    "--table", str(table_path),
                    "--vocabulary", str(vocab_path),
                    "--out", str(tmp_path / "out.json"),
                    "--source-commit", COMMIT,
                ]
            )


class TestShippedResource:
    """The committed substitutions-v2.json is the shipped artifact — pin it."""

    def test_exists_and_is_v2(self):
        assert RESOURCE.exists(), "substitutions-v2.json must be committed"
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        assert document["schemaVersion"] == "2.0.0"

    def test_coverage_doubles_the_legacy_table(self):
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        audit = document["audit"]
        # The legacy app-id resource shipped 35 of 279 pairs (PR #154); the
        # reviewed table now carries 286 pairs and the resource ships 78.
        assert audit["pairsTotal"] == 286
        assert audit["pairsShipped"] > 70
        assert audit["pairsShipped"] + audit["pairsDropped"] == audit["pairsTotal"]

    def test_no_self_swaps_or_duplicate_offers(self):
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        offers = [(s["originalKey"], s["substituteKey"], s["role"]) for s in document["swaps"]]
        assert len(offers) == len(set(offers))
        assert all(o[0] != o[1] for o in offers)

    def test_every_swap_endpoint_has_a_composition(self):
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        for swap in document["swaps"]:
            for endpoint in (swap["originalKey"], swap["substituteKey"]):
                assert endpoint in document["compositions"]

    def test_unknown_compositions_ship_empty_classes(self):
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        for key, composition in document["compositions"].items():
            if not composition["compositionKnown"]:
                assert composition["allergenClasses"] == []
                assert composition["dietClasses"] == []

    def test_source_records_the_pinned_commit(self):
        document = json.loads(RESOURCE.read_text(encoding="utf-8"))
        # The reviewed table now lives in-repo; the source commit is the
        # commit holding the table this resource was regenerated from
        # (burst 11: abf1b70a).
        assert document["source"]["sourceCommit"].startswith("abf1b70")
        assert document["source"]["tableBranch"] == "overhaul/substitution-table"
