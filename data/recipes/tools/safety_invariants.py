#!/usr/bin/env python3
"""Shipped-bundle safety invariants — Linux-side, read-only.

Run: ``python3 -I data/recipes/tools/safety_invariants.py [bundle]``
Default bundle: ``data/recipes/build/recipes-v2.json``.

The app screens every recipe a household sees through ``HouseholdSafetyGate``
(``apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift``) over per-line
composition classes, while recipe cards and some recommendation paths read
the per-recipe claims (vegetarian, vegan, gluten_free, dairy_free). This
check proves on Linux, for every shipped recipe and every screened
household, that the claims never admit a recipe the class screen blocks,
and pins today's violations so the catalog rebuild
(burst11-fridgeluck-catalog-rebuild) can clear them.

Five rules:

1. A claim is true only when ``compile_bundle.derive_claim`` over the lines'
   classes is True (imported here — one definition, never re-derived).
   ``compile_bundle`` keeps an authored True claim where the classes cannot
   verify it (derive None), and ``validate_bundle`` fails only
   true-vs-false contradictions, so a true claim over an 'unknown' line
   ships silently.
2. A vegan claim implies the vegetarian and dairy_free claims.
3. Sweep: for every recipe and every household — the 10 allergen groups and
   4 diets each singly, plus a pinned set of multi-restriction households —
   everything the claims admit the class screen admits too. Claims speak
   only four languages (milk -> dairy_free, wheat_gluten -> gluten_free,
   vegetarian -> vegetarian, vegan -> vegan). A household with any other
   restriction is never claim-admitted: the claim path fails closed, like
   the gate does. Keto never claim-admits either (no class expresses keto).
4. A recipe with a raw meat/poultry/fish/shellfish/egg line that a step
   cooks carries a thermometer check. Ready-to-eat keys are exempt by name,
   each with a reason.
5. Every timer is between 1 s and 12 h.

Exit code: 0 when rules 1-5 find no violation, 1 otherwise, 2 on usage/IO
errors. The oats advisory (gluten_free recipes using oats, which the bundle
classes as plain 'plant'; whether they need certified gluten-free oats is
Sam's call) is recorded, never decided, and never affects the exit code.

The tables below mirror ``HouseholdSafetyGate.swift``;
``tests/test_safety_invariants.py`` reads that file's enum lines and fails
when they drift.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).resolve().parent
DEFAULT_BUNDLE = REPO / "data/recipes/build/recipes-v2.json"
SWIFT_GATE = REPO / "apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift"

sys.path.insert(0, str(TOOLS))
import compile_bundle  # noqa: E402  (one definition of derive_claim)

# Claim blockers: the compiler's own sets, imported — not copied.
CLAIM_BLOCKERS = {
    "vegetarian": compile_bundle.VEGETARIAN_BLOCKERS,
    "vegan": compile_bundle.VEGAN_BLOCKERS,
    "gluten_free": compile_bundle.GLUTEN_BLOCKERS,
    "dairy_free": compile_bundle.DAIRY_BLOCKERS,
}

# --- Tables mirroring HouseholdSafetyGate.swift (drift-checked by test) ---

UNKNOWN_CLASS = "unknown"

# HouseholdAllergenGroup.ingredientClass: group -> the class it screens out.
GROUP_TO_CLASS = {
    "milk": "dairy",
    "egg": "egg",
    "peanut": "peanut",
    "tree_nut": "tree_nut",
    "soy": "soy",
    "wheat_gluten": "gluten",
    "fish": "fish",
    "shellfish": "shellfish",
    "sesame": "sesame",
    "mustard": "mustard",
}

# HouseholdDiet.blockedClasses. Keto blocks via the unset
# ketoMaxCarbsPerServingGrams constant, not via classes — mirrored below.
DIET_BLOCKED = {
    "vegetarian": {"meat", "fish", "shellfish"},
    "pescatarian": {"meat", "animal"},
    "vegan": {"meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"},
    "keto": set(),
}
KETO_FAILS_CLOSED = True

# The claim each restriction reads. Restrictions absent here have no claim:
# the claim path never admits a household that restricts them.
CLAIM_FOR = {
    "milk": "dairy_free",
    "wheat_gluten": "gluten_free",
    "vegetarian": "vegetarian",
    "vegan": "vegan",
}

# --- Households: 14 single-restriction + 11 pinned multi-restriction ---

HOUSEHOLDS = tuple(
    {"name": name, "groups": (name,), "diet": None} for name in GROUP_TO_CLASS
) + tuple(
    {"name": name, "groups": (), "diet": name} for name in DIET_BLOCKED
)


def _household(parts: tuple[str, ...]) -> dict:
    diet = parts[-1] if parts[-1] in DIET_BLOCKED else None
    groups = tuple(p for p in parts if p in GROUP_TO_CLASS)
    return {"name": "+".join(parts), "groups": groups, "diet": diet}


MULTI_HOUSEHOLDS = tuple(_household(parts) for parts in (
    ("milk", "vegetarian"),
    ("milk", "vegan"),
    ("wheat_gluten", "vegetarian"),
    ("wheat_gluten", "vegan"),
    ("milk", "wheat_gluten"),
    ("milk", "wheat_gluten", "vegetarian"),
    ("milk", "wheat_gluten", "vegan"),
    ("egg", "peanut"),
    ("tree_nut", "sesame"),
    ("milk", "keto"),
    ("milk", "pescatarian"),
))
HOUSEHOLDS += MULTI_HOUSEHOLDS

# --- Rules 4 and 5 ---

# Poultry has no composition class of its own; the bundle classes poultry
# lines "meat" (confirmed against the shipped bundle's class inventory).
RAW_ANIMAL_CLASSES = {"meat", "fish", "shellfish", "egg"}

# Ready-to-eat keys exempt from rule 4, each with its reason. "tuna" (raw
# steak) is deliberately absent — it is cooked and needs a thermometer.
READY_TO_EAT = {
    "canned_tuna": "commercially cooked and shelf-stable; eaten straight from the can",
    "canned_light_tuna": "commercially cooked and shelf-stable; eaten straight from the can",
    "sardines": "packed cooked; eaten without further cooking",
    "anchovies": "salt-cured; eaten without further cooking",
    "nduja": "cured, spreadable salami; ready to eat",
    "chicharrones": "fried crisp in production; ready to eat",
    "chicken_stock": "finished liquid from hours of simmering; ready to use",
    "beef_stock": "finished liquid from hours of simmering; ready to use",
    "vegetable_stock": "finished liquid from hours of simmering; ready to use",
    "beef_vegetable_stock": "finished liquid from hours of simmering; ready to use",
    "stock": "finished liquid from hours of simmering; ready to use",
    "broth": "finished long-simmered liquid; ready to use",
    "fish_sauce": "fermented condiment; ready to use",
}

COOK_VERBS = re.compile(
    r"\b(bake\w*|roast\w*|broil\w*|grill\w*|sear\w*|saute\w*|fry\w*|simmer\w*"
    r"|boil\w*|poach\w*|braise\w*|stew\w*|scramble\w*|cook\w*|char\w*"
    r"|blacken\w*|steam\w*|toast\w*)\b"
)

TIMER_MIN_S = 1
TIMER_MAX_S = 12 * 3600


# --- Bundle access ---

def load_bundle(path: str | Path) -> tuple[dict, dict[str, dict]]:
    bundle = json.loads(Path(path).read_text())
    return bundle, {e["key"]: e for e in bundle["ingredients"]}


def line_classes(recipe: dict, ingredients: dict[str, dict]) -> list[set[str]]:
    """Per-line class sets; a missing key or entry with no classes is the
    empty set, which screens as unknown (fail-closed), matching the gate."""
    return [set((ingredients.get(line["key"]) or {}).get("classes") or [])
            for line in recipe["ingredients"]]


# --- Rules ---

def check_claims(bundle: dict, ingredients: dict[str, dict]) -> list[dict]:
    """Rule 1: a shipped True claim derive_claim does not prove True."""
    out: list[dict] = []
    for recipe in bundle["recipes"]:
        lc = line_classes(recipe, ingredients)
        for claim, blockers in CLAIM_BLOCKERS.items():
            if recipe["claims"].get(claim) is not True:
                continue
            derived = compile_bundle.derive_claim(lc, blockers)
            if derived is True:
                continue
            suspects = sorted({
                line["key"] for line, cc in zip(recipe["ingredients"], lc)
                if not cc or UNKNOWN_CLASS in cc or (derived is False and cc & blockers)
            })
            why = ("blocked by line classes" if derived is False
                   else "not provable from line classes (unknown present)")
            out.append({"recipe": recipe["catalog_id"], "claim": claim,
                        "detail": f"{why}: {suspects}"})
    return out


def check_vegan_lattice(bundle: dict) -> list[dict]:
    """Rule 2: vegan True implies vegetarian True and dairy_free True."""
    out: list[dict] = []
    for recipe in bundle["recipes"]:
        claims = recipe["claims"]
        if claims.get("vegan") is not True:
            continue
        missing = sorted(k for k in ("vegetarian", "dairy_free")
                         if claims.get(k) is not True)
        if missing:
            out.append({"recipe": recipe["catalog_id"], "missing": missing})
    return out


def screen_block(groups: tuple[str, ...], diet: str | None,
                 lc: list[set[str]]) -> str | None:
    """Mirror of HouseholdSafetyGate.screen: None when allowed, else why not.
    Order matches the Swift: allergen classes, then the diet, then unknown
    composition for any restricted household."""
    for group, forbidden in GROUP_TO_CLASS.items():
        if group in groups and any(forbidden in c for c in lc):
            return f"allergen {group} (class {forbidden!r})"
    if diet == "keto" and KETO_FAILS_CLOSED:
        return "keto (fail-closed: no class expresses keto, limit unset)"
    if diet and diet != "keto":
        for c in lc:
            if c & DIET_BLOCKED[diet]:
                return f"diet {diet} blocked by line classes {sorted(c & DIET_BLOCKED[diet])}"
    if (groups or diet) and any(not c or UNKNOWN_CLASS in c for c in lc):
        return "unknown composition"
    return None


def claims_admit(groups: tuple[str, ...], diet: str | None, claims: dict) -> bool:
    """Whether the claim path admits this recipe for this household: every
    restriction needs a claim that is True; restrictions without a claim
    fail closed."""
    for restriction in (*groups, diet):
        if restriction is None:
            continue
        claim = CLAIM_FOR.get(restriction)
        if claim is None or claims.get(claim) is not True:
            return False
    return True


def check_sweep(bundle: dict, ingredients: dict[str, dict]) -> list[dict]:
    """Rule 3: claims admit -> class screen admits, for every recipe and
    every household in HOUSEHOLDS."""
    out: list[dict] = []
    for household in HOUSEHOLDS:
        groups, diet = household["groups"], household["diet"]
        for recipe in bundle["recipes"]:
            if not claims_admit(groups, diet, recipe["claims"]):
                continue
            reason = screen_block(groups, diet, line_classes(recipe, ingredients))
            if reason:
                out.append({"recipe": recipe["catalog_id"],
                            "household": household["name"], "detail": reason})
    return out


def check_thermometers(bundle: dict, ingredients: dict[str, dict]) -> list[dict]:
    """Rule 4: raw animal lines a step cooks need a thermometer check."""
    out: list[dict] = []
    for recipe in bundle["recipes"]:
        lines = recipe["ingredients"]
        raw_cooked: set[str] = set()
        for i, line in enumerate(lines):
            classes = set((ingredients.get(line["key"]) or {}).get("classes") or [])
            if not (classes & RAW_ANIMAL_CLASSES) or line["key"] in READY_TO_EAT:
                continue
            for step in recipe["steps"]:
                text = str(step.get("text", "")).replace("é", "e").lower()
                if i in (step.get("uses") or []) and COOK_VERBS.search(text):
                    raw_cooked.add(line["key"])
        if raw_cooked and not any(step.get("thermometer") for step in recipe["steps"]):
            out.append({"recipe": recipe["catalog_id"], "keys": sorted(raw_cooked)})
    return out


def check_timers(bundle: dict) -> list[dict]:
    """Rule 5: every timer is between 1 s and 12 h."""
    out: list[dict] = []
    for recipe in bundle["recipes"]:
        for i, step in enumerate(recipe["steps"]):
            t = step.get("timer_seconds")
            if t is None:
                continue
            if not (TIMER_MIN_S <= t <= TIMER_MAX_S):
                out.append({"recipe": recipe["catalog_id"], "step": i,
                            "timer_seconds": t})
    return out


def oats_advisory(bundle: dict, ingredients: dict[str, dict]) -> list[str]:
    """Recorded, never decided: gluten_free recipes using oats, which the
    bundle classes plain 'plant'. Certified gluten-free oats are Sam's call."""
    oat_keys = {k for k, e in ingredients.items() if "oat" in k}
    return sorted(r["catalog_id"] for r in bundle["recipes"]
                  if r["claims"].get("gluten_free") is True
                  and any(line["key"] in oat_keys for line in r["ingredients"]))


# --- Drift check against HouseholdSafetyGate.swift ---

_ENUM_CASE = re.compile(r'^\s*case (\w+)(?: = "([a-z_]+)")?\s*$', re.M)
_SWITCH_STRING = re.compile(r'case \.(\w+): return "([a-z_]+)"')
_SWITCH_SET = re.compile(r'case \.(\w+): return \[([^\]]*)\]')


def swift_table_drift(source: str) -> list[str]:
    """Compare this module's tables with the Swift enum lines. Empty list
    when they match."""
    drift: list[str] = []
    try:
        group_block = source.split("public enum HouseholdAllergenGroup", 1)[1] \
            .split("public enum HouseholdDiet", 1)[0]
        diet_block = source.split("public enum HouseholdDiet", 1)[1] \
            .split("public struct HouseholdSafetyProfile", 1)[0]
    except IndexError:
        return ["HouseholdSafetyGate.swift no longer declares the expected enums"]

    group_cases = _ENUM_CASE.findall(group_block)
    raw_of = {name: raw or name for name, raw in group_cases}
    if set(raw_of.values()) != set(GROUP_TO_CLASS):
        drift.append(f"allergen groups drifted: swift "
                     f"{sorted(raw_of.values())} vs check {sorted(GROUP_TO_CLASS)}")

    # Switch cases name the Swift enum cases (camelCase); compare through
    # the cases' raw values, which are the ids the check tables use.
    group_map = {raw_of.get(name, name): cls
                 for name, cls in _SWITCH_STRING.findall(group_block)}
    swift_groups = {k: v for k, v in group_map.items() if k in GROUP_TO_CLASS}
    if swift_groups != GROUP_TO_CLASS:
        drift.append(f"group->class drifted: swift {sorted(swift_groups.items())} "
                     f"vs check {sorted(GROUP_TO_CLASS.items())}")

    diet_cases = _ENUM_CASE.findall(diet_block)
    diet_raw = {name: raw or name for name, raw in diet_cases}
    if set(diet_raw.values()) != set(DIET_BLOCKED):
        drift.append(f"diets drifted: swift {sorted(diet_raw.values())} "
                     f"vs check {sorted(DIET_BLOCKED)}")

    diet_map: dict[str, set[str]] = {}
    for name, body in _SWITCH_SET.findall(diet_block):
        diet_map[diet_raw.get(name, name)] = {
            c.strip().strip('"') for c in body.split(",") if c.strip()}
    swift_diets = {k: v for k, v in diet_map.items() if k in DIET_BLOCKED}
    if swift_diets != DIET_BLOCKED:
        drift.append(f"diet->blockedClasses drifted: swift "
                     f"{sorted((k, sorted(v)) for k, v in swift_diets.items())} "
                     f"vs check {sorted((k, sorted(v)) for k, v in DIET_BLOCKED.items())}")

    if "ketoMaxCarbsPerServingGrams: Double? = nil" not in source:
        drift.append("ketoMaxCarbsPerServingGrams is no longer nil: keto no "
                     "longer fails closed; revisit KETO_FAILS_CLOSED and the sweep")
    if 'classes.contains("unknown")' not in source or "line.classes.isEmpty" not in source:
        drift.append("the unknown-composition fail-closed screen is gone from "
                     "HouseholdSafetyGate.swift")
    return drift


# --- Report ---

def run_all(bundle_path: str | Path) -> dict:
    bundle, ingredients = load_bundle(bundle_path)
    return {
        "bundle": str(bundle_path),
        "recipes": len(bundle["recipes"]),
        "rule1_claims": check_claims(bundle, ingredients),
        "rule2_vegan_lattice": check_vegan_lattice(bundle),
        "rule3_sweep": check_sweep(bundle, ingredients),
        "rule4_thermometers": check_thermometers(bundle, ingredients),
        "rule5_timers": check_timers(bundle),
        "oats_advisory": oats_advisory(bundle, ingredients),
    }


def main(argv: list[str]) -> int:
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ("-h", "--help")):
        print(f"usage: {argv[0]} [bundle]", file=sys.stderr)
        return 2
    path = Path(argv[1]) if len(argv) == 2 else DEFAULT_BUNDLE
    if not path.exists():
        print(f"bundle not found: {path}", file=sys.stderr)
        return 2

    report = run_all(path)
    print(f"bundle: {report['bundle']} ({report['recipes']} recipes, "
          f"{len(HOUSEHOLDS)} households: {len(GROUP_TO_CLASS)} allergen groups "
          f"+ {len(DIET_BLOCKED)} diets singly, {len(MULTI_HOUSEHOLDS)} pinned multi)")

    sections = (
        ("rule 1 — true claims the line classes do not prove (derive_claim not True)",
         report["rule1_claims"]),
        ("rule 2 — vegan claimed without vegetarian/dairy_free", report["rule2_vegan_lattice"]),
        ("rule 3 — recipes the claims admit but the class screen blocks",
         report["rule3_sweep"]),
        ("rule 4 — cooked raw animal lines without a thermometer check",
         report["rule4_thermometers"]),
        ("rule 5 — timers outside 1 s .. 12 h", report["rule5_timers"]),
    )
    total = 0
    for title, rows in sections:
        print(f"\n{title}: {len(rows)}")
        for row in rows:
            print(f"  {row}")
        total += len(rows)

    print(f"\nadvisory (Sam's call — recorded, never decided): gluten_free "
          f"recipes over oats, classed plain 'plant': {len(report['oats_advisory'])}")
    for rid in report["oats_advisory"]:
        print(f"  {rid}")

    print(f"\nviolations: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
