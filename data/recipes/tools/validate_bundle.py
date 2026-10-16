#!/usr/bin/env python3
"""Validate a compiled recipe bundle against the v2 contract and evidence.

Checks, in order:
1. JSON Schema conformance (recipe-bundle-v2.schema.json, draft 2020-12).
2. Ingredient references: every line's key names a bundle ingredient.
3. Nutrition plausibility: kcal within 40 percent of the Atwater sum of the
   macros it ships with; sodium sane; no negative or absurd values.
4. Claims fail closed: a true dietary claim must not conflict with the
   composition class of any line in the recipe; a claim the classes actively
   contradict (bundle false where every line is known-good) is also a defect;
   null claims warn as unverifiable, never pass silently as false.
5. Rights: every recipe carries an original/quarantined status with evidence.
6. FSIS: a thermometer endpoint may only appear on a step of a recipe whose
   lines carry an FSIS doneness class (meat/fish/shellfish/egg), the source
   must be usda-fsis, and the endpoint must meet the FSIS minimum of the
   check's OWN cited fsis_class — the corpus gate owns coverage and mixture
   rules with the same specific classes, and a coarse recipe-level proxy
   produced false conflicts (a valid 160 F ground-meat check under a
   strictest-meat 165 F rule). The corpus recipe behind each bundle recipe
   must still be clean under the full gate.
7. Classes: every bundle ingredient's classes list must equal the vocabulary
   evidence for its key, and every step timer must be consistent with its
   text (a step the text parser can time cannot ship a null timer; an
   authored corpus timer_min must be the shipped seconds).
8. (optional) Kcal drift: with --previous, a per-serving kcal move of more
   than 40 percent against the previously published bundle must be recorded
   in a changes file (--changes) naming the vocabulary change that caused it.

Exit code 0 and "PASS" on success; every failure is printed with its recipe id.
"""
from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

import jsonschema

from pipeline import fsis

REPO = Path(__file__).resolve().parents[3]
SCHEMA = REPO / "docs/spec/recipes/contracts/recipe-bundle-v2.schema.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"

# Classes whose presence makes a claim impossible (fail-closed). The corpus
# composition gate is the fail-closed authority for claims (fixture classes on
# ingredient names); this bundle-level audit catches contradictions expressible
# in the vocabulary. Lines whose classes are missing or 'unknown' are
# unverifiable here — the claim must ship null, not true.
CLAIM_BLOCKERS = {
    # Lacto-ovo vegetarian: flesh is out; dairy/egg/honey (the vocabulary's
    # coarse 'animal' entries: ghee, honey, mayonnaise) are in.
    "vegetarian": {"meat", "fish", "shellfish"},
    "vegan": {"meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"},
    "gluten_free": {"gluten"},
    "dairy_free": {"dairy"},
}

# Vocabulary classes an FSIS thermometer check makes sense for, mapped to the
# FSIS rows each coarse class covers (the vocabulary's 'meat' spans all four
# meat rows; the check's own fsis_class is the specific row it enforces).
VOCAB_CLASS_TO_FSIS_FAMILY = {
    "meat": {"meat_poultry", "meat_ground", "meat_whole_cut_pork", "meat_whole_cut_red"},
    "fish": {"flesh_fish"},
    "shellfish": {"flesh_shellfish"},
    "egg": {"egg"},
}

# Atwater factors, fiber-adjusted (carbs are by-difference and include fiber
# at ~2 kcal/g), cross-checked against shipped kcal with an absolute floor:
# small absolute deltas on low-energy foods are noise, and alcohol contributes
# 7 kcal/g that the shipped macros cannot express.
ATWATER = {"protein_g": 4, "carbs_g": 4, "fat_g": 9}
ATWATER_FIBER = 2
KCAL_DRIFT_THRESHOLD = 0.40
KCAL_MATCH_TOLERANCE = 0.05
CHANGES_FILE = REPO / "data/recipe-bundle/nutrition-changes-2026-10.json"
ALCOHOL_KEYS = {
    "red_wine", "white_wine", "beer", "lager", "ale", "rum", "vodka", "brandy",
    "whiskey", "sherry", "mirin", "cooking_wine", "kahlua", "cointreau",
}


def fail(errors: list[str], recipe: str, message: str) -> None:
    errors.append(f"{recipe}: {message}")


def atwater_ok(n: dict, has_alcohol: bool) -> bool:
    if has_alcohol:
        return True
    carb_eff = max(n["carbs_g"] - n.get("fiber_g", 0.0), 0.0)
    fiber = n.get("fiber_g", 0.0)
    expected = (n["protein_g"] * ATWATER["protein_g"]
                + carb_eff * ATWATER["carbs_g"]
                + fiber * ATWATER_FIBER
                + n["fat_g"] * ATWATER["fat_g"])
    if expected <= 0:
        return n["kcal"] >= 10
    return abs(n["kcal"] - expected) <= max(50.0, 0.40 * expected)


def kcal_swing(old: float, new: float) -> float:
    """Relative per-serving kcal move; infinite when the old value was zero."""
    if old == 0:
        return 0.0 if new == 0 else float("inf")
    return abs(new - old) / old


def check_kcal_drift(new: dict, prev: dict | None, changes: dict | None) -> list[str]:
    """Every >40 percent kcal move against the previous published bundle must
    be exempted in the changes file with the vocabulary change that caused it.
    Entries must reproduce both kcal values so stale exemptions fail loudly."""
    errors: list[str] = []
    if prev is None:
        return errors
    prev_n = {r["catalog_id"]: r.get("nutrition_per_serving", {}) for r in prev["recipes"]}
    exemptions = {e["catalog_id"]: e for e in (changes or {}).get("entries", [])}
    swings = 0
    for recipe in new["recipes"]:
        rid = recipe["catalog_id"]
        old_n = prev_n.get(rid)
        if old_n is None or "kcal" not in old_n:
            continue  # new or re-keyed recipe: nothing to compare against
        n = recipe.get("nutrition_per_serving", {})
        if "kcal" not in n:
            continue
        swing = kcal_swing(old_n["kcal"], n["kcal"])
        if swing <= KCAL_DRIFT_THRESHOLD:
            continue
        swings += 1
        entry = exemptions.get(rid)
        if entry is None:
            errors.append(
                f"{rid}: kcal moved {old_n['kcal']} -> {n['kcal']} "
                f"(>{KCAL_DRIFT_THRESHOLD:.0%}) against the previous published "
                f"bundle; record the vocabulary change that caused it in "
                f"{CHANGES_FILE.name}")
            continue
        for field, value in (("old_kcal", old_n["kcal"]), ("new_kcal", n["kcal"])):
            if field not in entry:
                errors.append(
                    f"{rid}: exemption missing {field}; it must reproduce both "
                    "kcal values of the move it exempts")
                continue
            if abs(entry[field] - value) > KCAL_MATCH_TOLERANCE:
                errors.append(
                    f"{rid}: exemption {field} is {entry.get(field)!r} but the "
                    f"bundle value is {value!r}; stale exemption")
        if not (entry.get("vocabulary_change") or "").strip():
            errors.append(f"{rid}: exemption must name the vocabulary change that caused it")
    return errors


def check_rights_statuses(bundle: dict, cleared_catalog_ids: set[str]) -> list[str]:
    """Rights labels must say what the release gate vouches for.

    The schema enum is original | quarantined. `original` is reserved for
    recipes whose rights record (an FridgeLuck original or original-rewrite
    under LicenseRef-FL-Original) the release gate clears; anything else the
    gate does not clear must ship `quarantined`. A status outside the enum, or
    an `original` with no cleared record, is a defect: the label contradicts
    the gate that decides which recipes may be shown at all."""
    errors: list[str] = []
    for recipe in bundle["recipes"]:
        rid = recipe["catalog_id"]
        status = recipe["rights"]["status"]
        if status not in ("original", "quarantined"):
            fail(errors, rid, f"rights status {status!r} is outside the schema "
                              "enum original|quarantined")
        elif status == "original" and rid not in cleared_catalog_ids:
            fail(errors, rid, "ships rights status 'original' but the release "
                              "gate does not clear its rights record; only a "
                              "cleared FL original/original-rewrite may ship "
                              "'original' — quarantine it or fix the record")
    return errors


def gate_cleared_catalog_ids() -> set[str]:
    """Re-run the release gate's per-recipe rights verdict over the committed
    corpus (same code the compiler labels from) and return the cleared ids."""
    import validate_corpus  # noqa: E402  (local: sys.path is set below)

    corpus = [json.loads(line)
              for line in (REPO / "data/recipes/corpus.jsonl")
              .read_text(encoding="utf-8").splitlines() if line.strip()]
    ctx = validate_corpus.load_rights_context()
    cleared, _ = validate_corpus.cleared_and_quarantined(corpus, ctx)
    return cleared


def corpus_recipes_by_catalog_id() -> dict[str, dict]:
    """Committed corpus records keyed by the bundle's catalog_id."""
    import validate_corpus  # noqa: E402

    corpus = [json.loads(line)
              for line in (REPO / "data/recipes/corpus.jsonl")
              .read_text(encoding="utf-8").splitlines() if line.strip()]
    return {validate_corpus.catalog_id_for(r["id"]): r for r in corpus}


def main(path: str, previous: str | None = None, changes: str | None = None) -> int:
    bundle = json.load(open(path))
    schema = json.load(SCHEMA.open())
    errors: list[str] = []

    validator = jsonschema.Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(bundle), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        fail(errors, loc, err.message[:160])

    prev_bundle = json.load(open(previous)) if previous else None
    changes_doc = json.load(open(changes)) if changes else None
    if previous and not changes_doc:
        print("note: no changes file supplied; any kcal swing will fail")
    drift_errors = check_kcal_drift(bundle, prev_bundle, changes_doc)
    errors.extend(drift_errors)
    if prev_bundle is not None:
        print(f"kcal drift: compared against {previous}; "
              f"{len(drift_errors)} unrecorded/exempted problems")

    # Rights labels must repeat what the release gate vouches for: re-run the
    # gate's per-recipe rights verdict and audit every shipped label against it.
    cleared = gate_cleared_catalog_ids()
    rights_errors = check_rights_statuses(bundle, cleared)
    errors.extend(rights_errors)
    shipped = collections.Counter(r["rights"]["status"] for r in bundle["recipes"])
    print(f"rights: {shipped.get('original', 0)} original, "
          f"{shipped.get('quarantined', 0)} quarantined; "
          f"gate clears {len(cleared)} corpus recipes; "
          f"{len(rights_errors)} label problems")

    ingredients = {i["key"]: i for i in bundle["ingredients"]}
    # Bundle ingredients now CARRY their classes; the vocabulary remains the
    # evidence the bundle must not drift from.
    vocab_classes = {e["key"]: set(e.get("classes") or [])
                     for e in json.load(VOCAB.open())["entries"]}
    warnings: list[str] = []

    import food_safety  # noqa: E402  (corpus gate: the coverage authority)
    import compile_bundle  # noqa: E402  (parse_timer, shared claim semantics)
    corpus = corpus_recipes_by_catalog_id()

    for recipe in bundle["recipes"]:
        rid = recipe["catalog_id"]
        keys = {line["key"] for line in recipe["ingredients"]}
        for key in keys:
            if key not in ingredients:
                fail(errors, rid, f"line key {key!r} is not a bundle ingredient")
        # Bundle classes must equal the vocabulary evidence for the key.
        for key in keys:
            shipped_classes = set((ingredients.get(key) or {}).get("classes") or [])
            if shipped_classes != vocab_classes.get(key, set()):
                fail(errors, rid,
                     f"ingredient {key!r} classes {sorted(shipped_classes)} differ from "
                     f"the vocabulary evidence {sorted(vocab_classes.get(key, set()))}")
        line_classes = [set((ingredients.get(line["key"]) or {}).get("classes") or [])
                        for line in recipe["ingredients"]]
        # Claims fail closed against line composition classes: a true claim a
        # class blocks is a defect, and so is a false claim on all-known lines
        # that support it. Null warns as unverifiable (the app gate fails it
        # closed), never silently.
        for claim, blockers in CLAIM_BLOCKERS.items():
            shipped = recipe["claims"].get(claim)
            derived = compile_bundle.derive_claim(line_classes, blockers)
            if shipped is True and derived is False:
                blocking = next((line["key"] for line, cc in
                                 zip(recipe["ingredients"], line_classes)
                                 if cc & blockers), None)
                fail(errors, rid,
                     f"claims {claim} but the lines' composition classes block it "
                     f"(e.g. {blocking!r})")
            elif shipped is False and derived is True:
                fail(errors, rid,
                     f"claims {claim}=false but every line's composition classes "
                     "support it")
            elif shipped is None:
                unknown_keys = [line["key"] for line, cc in
                                zip(recipe["ingredients"], line_classes)
                                if not cc or "unknown" in cc]
                warnings.append(f"{rid}: {claim} ships null (unverifiable: "
                                f"unknown or unclassed lines e.g. {unknown_keys[:3]})")
        # Nutrition plausibility against the macros the recipe itself ships.
        n = recipe["nutrition_per_serving"]
        if n["sodium_mg"] > 6000:
            fail(errors, rid, f"sodium {n['sodium_mg']} mg/serving is implausible")
        if not atwater_ok(n, bool(keys & ALCOHOL_KEYS)):
            fail(errors, rid,
                 f"kcal {n['kcal']} is implausibly far from the Atwater sum of its macros")
        # FSIS: each thermometer must cite a real FSIS row, meet that row's
        # minimum, and its class must have a basis in the recipe (an FSIS
        # doneness class on a line, the leftovers class, or a class the corpus
        # gate requires). The corpus gate owns coverage and mixtures with the
        # same specific classes; a coarse recipe-level proxy re-derived from
        # bundle classes produced false conflicts — a valid 160 F ground-meat
        # check under a strictest-meat 165 F rule, and leftovers reheating
        # checks on vegetarian dishes with no meat line. The corpus recipe
        # behind this bundle recipe must also be clean under the full gate.
        corpus_rec = corpus.get(rid)
        corpus_violations = (food_safety.safety_violations(corpus_rec)
                             if corpus_rec is not None else [])
        if corpus_violations:
            fail(errors, rid, "corpus recipe is not clean under the food-safety "
                             f"gate: {corpus_violations[:2]}")
        required = set(food_safety.required_classes(corpus_rec)) if corpus_rec else set()
        line_vocab = set().union(*line_classes) if line_classes else set()
        line_fsis = set().union(*(VOCAB_CLASS_TO_FSIS_FAMILY.get(c, set())
                                  for c in line_vocab))
        allowed_classes = line_fsis | {"leftovers"} | required
        for i, step in enumerate(recipe["steps"]):
            thermo = step["thermometer"]
            if thermo is None:
                # A step whose own text names a duration cannot ship a null timer.
                if (step["timer_seconds"] is None
                        and compile_bundle.parse_timer(step["text"]) is not None):
                    fail(errors, rid, f"step {i} text names a duration but ships no "
                                     "timer_seconds")
                continue
            if not thermo["source"].startswith("usda-fsis"):
                fail(errors, rid, f"step {i} thermometer source is not usda-fsis")
            cls = thermo.get("fsis_class")
            if cls not in fsis.FSIS_MIN_F:
                fail(errors, rid, f"step {i} thermometer fsis_class {cls!r} is not "
                                 "an FSIS row")
                continue
            min_c = fsis.f_to_c(fsis.FSIS_MIN_F[cls][0])
            if thermo["endpoint_c"] + 1e-9 < min_c:
                fail(errors, rid,
                     f"step {i} thermometer endpoint {thermo['endpoint_c']} C is "
                     f"below the FSIS minimum {min_c} C for {cls!r}")
            if cls not in allowed_classes:
                fail(errors, rid,
                     f"step {i} thermometer class {cls!r} has no basis in this "
                     f"recipe (no matching line classes, not leftovers, gate "
                     f"requires {sorted(required)})")
            if corpus_rec is not None and i < len(corpus_rec["steps"]):
                authored = corpus_rec["steps"][i].get("timer_min")
                if authored is not None and step["timer_seconds"] != authored * 60:
                    fail(errors, rid, f"step {i} timer_seconds {step['timer_seconds']} "
                                     f"disagrees with the authored timer_min "
                                     f"{authored} (x60)")
        if recipe["rights"]["status"] == "quarantined" and not recipe["rights"]["evidence"]:
            fail(errors, rid, "quarantined recipe must cite rights evidence")

    if warnings:
        print(f"warnings (not gated): {len(warnings)}")
        for w in warnings[:12]:
            print(" ?", w)
        if len(warnings) > 12:
            print(f" ... and {len(warnings) - 12} more")
    if errors:
        print(f"FAIL ({len(errors)} problems)")
        for e in errors[:40]:
            print(" -", e)
        if len(errors) > 40:
            print(f" ... and {len(errors) - 40} more")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("bundle", nargs="?", default="data/recipes/build/recipes-v2.json")
    ap.add_argument("--previous", help="previously published bundle to compare kcal against")
    ap.add_argument("--changes", help="changes file exempting >40%% kcal moves")
    args = ap.parse_args()
    sys.exit(main(args.bundle, args.previous, args.changes))
