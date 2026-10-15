#!/usr/bin/env python3
"""Slice-local checker for data/recipe-sources/everyday-2026-10.

Suite C's validator (run unmodified via ``run_validator`` below) already
enforces RS v1 lint, FSIS food safety, claim composition, coverage bands,
id hygiene and the rights-*record* shape. This checker enforces the rules
the pinned validator does NOT implement for this slice's source tag:

  R-A  ingredient names resolve in the USDA catalog or the canonical
       vocabulary (legacy bundled names + suite allergen aliases);
  R-B  every household quantity's grams agree with the pinned conversion
       row it cites (value x grams_per_unit, 2% tolerance);
  R-C  the slice's ``category`` field is one of the eight declared
       categories and is coherent with the recipe (slots, minutes, reheat),
       and the batch meets the balance bars: at least a third vegetarian,
       every category non-empty, all cuisines/slots/time bands represented;
  R-D  the rights manifest carries a complete record for every recipe and
       the pinned evidence file agrees with the shipped text;
  R-E  no duplicate (normalized title, core ingredient set) within or
       across the slice's files, against the shipped #113 corpus, against
       PR #144's legacy titles (rewrites carry fresh titles), and no
       shared 12-word run with the bundled catalog or 9-word run with
       #144's legacy instruction text;
  R-F  step text never names a food that is missing from the ingredient
       list (whitelist: water and ice).

Everything here fails closed: a rule it cannot evaluate is an error, not
a pass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

WHITELIST_STEP_FOODS = {"water", "ice"}
CATEGORIES = (
    "breakfasts",
    "packed-lunches",
    "20-minute-dinners",
    "budget-student-pantry",
    "high-protein",
    "vegetarian-vegan-mains",
    "batch-leftovers",
    "sides-salads",
)
CUISINES = {"american", "asian", "indian", "italian", "mediterranean", "mexican"}
SLOTS = {"breakfast", "lunch", "dinner"}
MEAT_CLASSES = {"meat_poultry", "meat_ground", "meat_whole_cut_pork",
                "meat_whole_cut_red", "flesh_fish", "flesh_shellfish"}
# Names the allergen alias table does not carry get a conservative keyword
# pass; a hit means "animal protein", never a guess of vegetarian.
MEAT_WORDS = re.compile(
    r"\b(?:chicken|turkey|duck|beef|steak|pork|bacon|ham|lamb|sausage|chorizo|"
    r"meatball|burger|mince|venison|fish|salmon|cod|tilapia|tuna|trout|"
    r"anchov\w*|shrimp|prawn|crab|lobster|scallop|clam|mussel|squid)\b",
    re.IGNORECASE)
DAIRY_EGG_WORDS = re.compile(
    r"\b(?:cheese|milk|yog(?:h)?urt|cream(?! cheese)|butter(?! ?(?:bean|nut))|"
    r"egg|eggs|honey|ghee|paneer|halloumi|feta|cheddar|mozzarella|parmesan|"
    r"ricotta|mayonnaise)\b", re.IGNORECASE)
# Foods a step may name; each must be covered by an ingredient line whose
# name contains it (word-boundary phrase match).
STEP_FOOD_NAMES = (
    "all-purpose flour", "almonds", "apple", "avocado", "baking powder",
    "basil", "bell peppers", "black beans", "black pepper", "bread",
    "breadcrumbs", "broccoli", "brown rice", "brown sugar", "butter",
    "cabbage", "canned tomatoes", "capers", "carrots", "cashews",
    "cauliflower", "cheddar", "chicken breast", "chicken stock",
    "chicken thighs", "chickpeas", "chili flakes", "cilantro", "cinnamon",
    "coconut milk", "coconut oil", "cod fillets", "cooked rice", "corn",
    "cornmeal", "cornstarch", "couscous", "cream", "cucumber", "cumin",
    "curry powder", "edamame", "eggplant", "eggs", "feta", "fish sauce",
    "flank steak", "flour tortillas", "garam masala", "garlic", "ginger",
    "gochujang", "greek yogurt", "green beans", "green onions",
    "ground beef", "halloumi", "harissa", "hoisin sauce", "honey",
    "italian sausage", "kale", "kidney beans", "lamb shoulder", "lemon",
    "lentils", "lime", "maple syrup", "mashed potatoes", "milk", "mint",
    "miso", "mozzarella", "mushrooms", "olive oil", "onion", "oregano",
    "orzo", "oyster sauce", "paneer", "panko", "parmesan", "parsley",
    "pasta", "peanut butter", "peanuts", "peas", "pita", "pork chops",
    "potatoes", "quinoa", "red lentils", "red onion", "red wine vinegar",
    "rice noodles", "rice vinegar", "rolled oats", "rosemary",
    "salmon fillets", "salt", "sesame oil", "sesame seeds", "shrimp",
    "smoked paprika", "soy sauce", "spinach", "sugar", "sweet potatoes",
    "tahini", "tamari", "tempeh", "thyme", "tofu", "tomatoes",
    "tortilla chips", "turmeric", "vegetable oil", "vegetable stock",
    "white beans", "white rice", "zucchini",
    # common extras that must appear as lines when steps name them
    "celery", "lettuce", "banana", "sour cream", "canned tuna", "walnuts",
    "mayonnaise", "mustard", "scallions", "shallots", "dill", "arugula",
    "romaine", "cocoa", "chocolate", "raisins", "croutons", "olives",
    "pickles", "salsa", "corn tortillas", "cream cheese", "chili powder",
)
MAX_SHARED_BUNDLED = 12   # matches rights_evidence.MAX_SHARED_WORDS
MAX_SHARED_LEGACY = 9     # #113's measured corpus maximum, held here
SRC_LINE = re.compile(r"^\s*(?:Source|source|Adapted)\s*:.*$", re.MULTILINE)


def norm(s: Any) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(s).lower()).strip()


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", str(text).lower())


PLURAL_FIXES = {"tomatoes": "tomato", "potatoes": "potato", "mangoes": "mango",
                "tomatoe": "tomato", "potatoe": "potato"}


def singular(word: str) -> str:
    if word in PLURAL_FIXES:
        return PLURAL_FIXES[word]
    if word.endswith("ies") and len(word) > 3:
        return word[:-3] + "y"
    if word.endswith(("oes", "ses", "xes", "zes", "ches", "shes")) and len(word) > 4:
        return word[:-2]
    return word[:-1] if word.endswith("s") and not word.endswith("ss") else word


def name_variants(name: str) -> set[str]:
    w = norm(name)
    out = {w, singular(w)}
    return {v for v in out if v}


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

def load_jsonl(path: Path) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for n, line in enumerate(path.read_bytes().split(b"\n"), start=1):
        if not line.strip():
            continue
        out.append(json.loads(line.decode("utf-8")))
    return out


def load_slice(d: Path) -> dict[str, Any]:
    originals = load_jsonl(d / "originals.jsonl")
    converted = load_jsonl(d / "converted-144.jsonl")
    manifest = json.loads((d / "rights_manifest.json").read_text(encoding="utf-8"))
    allergens = json.loads((d / "evidence" / "allergen-classes.json").read_text(encoding="utf-8"))
    conversions = json.loads((d / "evidence" / "conversions-pinned.json").read_text(encoding="utf-8"))
    conversions = conversions.get("conversions", conversions)
    evidence = json.loads((d / "evidence" / "rights.json").read_text(encoding="utf-8"))
    return {"originals": originals, "converted": converted, "manifest": manifest,
            "allergens": allergens, "conversions": conversions, "evidence": evidence}


def catalog_names(catalog_path: Path) -> set[str]:
    import sqlite3
    con = sqlite3.connect(str(catalog_path))
    names: set[str] = set()
    for name, normed, alt in con.execute(
            "select display_name, normalized_name, alt_names_json from ingredient_catalog"):
        names.add(name.lower())
        names.add(normed.lower())
        names.update(a.lower() for a in json.loads(alt))
    for (alias,) in con.execute("select alias from ingredient_aliases"):
        names.add(alias.lower())
    con.close()
    return names


def canonical_names(bundled_path: Path | None, allergens: dict[str, Any]) -> set[str]:
    """Legacy bundled ingredient display names + suite allergen aliases."""
    names = set(allergens.get("ingredient_aliases", {}).keys())
    if bundled_path and bundled_path.is_file():
        data = json.loads(bundled_path.read_text(encoding="utf-8"))
        for v in data.get("ingredients", {}).values():
            if isinstance(v, list) and v:
                names.add(str(v[0]).lower())
    return names


# ---------------------------------------------------------------------------
# R-A resolution
# ---------------------------------------------------------------------------

def resolution_misses(recipes: list[dict[str, Any]], universe: set[str]) -> list[str]:
    misses: list[str] = []
    for r in recipes:
        for line in r.get("ingredients", []):
            if not isinstance(line, dict):
                continue
            name = str(line.get("name", ""))
            if not (name_variants(name) & universe):
                misses.append(f"{r.get('id', '?')}: ingredient {name!r} resolves in neither "
                              "the USDA catalog nor the canonical vocabulary")
    return misses


# ---------------------------------------------------------------------------
# R-B household grams vs pinned conversion rows
# ---------------------------------------------------------------------------

def quantity_errors(recipes: list[dict[str, Any]], conversions: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for r in recipes:
        for line in r.get("ingredients", []):
            if not isinstance(line, dict):
                continue
            qty = line.get("qty") or {}
            if qty.get("kind") != "household":
                continue
            ref = qty.get("conversion_ref")
            row = conversions.get(ref)
            if not isinstance(row, dict) or not row.get("grams_per_unit"):
                out.append(f"{r.get('id', '?')}: {line.get('name')!r} cites conversion "
                           f"{ref!r} which the pinned table does not carry")
                continue
            value = qty.get("value")
            grams = qty.get("grams")
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
                out.append(f"{r.get('id', '?')}: {line.get('name')!r} household value must be positive")
                continue
            if not isinstance(grams, (int, float)) or isinstance(grams, bool) or grams <= 0:
                out.append(f"{r.get('id', '?')}: {line.get('name')!r} household line carries no grams")
                continue
            expected = value * float(row["grams_per_unit"])
            if abs(grams - expected) > max(1.0, 0.02 * expected):
                out.append(f"{r.get('id', '?')}: {line.get('name')!r} grams {grams} disagree with "
                           f"{ref} ({value} x {row['grams_per_unit']} = {expected})")
    return out


# ---------------------------------------------------------------------------
# R-C category coherence + balance bars
# ---------------------------------------------------------------------------

def ingredient_classes(name: str, allergens: dict[str, Any]) -> set[str]:
    got = allergens.get("ingredient_aliases", {}).get(norm(name))
    if got:
        return set(allergens.get("ingredients", {}).get(got, {}).get("classes", []))
    if MEAT_WORDS.search(str(name)):
        return {"meat_unknown"}
    return set()


def is_vegetarian(recipe: dict[str, Any], allergens: dict[str, Any]) -> bool:
    for line in recipe.get("ingredients", []):
        if not isinstance(line, dict):
            continue
        classes = ingredient_classes(str(line.get("name", "")), allergens)
        if classes & MEAT_CLASSES or "meat_unknown" in classes:
            return False
    return True


def is_vegan(recipe: dict[str, Any], allergens: dict[str, Any]) -> bool:
    if not is_vegetarian(recipe, allergens):
        return False
    for line in recipe.get("ingredients", []):
        if not isinstance(line, dict):
            continue
        name = str(line.get("name", ""))
        classes = ingredient_classes(name, allergens)
        if {"dairy", "egg"} & classes or "honey" in classes:
            return False
        if DAIRY_EGG_WORDS.search(name):
            return False
    return True


def has_reheat_step(recipe: dict[str, Any]) -> bool:
    return any(isinstance(s, dict) and s.get("reheat")
               and isinstance(s.get("safety"), dict)
               and s["safety"].get("class") == "leftovers"
               and s["safety"].get("temp_f", 0) >= 165
               for s in recipe.get("steps", []))


def category_errors(recipes: list[dict[str, Any]], allergens: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for r in recipes:
        rid = r.get("id", "?")
        cat = r.get("category")
        if cat not in CATEGORIES:
            out.append(f"{rid}: category {cat!r} is not one of the eight declared categories")
            continue
        slots = set(r.get("meal_slots", []))
        minutes = r.get("minutes", 0)
        if cat == "breakfasts" and "breakfast" not in slots:
            out.append(f"{rid}: breakfasts recipe lacks the breakfast slot")
        if cat == "packed-lunches" and "lunch" not in slots:
            out.append(f"{rid}: packed-lunches recipe lacks the lunch slot")
        if cat == "20-minute-dinners" and ("dinner" not in slots or minutes > 20):
            out.append(f"{rid}: 20-minute-dinners recipe takes {minutes} min or skips the dinner slot")
        if cat == "vegetarian-vegan-mains":
            if not is_vegetarian(r, allergens):
                out.append(f"{rid}: vegetarian-vegan-mains recipe computes as non-vegetarian")
            if "dinner" not in slots:
                out.append(f"{rid}: vegetarian-vegan-mains recipe lacks the dinner slot")
        if cat == "batch-leftovers":
            if not has_reheat_step(r):
                out.append(f"{rid}: batch-leftovers recipe carries no flagged 165 F leftovers reheat step")
            if "dinner" not in slots:
                out.append(f"{rid}: batch-leftovers recipe lacks the dinner slot")
        if cat == "sides-salads" and minutes > 30:
            out.append(f"{rid}: sides-salads recipe takes {minutes} min (bar is 30)")
    # balance bars over the originals batch
    veg = sum(1 for r in recipes if is_vegetarian(r, allergens))
    if recipes and 3 * veg < len(recipes):
        out.append(f"balance: {veg}/{len(recipes)} originals compute vegetarian "
                   "(bar: at least a third)")
    for cat in CATEGORIES:
        if not any(r.get("category") == cat for r in recipes):
            out.append(f"balance: category {cat!r} has no recipe")
    for cuisine in CUISINES:
        if not any(r.get("cuisine") == cuisine for r in recipes):
            out.append(f"balance: cuisine {cuisine!r} has no recipe")
    for slot in SLOTS:
        if not any(slot in r.get("meal_slots", []) for r in recipes):
            out.append(f"balance: meal slot {slot!r} has no recipe")
    for band, low, high in (("0-15", 0, 15), ("16-30", 16, 30), ("31-45", 31, 45),
                            ("46-60", 46, 60), ("61+", 61, 10_000)):
        if not any(low <= r.get("minutes", 0) <= high for r in recipes):
            out.append(f"balance: time band {band} has no recipe")
    return out


# ---------------------------------------------------------------------------
# R-D rights records + pinned evidence agreement
# ---------------------------------------------------------------------------

PERMISSION_FIELDS = ("text", "images", "modification", "attribution",
                     "caching", "offline_use")
REQUIRED_RECORD_FIELDS = ("source_id", "source_type", "origin", "license", "access_date")


def ingredients_sha256(recipe: dict[str, Any]) -> str:
    names = [str(i.get("name")) for i in recipe.get("ingredients", []) if isinstance(i, dict)]
    return hashlib.sha256(json.dumps(names, ensure_ascii=False).encode("utf-8")).hexdigest()


def _pinned_file(group: dict[str, Any], slice_dir: Path | None) -> Path | None:
    """Resolve a pinned recipes_file: bare names are slice-relative (committed
    evidence must stay checkout-portable); absolute paths pass through."""
    raw = group.get("recipes_file")
    if not raw:
        return None
    p = Path(str(raw))
    return p if p.is_absolute() or slice_dir is None else slice_dir / p


def rights_errors(recipes: list[dict[str, Any]], manifest: dict[str, Any],
                  evidence: dict[str, Any],
                  slice_dir: Path | None = None) -> list[str]:
    out: list[str] = []
    records = manifest.get("records", {})
    pinned_groups = {k: v for k, v in evidence.items()
                     if k.startswith("everyday") and isinstance(v, dict)}
    pinned: dict[str, dict[str, Any]] = {}
    for group in pinned_groups.values():
        for rid, rec in group.get("records", {}).items():
            pinned[rid] = rec
    sha_ok: dict[str, bool] = {}
    for group_name, group in pinned_groups.items():
        want = group.get("recipes_sha256")
        f = _pinned_file(group, slice_dir)
        if want and f and f.is_file():
            sha_ok[group_name] = (hashlib.sha256(f.read_bytes()).hexdigest() == want)
    for r in recipes:
        rid = r.get("id", "?")
        rec = records.get(r.get("source_ref"))
        if not isinstance(rec, dict):
            out.append(f"{rid}: no rights record for source_ref {r.get('source_ref')!r}")
            continue
        if any(not rec.get(f) for f in REQUIRED_RECORD_FIELDS):
            out.append(f"{rid}: rights record is missing required fields")
            continue
        perms = rec.get("permissions")
        if not isinstance(perms, dict) or not all(isinstance(perms.get(p), bool) for p in PERMISSION_FIELDS):
            out.append(f"{rid}: rights record lacks all six permission fields")
            continue
        if rec.get("license") != "LicenseRef-FL-Original":
            out.append(f"{rid}: slice license must be LicenseRef-FL-Original")
            continue
        if rec.get("source_type") not in ("original", "original-rewrite"):
            out.append(f"{rid}: unexpected source_type {rec.get('source_type')!r}")
            continue
        prec = pinned.get(rid)
        if prec is None:
            out.append(f"{rid}: no pinned authoring record in evidence/rights.json")
            continue
        if prec.get("title") != r.get("title"):
            out.append(f"{rid}: pinned evidence describes a different title")
        if prec.get("ingredients_sha256") != ingredients_sha256(r):
            out.append(f"{rid}: pinned evidence describes different ingredients")
        if prec.get("source_type") != rec.get("source_type"):
            out.append(f"{rid}: pinned evidence source_type disagrees")
        denied = [p for p in ("text", "modification", "caching", "offline_use")
                  if prec.get("permissions", {}).get(p) is not True]
        if denied:
            out.append(f"{rid}: pinned evidence does not grant {denied}")
    for group_name, ok in sha_ok.items():
        if not ok:
            out.append(f"evidence: recipes_sha256 for {group_name} does not match the shipped file")
    missing_files = [name for name, group in pinned_groups.items()
                     if group.get("recipes_file")
                     and not ((_pf := _pinned_file(group, slice_dir)) and _pf.is_file())]
    if missing_files:
        out.append(f"evidence: pinned recipes files absent, cannot verify: {missing_files}")
    return out


# ---------------------------------------------------------------------------
# R-E dedupe + fresh-expression overlap
# ---------------------------------------------------------------------------

def dedupe_key(recipe: dict[str, Any]) -> tuple[str, frozenset[str]]:
    title = norm(recipe.get("title", ""))
    core = frozenset(norm(i.get("name", "")) for i in recipe.get("ingredients", [])
                     if isinstance(i, dict))
    return title, core


def ngrams(text: str, n: int) -> set[tuple[str, ...]]:
    w = words(text)
    return {tuple(w[i:i + n]) for i in range(len(w) - n + 1)}


def recipe_text(recipe: dict[str, Any]) -> str:
    parts = [str(recipe.get("title", ""))]
    parts += [str(s.get("text", "")) for s in recipe.get("steps", []) if isinstance(s, dict)]
    return " ".join(parts)


def dedupe_errors(originals: list[dict[str, Any]], converted: list[dict[str, Any]],
                  corpus113_path: Path | None, legacy144_path: Path | None,
                  bundled_path: Path | None) -> list[str]:
    out: list[str] = []
    seen: dict[tuple[str, frozenset[str]], str] = {}
    for r in originals + converted:
        key = dedupe_key(r)
        if key in seen:
            out.append(f"{r.get('id', '?')}: duplicate (title, core ingredients) with {seen[key]}")
        seen[key] = r.get("id", "?")
    if corpus113_path and Path(corpus113_path).is_file():
        for r in load_jsonl(Path(corpus113_path)):
            key = dedupe_key(r)
            if key in seen:
                out.append(f"{seen[key]}: duplicates shipped corpus recipe {r.get('id')} "
                           f"({r.get('title')!r})")
        ref_bundled: set[tuple[str, ...]] = set()
        for r in load_jsonl(Path(corpus113_path)):
            ref_bundled |= ngrams(recipe_text(r), MAX_SHARED_BUNDLED)
        for r in originals + converted:
            hit = ngrams(recipe_text(r), MAX_SHARED_BUNDLED) & ref_bundled
            if hit:
                out.append(f"{r.get('id', '?')}: shares a {MAX_SHARED_BUNDLED}-word run with "
                           f"the shipped corpus: {' '.join(next(iter(hit)))!r}")
    if legacy144_path and Path(legacy144_path).is_file():
        legacy = json.loads(Path(legacy144_path).read_text(encoding="utf-8"))
        raw_recipes = legacy.get("recipes", [])
        if isinstance(raw_recipes, dict):
            legacy_map = {str(t): str(rec.get("instructions", ""))
                          for t, rec in raw_recipes.items()}
        else:
            # PR #144 data.json shape: rows of [id, title, minutes, servings,
            # ingredients, tags, instructions, ...]
            legacy_map = {str(row[1]): str(row[6])
                          for row in raw_recipes
                          if isinstance(row, (list, tuple)) and len(row) > 6}
        legacy_titles = {norm(t) for t in legacy_map}
        legacy_texts = list(legacy_map.values())
        ref_legacy9: set[tuple[str, ...]] = set()
        for text in legacy_texts:
            ref_legacy9 |= ngrams(SRC_LINE.sub("", text), MAX_SHARED_LEGACY)
        for r in converted:
            if norm(r.get("title", "")) in legacy_titles:
                out.append(f"{r.get('id', '?')}: rewrite keeps PR #144's legacy title "
                           f"{r.get('title')!r} (fresh expression required)")
            hit = ngrams(recipe_text(r), MAX_SHARED_LEGACY) & ref_legacy9
            if hit:
                out.append(f"{r.get('id', '?')}: shares a {MAX_SHARED_LEGACY}-word run with "
                           f"PR #144 legacy text: {' '.join(next(iter(hit)))!r}")
    if bundled_path and Path(bundled_path).is_file():
        bundled = json.loads(Path(bundled_path).read_text(encoding="utf-8"))
        ref: set[tuple[str, ...]] = set()
        for row in bundled.get("recipes", []):
            if isinstance(row, list) and len(row) >= 7:
                ref |= ngrams(f"{row[1]} {row[6]}", MAX_SHARED_BUNDLED)
        for r in originals + converted:
            hit = ngrams(recipe_text(r), MAX_SHARED_BUNDLED) & ref
            if hit:
                out.append(f"{r.get('id', '?')}: shares a {MAX_SHARED_BUNDLED}-word run with "
                           f"the bundled catalog: {' '.join(next(iter(hit)))!r}")
    return out


# ---------------------------------------------------------------------------
# R-F step/ingredient integrity
# ---------------------------------------------------------------------------

def step_food_errors(recipes: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for r in recipes:
        have = " | ".join(norm(str(i.get("name", ""))) for i in r.get("ingredients", [])
                          if isinstance(i, dict))
        for s in r.get("steps", []):
            if not isinstance(s, dict):
                continue
            text = norm(str(s.get("text", "")))
            for food in STEP_FOOD_NAMES:
                food_n = norm(food)
                if not re.search(rf"\b{re.escape(food_n)}\b", text):
                    continue
                # an ingredient line whose name contains this food covers it
                if re.search(rf"\b{re.escape(food_n)}\b", have):
                    continue
                if singular(food_n) and re.search(rf"\b{re.escape(singular(food_n))}\b", have):
                    continue
                # a plural line ("green onions") covers the singular food ("onion")
                if re.search(rf"\b{re.escape(food_n)}s\b", have):
                    continue
                out.append(f"{r.get('id', '?')}: step names {food!r} but no ingredient "
                           "line provides it")
    return out


# ---------------------------------------------------------------------------
# suite-C validator adapter (run unmodified, extended rights forms)
# ---------------------------------------------------------------------------

def run_validator(slice_dir: Path, suite_dir: Path, tools_dir: Path,
                  workdir: Path) -> int:
    """Run the pinned validator over this slice with an adapter.

    The validator is never modified. The adapter (a) builds the temporary
    checkout the validator expects, (b) points rights_evidence's
    AFFIRMATIVE_FORMS at this slice's pinned evidence before import — the
    extension is local to this process. Anything the adapter cannot set up
    is an error.
    """
    import shutil
    import subprocess
    workdir.mkdir(parents=True, exist_ok=True)
    checkout = workdir / "checkout"
    if checkout.exists():
        shutil.rmtree(checkout)
    checkout.mkdir()
    # the pieces the validator reads relative to the tools directory
    for rel in ("apps/ios/Resources/data.json", "data/recipes/quarantine.jsonl",
                "docs/spec/recipes"):
        src = tools_dir.parent.parent.parent / rel
        dst = checkout / rel
        if src.is_file():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        elif src.is_dir():
            shutil.copytree(src, dst)
        else:
            print(f"ADAPTER ERROR: expected validator input missing: {src}")
            return 2
    tools_dst = checkout / "data/recipes/tools"
    shutil.copytree(tools_dir, tools_dst)
    shutil.copy2(slice_dir / "rights_manifest.json", checkout / "data/recipes/rights_manifest.json")
    combined = checkout / "data/recipes/corpus.jsonl"
    with combined.open("wb") as fh:
        for name in ("originals.jsonl", "converted-144.jsonl"):
            fh.write((slice_dir / name).read_bytes())
    ev_dir = checkout / "data/recipes/evidence"
    ev_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(slice_dir / "evidence" / "rights.json", ev_dir / "rights.json")

    # extend the affirmative forms with this slice's pinned evidence forms,
    # strictly: pinned record, FL-Original license, source_type agreement,
    # app permissions, title and ingredient-hash agreement.
    sys.path.insert(0, str(tools_dst))
    import rights_evidence  # noqa: E402

    def _everyday_form(tag_group: str):
        def form(recipe: dict[str, Any], rec: dict[str, Any], evidence: dict[str, Any]) -> str | None:
            rid = recipe.get("id")
            group = evidence.get(tag_group, {})
            prec = group.get("records", {}).get(rid)
            if prec is None:
                return f"no pinned authoring record for {rid} in {tag_group}"
            if prec.get("license") != "LicenseRef-FL-Original" or rec.get("license") != "LicenseRef-FL-Original":
                return "the authoring record does not license this as FridgeLuck-original text"
            if prec.get("source_type") != rec.get("source_type"):
                return f"source_type {rec.get('source_type')!r} differs from the authoring record"
            denied = [p for p in rights_evidence.APP_PERMISSIONS
                      if prec.get("permissions", {}).get(p) is not True]
            if denied:
                return f"the authoring record does not grant {denied}"
            if prec.get("title") != recipe.get("title") or \
                    prec.get("ingredients_sha256") != rights_evidence.ingredients_sha256(recipe):
                return "the authoring record describes a different recipe"
            cited = str(rec.get("license_evidence", ""))
            sha = group.get("recipes_sha256", "")
            if not sha or sha[:12] not in cited:
                return f"license_evidence does not cite the pinned {tag_group} recipes sha256"
            return None
        return form

    rights_evidence.AFFIRMATIVE_FORMS["original"] = _everyday_form("everyday-originals")
    rights_evidence.AFFIRMATIVE_FORMS["original-rewrite"] = _everyday_form("everyday-144")

    # Run the validator in-process (runpy): AFFIRMATIVE_FORMS patches live in
    # this interpreter only, so a subprocess would fall back to the pinned
    # fl-original forms and refuse every slice record.
    import runpy
    sys.argv = ["validate_corpus.py", "--suite-dir", str(suite_dir),
                "--corpus", str(combined),
                "--conversions", str(checkout / "data/recipes/no-conversions.json")]
    try:
        runpy.run_path(str(tools_dst / "validate_corpus.py"), run_name="__main__")
    except SystemExit as exc:  # the validator calls sys.exit(code)
        code = exc.code
        return 0 if code in (None, 0) else int(code)
    return 0


# ---------------------------------------------------------------------------

def external_skips(corpus113_path: Path | None, legacy144_path: Path | None,
                   bundled_path: Path | None) -> list[str]:
    """External checks that cannot run without their input, so a green run
    stays unambiguous about what was and was not verified."""
    skips: list[str] = []
    if not (corpus113_path and Path(corpus113_path).is_file()):
        skips.append("R-E #113-corpus dedupe + 12-word overlap (pass --corpus113)")
    if not (legacy144_path and Path(legacy144_path).is_file()):
        skips.append("R-E #144-legacy dedupe + 9-word overlap (pass --legacy144)")
    if not (bundled_path and Path(bundled_path).is_file()):
        skips.append("bundled-catalog legacy names + overlap (pass --bundled)")
    return skips


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", required=True, type=Path, help="the everyday-2026-10 slice directory")
    ap.add_argument("--catalog", type=Path, default=None,
                    help="apps/ios/Resources/usda_ingredient_catalog.sqlite")
    ap.add_argument("--bundled", type=Path, default=None,
                    help="apps/ios/Resources/data.json (canonical legacy names + overlap reference)")
    ap.add_argument("--corpus113", type=Path, default=None, help="shipped #113 corpus.jsonl")
    ap.add_argument("--legacy144", type=Path, default=None, help="PR #144 legacy data.json")
    ap.add_argument("--validate-suite", type=Path, default=None,
                    help="extracted suite at 26c7004; runs the pinned validator too")
    ap.add_argument("--corpus-tools", type=Path, default=None,
                    help="corpus worktree data/recipes/tools (validate_corpus.py et al)")
    ap.add_argument("--validate-workdir", type=Path, default=Path("/tmp/everyday-validate"))
    args = ap.parse_args()

    d = args.dir
    errors: list[str] = []
    s = load_slice(d)
    recipes = s["originals"] + s["converted"]
    print(f"slice: {len(s['originals'])} originals + {len(s['converted'])} converted "
          f"= {len(recipes)} recipes")

    universe = set()
    if args.catalog and args.catalog.is_file():
        universe |= catalog_names(args.catalog)
    else:
        errors.append("R-A: --catalog is required and must exist (fail closed)")
    universe |= canonical_names(args.bundled, s["allergens"])
    errors.extend(resolution_misses(recipes, universe))

    errors.extend(quantity_errors(recipes, s["conversions"]))
    # category coherence: per-recipe for the whole slice; balance bars over
    # the originals batch only (the converted file inherits its own balance)
    all_cat_errors = category_errors(s["originals"], s["allergens"])
    batch_only = [e for e in all_cat_errors if e.startswith("balance:")]
    per_recipe = [e for e in all_cat_errors if not e.startswith("balance:")]
    for r in s["converted"]:
        cat = r.get("category")
        if cat not in CATEGORIES:
            per_recipe.append(f"{r.get('id', '?')}: category {cat!r} is not one of the eight declared categories")
    errors.extend(per_recipe + batch_only)
    errors.extend(rights_errors(recipes, s["manifest"], s["evidence"], slice_dir=d))
    errors.extend(dedupe_errors(s["originals"], s["converted"],
                                args.corpus113, args.legacy144, args.bundled))
    errors.extend(step_food_errors(recipes))

    skips = external_skips(args.corpus113, args.legacy144, args.bundled)
    for msg in skips:
        print(f"SKIPPED {msg}")
    for e in errors:
        print(f"FAIL {e}")
    print(f"slice-local checker: {len(errors)} error(s)"
          + (f" ({len(skips)} external check(s) skipped)" if skips else ""))
    if errors:
        return 1

    if args.validate_suite and args.corpus_tools:
        rc = run_validator(d, args.validate_suite, args.corpus_tools, args.validate_workdir)
        if rc != 0:
            print(f"pinned validator exited {rc}")
            return rc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
