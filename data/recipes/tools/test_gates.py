"""Planted-failure tests for the corpus release gates.

Each test plants a recipe that the validator at 4b6e163 accepted and asserts
the gate now refuses it, plus a passing twin so a gate that refuses everything
also fails. The last class runs the gates over the committed corpus files.

    python3 -I -m unittest discover -s data/recipes/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import composition  # noqa: E402
import corpus_io  # noqa: E402
import food_safety  # noqa: E402
import rights_evidence  # noqa: E402
import validate_corpus  # noqa: E402

# suite C allergens.json as validate_corpus reads it (eval/scorecard-runner
# at 26c7004; unchanged at 9e04af4). Set FL_SUITE_DIR to use an extracted copy.
SUITE_PIN = "26c7004e6068f70115dba27bc5b3fc94ce90f4d6"


def suite_allergens() -> dict:
    env = os.environ.get("FL_SUITE_DIR")
    if env:
        return json.loads((Path(env) / "allergens.json").read_text(encoding="utf-8"))
    out = subprocess.run(
        ["git", "-C", str(corpus_io.REPO_ROOT), "show",
         f"{SUITE_PIN}:evaluation/suites/recipes/allergens.json"],
        capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(f"suite C allergens.json at {SUITE_PIN} is not in this clone "
                           f"({out.stderr.strip()}); run `git fetch origin "
                           "eval/scorecard-runner` or set FL_SUITE_DIR")
    return json.loads(out.stdout)


# A slice of allergens.json, enough for the planted recipes.
MINI_ALLERGENS = {
    "ingredient_aliases": {"vegetable oil": "vegetable_oil", "red lentils": "lentils",
                           "butter": "butter", "vegetable stock": "veg_stock",
                           "parmesan": "parmesan", "rice": "white_rice", "soy sauce": "soy_sauce"},
    "ingredients": {"vegetable_oil": {"classes": []}, "lentils": {"classes": []},
                    "butter": {"classes": ["dairy", "animal_product"]},
                    "veg_stock": {"classes": []},
                    "parmesan": {"classes": ["dairy", "animal_product"]},
                    "white_rice": {"classes": []},
                    "soy_sauce": {"classes": ["soy", "gluten"]}},
    "claims": {"vegetarian": {"forbids": ["meat_poultry", "flesh_fish"]},
               "vegan": {"forbids": ["meat_poultry", "flesh_fish", "dairy", "egg", "honey"]},
               "gluten-free": {"forbids": ["gluten"]},
               "dairy-free": {"forbids": ["dairy"]},
               "nut-free": {"forbids": ["tree_nut", "peanut"]}},
}

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
            [r], {"fl-seed-9001": self.SEED_RECORD}, {"recipes": []}, allergens=MINI_ALLERGENS)
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
        # a rest in the following step is not read with the check
        later = copy.deepcopy(bad)
        later["steps"][1]["text"] = "Rest it 3 minutes, then shred and serve."
        self.assertTrue(any("rest" in e for e in endpoint_errors(later)))
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

    def test_jammy_yolk_is_refused(self):
        # fl-original-0152 at 4b6e163: 160 F in the white, yolk still jammy
        bad = recipe(ingredients=ing("eggs"), steps=[
            {"text": "Cook until a food thermometer through a white reads 160 °F with the "
                     "yolk still jammy.", "safety": chk("egg", 160)}])
        self.assertTrue(any("yolk" in e for e in endpoint_errors(bad)))
        good = recipe(ingredients=ing("eggs"), steps=[
            {"text": "Cook until the yolks are firm and a food thermometer in a yolk reads "
                     "160 °F.", "safety": chk("egg", 160)}])
        self.assertEqual(endpoint_errors(good), [])

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
            [bad], {bad["id"]: ORIGINAL_RECORD}, {"recipes": []}, allergens=MINI_ALLERGENS)
        self.assertTrue(any("casserole" in e or "title" in e for e in errors), errors)


class CookFacingText(unittest.TestCase):
    """Finding 2: the thermometer check is in the instruction, not only metadata."""

    def test_metadata_only_egg_check_is_refused(self):
        # fl-seed-0001 at 4b6e163: "Scramble eggs, set aside" with an egg check
        bad = recipe(ingredients=ing("eggs"), steps=[
            {"text": "Scramble eggs, set aside", "safety": chk("egg", 160)}])
        errors = food_safety.text_violations(bad)
        self.assertTrue(any("metadata only" in e for e in errors), errors)
        self.assertTrue(any("does not state the 160" in e for e in errors), errors)
        good = copy.deepcopy(bad)
        good["steps"][0]["text"] = "Scramble the eggs until a food thermometer reads 160 °F."
        self.assertEqual(food_safety.safety_violations(good), [])

    def test_metadata_only_reheat_check_is_refused(self):
        # fl-seed-0001 at 4b6e163: leftover rice reheated with the check in metadata
        bad = recipe(ingredients=ing("cooked rice"), steps=[
            {"text": "Stir-fry rice for 2-3 minutes", "reheat": True,
             "safety": chk("leftovers", 165)}])
        self.assertTrue(food_safety.text_violations(bad))

    def test_doneness_by_colour_without_a_check_is_refused(self):
        bad = recipe(ingredients=ing("ground beef"), steps=[
            {"text": "Brown the beef until no longer pink."},
            {"text": "Simmer until a food thermometer reads 160 °F.",
             "safety": chk("meat_ground", 160)}])
        errors = food_safety.text_violations(bad)
        self.assertTrue(any("by look or touch" in e for e in errors), errors)

    def test_temperature_on_a_step_without_a_check_is_refused(self):
        bad = recipe(ingredients=ing("cod fillets"), steps=[
            {"text": "Poach the cod until a food thermometer reads 145 °F.",
             "safety": chk("flesh_fish", 145)},
            {"text": "The centres are held at 145 °F from the poach."}])
        errors = food_safety.text_violations(bad)
        self.assertTrue(any("carries no safety check" in e for e in errors), errors)

    def test_negated_reading_is_not_a_check(self):
        # second review: keywords present, no instruction to measure
        bad = recipe(ingredients=ing("ground beef"), steps=[
            {"text": "A thermometer reading 160 F is unnecessary; cook until no longer pink.",
             "safety": chk("meat_ground", 160)}])
        self.assertTrue(any("does not tell the cook to read" in e
                            for e in food_safety.text_violations(bad)))
        bad["steps"][0]["text"] = "Do not use a thermometer; it reads 160 °F anyway."
        self.assertTrue(food_safety.text_violations(bad))

    def test_oven_setting_is_not_a_reading(self):
        bad = recipe(ingredients=ing("eggs"), steps=[
            {"text": "Bake in a 160 °F oven and check with a thermometer.",
             "safety": chk("egg", 160)}])
        self.assertTrue(any("does not tell the cook to read" in e
                            for e in food_safety.text_violations(bad)))

    def test_reading_without_a_measuring_verb_is_refused(self):
        # fl-original-0124 before READING_EDITS: "settles at 165 °F on a food thermometer"
        bad = recipe(ingredients=ing("chicken breast"), steps=[
            {"text": "Let the chicken settle at 165 °F on a food thermometer.",
             "safety": chk("meat_poultry", 165)}])
        self.assertTrue(food_safety.text_violations(bad))

    def test_negated_rest_is_not_a_rest(self):
        bad = recipe(ingredients=ing("pork chops"), steps=[
            {"text": "Cook until a food thermometer reads 145 °F. Do not rest 3 minutes.",
             "safety": chk("meat_whole_cut_pork", 145)}])
        self.assertTrue(any("rest" in e for e in endpoint_errors(bad)))

    def test_unrelated_negation_does_not_void_the_check(self):
        ok = recipe(ingredients=ing("ground beef"), steps=[
            {"text": "Cook until no longer pink and an instant-read thermometer reads 160 °F.",
             "safety": chk("meat_ground", 160)}])
        self.assertEqual(food_safety.safety_violations(ok), [])

    def test_validator_refuses_a_metadata_only_check(self):
        bad = recipe(ingredients=ing("chicken thighs"), steps=[
            {"text": "Reduce heat, cover, simmer 18-20 min",
             "safety": chk("meat_poultry", 165)}])
        errors = validate_corpus.release_gate_errors(
            [bad], {bad["id"]: ORIGINAL_RECORD}, {"recipes": []}, allergens=MINI_ALLERGENS)
        self.assertTrue(any("metadata only" in e for e in errors), errors)


def claim(name: str) -> dict:
    return {"claim": name, "evidence": {"conflicts": []}}


class ClaimComposition(unittest.TestCase):
    """Finding 4: unknown composition blocks a claim; it never means allowed."""

    def test_unknown_alternative_blocks_dairy_free(self):
        # fl-original-0065 at 4b6e163: "ghee or vegetable oil", dairy-free
        bad = recipe(ingredients=ing("red lentils", "ghee or vegetable oil"),
                     claims=[claim("dairy-free")])
        problems = composition.claim_problems(bad, MINI_ALLERGENS)
        self.assertIn("dairy-free", problems)
        self.assertTrue(any("ghee" in p for p in problems["dairy-free"]), problems)

    def test_alternatives_carry_every_option(self):
        # both options known, one of them dairy: the line is not dairy-free
        r = recipe(ingredients=ing("red lentils", "butter or vegetable oil"),
                   claims=[claim("dairy-free")])
        problems = composition.claim_problems(r, MINI_ALLERGENS)["dairy-free"]
        self.assertTrue(any("forbidden classes ['dairy']" in p for p in problems), problems)

    def test_unrecognised_name_blocks_every_claim(self):
        r = recipe(ingredients=ing("red lentils", "sour cream"),
                   claims=[claim("nut-free"), claim("gluten-free")])
        self.assertEqual(set(composition.claim_problems(r, MINI_ALLERGENS)),
                         {"nut-free", "gluten-free"})

    def test_compound_ingredients(self):
        # stock may contain milk or wheat; cheese may use animal rennet
        r = recipe(ingredients=ing("red lentils", "vegetable stock"),
                   claims=[claim("dairy-free"), claim("gluten-free"), claim("nut-free")])
        self.assertEqual(set(composition.claim_problems(r, MINI_ALLERGENS)),
                         {"dairy-free", "gluten-free"})
        r = recipe(ingredients=ing("red lentils", "parmesan"), claims=[claim("vegetarian")])
        self.assertIn("vegetarian", composition.claim_problems(r, MINI_ALLERGENS))
        # soy sauce contains wheat, recorded or not
        r = recipe(ingredients=ing("rice", "soy sauce"), claims=[claim("gluten-free")])
        self.assertIn("gluten-free", composition.claim_problems(r, MINI_ALLERGENS))

    def test_food_named_only_in_a_step_blocks_the_claim(self):
        r = recipe(ingredients=ing("red lentils", "vegetable oil"),
                   steps=[{"text": "Serve with a spoon of sour cream."}],
                   claims=[claim("dairy-free")])
        self.assertIn("dairy-free", composition.claim_problems(r, MINI_ALLERGENS))
        ok = recipe(ingredients=ing("red lentils", "vegetable oil"),
                    steps=[{"text": "Stir in coconut milk and a little nutmeg."}],
                    claims=[claim("dairy-free")])
        self.assertEqual(composition.claim_problems(ok, MINI_ALLERGENS), {})

    def test_known_composition_keeps_the_claim(self):
        ok = recipe(ingredients=ing("red lentils", "vegetable oil"),
                    claims=[claim("dairy-free"), claim("vegan")])
        self.assertEqual(composition.claim_problems(ok, MINI_ALLERGENS), {})

    def test_validator_refuses_the_planted_claim(self):
        bad = recipe(ingredients=ing("red lentils", "ghee or vegetable oil"),
                     claims=[claim("dairy-free")])
        errors = validate_corpus.release_gate_errors(
            [bad], {bad["id"]: ORIGINAL_RECORD}, {"recipes": []}, allergens=MINI_ALLERGENS)
        self.assertTrue(any("'dairy-free' is not proven" in e for e in errors), errors)


class NhsSafetyConversion(unittest.TestCase):
    """Finding 5: the NHS conversion applies the same endpoints as the gate."""

    @classmethod
    def setUpClass(cls):
        import ingest_nhs
        cls.build = staticmethod(ingest_nhs.build_steps)

    def checks(self, steps: list) -> list:
        return [(s["safety"]["class"], s["safety"]["temp_f"]) for s in steps if "safety" in s]

    def test_ground_poultry_no_longer_pink_is_165(self):
        # 4b6e163 rewrote every "no longer pink" to 160 F ground meat
        steps, problems = self.build(["Cook until no longer pink, about 10 minutes."],
                                     ["turkey mince", "onion"], "Turkey burgers")
        self.assertEqual(problems, [])
        self.assertEqual(self.checks(steps), [("meat_poultry", 165)])
        self.assertIn("165 °F", steps[0]["text"])

    def test_pork_cooked_through_states_the_rest(self):
        steps, problems = self.build(["Fry until the pork is cooked through."],
                                     ["pork loin steaks"], "Pork and apple")
        self.assertEqual(problems, [])
        self.assertIn("rest it for at least 3 minutes", steps[0]["text"])

    def test_reheat_check_survives_an_earlier_check(self):
        # 4b6e163 skipped the reheat check once any earlier step had a check
        steps, problems = self.build(
            ["Cook until the chicken is cooked through.", "Reheat leftovers until piping hot."],
            ["chicken breast"], "Chicken rice")
        self.assertEqual(problems, [])
        self.assertEqual(self.checks(steps), [("meat_poultry", 165), ("leftovers", 165)])
        self.assertTrue(steps[1].get("reheat"))
        self.assertIn("thermometer", steps[1]["text"])

    def test_mixed_poultry_and_egg_take_the_poultry_endpoint(self):
        # 4b6e163's fallback chose egg (160 F) before poultry
        steps, problems = self.build(["Mix everything and cook for 20 minutes."],
                                     ["eggs", "chicken breast"], "Chicken and egg skillet")
        self.assertEqual(problems, [])
        self.assertEqual(max(t for _, t in self.checks(steps)), 165)

    def test_casserole_reaches_165(self):
        steps, problems = self.build(["Bake until the fish flakes easily with a fork."],
                                     ["cod fillets", "potatoes"], "Fish pie")
        self.assertEqual(problems, [])
        self.assertEqual(self.checks(steps), [("leftovers", 165)])

    def test_html_entities_are_decoded(self):
        import ingest_nhs
        html = "<h2>Method</h2><ol><li>Don&#x27;t let them burn!</li></ol></section>"
        self.assertEqual(ingest_nhs.method_steps_from_html(html), ["Don't let them burn!"])


class CommittedCorpus(unittest.TestCase):
    """The committed corpus passes every gate."""

    @classmethod
    def setUpClass(cls):
        cls.recipes = [l.obj for l in corpus_io.read_jsonl(corpus_io.CORPUS)]
        cls.records = corpus_io.read_manifest()["records"]
        cls.quarantine = [l.obj for l in corpus_io.read_jsonl(corpus_io.QUARANTINE)]
        cls.bundled = json.loads(validate_corpus.BUNDLED.read_text(encoding="utf-8"))
        cls.allergens = suite_allergens()

    def test_release_gates(self):
        errors = validate_corpus.release_gate_errors(
            copy.deepcopy(self.recipes), self.records, self.bundled, allergens=self.allergens)
        self.assertEqual(errors, [], "\n".join(errors[:20]))

    def test_safety_edits_reproduce_the_corpus_from_the_ingested_originals(self):
        # fix_doneness.py applied to the originals as ingested at 4b6e163
        # yields exactly the committed steps, and a second pass changes nothing
        import fix_doneness
        out = subprocess.run(["git", "-C", str(corpus_io.REPO_ROOT), "show",
                              "4b6e163:data/recipes/corpus.jsonl"],
                             capture_output=True, text=True, check=True).stdout
        ingested = {r["id"]: r for r in map(json.loads, out.splitlines())
                    if r["id"].startswith("fl-original-")}
        fix_doneness.apply(ingested, fix_doneness.EDITS)
        self.assertEqual(fix_doneness.apply(ingested, fix_doneness.EDITS), [])
        committed = {r["id"]: r for r in self.recipes}
        mismatched = [rid for rid, r in ingested.items()
                      if r["steps"] != committed[rid]["steps"]]
        self.assertEqual(mismatched, [])

    def test_quarantine_file(self):
        errors = validate_corpus.quarantine_errors(self.recipes, self.records, self.quarantine)
        self.assertEqual(errors, [], "\n".join(errors[:20]))


if __name__ == "__main__":
    unittest.main()
