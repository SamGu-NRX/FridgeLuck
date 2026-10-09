"""Regression tests for the recipe import fidelity repairs.

Backs the audit findings (fidelity report, dev split): singularization,
name-variant index collisions, count-unit stripping, parenthetical gram
conversions, unit-aware gram estimation, diet-tag word boundaries, and the
merge report rejection/review taxonomy with overrides.

Run: python -m pytest scripts/recipe_scraper/tests -q
Portable: no network, no Xcode, no bundled data dependency.
"""

import importlib.util
import json
from pathlib import Path

from typer.testing import CliRunner

MODULE_PATH = Path(__file__).resolve().parents[1] / "scrape_recipes.py"

_spec = importlib.util.spec_from_file_location("scrape_recipes_under_test", MODULE_PATH)
mod = importlib.util.module_from_spec(_spec)
# pydantic resolves annotations through sys.modules; register before exec
import sys  # noqa: E402

sys.modules[_spec.name] = mod
_spec.loader.exec_module(mod)


def _catalog_payload() -> dict:
    """Minimal bundled-data payload shaped like apps/ios/Resources/data.json."""

    def ing(name: str) -> list:
        return [name] + [0.0] * 9

    return {
        "tags": [],
        "ingredients": {
            "1": ing("milk"),
            "2": ing("egg"),
            "3": ing("garlic"),
            "4": ing("onion"),
            "5": ing("tomato"),
            "6": ing("potato"),
            "7": ing("olive oil"),
            "8": ing("sesame oil"),
            "9": ing("ground beef"),
            "10": ing("corn"),
            "11": ing("butter"),
            "12": ing("spinach"),
            "13": ing("bell pepper"),
            "14": ing("yogurt"),
            "15": ing("canned tuna"),
        },
        "recipes": [],
    }


def _ing(raw: str, name: str | None = None) -> mod.IngredientOut:
    return mod.IngredientOut(raw=raw, scaled_raw=raw, name=name if name is not None else raw)


def _recipe(ingredients: list, title: str = "Test Dish", steps: list | None = None) -> mod.RecipeOut:
    return mod.RecipeOut(
        source_url=f"https://en.wikibooks.org/wiki/Cookbook:{title.replace(' ', '_')}",
        title=title,
        servings_original=2,
        servings_target=2,
        ingredients=ingredients,
        steps=steps if steps is not None else ["Do the thing."] * 7,
    )


# --- singularization and name variants -------------------------------------


def test_singularize_handles_oes_plurals():
    assert "tomato" in mod._canonical_name_variants("tomatoes")
    assert "tomatoe" not in mod._canonical_name_variants("tomatoes")
    assert "potato" in mod._canonical_name_variants("potatoes")


def test_ingredient_index_has_no_generic_last_word_leak():
    index = mod._build_ingredient_index(_catalog_payload())
    assert "oil" not in index, "bare last-word variant leaks generic keys into the index"
    # "sesame oil" registered last must not own the generic key
    assert mod._resolve_ingredient_id("sesame oil", index) == 8


def test_extra_virgin_olive_oil_maps_to_olive_not_sesame():
    index = mod._build_ingredient_index(_catalog_payload())
    assert mod._resolve_ingredient_id("extra virgin olive oil", index) == 7
    assert mod._resolve_ingredient_id("virgin olive oil", index) == 7


def test_identity_safe_aliases_resolve():
    index = mod._build_ingredient_index(_catalog_payload())
    assert mod._resolve_ingredient_id("tinned tomatoes", index) == 5
    assert mod._resolve_ingredient_id("chopped tomatoes", index) == 5
    assert mod._resolve_ingredient_id("minced beef", index) == 9
    assert mod._resolve_ingredient_id("sweetcorn", index) == 10
    assert mod._resolve_ingredient_id("greek yogurt", index) == 14
    # ambiguous or absent identities stay unsupported
    assert mod._resolve_ingredient_id("vegetable oil", index) is None
    assert mod._resolve_ingredient_id("salt", index) is None


# --- name normalization -----------------------------------------------------


def test_leading_conversion_paren_does_not_eat_the_name():
    assert mod.normalize_ingredient_name("1 cup (240 g / 8.5 oz) butter") == "butter"
    name = mod.normalize_ingredient_name("2 cups (450 g / 16 oz) white granulated sugar")
    assert name.startswith("white") and "sugar" in name


def test_count_unit_words_strip_from_name():
    assert mod.normalize_ingredient_name("2 cloves garlic") == "garlic"
    assert mod.normalize_ingredient_name("2 piece onion") == "onion"
    assert mod.normalize_ingredient_name("1 slice bread") == "bread"
    # names without a leading quantity keep count words via aliases only
    index = mod._build_ingredient_index(_catalog_payload())
    assert mod._resolve_ingredient_id(mod.normalize_ingredient_name("2 cloves garlic"), index) == 3
    assert mod._resolve_ingredient_id(mod.normalize_ingredient_name("2 piece onion"), index) == 4


# --- gram estimation ---------------------------------------------------------


def test_estimate_grams_prefers_parenthetical_metric():
    ing = _ing("1 cup (240 g / 8.5 oz) milk", name="milk")
    assert mod._estimate_grams(ing) == 240.0


def test_estimate_grams_uses_the_quantity_unit():
    assert mod._estimate_grams(_ing("1 cup milk", name="milk")) == 240.0
    assert mod._estimate_grams(_ing("2 cups milk", name="milk")) == 480.0
    assert mod._estimate_grams(_ing("2 tbsp olive oil", name="olive oil")) == 30.0
    assert mod._estimate_grams(_ing("1 kg potatoes", name="potato")) == 1000.0


def test_estimate_grams_count_items_and_defaults():
    assert mod._estimate_grams(_ing("2 eggs", name="eggs")) == 100.0
    # "eggplant" must not match the "egg" per-unit entry (word boundary)
    assert mod._estimate_grams(_ing("3 eggplants", name="eggplant")) == 150.0
    # no unit, no table hit -> documented 50 g default
    assert mod._estimate_grams(_ing("1 splash milk", name="milk")) == 50.0


def test_estimate_grams_metric_amount_path_unchanged():
    ing = mod.IngredientOut(raw="500 g tomatoes", scaled_raw="500 g tomatoes", name="tomatoes", amount_value=500, amount_unit="g")
    assert mod._estimate_grams(ing) == 500.0


# --- diet tag inference ------------------------------------------------------


def _bits(title: str, ingredient_names: list[str]) -> int:
    recipe = _recipe([_ing(f"1 cup {n}", name=n) for n in ingredient_names], title=title)
    return mod._infer_tag_bitmask(recipe)


def test_tag_inference_eggplant_is_not_egg():
    bits = _bits("Veggie Stir Fry", ["eggplant"])
    assert bits & (1 << mod.RECIPE_TAG_BITS["vegetarian"])
    assert bits & (1 << mod.RECIPE_TAG_BITS["vegan"])


def test_tag_inference_plant_milks_are_vegan():
    bits = _bits("Coconut Curry", ["coconut milk", "rice"])
    assert bits & (1 << mod.RECIPE_TAG_BITS["vegan"])


def test_tag_inference_stocks_and_animal_fats_are_animal():
    for names in (["chicken stock"], ["anchovies"], ["fish sauce"], ["paneer"], ["lard"]):
        bits = _bits("Savory Dish", names)
        assert not bits & (1 << mod.RECIPE_TAG_BITS["vegan"]), names
    bits = _bits("Savory Dish", ["chicken stock"])
    assert not bits & (1 << mod.RECIPE_TAG_BITS["vegetarian"])


def test_tag_inference_dairy_and_egg_families():
    bits = _bits("Cheesy Bake", ["paneer", "ghee"])
    assert bits & (1 << mod.RECIPE_TAG_BITS["vegetarian"])
    assert not bits & (1 << mod.RECIPE_TAG_BITS["vegan"])


def test_tag_inference_peanut_butter_is_not_butter():
    bits = _bits("PB Toast", ["peanut butter", "bread"])
    assert bits & (1 << mod.RECIPE_TAG_BITS["vegan"])


# --- merge report taxonomy ----------------------------------------------------


def _scraped_payload() -> list[dict]:
    def recipe_dict(title: str, url: str, ingredients: list, servings: int = 2) -> dict:
        return {
            "source_url": url,
            "title": title,
            "servings_original": servings,
            "servings_target": servings,
            "ingredients": [{"raw": r, "scaled_raw": r, "name": n, "amount_value": None, "amount_unit": None, "prep_actions": []} for r, n in ingredients],
            "steps": ["Step one.", "Step two.", "Step three.", "Step four.", "Step five.", "Step six."],
        }

    return [
        recipe_dict(
            "Garlic Tomato Fry",
            "https://example.com/a",
            [("1 cup tomatoes", "tomatoes"), ("2 cloves garlic", "garlic"), ("salt to taste", "salt taste")],
        ),
        recipe_dict("Thin Soup", "https://example.com/b", [("1 onion", "onion"), ("1 cup water", "water")]),
        recipe_dict(
            "Flagged Dish",
            "https://example.com/c",
            [("2 eggs", "eggs"), ("1 cup milk", "milk"), ("1 pinch salt", "salt"), ("1 cup water", "water")],
        ),
        recipe_dict("Empty Shell", "https://example.com/d", [("1 cup water", "water")]),
        recipe_dict("Garlic Tomato Fry", "https://example.com/e", [("1 cup tomatoes", "tomatoes"), ("2 cloves garlic", "garlic")]),
    ]


def _invoke_merge(tmp_path: Path, overrides: Path | None):
    runner = CliRunner()
    scraped = tmp_path / "scraped.json"
    scraped.write_text(json.dumps(_scraped_payload()))
    bundled = tmp_path / "bundled.json"
    bundled.write_text(json.dumps(_catalog_payload()))
    out = tmp_path / "out.json"
    report = tmp_path / "report.json"
    args = ["--scraped", str(scraped), "--bundled-data", str(bundled), "--out", str(out), "--report-out", str(report)]
    if overrides is not None:
        args += ["--overrides", str(overrides)]
    result = runner.invoke(mod.app, ["merge-grdb", *args])
    assert result.exit_code == 0, result.output
    return json.loads(report.read_text()), json.loads(out.read_text())


def test_merge_report_taxonomy(tmp_path):
    report, _ = _invoke_merge(tmp_path, None)
    assert "skipped_recipes" not in report
    assert report["accepted_recipe_count"] == 2  # Garlic Tomato Fry + Flagged Dish
    rejected = {r["title"]: r["reasons"] for r in report["rejected_recipes"]}
    assert rejected["Thin Soup"] == ["too_few_mapped_required_ingredients"]
    assert rejected["Empty Shell"] == ["too_few_mapped_required_ingredients"]
    assert rejected["Garlic Tomato Fry"] == ["duplicate_title"]
    assert report["rejected_recipe_count"] == 3
    flagged = {r["title"]: {f["kind"] for f in r["flags"]} for r in report["review_recipes"]}
    assert flagged["Flagged Dish"] == {"high_unsupported_share"}
    assert report["overridden_recipe_count"] == 0


def test_merge_override_forces_only_too_few_rejections(tmp_path):
    overrides = tmp_path / "overrides.json"
    overrides.write_text(json.dumps([{"title": "Thin Soup", "note": "verified by hand"}]))
    report, merged = _invoke_merge(tmp_path, overrides)
    assert report["overridden_recipe_count"] == 1
    assert report["overridden_recipes"][0]["note"] == "verified by hand"
    assert report["accepted_recipe_count"] == 3
    titles = [row[1] for row in merged["recipes"]]
    assert "Thin Soup" in titles
    # duplicate titles stay rejected even when an override matches the title
    dup = [r for r in report["rejected_recipes"] if r["reasons"] == ["duplicate_title"]]
    assert len(dup) == 1


def test_merge_report_counts_match_rows(tmp_path):
    report, merged = _invoke_merge(tmp_path, None)
    assert report["scraped_recipe_count"] == len(_scraped_payload())
    assert len(merged["recipes"]) == report["accepted_recipe_count"]
    for row in merged["recipes"]:
        assert len(row) == 8
