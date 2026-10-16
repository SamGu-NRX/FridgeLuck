"""Tests for the legacy recipe audit.

Runs the real audit against the real bundled data.json and quarantine.jsonl,
so the tests pin both the rule behavior and the shipped verdicts. Synthetic
recipes are built from real ingredient ids looked up by name, so the tests
survive ingredient-row reordering.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import audit  # noqa: E402

REPO_ROOT = audit.REPO_ROOT


@pytest.fixture(scope="module")
def loaded():
    ingredients, recipes = audit.load_data()
    quarantined = audit.load_quarantined_legacy_ids()
    return ingredients, recipes, quarantined


@pytest.fixture(scope="module")
def ingredients(loaded):
    return loaded[0]


@pytest.fixture(scope="module")
def by_name(ingredients):
    return {ing["name"]: int(iid) for iid, ing in ingredients.items()}


def _recipe(rid, title, instructions, tags, required=None, optional=None, servings=2):
    return {
        "id": rid,
        "title": title,
        "servings": servings,
        "required": required or [],
        "optional": optional or [],
        "instructions": instructions,
        "tags": tags,
    }


def _run_check(recipe, ingredients, quarantined=None):
    return audit.check_recipe(recipe, ingredients, quarantined or {})


# --------------------------------------------------------------------------
# Term matching: phrases beat their inner words; plurals match.
# --------------------------------------------------------------------------


def test_butter_beans_does_not_fire_dairy_butter():
    assert audit.families_in_text("tip in the butter beans and stock") == {"butter-bean"}


def test_coconut_milk_does_not_fire_dairy_milk():
    assert audit.families_in_text("pour in the coconut milk") == {"coconut-milk"}


def test_egg_noodles_carry_both_families():
    assert audit.families_in_text("cook the egg noodles") == {"egg", "noodle"}


def test_peanut_butter_does_not_fire_dairy_butter():
    assert audit.families_in_text("stir in 2 tbsp chunky peanut butter") == {"peanut"}


def test_nut_butter_prose_maps_to_peanut():
    # id 105's steps contain the note 'some nut butters are thicker than
    # others' - prose about the peanut-butter ingredient, which the recipe
    # lists on a real line.
    assert audit.families_in_text("some nut butters are thicker than others") == {"peanut"}


def test_plural_terms_match():
    assert "peanut" in audit.families_in_text("roast the peanuts")
    assert "anchovy" in audit.families_in_text("mash the garlic and anchovies")
    assert "butter-bean" in audit.families_in_text("drain the butter bean")


def test_source_urls_do_not_fire_families():
    assert audit.families_in_text(
        "Source: https://www.bbcgoodfood.com/recipes/pasta-pine-nuts-broccoli | 1. chop garlic"
    ) == set()


# --------------------------------------------------------------------------
# Rule (a): a food named in the title or steps with no matching line.
# --------------------------------------------------------------------------


def test_title_named_food_without_line_hides(ingredients, by_name):
    chicken = by_name["chicken_breast"]
    recipe = _recipe(
        9001,
        "Chicken madras",
        "Source: x | 1. add 4 chicken breasts cut into chunks",
        ["high_protein"],
        required=[(by_name["garlic"], 5)],
    )
    findings = _run_check(recipe, ingredients)
    assert any(r.startswith("missing_headline:chicken") for r in findings["hide_reasons"])


def test_satisfied_line_suppresses_title_flag(ingredients, by_name):
    chicken = by_name["chicken_breast"]
    recipe = _recipe(
        9002,
        "Chicken madras",
        "Source: x | 1. add 4 chicken breasts cut into chunks",
        ["high_protein"],
        required=[(chicken, 400), (by_name["garlic"], 5)],
    )
    findings = _run_check(recipe, ingredients)
    assert not [r for r in findings["hide_reasons"] if r.startswith("missing_headline:chicken")]


def test_generic_family_suppressed_when_specific_sibling_present(ingredients, by_name):
    # A salmon line satisfies a generic 'fish' mention in the steps.
    salmon = by_name["salmon"]
    recipe = _recipe(
        9003,
        "Salmon supper",
        "Source: x | 1. season the fish and bake",
        ["quick"],
        required=[(salmon, 340)],
    )
    findings = _run_check(recipe, ingredients)
    assert not [r for r in findings["hide_reasons"] if "fish-generic" in r]


def test_steps_named_animal_food_without_line_hides(ingredients, by_name):
    # Fish sauce is fish-derived and the steps instruct using it, so the
    # recipe must hide even though the dish title never says fish.
    recipe = _recipe(
        9004,
        "Healthy chicken salad",
        "Source: x | 1. stir together the fish sauce, lime juice and sugar",
        ["high_protein"],
        required=[(by_name["chicken_breast"], 200)],
    )
    findings = _run_check(recipe, ingredients)
    assert any(r.startswith("missing_headline:fish-generic") for r in findings["hide_reasons"])


# --------------------------------------------------------------------------
# Rule (b): diet tags contradicted by the food families present.
# --------------------------------------------------------------------------


def test_vegan_tag_contradicted_by_title_anchovy(ingredients, by_name):
    recipe = _recipe(
        9005,
        "Caramelised red onion & anchovy pasta",
        "Source: x | 1. fry the anchovies",
        ["vegetarian", "vegan"],
        required=[(by_name["garlic"], 5)],
    )
    findings = _run_check(recipe, ingredients)
    tags_flagged = {r.split(":")[1].split(" ")[0] for r in findings["hide_reasons"] if r.startswith("tag_contradiction")}
    assert tags_flagged == {"vegetarian", "vegan"}


def test_gluten_free_tag_contradicted_by_pasta(ingredients, by_name):
    # No shipped recipe carries gluten_free, but the boundary must still
    # reject it if a future import assigns it to a pasta dish.
    recipe = _recipe(
        9006,
        "Pasta supper",
        "Source: x | 1. boil the spaghetti",
        ["gluten_free"],
        required=[(by_name["garlic"], 5)],
    )
    findings = _run_check(recipe, ingredients)
    assert any(r.startswith("tag_contradiction:gluten_free") for r in findings["hide_reasons"])


# --------------------------------------------------------------------------
# Rules (c) and (d): plausibility bands.
# --------------------------------------------------------------------------


def test_tiny_required_mass_flags_review(ingredients, by_name):
    recipe = _recipe(
        9007,
        "Pepper water",
        "Source: x | 1. boil",
        [],
        required=[(by_name["bell_pepper"], 4)],
    )
    findings = _run_check(recipe, ingredients)
    assert any(letter == "c" for letter, _msg in findings["review"])


def test_heavy_sodium_flags_review(ingredients, by_name):
    recipe = _recipe(
        9008,
        "Salty bowl",
        "Source: x | 1. simmer",
        [],
        required=[(by_name["soy_sauce"], 900)],
    )
    findings = _run_check(recipe, ingredients)
    assert any(letter == "d" for letter, _msg in findings["review"])


# --------------------------------------------------------------------------
# Drop mechanism: hand-checked false positives stay on record, out of reasons.
# --------------------------------------------------------------------------


def test_id15_optional_sweet_potato_does_not_contradict_low_carb(loaded):
    _ingredients, recipes, _q = loaded
    recipe = next(r for r in recipes if r["id"] == 15)
    ingredients = _ingredients
    findings = _run_check(recipe, ingredients)
    assert not [r for r in findings["hide_reasons"] if r.startswith("tag_contradiction:low_carb")]
    assert any(d["key"] == "low_carb" and d["kind"] == "tag_contradiction" for d in findings["dropped"])


def test_id48_potato_masher_is_not_an_ingredient(loaded):
    _ingredients, recipes, _q = loaded
    recipe = next(r for r in recipes if r["id"] == 48)
    findings = _run_check(recipe, loaded[0])
    assert not [r for r in findings["hide_reasons"] if r.startswith("tag_contradiction:low_carb")]


def test_id154_toppings_menu_leaves_recipe_unhidden(loaded):
    # Every automated finding on id 154 comes from the BBC page's optional
    # 'Choose your toppings' menu; the shipped one-pot is correctly vegan.
    _ingredients, recipes, _q = loaded
    recipe = next(r for r in recipes if r["id"] == 154)
    findings = _run_check(recipe, loaded[0])
    assert findings["hide_reasons"] == []
    assert findings["dropped"], "id 154's dropped findings should stay on record"


def test_id92_cauliflower_steaks_are_not_beef(loaded):
    _ingredients, recipes, _q = loaded
    recipe = next(r for r in recipes if r["id"] == 92)
    findings = _run_check(recipe, loaded[0])
    assert not [r for r in findings["hide_reasons"] if "beef" in r]
    assert not [r for r in findings["hide_reasons"] if r.startswith("tag_contradiction")]


def test_drop_table_covers_every_drop_reason_shape():
    for (rid, key), why in audit.DROPPED_FALSE_POSITIVES.items():
        assert isinstance(rid, int) and isinstance(key, str) and len(why) > 20


# --------------------------------------------------------------------------
# Rule (f): quarantine mapping.
# --------------------------------------------------------------------------


def test_quarantined_recipe_gets_rights_reason(loaded):
    _ingredients, recipes, quarantined = loaded
    assert 1 in quarantined and quarantined[1] == "fl-seed-0001"
    recipe = next(r for r in recipes if r["id"] == 1)
    findings = _run_check(recipe, loaded[0], quarantined)
    assert any(r.startswith("quarantined:rights") for r in findings["hide_reasons"])


def test_quarantine_entries_all_resolve_to_real_recipe_ids(loaded):
    _ingredients, recipes, quarantined = loaded
    known = {r["id"] for r in recipes}
    assert set(quarantined) <= known, "every quarantine entry must name a bundled recipe id"


# --------------------------------------------------------------------------
# Whole-run invariants and byte-stable regeneration.
# --------------------------------------------------------------------------


def test_full_run_row_count_and_counts_match(loaded):
    _ingredients, _recipes, _q = loaded
    result = audit.audit()
    row_count = len(result["hide_rows"])
    assert row_count == 128
    a_reasons = sum(
        1 for row in result["hide_rows"] for r in row["reasons"] if r.startswith("missing_headline")
    )
    b_reasons = sum(
        1 for row in result["hide_rows"] for r in row["reasons"] if r.startswith("tag_contradiction")
    )
    assert a_reasons == result["counts"]["a"] == 162
    assert b_reasons == result["counts"]["b"] == 41
    assert result["counts"]["g"] == 36


def test_every_hide_row_has_evidence_and_reasons(loaded):
    result = audit.audit()
    for row in result["hide_rows"]:
        assert row["verdict"] == "hide"
        assert row["reasons"], f"id {row['legacy_id']} hidden with no reasons"
        assert len(row["evidence"]) == len(row["reasons"])
        for reason in row["reasons"]:
            assert any(
                reason.startswith(p) for p in ("missing_headline:", "tag_contradiction:", "quarantined:")
            )


def test_every_a_b_reasons_key_has_an_evidence_excerpt(ingredients):
    # A steps-fired flag must quote the mentioning step, so a reviewer can
    # confirm or refute the flag without re-deriving the match.
    _ingredients, recipes, quarantined = loaded_all()
    for recipe in recipes:
        findings = audit.check_recipe(recipe, ingredients, quarantined)
        for reason, evidence in zip(findings["hide_reasons"], findings["hide_evidence"]):
            if reason.startswith("missing_headline") and "steps mention" in reason:
                assert evidence.startswith("steps: ..."), (recipe["id"], reason, evidence)


def loaded_all():
    ingredients, recipes = audit.load_data()
    return ingredients, recipes, audit.load_quarantined_legacy_ids()


def test_regen_is_byte_identical(tmp_path):
    """Two consecutive runs produce the same JSONL bytes."""
    out_a, out_b = tmp_path / "a.jsonl", tmp_path / "b.jsonl"
    for out in (out_a, out_b):
        proc = subprocess.run(
            [sys.executable, str(Path(__file__).parent / "audit.py")],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
        )
        assert proc.returncode == 0, proc.stderr
        out.write_bytes(audit.OUTPUT_JSONL.read_bytes())
    assert out_a.read_bytes() == out_b.read_bytes()


def test_committed_jsonl_matches_current_rules(loaded):
    """The shipped legacy-audit.jsonl was produced by the current rules."""
    committed = [json.loads(l) for l in audit.OUTPUT_JSONL.read_text().splitlines()]
    result = audit.audit()
    assert [dict(r) for r in result["hide_rows"]] == committed


def test_no_hidden_recipe_survives_without_cause(loaded):
    # A row whose reasons were all dropped must not appear in the hide list.
    result = audit.audit()
    for row in result["hide_rows"]:
        assert row["reasons"] or not row.get("dropped_false_positives")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
