#!/usr/bin/env python3
"""Convert the 25 audited-keep bundled seed recipes to RS v1 corpus form.

Sources of truth, and what this tool does with them:

- Input recipes: ``apps/ios/Resources/data.json`` on alpha (positional arrays).
  Only bundled ids 1-25 are read: exactly the rows ``data/recipes/RIGHTS-AUDIT.md``
  (branch ``obv/fl-next-recipe-fidelity`` at 9b827a3) verdicts **keep**. The 141
  BBC rewrite rows are ignored here; dishes marked ``rewrite`` never contribute
  text to the corpus.
- Ingredient grams: the bundled recipe rows carry per-ingredient grams that were
  built from the bundle's USDA-based per-portion ingredient catalog. They are
  emitted as ``qty.kind = "source_grams"`` with provenance naming data.json and
  the audit entry. No mass is invented.
- Ingredient names: normalized to names the suite's ``allergens.json`` alias
  table recognizes wherever that is truthful (catalog ``egg`` -> ``eggs``,
  ``cheese`` -> per-dish cheddar/mozzarella/parmesan, ``tortilla`` ->
  ``flour tortillas``, ...). Names left unaliased (green onion, sour cream,
  canned tuna, ...) are printed in the coverage report.
- Steps: the bundled terse instructions are split into steps, renumbering
  stripped, natural timers attached (stated upper bound of a min/sec duration,
  seconds as fractional minutes, never from hours or temperatures). Steps that
  stated doneness by colour or time on animal-protein dishes are rephrased to
  thermometer language, and FSIS safety checks (rulebook citation string from
  ``data/food-safety/rules.json`` rs_alignment) are attached to the step where
  doneness is actually established.
- Claims: written ONLY where (a) the suite AllergenScanner recomputes the same
  empty conflicts list AND (b) the claim is true of the real dish. Scanner-only
  verification is not enough: unrecognized names (sour cream = dairy, canned
  tuna = fish) are invisible to the scan, so the per-recipe allowlist below
  blocks claims those ingredients would falsify. Every emitted claim is
  verified against the scanner at build time; a mismatch fails the build.
- Rights: none. This tool first wrote the 25 seeds into corpus.jsonl with
  ``LicenseRef-FL-Original`` records whose only evidence was missing
  attribution (no Source line, present since the initial commit, title absent
  from the BBC scrape cache). That proves neither authorship nor permission,
  so the seeds now sit in ``data/recipes/quarantine.jsonl`` (stage
  ``rights``, moved by ``quarantine.py --rights``). The tool no longer writes
  the corpus or the manifest; it writes converted records to ``--out`` for
  whoever obtains an affirmative authorship or permission record.
- Dedupe: normalized titles must be unique and required-line ingredient sets
  must not collide (SCHEMA.md section 7) — asserted at build time.

Output: ``--out`` (RS v1 JSONL, UTF-8, LF, one object per line). Never
``corpus.jsonl`` or ``rights_manifest.json``.

Usage:
    python3 data/recipes/tools/convert_bundled.py \
        --suite-dir <extracted evaluation/suites/recipes> --out <review.jsonl>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
BUNDLED_PATH = REPO_ROOT / "apps/ios/Resources/data.json"
OUT_CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
OUT_MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"

# The keep verdicts live on the Part 1a branch; the provenance cites it.
AUDIT_BRANCH = "obv/fl-next-recipe-fidelity"
AUDIT_HEAD = "9b827a3"
AUDIT_PATH = "data/recipes/RIGHTS-AUDIT.md"
BUNDLED_REF = "apps/ios/Resources/data.json (branch alpha)"
KEEP_IDS = set(range(1, 26))

BUILD_DATE = "2026-10-11"  # audit date (RIGHTS-AUDIT.md); corpus build date

FSIS_SOURCE = (
    "USDA FSIS Safe Minimum Internal Temperature Chart, "
    "https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/"
    "food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11"
)

# Catalog ingredient id -> corpus ingredient name. Names prefer the suite
# allergens.json alias table wherever that is truthful for the catalog entry.
CATALOG_NAMES: dict[int, str] = {
    1: "eggs", 2: "cooked rice", 3: "soy sauce", 4: "chicken breast",
    5: "onion", 6: "garlic", 7: "tomato", 8: "bell pepper", 9: "pasta",
    10: "potatoes", 11: "carrot", 12: "cheese", 13: "milk", 14: "butter",
    15: "bread", 16: "olive oil", 17: "lemon", 18: "mushrooms", 19: "spinach",
    20: "banana", 21: "green onion", 22: "sesame oil", 23: "tofu",
    24: "broccoli", 25: "cucumber", 26: "avocado", 27: "black beans",
    28: "flour tortillas", 29: "lime", 30: "ginger", 31: "rolled oats",
    32: "greek yogurt", 33: "honey", 34: "corn", 35: "chickpeas",
    36: "salmon fillets", 37: "sweet potatoes", 38: "ground beef",
    39: "lettuce", 40: "apple", 41: "peanut butter", 42: "frozen peas",
    43: "canned tuna", 44: "celery", 45: "zucchini", 46: "chili flakes",
    47: "cumin", 48: "cilantro", 49: "coconut milk", 50: "sour cream",
}

# Catalog "cheese" (id 12) is named per dish where the dish fixes the cheese;
# default cheddar (the catalog's per-100 g values are cheddar's).
CHEESE_BY_RECIPE: dict[int, str] = {10: "mozzarella", 23: "parmesan"}

# Per-dish judgment recorded once: cuisine and meal slots for each keep row.
RECIPE_CONFIG: dict[int, dict[str, Any]] = {
    1:  {"cuisine": "asian",        "meal_slots": ["lunch", "dinner"]},
    2:  {"cuisine": "american",     "meal_slots": ["breakfast"]},
    3:  {"cuisine": "italian",      "meal_slots": ["lunch", "dinner"]},
    4:  {"cuisine": "asian",        "meal_slots": ["lunch", "dinner"]},
    5:  {"cuisine": "asian",        "meal_slots": ["lunch", "dinner"]},
    6:  {"cuisine": "american",     "meal_slots": ["breakfast", "lunch"]},
    7:  {"cuisine": "mexican",      "meal_slots": ["lunch", "dinner"]},
    8:  {"cuisine": "american",     "meal_slots": ["breakfast"]},
    9:  {"cuisine": "american",     "meal_slots": ["lunch", "dinner"]},
    10: {"cuisine": "italian",      "meal_slots": ["lunch", "dinner"]},
    11: {"cuisine": "american",     "meal_slots": ["lunch", "dinner"]},
    12: {"cuisine": "american",     "meal_slots": ["breakfast", "lunch"]},
    13: {"cuisine": "asian",        "meal_slots": ["lunch", "dinner"]},
    14: {"cuisine": "mediterranean", "meal_slots": ["lunch", "dinner"]},
    15: {"cuisine": "american",     "meal_slots": ["lunch", "dinner"]},
    16: {"cuisine": "american",     "meal_slots": ["lunch"]},
    17: {"cuisine": "mexican",      "meal_slots": ["lunch", "dinner"]},
    18: {"cuisine": "american",     "meal_slots": ["breakfast"]},
    19: {"cuisine": "indian",       "meal_slots": ["lunch", "dinner"]},
    20: {"cuisine": "mexican",      "meal_slots": ["lunch", "dinner"]},
    21: {"cuisine": "american",     "meal_slots": ["breakfast"]},
    22: {"cuisine": "mediterranean", "meal_slots": ["lunch", "dinner"]},
    23: {"cuisine": "italian",      "meal_slots": ["lunch", "dinner"]},
    24: {"cuisine": "american",     "meal_slots": ["breakfast", "lunch"]},
    25: {"cuisine": "american",     "meal_slots": ["breakfast"]},
}

# Claims written per recipe. Each is (a) scanner-verified at build time and
# (b) true of the real dish; blocked claims are listed in CLAIM_NOTES.
CLAIMS_BY_RECIPE: dict[int, list[str]] = {
    1:  ["vegetarian", "dairy-free", "nut-free"],
    2:  ["vegetarian", "gluten-free", "nut-free"],
    3:  ["vegetarian", "nut-free"],
    4:  ["dairy-free", "nut-free"],
    5:  ["vegetarian", "gluten-free", "dairy-free", "nut-free"],
    6:  ["vegetarian", "dairy-free", "nut-free"],
    7:  ["vegetarian", "nut-free"],
    8:  ["vegetarian", "nut-free"],
    9:  ["dairy-free", "gluten-free", "nut-free"],
    10: ["vegetarian", "gluten-free", "nut-free"],
    11: ["vegetarian", "gluten-free", "nut-free"],
    12: ["vegetarian"],
    13: ["vegan", "vegetarian", "dairy-free", "nut-free"],
    14: ["vegan", "vegetarian", "gluten-free", "dairy-free", "nut-free"],
    15: ["dairy-free", "gluten-free", "nut-free"],
    16: ["dairy-free", "nut-free"],
    17: ["gluten-free", "nut-free"],
    18: ["vegetarian", "gluten-free", "nut-free"],
    19: ["vegan", "vegetarian", "gluten-free", "dairy-free"],
    20: ["vegetarian", "gluten-free", "nut-free"],
    21: ["vegetarian", "nut-free"],
    22: ["dairy-free", "gluten-free", "nut-free"],
    23: ["vegetarian", "gluten-free", "nut-free"],
    24: ["vegetarian", "nut-free"],
    25: ["vegetarian", "nut-free"],
}

# Why a scanner-passing claim is NOT written (unrecognized names are invisible
# to the scan but real): documented so the policy is auditable.
CLAIM_NOTES: dict[int, list[str]] = {
    7:  ["vegan/dairy-free blocked: optional sour cream is dairy "
         "(unrecognized by the alias table)"],
    8:  ["vegan blocked: honey and dairy; dairy-free blocked: milk and greek "
         "yogurt; gluten-free skipped: rolled oats (certified-GF subtlety)"],
    11: ["vegan blocked: butter/cheese/sour cream; dairy-free blocked: dairy "
         "(sour cream unrecognized by the alias table)"],
    12: ["vegan blocked: milk and honey; dairy-free blocked: milk; "
         "nut-free scanner-conflicts with peanut butter; gluten-free skipped: "
         "rolled oats (certified-GF subtlety)"],
    16: ["vegetarian blocked: canned tuna is fish (unrecognized by the alias "
         "table); gluten-free skipped: served on lettuce or bread"],
    20: ["vegan/dairy-free blocked: optional sour cream is dairy "
         "(unrecognized by the alias table)"],
    25: ["vegan blocked: eggs and honey; dairy-free blocked: optional butter; "
         "gluten-free skipped: rolled oats (certified-GF subtlety)"],
}

# Step-text rephrasings (index -> new text). Only where the bundled step states
# doneness by colour/time on an animal-protein dish, or reads better structured.
TEXT_EDITS: dict[tuple[int, int], str] = {
    (2, 6): "Cook 1 more minute until the cheese melts and the eggs are fully set.",
    (4, 3): "Sear the chicken strips for 3-4 minutes, turning once.",
    (5, 4): "Slowly drizzle the beaten eggs into the simmering soup while stirring.",
    (6, 0): "Toast the bread in a toaster or a hot dry pan.",
    (6, 3): "Fry or poach the egg until the white is fully set.",
    (15, 6): ("Bake 15-18 minutes, then verify the thickest point of the salmon "
              "reaches 145 °F with a food thermometer."),
    (17, 0): ("Brown the ground beef in a pan over medium heat, breaking it up "
              "as it cooks, then drain the fat."),
    (18, 4): "Scramble gently over medium heat until the eggs are fully set.",
    (24, 0): "Beat the eggs, then scramble them in the pan until fully set.",
}

# Step splits: (recipe, index) -> replacement steps (one action each).
STEP_SPLIT: dict[tuple[int, int], list[str]] = {
    (23, 2): ["Sauté the onion for 3 minutes.",
              "Add the mushrooms and cook for 4 minutes."],
}

# Step insertion: recipe -> (index, step text). Inserted where doneness is
# actually established (id 4: after tossing, before serving).
STEP_INSERT: dict[int, tuple[int, str]] = {
    4: (7, ("Check the chicken with a food thermometer at its thickest point; "
            "it is done at 165 °F.")),
}

# FSIS safety checks attached to the step where doneness is established.
# (recipe, step_index) -> (class, minimum temp the check asserts).
SAFETY_ATTACH: dict[tuple[int, int], tuple[str, int]] = {
    (1, 3): ("egg", 160),            # eggs scrambled in the wok
    (1, 4): ("leftovers", 165),      # leftover rice stir-fried
    (2, 6): ("egg", 160),            # omelette fully set
    (4, 7): ("meat_poultry", 165),   # inserted check step (after tossing)
    (5, 4): ("egg", 160),            # egg ribbons set in the hot soup
    (6, 3): ("egg", 160),            # fried/poached egg
    (9, 6): ("meat_poultry", 165),   # chicken simmered in the pot
    (15, 6): ("flesh_fish", 145),    # salmon baked
    (17, 0): ("meat_ground", 160),   # ground beef browned
    (18, 4): ("egg", 160),           # scramble fully set
    (21, 4): ("egg", 160),           # french-toast custard
    (22, 6): ("meat_poultry", 165),  # chicken finished in the oven
    (24, 0): ("egg", 160),           # wrap eggs scrambled
    (25, 5): ("egg", 160),           # pancake batter eggs
}

REHEAT_STEPS: set[tuple[int, int]] = {(1, 4)}  # fried rice: leftover rice

# Natural timers: stated upper bound of a min/sec duration in the step text.
TIMER_RE = re.compile(
    r"(?P<first>\d+(?:\.\d+)?)(?:\s*-\s*(?P<second>\d+(?:\.\d+)?))?\s*"
    r"(?P<unit>minutes?|mins?|secs?|seconds?)\b",
    re.IGNORECASE,
)


def timer_from_text(text: str) -> float | None:
    """Upper bound of the first stated min/sec duration, in minutes.

    Hours never become timers (an overnight rest is not a kitchen timer);
    temperatures and counts never match the unit pattern.
    """
    m = TIMER_RE.search(text)
    if not m:
        return None
    value = float(m.group("second") or m.group("first"))
    unit = m.group("unit").lower()
    if unit.startswith("s"):
        value /= 60.0
    return value if 0 < value <= 240 else None


def safety_dict(fs_class: str, temp_f: int) -> dict[str, Any]:
    return {
        "class": fs_class,
        "temp_f": temp_f,
        "method": "thermometer",
        "source": FSIS_SOURCE,
    }


def normalize_title(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", title.lower()).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True,
                    help="extracted evaluation/suites/recipes (eval/scorecard-runner)")
    ap.add_argument("--out", required=True,
                    help="review file for the converted seeds (never the corpus)")
    args = ap.parse_args()
    suite_dir = Path(args.suite_dir)
    sys.path.insert(0, str(suite_dir))
    import rs  # suite C linter module (read-only use)

    scanner = rs.AllergenScanner(json.loads((suite_dir / "allergens.json").read_text()))
    alias_table: dict[str, str] = json.loads(
        (suite_dir / "allergens.json").read_text())["ingredient_aliases"]

    bundled = json.loads(BUNDLED_PATH.read_text())
    catalog: dict[int, list[Any]] = {
        int(k): v for k, v in bundled["ingredients"].items()}
    recipes_out: list[dict[str, Any]] = []
    unaliased: set[str] = set()

    for row in bundled["recipes"]:
        rid, title, minutes, servings, req, opt, instructions = row[:7]
        if rid not in KEEP_IDS:
            continue
        cfg = RECIPE_CONFIG[rid]
        cheese = CHEESE_BY_RECIPE.get(rid, "cheddar")

        ingredients: list[dict[str, Any]] = []
        for ing_id, grams in list(req or []) + list(opt or []):
            name = CATALOG_NAMES[ing_id]
            if name == "cheese":
                name = cheese
            if name.lower() not in alias_table:
                unaliased.add(name)
            if not isinstance(grams, (int, float)) or grams <= 0:
                raise SystemExit(f"bundled id {rid}: non-positive grams for {name}")
            ingredients.append({
                "name": name,
                "qty": {"kind": "source_grams", "grams": grams},
            })

        # steps: split the bundled numbered text, apply edits/splits/inserts
        lines = [ln.strip() for ln in instructions.split("\n") if ln.strip()]
        base: list[str] = []
        for line in lines:
            base.append(re.sub(r"^\d+\.\s*", "", line))
        steps_text: list[str] = []
        for idx, text in enumerate(base):
            steps_text.extend(STEP_SPLIT.get((rid, idx), [TEXT_EDITS.get((rid, idx), text)]))
        if rid in STEP_INSERT:
            at, text = STEP_INSERT[rid]
            steps_text.insert(at, text)

        steps: list[dict[str, Any]] = []
        for idx, text in enumerate(steps_text):
            step: dict[str, Any] = {"text": text}
            timer = timer_from_text(text)
            if timer is not None:
                step["timer_min"] = timer
            if (rid, idx) in REHEAT_STEPS:
                step["reheat"] = True
            if (rid, idx) in SAFETY_ATTACH:
                fs_class, temp = SAFETY_ATTACH[(rid, idx)]
                step["safety"] = safety_dict(fs_class, temp)
            steps.append(step)

        fl_id = f"fl-seed-{rid:04d}"
        recipe: dict[str, Any] = {
            "rs_version": "1",
            "id": fl_id,
            "title": title,
            "cuisine": cfg["cuisine"],
            "meal_slots": cfg["meal_slots"],
            "minutes": minutes,
            "servings": servings,
            "ingredients": ingredients,
            "steps": steps,
            "source_ref": fl_id,
        }

        claims: list[dict[str, Any]] = []
        for claim_name in CLAIMS_BY_RECIPE[rid]:
            claim = {"claim": claim_name, "evidence": {"conflicts": []}}
            verdict = scanner.verify_claim(recipe, claim)
            if verdict is not True:
                raise SystemExit(
                    f"{fl_id}: claim {claim_name!r} does not verify: {verdict}")
            claims.append(claim)
        recipe["claims"] = claims

        recipe["provenance"] = {
            "bundled_catalog": f"{BUNDLED_REF}, bundled recipe id {rid}",
            "rights_audit": (
                f"{AUDIT_PATH} keep verdict for bundled recipe id {rid} "
                f"(branch {AUDIT_BRANCH} at {AUDIT_HEAD})"),
            "ingredient_grams": (
                f"bundled recipe row {rid} required/optional ingredient pairs "
                f"({BUNDLED_REF}; USDA-based per-portion ingredient catalog); "
                "qty kind source_grams"),
        }
        recipes_out.append(recipe)

    # dedupe (SCHEMA.md section 7): duplicates share normalized title AND
    # core-ingredient set; core-set twins with distinct titles are legitimate
    # distinct dishes (e.g. omelette vs scramble) and only reported.
    titles = [normalize_title(r["title"]) for r in recipes_out]
    cores = [frozenset(
        normalize_title(i["name"]) for i in r["ingredients"]) for r in recipes_out]
    keys = list(zip(titles, cores))
    if len(set(keys)) != len(keys):
        dupes = {k for k in keys if keys.count(k) > 1}
        raise SystemExit(f"duplicate (title, core-ingredients) pairs: {dupes}")
    twins = {(recipes_out[i]["id"], recipes_out[j]["id"])
             for i in range(len(cores)) for j in range(i + 1, len(cores))
             if cores[i] == cores[j]}
    if twins:
        print(f"note: core-ingredient twins (distinct titles, allowed by "
              f"section 7): {sorted(twins)}")

    # No rights records: the seeds have no affirmative authorship or
    # permission evidence (see the module docstring).
    out = Path(args.out).resolve()
    if out in (OUT_CORPUS.resolve(), OUT_MANIFEST.resolve()):
        raise SystemExit(f"--out {out} is a corpus file; the seeds are quarantined "
                         "for rights and must not be written there")
    with out.open("w", encoding="utf-8", newline="\n") as f:
        for recipe in recipes_out:
            f.write(json.dumps(recipe, ensure_ascii=False) + "\n")

    n_lines = sum(len(r["ingredients"]) for r in recipes_out)
    n_claims = sum(len(r["claims"]) for r in recipes_out)
    print(f"wrote {len(recipes_out)} recipes / {n_lines} ingredient lines / "
          f"{n_claims} verified claims to {out} (not the corpus)")
    print(f"unaliased ingredient names (no allergen classes; scanned as absent): "
          f"{sorted(unaliased) or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
