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

import collections
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

from pipeline.normalize import normalize_name  # noqa: E402
from pipeline import fsis  # noqa: E402
import food_safety  # noqa: E402
from build_vocab import merge_nutrition  # noqa: E402
import validate_corpus  # noqa: E402

CORPUS = REPO / "data/recipes/corpus.jsonl"
MAPPINGS = REPO / "data/ingredients/name-mappings.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
RIGHTS = REPO / "data/recipes/rights_manifest.json"
LEGACY_MAP = REPO / "data/recipes/legacy-ingredient-map.json"
OUT = REPO / "data/recipes/build/recipes-v2.json"

# Pinned so repeat runs are byte identical; bump deliberately when recompiling.
GENERATED_AT = "2026-10-15T16:46:35Z"

# First corpus id maps to rcp-000167 (validate_corpus.FIRST_CATALOG_ID):
# rcp-000001..rcp-000166 are reserved for migrated legacy rows per the
# bundle-v2 contract.

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

# Claim blockers mirror validate_bundle.CLAIM_BLOCKERS (kept in sync by test).
# composition.py is the fail-closed authority: a line classed 'unknown' (or an
# unclassed line) cannot support ANY claim, because the coarse marker cannot
# say which claim it blocks.
VEGETARIAN_BLOCKERS = {"meat", "fish", "shellfish"}
VEGAN_BLOCKERS = {"meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"}
GLUTEN_BLOCKERS = {"gluten"}
DAIRY_BLOCKERS = {"dairy"}


def derive_claim(line_classes: list[set[str]], blockers: set[str]) -> bool | None:
    """False when a line's composition classes certainly block the claim; None
    when any line is unclassed or carries the 'unknown' marker; True when every
    line's classes are known and none blocks."""
    if any(c & blockers for c in line_classes):
        return False
    if any(not c or "unknown" in c for c in line_classes):
        return None
    return True

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


def legacy_ids_by_key() -> dict[str, int]:
    """legacy_id per vocabulary key, from the legacy-ingredient map.

    Only entries whose identity is `resolved` ship a link: a legacy id is
    attached to a catalog key only when the map records evidence that the
    legacy ingredient and the key are the same food. `proposed` entries stay
    unlinked until that evidence exists."""
    m = json.load(LEGACY_MAP.open())
    vocab = json.load(VOCAB.open())["entries"]
    by_alias: dict[str, set[str]] = {}
    for e in vocab:
        for alias in set([e["key"], *e.get("aliases", [])]):
            by_alias.setdefault(alias, set()).add(e["key"])
    ids: dict[str, int] = {}
    owner: dict[int, str] = {}
    for e in m["entries"]:
        if e["status"] != "resolved":
            continue
        lid = e["legacy_id"]
        if not isinstance(lid, int) or not 1 <= lid <= m["legacy_count"]:
            raise SystemExit(f"legacy id {lid!r} for key {e['key']!r} is outside "
                             f"1..{m['legacy_count']}")
        if lid in owner:
            raise SystemExit(f"legacy id {lid} claimed by both {owner[lid]!r} "
                             f"and {e['key']!r}")
        owner[lid] = e["key"]
        # The map's key is the identity the evidence named; resolve it against
        # the vocabulary exactly first, then through the entry's aliases
        # (legacy "tortilla" resolves through the plural key "tortillas").
        targets = sorted(by_alias.get(e["key"], []))
        if len(targets) != 1:
            raise SystemExit(f"legacy map resolves {e['key']!r} but the vocabulary "
                             f"matches {targets!r} (need exactly one key)")
        ids[targets[0]] = lid
    return ids


def rights_label_for(rec: dict, ctx: dict) -> str:
    """The shipped rights label, derived from the release gate's own per-recipe
    verdict (recipe_rights_errors) rather than from source_type alone.

    A FridgeLuck original or original-rewrite under LicenseRef-FL-Original
    that the gate clears is `original`; only a recipe the gate does not clear
    is `quarantined` (schema enum original | quarantined). A cleared record of
    any other shape has no honest label in the enum: fail closed instead of
    mislabelling it."""
    cleared = not validate_corpus.recipe_rights_errors(
        rec, ctx["statuses"], ctx["records"], ctx["ref_ngrams"], ctx["evidence"])
    record = (ctx["records"].get(rec.get("source_ref"))
              or ctx["records"].get(rec.get("id")))
    if not cleared:
        return "quarantined"
    if (isinstance(record, dict)
            and record.get("license") == "LicenseRef-FL-Original"
            and record.get("source_type") in ("original", "original-rewrite")):
        return "original"
    raise SystemExit(
        f"{rec['id']}: the release gate clears source_type "
        f"{record.get('source_type') if record else None!r}, but the bundle-v2 "
        "rights enum (original|quarantined) has no honest label for it")


def _auto_check_placement(rec: dict, names: list[str], used: set[int]) -> int | None:
    """First free step that mentions one of the ingredient names, else the
    first free step, else None."""
    words = [{w for w in re.split(r"[^a-z0-9]+", n.lower()) if w} for n in names]
    free = [i for i in range(len(rec["steps"])) if i not in used]
    for i in free:
        text_words = {w for w in re.split(r"[^a-z0-9]+", rec["steps"][i]["text"].lower()) if w}
        if any(ws & text_words for ws in words if ws):
            return i
    return free[0] if free else None


def thermometer_checks(rec: dict) -> dict[int, dict]:
    """The bundle thermometer object per step index, from the corpus safety
    blocks plus any class the food-safety gate still counts uncovered.

    An authored check is validated against its OWN cited FSIS class, not a
    coarse recipe-level proxy: the corpus gate (food_safety.endpoint_violations)
    owns coverage and mixture rules with these same specific classes, and a
    coarse re-check here produced false conflicts (a valid 160 F ground-meat
    check under a strictest-meat 165 F rule). Classes the gate deems uncovered
    get an auto-added check on the first step that cooks one of their
    ingredients — empty on the committed corpus, which the gate already
    refuses to let under-cover, but exercised by test with a synthetic recipe
    so a future corpus edit cannot compile silently under-covered."""
    placed: dict[int, dict] = {}
    for i, step in enumerate(rec["steps"]):
        chk = step.get("safety")
        if not isinstance(chk, dict):
            continue
        cls = chk.get("class")
        if cls not in fsis.FSIS_MIN_F:
            raise SystemExit(f"{rec['id']}: step {i} safety class {cls!r} is not "
                             "an FSIS row")
        min_f, label = fsis.FSIS_MIN_F[cls]
        temp_f = chk.get("temp_f")
        if not isinstance(temp_f, (int, float)) or temp_f + 1e-9 < min_f:
            raise SystemExit(f"{rec['id']}: step {i} authored {cls} check at "
                             f"{temp_f} F is below the FSIS minimum {min_f} F")
        placed[i] = {
            "endpoint_c": fsis.f_to_c(temp_f),
            "food": label,
            "fsis_class": cls,
            "source": f"{fsis.source_citation(cls)}; authored corpus safety block",
        }
    for cls, names in sorted(food_safety.uncovered_classes(rec).items()):
        if cls not in fsis.FSIS_MIN_F:
            continue  # uncharted class: the gate already refused the recipe
        target = _auto_check_placement(rec, names, set(placed))
        if target is None:
            raise SystemExit(f"{rec['id']}: uncovered class {cls!r} has no free "
                             "step for an auto-added thermometer check")
        min_f, _ = fsis.FSIS_MIN_F[cls]
        placed[target] = {
            "endpoint_c": fsis.f_to_c(min_f),
            "food": ", ".join(sorted(names)),
            "fsis_class": cls,
            "source": f"{fsis.source_citation(cls)}; auto-added for uncovered {cls}",
        }
    return placed


def compile_recipe(rec: dict, mappings: dict, vocab_by_key: dict,
                   rights_records: dict, labels: dict) -> dict:
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
    thermos = thermometer_checks(rec)
    for i, step in enumerate(rec["steps"]):
        text = step["text"]
        steps.append({
            "text": text,
            "uses": step_uses(text, surfaces),
            # Authored metadata is the intent; the text parse is the fallback
            # (the two disagree on 20 corpus steps — metadata wins there).
            "timer_seconds": (step["timer_min"] * 60
                              if "timer_min" in step else parse_timer(text)),
            "thermometer": thermos.get(i),
        })

    claims_in = {c.get("claim"): c for c in rec.get("claims", [])}
    claims = {"vegetarian": None, "vegan": None, "gluten_free": None,
              "dairy_free": None}
    for claim, value in claims_in.items():
        field = CLAIM_MAP.get(claim)
        if field and not value.get("evidence", {}).get("conflicts"):
            claims[field] = True

    # Derive claims from line composition classes. Fail closed: an authored
    # true claim survives ONLY when the line classes prove it (derived True) —
    # a claim the classes cannot prove ships null (unverifiable), and a claim
    # a known class contradicts refuses the compile. The bundle must never
    # ship, as true, anything its own lines do not prove.
    line_classes = [set(vocab_by_key[line["key"]].get("classes") or ["unknown"])
                    for line in lines]
    derived = {
        "vegetarian": derive_claim(line_classes, VEGETARIAN_BLOCKERS),
        "vegan": derive_claim(line_classes, VEGAN_BLOCKERS),
        "gluten_free": derive_claim(line_classes, GLUTEN_BLOCKERS),
        "dairy_free": derive_claim(line_classes, DAIRY_BLOCKERS),
    }
    for field, value in derived.items():
        if claims[field] is True and value is False:
            raise SystemExit(f"{rec['id']}: authored claim {field!r} contradicts "
                             "line composition classes — fix the corpus claim or "
                             "the classes")
        claims[field] = value
    # vegan proven true requires every line classed and free of meat, fish,
    # shellfish, animal, dairy, egg and honey — which is exactly vegetarian
    # and dairy_free proven too. Enforce the implication defensively so a
    # future blocker-set edit cannot ship a vegan claim without its implies.
    if claims["vegan"] is True:
        for implied in ("vegetarian", "dairy_free"):
            if claims[implied] is not True:
                raise SystemExit(f"{rec['id']}: proven vegan claim without proven "
                                 f"{implied!r} — vegan implies both")

    nutrition = nutrition_for(lines, vocab_by_key, rec)
    status = labels[rec["id"]]
    rights = rights_records.get(rec.get("source_ref")) or rights_records.get(rec["id"])
    evidence = rights["origin"] if isinstance(rights, dict) else \
        "no rights record found — quarantine (fail-closed)"
    keywords = keyword_list(rec, surfaces)

    return {
        "catalog_id": validate_corpus.catalog_id_for(rec["id"]),
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

    # The shipped rights label comes from the release gate's own per-recipe
    # verdict, never from source_type alone (source_type "original-rewrite"
    # used to compile as "quarantined", the enum value reserved for unknown
    # rights). Labels are decided once, up front, then attached per recipe.
    ctx = validate_corpus.load_rights_context()
    labels = {rec["id"]: rights_label_for(rec, ctx) for rec in corpus}
    quarantined = [rid for rid, label in labels.items() if label == "quarantined"]
    statuses = collections.Counter(labels.values())

    # Legacy ingredient links: attach resolved legacy ids to the vocabulary
    # entries the bundle compiles from; proposed entries stay unlinked.
    # legacy_ids_by_key has already resolved every key against the vocabulary.
    legacy_ids = legacy_ids_by_key()
    for key, lid in legacy_ids.items():
        vocab_by_key[key]["legacy_id"] = lid

    recipes = [compile_recipe(rec, mappings, vocab_by_key, rights, labels)
               for rec in corpus]
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
            "classes": e.get("classes") or ["unknown"],
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
    thermos = sum(1 for r in recipes for s in r['steps'] if s['thermometer'])
    auto = sum(1 for r in recipes for s in r['steps']
               if s['thermometer'] and 'auto-added' in s['thermometer']['source'])
    print(f"thermometer checks: {thermos} ({auto} auto-added)")
    claim_counts = {f: collections.Counter(r['claims'][f] for r in recipes)
                    for f in ('vegetarian', 'vegan', 'gluten_free', 'dairy_free')}
    print("claims (true/false/null): " + ", ".join(
        f"{f} {c.get(True, 0)}/{c.get(False, 0)}/{c.get(None, 0)}"
        for f, c in claim_counts.items()))
    print(f"rights: {statuses.get('original', 0)} original, "
          f"{statuses.get('quarantined', 0)} quarantined")
    if quarantined:
        print(f"quarantined ids ({len(quarantined)}): {', '.join(sorted(quarantined))}")
    linked = sum(1 for i in ingredients if i["legacy_id"] is not None)
    print(f"legacy ingredient links: {linked} of {len(ingredients)} keys carry a "
          f"legacy_id ({len(legacy_ids)} resolved in the map)")


if __name__ == "__main__":
    main()
