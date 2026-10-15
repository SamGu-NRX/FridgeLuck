#!/usr/bin/env python3
"""Tests for check_everyday.py: one planted failure per rule, plus controls.

Run:  python3 tools/test_check_everyday.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_everyday", HERE / "check_everyday.py")
ce = importlib.util.module_from_spec(spec)
sys.modules["check_everyday"] = ce
spec.loader.exec_module(ce)

ALLERGENS = {
    "ingredient_aliases": {
        "eggs": "egg_k", "chicken thighs": "chk_k", "tofu": "tofu_k",
        "cheddar": "ched_k", "honey": "honey_k", "ground beef": "gb_k",
    },
    "ingredients": {
        "egg_k": {"classes": ["egg", "animal_product"]},
        "chk_k": {"classes": ["meat_poultry", "animal_product"]},
        "tofu_k": {"classes": ["legume"]},
        "ched_k": {"classes": ["dairy", "animal_product"]},
        "honey_k": {"classes": ["honey"]},
        "gb_k": {"classes": ["meat_ground", "animal_product"]},
    },
}

FS = {"class": "meat_poultry", "temp_f": 165, "method": "thermometer",
      "source": "USDA FSIS Safe Minimum Internal Temperature Chart (fsis.usda.gov)"}


def step(text, timer=None, safety=None, reheat=False):
    s = {"text": text}
    if timer is not None:
        s["timer_min"] = timer
    if safety is not None:
        s["safety"] = safety
    if reheat:
        s["reheat"] = True
    return s


def line_h(name, ref, value, unit, grams):
    return {"name": name, "qty": {"kind": "household", "conversion_ref": ref,
                                  "value": value, "unit": unit, "grams": grams}}


def line_g(name, grams):
    return {"name": name, "qty": {"kind": "source_grams", "grams": grams}}


def recipe(rid="fl-everyday-0001", title="Test Dish", cuisine="american",
           slots=("dinner",), minutes=15, servings=2, ingredients=None,
           steps=None, category="20-minute-dinners"):
    return {
        "rs_version": "1", "id": rid, "title": title, "cuisine": cuisine,
        "meal_slots": list(slots), "minutes": minutes, "servings": servings,
        "ingredients": ingredients if ingredients is not None else [
            line_g("tofu", 200), line_h("eggs", "egg_piece", 2, "piece", 100)],
        "steps": steps if steps is not None else [
            step("Whisk the eggs and fry the tofu, until a thermometer reads 160 F.",
                 5, {"class": "egg", "temp_f": 160, "method": "thermometer",
                     "source": "USDA FSIS Safe Minimum Internal Temperature Chart (fsis.usda.gov)"})],
        "source_ref": rid, "category": category,
    }


CONVERSIONS = {"egg_piece": {"ingredient": "large egg", "grams_per_unit": 50}}


class TestResolution(unittest.TestCase):
    def test_unknown_name_fails(self):
        errs = ce.resolution_misses([recipe()], {"tofu"})
        self.assertTrue(any("eggs" in e for e in errs))

    def test_known_name_passes(self):
        universe = {"tofu", "egg"}  # singular of eggs resolves
        self.assertEqual(ce.resolution_misses([recipe()], universe), [])

    def test_missing_catalog_fails_closed(self):
        # main() records an error when --catalog is absent; here we assert
        # that an empty universe flags every ingredient (fail closed).
        errs = ce.resolution_misses([recipe()], set())
        self.assertEqual(len(errs), 2)


class TestQuantities(unittest.TestCase):
    def test_grams_agree(self):
        self.assertEqual(ce.quantity_errors([recipe()], CONVERSIONS), [])

    def test_grams_wrong_is_planted(self):
        r = recipe(ingredients=[line_h("eggs", "egg_piece", 2, "piece", 77)])
        errs = ce.quantity_errors([r], CONVERSIONS)
        self.assertTrue(any("disagree" in e for e in errs))

    def test_unknown_ref_is_planted(self):
        r = recipe(ingredients=[line_h("eggs", "egg_dozen", 1, "dozen", 600)])
        errs = ce.quantity_errors([r], CONVERSIONS)
        self.assertTrue(any("does not carry" in e for e in errs))


class TestCategories(unittest.TestCase):
    def test_coherent_recipe_passes(self):
        errs = ce.category_errors([recipe()], ALLERGENS)
        self.assertEqual([e for e in errs if not e.startswith("balance:")], [])

    def test_wrong_category_is_planted(self):
        r = recipe(category="soups")
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("not one of the eight" in e for e in errs))

    def test_20min_bar_is_planted(self):
        r = recipe(minutes=35)
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("20-minute-dinners" in e for e in errs))

    def test_meat_in_veg_category_is_planted(self):
        r = recipe(category="vegetarian-vegan-mains", slots=("dinner",),
                   ingredients=[line_g("chicken thighs", 300)], )
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("non-vegetarian" in e for e in errs))

    def test_batch_without_reheat_is_planted(self):
        r = recipe(category="batch-leftovers")
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("reheat" in e for e in errs))

    def test_vegetarian_fraction_bar(self):
        meat = recipe(rid="fl-everyday-0002", category="high-protein",
                      ingredients=[line_g("ground beef", 400)])
        errs = ce.category_errors([recipe(), meat], ALLERGENS)
        self.assertTrue(any("vegetarian" in e for e in errs))

    def test_missing_band_is_planted(self):
        r = recipe(minutes=25)  # only 16-30
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("time band" in e for e in errs))

    def test_keyword_fallback_catches_unknown_meat(self):
        r = recipe(rid="fl-everyday-0003", category="vegetarian-vegan-mains",
                   slots=("dinner",), ingredients=[line_g("canned tuna", 150)])
        errs = ce.category_errors([r], ALLERGENS)
        self.assertTrue(any("non-vegetarian" in e for e in errs))


def sha_of_file(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


class TestRights(unittest.TestCase):
    def evidence_for(self, r, tmp: Path) -> dict:
        return {"everyday-originals": {
            "recipes_sha256": sha_of_file(tmp / "orig.jsonl"), "recipes_file": str(tmp / "orig.jsonl"),
            "records": {r["id"]: {
                "license": "LicenseRef-FL-Original",
                "source_type": "original",
                "permissions": {"text": True, "modification": True,
                                "caching": True, "offline_use": True},
                "title": r["title"],
                "ingredients_sha256": ce.ingredients_sha256(r),
            }}}}

    def test_complete_record_passes(self):
        r = recipe()
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            (tmp / "orig.jsonl").write_text(json.dumps(r))
            manifest = {"records": {r["source_ref"]: {
                "source_id": r["id"], "source_type": "original",
                "origin": "test", "license": "LicenseRef-FL-Original",
                "access_date": "2026-10-15",
                "permissions": {"text": True, "images": False, "modification": True,
                                "attribution": True, "caching": True, "offline_use": True}}}}
            errs = ce.rights_errors([r], manifest, self.evidence_for(r, tmp))
        self.assertEqual(errs, [])

    def test_incomplete_permissions_is_planted(self):
        r = recipe()
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            (tmp / "orig.jsonl").write_text(json.dumps(r))
            manifest = {"records": {r["source_ref"]: {
                "source_id": r["id"], "source_type": "original",
                "origin": "test", "license": "LicenseRef-FL-Original",
                "access_date": "2026-10-15",
                "permissions": {"text": True, "modification": True}}}}
            errs = ce.rights_errors([r], manifest, self.evidence_for(r, tmp))
        self.assertTrue(any("permission" in e for e in errs))

    def test_title_drift_is_planted(self):
        r = recipe()
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            (tmp / "orig.jsonl").write_text(json.dumps(r))
            manifest = {"records": {r["source_ref"]: {
                "source_id": r["id"], "source_type": "original",
                "origin": "test", "license": "LicenseRef-FL-Original",
                "access_date": "2026-10-15",
                "permissions": {"text": True, "images": False, "modification": True,
                                "attribution": True, "caching": True, "offline_use": True}}}}
            ev = self.evidence_for(r, tmp)
            ev["everyday-originals"]["records"][r["id"]]["title"] = "Other Dish"
            errs = ce.rights_errors([r], manifest, ev)
        self.assertTrue(any("different title" in e for e in errs))


class TestDedupe(unittest.TestCase):
    def test_near_duplicate_is_planted(self):
        a = recipe()
        b = recipe(rid="fl-everyday-0002", ingredients=[
            line_g("tofu", 200), line_h("eggs", "egg_piece", 2, "piece", 100)])
        errs = ce.dedupe_errors([a, b], [], None, None, None)
        self.assertTrue(any("duplicate" in e for e in errs))

    def test_distinct_recipes_pass(self):
        a = recipe()
        b = recipe(rid="fl-everyday-0002", title="Other Bowl",
                   ingredients=[line_g("tofu", 200)])
        self.assertEqual(ce.dedupe_errors([a, b], [], None, None, None), [])

    def test_shared_nine_word_run_with_legacy_is_planted(self):
        legacy = {"recipes": {"old dish": {"instructions": "1. Stir the beans and rice together in a pot and cook them\n"}}}
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "legacy.json"
            p.write_text(json.dumps(legacy))
            r = recipe(steps=[step("Stir the beans and rice together in a pot and cook them well.")])
            errs = ce.dedupe_errors([], [r], None, p, None)
        self.assertTrue(any("9-word" in e for e in errs))

    def test_legacy_title_reuse_is_planted(self):
        legacy = {"recipes": {"Test Dish": {"instructions": "1. Cook it\n"}}}
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "legacy.json"
            p.write_text(json.dumps(legacy))
            errs = ce.dedupe_errors([], [recipe()], None, p, None)
        self.assertTrue(any("fresh expression" in e for e in errs))


class TestStepIntegrity(unittest.TestCase):
    def test_missing_food_is_planted(self):
        r = recipe(steps=[step("Melt the butter, then fry the tofu.")])
        errs = ce.step_food_errors([r])
        self.assertTrue(any("butter" in e for e in errs))

    def test_present_food_passes(self):
        r = recipe(ingredients=[line_g("tofu", 200), line_h("eggs", "egg_piece", 2, "piece", 100),
                                line_g("butter", 14)],
                   steps=[step("Melt the butter, then fry the tofu and the eggs.")])
        self.assertEqual(ce.step_food_errors([r]), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
