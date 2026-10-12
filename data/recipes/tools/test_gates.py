"""Planted-failure tests for the corpus release gates.

Each test plants a recipe that the validator at 4b6e163 accepted and asserts
the gate now refuses it, plus a passing twin so a gate that refuses everything
also fails. The last class runs the gates over the committed corpus files.

    python3 -I -m unittest discover -s data/recipes/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import corpus_io  # noqa: E402
import food_safety  # noqa: E402
import rights_evidence  # noqa: E402
import validate_corpus  # noqa: E402

ORIGINAL_RECORD = {
    "source_id": "fl-original-9001",
    "source_type": "original",
    "origin": "FridgeLuck original expression authored for FridgeLuck (task fl-original-recipes-f1)",
    "license": "LicenseRef-FL-Original",
    "access_date": "2026-10-11",
    "license_evidence": ("data/recipes/originals/rights_manifest.json record fl-original-9001 "
                         "(branch overhaul/original-recipes at 607ef99); ingested after "
                         "re-verification"),
    "permissions": {"text": True, "images": False, "modification": True,
                    "attribution": True, "caching": True, "offline_use": True},
}


def recipe(rid: str = "fl-original-9001", title: str = "Planted Lentil Soup",
           ingredients: list | None = None, steps: list | None = None,
           claims: list | None = None) -> dict:
    return {
        "rs_version": "1", "id": rid, "title": title, "cuisine": "american",
        "meal_slots": ["dinner"], "minutes": 30, "servings": 2,
        "ingredients": ingredients or [{"name": "red lentils",
                                        "qty": {"kind": "unknown"}}],
        "steps": steps or [{"text": "Simmer the lentils in water until soft."}],
        "source_ref": rid,
        "claims": claims or [],
    }


class RightsGate(unittest.TestCase):
    """Finding 3: rights need affirmative evidence, not missing attribution."""

    # The seed record shape at 4b6e163 (fl-seed-0001), on a planted id.
    SEED_RECORD = {
        "source_id": "frideluck_original",
        "source_type": "original",
        "origin": ("FridgeLuck seed (bundled recipe id 1; in-house authorship traced "
                   "through git history to initial commit 69f0286)"),
        "license": "LicenseRef-FL-Original",
        "access_date": "2026-10-11",
        "license_evidence": ("data/recipes/RIGHTS-AUDIT.md keep verdict for bundled recipe "
                             "id 1: no Source line; in repo since 69f0286 (2026-02-08, "
                             "initial commit); title not in the BBC scrape cache"),
        "permissions": dict(ORIGINAL_RECORD["permissions"]),
    }

    def test_absence_only_seed_record_is_refused(self):
        r = recipe("fl-seed-9001")
        problems = rights_evidence.rights_violations(r, self.SEED_RECORD)
        self.assertTrue(any("missing attribution" in p for p in problems), problems)
        self.assertTrue(any("authoring task's record" in p for p in problems), problems)

    def test_validator_refuses_the_planted_seed(self):
        r = recipe("fl-seed-9001")
        errors = validate_corpus.release_gate_errors(
            [r], {"fl-seed-9001": self.SEED_RECORD}, {"recipes": []})
        self.assertTrue(errors)

    def test_original_with_its_authoring_record_passes(self):
        self.assertEqual(rights_evidence.rights_violations(recipe(), ORIGINAL_RECORD), [])

    def test_authoring_record_for_another_recipe_is_refused(self):
        r = recipe("fl-original-9002")
        problems = rights_evidence.rights_violations(r, ORIGINAL_RECORD)
        self.assertTrue(any("not fl-original-9002" in p for p in problems), problems)

    def test_unknown_source_type_is_refused(self):
        rec = dict(ORIGINAL_RECORD, source_type="community")
        problems = rights_evidence.rights_violations(recipe(), rec)
        self.assertTrue(any("no affirmative-evidence form" in p for p in problems), problems)

    def test_open_licence_needs_licence_and_page_urls(self):
        rec = dict(ORIGINAL_RECORD, source_type="government", license="OGL-3.0",
                   license_evidence="OGL v3.0 per SOURCES.md")
        self.assertTrue(rights_evidence.rights_violations(recipe(), rec))
        rec["license_evidence"] = ("OGL v3.0 at https://www.nhs.uk/our-policies/terms-and-"
                                   "conditions/; page https://www.nhs.uk/healthier-families/x/")
        self.assertEqual(rights_evidence.rights_violations(recipe(), rec), [])

    def test_original_that_copies_bundled_wording_is_refused(self):
        source = ("Heat the oven to 200C and toss the bread with two tablespoons of the "
                  "olive oil and season well before baking")
        ref = rights_evidence.reference_ngrams([source])
        copied = recipe(steps=[{"text": "First, " + source.lower() + "."}])
        self.assertIsNotNone(rights_evidence.overlap_violation(copied, ref))
        fresh = recipe(steps=[{"text": "Crisp torn bread in a hot oven with oil and salt."}])
        self.assertIsNone(rights_evidence.overlap_violation(fresh, ref))

    def test_quarantined_recipe_left_in_the_corpus_is_refused(self):
        r = recipe("fl-seed-9001")
        entry = {"id": "fl-seed-9001", "stage": "rights", "reason": "planted",
                 "recipe": r}
        errors = validate_corpus.quarantine_errors([r], {}, [entry])
        self.assertTrue(any("still in corpus.jsonl" in e for e in errors), errors)
        errors = validate_corpus.quarantine_errors([], {}, [dict(entry, reason="")])
        self.assertTrue(any("needs a stage and a reason" in e for e in errors), errors)


def ing(*names: str) -> list:
    return [{"name": n, "qty": {"kind": "unknown"}} for n in names]


def chk(cls: str, temp: int) -> dict:
    return {"class": cls, "temp_f": temp, "method": "thermometer",
            "source": food_safety.FSIS_SOURCE}


def endpoint_errors(r: dict) -> list[str]:
    return food_safety.endpoint_violations(r)


class IngredientClasses(unittest.TestCase):
    """One correct class per name, from the FSIS chart rows."""

    def test_classes(self):
        cases = {
            "ground turkey": "meat_poultry",       # Ground Poultry 165 F
            "ground chicken": "meat_poultry",
            "chicken mince": "meat_poultry",
            "boneless chicken thighs": "meat_poultry",
            "ground beef": "meat_ground",          # Ground Meats 160 F
            "ground pork": "meat_ground",
            "good sausages": "meat_ground",
            "pork chops": "meat_whole_cut_pork",   # whole cuts 145 F + rest
            "bacon, chopped": "meat_whole_cut_pork",
            "beef chuck roast": "meat_whole_cut_red",
            "lamb shanks": "meat_whole_cut_red",
            "cod fillets": "flesh_fish",
            "raw prawns, peeled": "flesh_shellfish",
            "eggs": "egg",
            "cooked chicken breast, shredded": "leftovers",
            "roast turkey, sliced": "leftovers",
            "chicken stock": None,
            "fish sauce": None,
            "canned tuna, drained": None,
            "burger buns": None,
            "egg noodles": None,
            "eggplant": None,
        }
        for name, want in cases.items():
            self.assertEqual(food_safety.ingredient_class(name), want, name)

    def test_casserole_titles(self):
        for title in ("Hash-Brown Breakfast Casserole", "Tuna Pasta Gratin",
                      "Chicken and Vegetable Pasta Bake", "Beef Lasagne"):
            self.assertTrue(food_safety.is_mixed_dish(title), title)
        for title in ("Quick Sausage Traybake", "Stuffed Peppers", "Baked Beans"):
            self.assertFalse(food_safety.is_mixed_dish(title), title)


class DonenessEndpoints(unittest.TestCase):
    """Finding 1: FSIS endpoints, strictest applicable, reheating at 165 F."""

    def test_casserole_at_egg_temperature_is_refused(self):
        # fl-original-0008 at 4b6e163: egg 160 F on a breakfast casserole
        bad = recipe(title="Breakfast Casserole", ingredients=ing("eggs", "potatoes"), steps=[
            {"text": "Bake until a thermometer in the centre reads 160 °F.",
             "safety": chk("egg", 160)}])
        self.assertTrue(any("casserole" in e or "title" in e for e in endpoint_errors(bad)))
        good = copy.deepcopy(bad)
        good["steps"][0] = {"text": "Bake until a thermometer in the centre reads 165 °F.",
                            "safety": chk("leftovers", 165)}
        self.assertEqual(endpoint_errors(good), [])

    def test_whole_cut_without_rest_is_refused(self):
        # fl-original-0094 at 4b6e163: pork at 145 F, no rest
        bad = recipe(ingredients=ing("boneless pork chops"), steps=[
            {"text": "Braise until the pork reads 145 °F with a thermometer.",
             "safety": chk("meat_whole_cut_pork", 145)},
            {"text": "Shred and serve."}])
        self.assertTrue(any("rest" in e for e in endpoint_errors(bad)))
        good = copy.deepcopy(bad)
        good["steps"][0]["text"] += " Rest it 3 minutes."
        self.assertEqual(endpoint_errors(good), [])

    def test_gratin_with_fish_endpoint_is_refused(self):
        # fl-original-0102 at 4b6e163: tuna gratin checked at the fish 145 F
        bad = recipe(title="Tuna Pasta Gratin", ingredients=ing("canned tuna", "pasta"),
                     steps=[{"text": "Fold the tuna into the pasta."},
                            {"text": "Bake until the edges bubble.",
                             "safety": chk("flesh_fish", 145)}])
        self.assertTrue(endpoint_errors(bad))

    def test_ground_poultry_at_ground_meat_temperature_is_refused(self):
        bad = recipe(ingredients=ing("ground turkey"), steps=[
            {"text": "Brown the turkey until a thermometer reads 160 °F.",
             "safety": chk("meat_ground", 160)}])
        self.assertTrue(any("meat_poultry" in e for e in endpoint_errors(bad)))

    def test_raw_egg_mixed_into_fish_lifts_the_endpoint(self):
        # fl-original-0343 at 4b6e163: raw egg folded into cod cakes, 145 F
        bad = recipe(ingredients=ing("cod fillets", "eggs"), steps=[
            {"text": "Mix the flaked cod with the egg and shape cakes."},
            {"text": "Fry the cakes until a thermometer reads 145 °F.",
             "safety": chk("flesh_fish", 145)}])
        errors = endpoint_errors(bad)
        self.assertTrue(any("strictest applicable is 160" in e for e in errors), errors)

    def test_fish_cooked_before_the_egg_is_added_keeps_its_endpoint(self):
        ok = recipe(ingredients=ing("cod fillets", "eggs"), steps=[
            {"text": "Poach the cod until a thermometer reads 145 °F.",
             "safety": chk("flesh_fish", 145)},
            {"text": "Mix the flaked cod with the egg and shape cakes."},
            {"text": "Fry the cakes until a thermometer reads 160 °F.",
             "safety": chk("egg", 160)}])
        self.assertEqual(endpoint_errors(ok), [])

    def test_reheat_needs_its_own_leftovers_check(self):
        bad = recipe(ingredients=ing("eggs"), steps=[
            {"text": "Reheat the rice, then scramble the eggs to 160 °F on a thermometer.",
             "safety": chk("egg", 160)}])
        errors = endpoint_errors(bad)
        self.assertTrue(any("reheats food" in e for e in errors), errors)
        self.assertTrue(any("not flagged reheat" in e for e in errors), errors)

    def test_carryover_below_the_minimum_is_refused(self):
        # fl-original-0023 at 4b6e163: steak pulled at 140 F
        bad = recipe(ingredients=ing("flank steak"), steps=[
            {"text": "Take the steak off at 140 °F on a thermometer; it climbs to 145 °F "
                     "as it rests 5 minutes.", "safety": chk("meat_whole_cut_red", 145)}])
        self.assertTrue(any("below the step's" in e for e in endpoint_errors(bad)))

    def test_validator_refuses_a_planted_casserole(self):
        bad = recipe(title="Breakfast Casserole", ingredients=ing("eggs"), steps=[
            {"text": "Bake until a thermometer reads 160 °F.", "safety": chk("egg", 160)}])
        errors = validate_corpus.release_gate_errors(
            [bad], {bad["id"]: ORIGINAL_RECORD}, {"recipes": []})
        self.assertTrue(any("casserole" in e or "title" in e for e in errors), errors)


class CommittedCorpus(unittest.TestCase):
    """The committed corpus passes every gate."""

    @classmethod
    def setUpClass(cls):
        cls.recipes = [l.obj for l in corpus_io.read_jsonl(corpus_io.CORPUS)]
        cls.records = corpus_io.read_manifest()["records"]
        cls.quarantine = [l.obj for l in corpus_io.read_jsonl(corpus_io.QUARANTINE)]
        cls.bundled = json.loads(validate_corpus.BUNDLED.read_text(encoding="utf-8"))

    def test_release_gates(self):
        errors = validate_corpus.release_gate_errors(
            copy.deepcopy(self.recipes), self.records, self.bundled)
        self.assertEqual(errors, [], "\n".join(errors[:20]))

    def test_quarantine_file(self):
        errors = validate_corpus.quarantine_errors(self.recipes, self.records, self.quarantine)
        self.assertEqual(errors, [], "\n".join(errors[:20]))


if __name__ == "__main__":
    unittest.main()
