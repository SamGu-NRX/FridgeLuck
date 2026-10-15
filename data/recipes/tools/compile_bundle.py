#!/usr/bin/env python3
"""Compile the RS v1 corpus into a recipe-bundle-v2 catalog.

Writes data/recipes/build/recipes-v2.json — outside apps/ios/; the integration
thread is responsible for shipping bundles into the app. The output is byte
identical across repeat runs: generated_at is pinned, ordering is stable, and
every number traces to committed evidence (vocabulary, name mappings, rights
manifest, corpus). Nothing is synthesized: lines without per-100g values carry
no nutrition, and unknown masses stay unknown.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

from pipeline.normalize import normalize_name  # noqa: E402
from build_vocab import merge_nutrition  # noqa: E402

CORPUS = REPO / "data/recipes/corpus.jsonl"
MAPPINGS = REPO / "data/ingredients/name-mappings.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
RIGHTS = REPO / "data/recipes/rights_manifest.json"
OUT = REPO / "data/recipes/build/recipes-v2.json"

# Pinned so repeat runs are byte identical; bump deliberately when recompiling.
GENERATED_AT = "2026-10-15T09:41:00Z"

# First corpus id maps to rcp-000167: rcp-000001..rcp-000166 are reserved for
# migrated legacy rows per the bundle-v2 contract.
FIRST_CORPUS_ID = 167

# Pantry staples the fit line treats as assumed (overhaul spec 3.2). Keys whose
# recipes nearly always assume them on hand.
STAPLE_KEYS = {
    "olive_oil", "vegetable_oil", "sunflower_oil", "coconut_oil", "sesame_oil",
    "salt", "black_pepper", "water", "sugar", "brown_sugar", "plain_flour",
    "all_purpose_flour", "butter", "soy_sauce", "lemon_juice", "white_wine_vinegar",
    "red_wine_vinegar", "apple_cider_vinegar", "rice_vinegar", "honey", "mustard",
    "chili_flakes", "smoked_paprika", "paprika", "dried_oregano", "oregano",
    "ground_cumin", "cumin", "coriander", "ground_corriander", "cinnamon",
    "bay_leaf", "stock_cube", "tomato_paste", "cornflour", "cornstarch",
    "garlic", "onion", "cooking_spray", "black_tea", "coffee", "sea_salt",
}

CLAIM_MAP = {
    "vegetarian": "vegetarian",
    "vegan": "vegan",
    "gluten-free": "gluten_free",
    "dairy-free": "dairy_free",
    "nut-free": None,  # no allergen field in bundle v2; allergens live in canon
}

DURATION_RE = re.compile(
    r"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h\b|minutes?|mins?|m\b|seconds?|secs?)",
    re.IGNORECASE,
)
UNIT_SECONDS = {"h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
                "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
                "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1}


def parse_timer(text: str) -> int | None:
    """Last explicit duration in the step text; None when only vague words."""
    hits = DURATION_RE.findall(text)
    if not hits:
        return None
    value, unit = hits[-1]
    unit = unit.lower().rstrip(".")
    if unit not in UNIT_SECONDS:
        return None
    seconds = int(float(value) * UNIT_SECONDS[unit])
    if not 10 <= seconds <= 21600:
        return None
    return seconds


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def quantity_from(qty: dict) -> dict:
    kind = qty["kind"]
    if kind == "source_grams":
        return {"kind": "grams", "grams": qty["grams"]}
    if kind == "household":
        grams = qty.get("grams")
        return {"kind": "household", "amount": qty["value"], "unit": qty["unit"],
                "grams": grams}
    if kind == "count":
        return {"kind": "count", "amount": qty["value"], "unit": qty["unit"],
                "grams": qty.get("grams")}
    # unknown: "to taste" and similar. Honest unknown mass, never guessed.
    return {"kind": "unknown", "note": qty.get("note") or "to taste"}


def surface_for(name: str, mappings: dict) -> str:
    rec = mappings.get(normalize_name(name))
    return rec["surface"] if rec else name


def step_uses(text: str, surfaces: list[str]) -> list[int]:
    """Indexes of lines whose surface name occurs in the step text."""
    hay = f" {text.lower()} "
    uses: list[int] = []
    for i, surface in enumerate(surfaces):
        needle = surface.lower()
        if re.search(rf"(?<![a-z]){re.escape(needle)}(?![a-z])", hay):
            uses.append(i)
    return uses


def compile_recipe(rec: dict, mappings: dict, vocab_by_key: dict,
                   rights_records: dict) -> dict:
    lines: list[dict] = []
    surfaces: list[str] = []
    for ing in rec["ingredients"]:
        norm = normalize_name(ing["name"])
        entry = mappings.get(norm)
        if entry is None:
            raise SystemExit(f"{rec['id']}: unmapped ingredient name {ing['name']!r}")
        key = entry["key"]
        vocab = vocab_by_key.get(key)
        if vocab is None:
            raise SystemExit(f"{rec['id']}: key {key!r} missing from vocabulary")
        note = ing.get("note")
        line = {
            "key": key,
            "quantity": quantity_from(ing["qty"]),
            "required": ing.get("required", True),
            "assumed_staple": key in STAPLE_KEYS,
            "note": note if note else None,
        }
        lines.append(line)
        surfaces.append(entry["surface"])

    steps: list[dict] = []
    for step in rec["steps"]:
        text = step["text"]
        steps.append({
            "text": text,
            "uses": step_uses(text, surfaces),
            "timer_seconds": parse_timer(text),
            "thermometer": None,
        })

    claims_in = {c.get("claim"): c for c in rec.get("claims", [])}
    claims = {"vegetarian": None, "vegan": None, "gluten_free": None,
              "dairy_free": None}
    for claim, value in claims_in.items():
        field = CLAIM_MAP.get(claim)
        if field and not value.get("evidence", {}).get("conflicts"):
            claims[field] = True

    nutrition = nutrition_for(lines, vocab_by_key, rec)
    seq = int(rec["id"].rsplit("-", 1)[-1])
    rights = rights_records.get(rec["id"])
    if rights is None:
        raise SystemExit(f"{rec['id']}: no rights record — fail closed")
    status = "original" if rights.get("source_type") == "original" else "quarantined"
    keywords = keyword_list(rec, surfaces)

    return {
        "catalog_id": f"rcp-{FIRST_CORPUS_ID + seq - 1:06d}",
        "revision": 1,
        "title": rec["title"],
        "cuisine": rec["cuisine"],
        "meal_slots": rec["meal_slots"],
        "collections": rec.get("collections", []),
        "minutes": rec["minutes"],
        "servings": rec["servings"],
        "equipment": rec.get("equipment", []),
        "ingredients": lines,
        "steps": steps,
        "claims": claims,
        "nutrition_per_serving": nutrition,
        "rights": {"status": status, "evidence": rights["origin"]},
        "keywords": keywords,
    }


def per_serving_kcal(totals: dict, servings: int) -> float:
    """Per-serving kcal, failing loudly outside the plausible 10-2500 range.

    Sodium fails loudly; kcal must too (review finding 3) — a silent clamp
    would ship 2500.0 for an honestly higher recipe with no marker, and the
    Atwater check would then validate the clamped number.
    """
    kcal = totals["kcal"] / servings
    if not 10.0 <= kcal <= 2500.0:
        raise SystemExit(
            f"per-serving kcal {kcal:.1f} outside the plausible 10-2500 range; "
            "refusing to clamp silently — fix the ingredient rows or servings")
    return round(kcal, 1)


def nutrition_for(lines: list[dict], vocab_by_key: dict, rec: dict) -> dict:
    fields = ["kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sodium_mg"]
    totals = {f: 0.0 for f in fields}
    weighed = 0
    covered = 0
    converted = 0
    for line in lines:
        qty = line["quantity"]
        if qty["kind"] == "unknown":
            continue
        weighed += 1
        grams = qty["grams"]
        if grams is None:
            continue
        converted += 1 if qty["kind"] in ("household", "count") else 0
        per100 = vocab_by_key[line["key"]].get("per_100g")
        if per100 is None:
            continue
        covered += 1
        scale = grams / 100.0
        for f in fields:
            totals[f] += per100[f] * scale
    servings = rec["servings"]
    if weighed == 0 or covered == 0:
        raise SystemExit(f"{rec['id']}: no nutrition basis — would be synthesized")
    if covered < weighed:
        coverage = "partial"
    elif converted:
        coverage = "estimated"
    else:
        coverage = "computed"
    return {
        "kcal": per_serving_kcal(totals, servings),
        "protein_g": round(totals["protein_g"] / servings, 1),
        "carbs_g": round(totals["carbs_g"] / servings, 1),
        "fat_g": round(totals["fat_g"] / servings, 1),
        "fiber_g": round(totals["fiber_g"] / servings, 1),
        "sodium_mg": round(totals["sodium_mg"] / servings, 1),
        "coverage": coverage,
        "basis": "catalog per-100g rows x line grams / servings",
    }


STOPWORDS = {"the", "a", "an", "with", "and", "of", "in", "for", "to", "on"}


def keyword_list(rec: dict, surfaces: list[str]) -> list[str]:
    words: list[str] = []
    for token in re.split(r"[^a-z0-9]+", rec["title"].lower()):
        if token and token not in STOPWORDS and token not in words:
            words.append(token)
    words.append(rec["cuisine"])
    for surface in surfaces:
        for token in re.split(r"[^a-z0-9]+", surface.lower()):
            if token and token not in words:
                words.append(token)
    return words


def main() -> None:
    corpus = load_jsonl(CORPUS)
    mappings = json.load(MAPPINGS.open())["mappings"]
    vocab = json.load(VOCAB.open())["entries"]
    vocab_by_key = {e["key"]: e for e in vocab}
    rights = json.load(RIGHTS.open())["records"]

    recipes = [compile_recipe(rec, mappings, vocab_by_key, rights) for rec in corpus]
    used_keys = sorted({line["key"] for r in recipes for line in r["ingredients"]})
    ingredients = []
    for key in used_keys:
        e = vocab_by_key[key]
        ingredients.append({
            "key": key,
            "fdc_id": e.get("fdc_id"),
            "legacy_id": e.get("legacy_id"),
            "display_name": e["display_name"],
            "category": e.get("category") or "other",
            "per_100g": e.get("per_100g"),
            "aliases": e.get("aliases", []),
        })

    bundle = {
        "schema": "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json",
        "bundle_version": 2,
        "generated_at": GENERATED_AT,
        "cuisines": ["american", "asian", "indian", "italian", "mediterranean",
                     "mexican"],
        "ingredients": ingredients,
        "recipes": recipes,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(bundle, indent=1, ensure_ascii=False, sort_keys=False) + "\n")
    coverage = {"computed": 0, "estimated": 0, "partial": 0}
    for r in recipes:
        coverage[r["nutrition_per_serving"]["coverage"]] += 1
    print(f"bundle: {len(recipes)} recipes, {len(ingredients)} ingredients -> {OUT}")
    print(f"nutrition coverage: {coverage}")
    print(f"steps with timers: "
          f"{sum(1 for r in recipes for s in r['steps'] if s['timer_seconds'])}")


if __name__ == "__main__":
    main()
