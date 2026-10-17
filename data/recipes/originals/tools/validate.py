#!/usr/bin/env python3
"""Validator for the FridgeLuck original recipe corpus (data/recipes/originals/).

Layers, in order:

1. The suite C RS linter (evaluation/suites/recipes/rs.py, PR #88) — R1 schema,
   R2 quantity evidence, R3 FSIS thermometer doneness, R4 claim evidence,
   R5 timers. Imported read-only from the commit pinned in SUITE-PIN.json.
2. Rights gate: every recipe's source_ref must have a complete rights record
   (rights.py, fail-closed) in a part tables/rights-manifest.json shard.
3. The originals craft layer (this file): untested marking, equipment, step
   length, tag implications, compound-allergen honesty, id/source_ref/cuisine
   conventions, per-recipe resolved quantity share, within-part duplicate
   titles, part-1 replaces links.

Usage:
    python3 tools/validate.py --all
    python3 tools/validate.py --part east-southeast-asian

Exit 0 only when every hard check passes for every discovered recipe.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nutrition as nutrition_mod  # noqa: E402
import originals_common as oc  # noqa: E402

SALTY_PATTERNS = oc.SALTY_PATTERNS

MAX_STEP_CHARS = 320  # readable from arm's length
NUTRITION_KEYS = ("kcal", "protein_g", "carbs_g", "fat_g")
# Must equal the basis string nutrition.py writes (kept in sync by the smoke test).
EXPECTED_NUTRITION_BASIS = (
    "USDA FoodData Central values committed in apps/ios/Resources/"
    "usda_ingredient_catalog.sqlite (matched fdc_id per ingredient in "
    "tables/nutrition-map.json), plus the app's shipped core-ingredient "
    "table (data.json) for items without an fdc_id; scaled by evidenced "
    "gram quantities"
)
KNOWN_TAGS = {
    "weeknight", "budget", "high-protein", "one-pot", "sheet-pan",
    "leftovers", "use-it-up", "make-ahead", "freezer-friendly",
}
SAFETY_TEMPS = {
    "meat_poultry": 165, "meat_ground": 160, "meat_whole_cut_pork": 145,
    "meat_whole_cut_red": 145, "flesh_fish": 145, "flesh_shellfish": 145,
    "egg": 160,
}


def suite_allergens() -> dict:
    return json.loads((oc.suite_dir() / "allergens.json").read_text())


def check_recipe(
    rid: str, r: dict, *, part: str, prefix: str, family: str,
    allowed_cuisines: set[str] | None, suite_cuisines: set[str],
    scanner_suite, scanner_strict, claim_defs: dict,
    rights_statuses: dict, bundled_ids_seen: dict[str, str],
    nutrition_maps: dict | None = None,
) -> tuple[list[str], list[str]]:
    """Hard violations and warnings for one recipe."""
    hard: list[str] = []
    soft: list[str] = []

    # --- identity & rights -------------------------------------------------
    if not rid.startswith(prefix + "-"):
        hard.append(f"ID-PREFIX: id {rid!r} must start with {prefix!r} in {part}")
    if r.get("source_ref") != f"orig:authored:{rid}":
        hard.append(f"SOURCE-REF: expected 'orig:authored:{rid}', got {r.get('source_ref')!r}")
    status = rights_statuses.get(r.get("source_ref"))
    if not status:
        hard.append(f"RIGHTS: no rights-manifest record for {r.get('source_ref')!r}")
    elif status["status"] != "clear":
        hard.append(f"RIGHTS: quarantined ({status['reason']})")
    if r.get("provenance") not in ("authored", "original"):
        soft.append(f"provenance {r.get('provenance')!r} (expected 'authored')")

    # --- cuisine / family --------------------------------------------------
    allowed = allowed_cuisines if allowed_cuisines else suite_cuisines
    if r.get("cuisine") not in allowed:
        hard.append(f"CUISINE: {r.get('cuisine')!r} outside the allowed set for {part}")
    if not str(r.get("cuisine_detail", "")).strip():
        hard.append("CUISINE-DETAIL: missing (fine-grained cuisine, e.g. 'thai')")
    if r.get("family") != family:
        soft.append(f"family {r.get('family')!r} (expected {family!r})")

    # --- untested marking ---------------------------------------------------
    if r.get("test_status") != "untested":
        hard.append(f"UNTESTED: test_status must be 'untested', got {r.get('test_status')!r}")

    # --- equipment ----------------------------------------------------------
    if not isinstance(r.get("equipment"), list) or not r.get("equipment"):
        hard.append("EQUIPMENT: top-level 'equipment' list is empty or missing")

    # --- steps -----------------------------------------------------------------
    timer_sum = 0.0
    for i, step in enumerate(r.get("steps", [])):
        text = str(step.get("text", ""))
        if len(text) > MAX_STEP_CHARS:
            hard.append(f"STEP-LEN: step[{i}] is {len(text)} chars (max {MAX_STEP_CHARS})")
        t = step.get("timer_min")
        if isinstance(t, (int, float)) and not isinstance(t, bool):
            timer_sum += float(t)

    # --- minutes / servings ------------------------------------------------------
    minutes = r.get("minutes")
    if not isinstance(minutes, int) or not (1 <= minutes <= 300):
        hard.append(f"MINUTES: {minutes!r} must be an int in 1..300")
    servings = r.get("servings")
    if not isinstance(servings, int) or not (1 <= servings <= 12):
        hard.append(f"SERVINGS: {servings!r} must be an int in 1..12")
    if isinstance(minutes, int) and timer_sum > minutes + 30:
        soft.append(f"timers sum to {timer_sum:.0f} min vs minutes={minutes}")

    # --- quantity evidence share ----------------------------------------------------
    lines = r.get("ingredients", [])
    n_lines = len(lines)
    n_resolved = sum(1 for ln in lines
                     if isinstance(ln.get("qty"), dict)
                     and ln["qty"].get("kind") in ("weighed", "source_grams", "household")
                     and oc.resolved_grams(ln) is not None)
    if n_lines and n_resolved / n_lines < 0.95:
        hard.append(f"QTY-SHARE: only {n_resolved}/{n_lines} lines resolve to grams (need >= 95%)")
    for i, ln in enumerate(lines):
        qty = ln.get("qty") if isinstance(ln, dict) else None
        if not isinstance(qty, dict):
            continue
        if qty.get("kind") == "household" and isinstance(qty.get("grams"), (int, float)) \
                and isinstance(qty.get("value"), (int, float)):
            expected = qty["value"] * float(qty.get("grams_per_unit", 0) or 0)
            if expected and abs(float(qty["grams"]) - expected) > max(1.0, 0.05 * expected):
                soft.append(f"line[{i}] {ln.get('name', '?')!r}: grams {qty['grams']} vs "
                            f"value*grams_per_unit {expected:.1f}")
        if qty.get("kind") == "unknown":
            soft.append(f"line[{i}] {ln.get('name', '?')!r}: qty kind=unknown (honest, counts unresolved)")

    # --- claims: suite recompute AND strict compound knowledge ----------------------
    classes_suite = scanner_suite.classes_for(r)
    classes_strict = scanner_strict.classes(r)
    present = classes_suite | classes_strict
    required = set(SAFETY_TEMPS) & present  # only classes that demand a check
    has_reheat = any(isinstance(s, dict) and s.get("reheat") for s in r.get("steps", []))
    safety_steps = [s["safety"] for s in r.get("steps", [])
                    if isinstance(s, dict) and isinstance(s.get("safety"), dict)]
    covered = set()
    for s in safety_steps:
        c, t = s.get("class"), s.get("temp_f")
        if c in SAFETY_TEMPS and t == SAFETY_TEMPS[c]:
            covered.add(c)
    missing = required - covered
    if has_reheat and not any(s.get("temp_f") == 165 for s in safety_steps):
        hard.append("SAFETY: reheat step requires a 165F thermometer check")
    if required and not covered:
        hard.append(f"SAFETY: {sorted(required)} present but no matching thermometer "
                    f"check with the FSIS temperature {sorted(missing)}")
    for claim in r.get("claims", []):
        cname = claim.get("claim")
        if cname not in claim_defs:
            hard.append(f"CLAIM: unknown claim type {cname!r}")
            continue
        recorded = sorted((claim.get("evidence") or {}).get("conflicts", []))
        forbid = set(claim_defs[cname].get("forbids", []))
        suite_conf = sorted(classes_suite & forbid)
        strict_conf = sorted(classes_strict & forbid)
        if recorded != suite_conf:
            hard.append(f"CLAIM: {cname} recorded conflicts {recorded} != suite recompute {suite_conf}")
        if strict_conf:
            hard.append(f"CLAIM: {cname} is false under compound-ingredient knowledge "
                        f"(contains {strict_conf}); fix ingredients or drop the claim")

    # --- tags -------------------------------------------------------------------------
    nutrition = r.get("nutrition_per_serving") or {}
    for tag in r.get("tags", []):
        if tag not in KNOWN_TAGS and not tag.startswith("use-it-up:"):
            hard.append(f"TAGS: {tag!r} outside the vocabulary")
    if "weeknight" in r.get("tags", []) and isinstance(minutes, int) and minutes > 30:
        hard.append("TAGS: weeknight but minutes > 30")
    if "budget" in r.get("tags", []):
        cost = r.get("cost_per_serving_usd")
        if not isinstance(cost, dict) or not isinstance(cost.get("value"), (int, float)) \
                or cost["value"] <= 0:
            hard.append("TAGS: budget recipe without a positive cost_per_serving_usd.value")
        elif not str(cost.get("assumptions_ref", "")).strip():
            hard.append("TAGS: budget recipe without cost assumptions_ref")
    if "high-protein" in r.get("tags", []):
        protein = nutrition.get("protein_g")
        if not isinstance(protein, (int, float)) or protein < 25:
            hard.append(f"TAGS: high-protein but protein_g={protein!r} (<25 or missing)")
    if "use-it-up" in r.get("tags", []) and not any(
            t.startswith("use-it-up:") for t in r.get("tags", [])):
        hard.append("TAGS: use-it-up needs a 'use-it-up:<ingredient>' companion tag")
    for tag in r.get("tags", []):
        if tag.startswith("use-it-up:"):
            item = tag.split(":", 1)[1].strip().lower()
            if not any(item in str(ln.get("name", "")).lower() for ln in lines):
                hard.append(f"TAGS: use-it-up:{item} but no such ingredient line")

    # --- nutrition field -----------------------------------------------------------------
    if not any(isinstance(nutrition.get(k), (int, float)) for k in NUTRITION_KEYS):
        hard.append("NUTRITION: nutrition_per_serving missing or empty — run tools/nutrition.py --write")
    else:
        cov = nutrition.get("coverage")
        if not isinstance(cov, (int, float)) or not (0.0 <= float(cov) <= 1.0):
            hard.append("NUTRITION: coverage must be a float in [0,1]")
        # sodium-confidence: when salty ingredients are unmapped the sodium
        # number under-counts; the block must say so (and only then).
        # Recomputed here from the recipe lines + nutrition maps, not trusted
        # from the stored block.
        salty_here = sorted({
            str(ln.get("name", "")).strip().lower()
            for ln in lines
            if any(p in str(ln.get("name", "")).lower() for p in SALTY_PATTERNS)
            and oc.resolved_grams(ln) is not None
            and (nutrition_maps or {}).get(str(ln.get("name", "")).strip().lower()) is None
        })
        flagged = nutrition.get("sodium_basis") == "incomplete-salty-unmapped"
        salty_list = nutrition.get("sodium_unmapped_salty") or []
        if flagged and not salty_list:
            hard.append("NUTRITION: sodium_basis flagged incomplete but sodium_unmapped_salty is empty")
        if salty_list and not flagged:
            hard.append("NUTRITION: unmapped salty ingredients present but sodium_basis not flagged")
        if salty_here != sorted(salty_list):
            hard.append(f"NUTRITION: sodium_unmapped_salty {salty_list} != recomputed {salty_here} "
                        f"(re-run nutrition.py --write)")
        # the stored number must come from the tool, never hand-edited
        if nutrition.get("basis") != EXPECTED_NUTRITION_BASIS:
            hard.append("NUTRITION: basis string must be the tool-generated one (re-run nutrition.py --write)")

    # --- part-1 replaces link ---------------------------------------------------------------
    if part == "part1-rewrite":
        rep = r.get("replaces")
        if not isinstance(rep, dict) or not rep.get("bundled_id"):
            hard.append("REPLACES: part-1 recipe must record replaces.bundled_id")
        else:
            bid = str(rep["bundled_id"])
            if bid in bundled_ids_seen:
                hard.append(f"REPLACES: bundled_id {bid} already replaced by {bundled_ids_seen[bid]}")
            else:
                bundled_ids_seen[bid] = rid

    return hard, soft


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--part", default=None, help="restrict to one part directory")
    ap.add_argument("--all", action="store_true", help="validate every part")
    args = ap.parse_args()
    if not args.all and not args.part:
        ap.error("pass --part <name> or --all")

    rs, bands, rights = oc.load_suite_modules()
    allergens = oc.suite_allergens() if hasattr(oc, "suite_allergens") \
        else json.loads((oc.suite_dir() / "allergens.json").read_text())
    claim_defs = allergens["claims"]
    suite_cuisines = bands.CUISINE_SET
    suite_slots = bands.SLOT_SET

    parts = sorted(oc.PARTS) if args.all else [args.part]
    if args.part and args.part not in oc.PARTS:
        print(f"unknown part {args.part!r}; known: {', '.join(sorted(oc.PARTS))}")
        return 2

    totals = {"recipes": 0, "hard": 0, "soft": 0, "rights_clear": 0, "pass": 0}

    nutrition_maps, nm_errors = nutrition_mod.load_maps(None)
    for e in nm_errors:
        print(f"HARD nutrition-map: {e}")
        totals["hard"] += 1

    bundled_ids_seen: dict[str, str] = {}
    per_part: dict[str, dict] = {}

    for part in parts:
        prefix, family, allowed = oc.PARTS[part]
        recipes, bad = oc.discover_recipes(part)
        conv, conv_conflicts = oc.load_conversions(part)
        rights_statuses, _manifests = oc.load_rights_manifests(part)
        scanner_suite = rs.AllergenScanner(allergens)
        scanner_strict = oc.StrictScanner(oc.load_compound_entries(part))
        n_hard = n_soft = n_pass = 0
        part_lines = part_resolved = 0

        for path, reason in bad:
            print(f"HARD [{part}] {path.name}: {reason}")
            n_hard += 1
        for ref in conv_conflicts:
            print(f"HARD [{part}] CONVERSION-CONFLICT: ref {ref!r} defined with different grams")
            n_hard += 1

        for path, r in recipes:
            rid = r["id"]
            totals["recipes"] += 1
            suite_violations = rs.lint_recipe(
                r, cuisines=suite_cuisines, meal_slots=suite_slots,
                conversions=conv, allergen_scan=scanner_suite,
            )
            craft_hard, craft_soft = check_recipe(
                rid, r, part=part, prefix=prefix, family=family,
                allowed_cuisines=allowed, suite_cuisines=suite_cuisines,
                scanner_suite=scanner_suite, scanner_strict=scanner_strict,
                claim_defs=claim_defs, rights_statuses=rights_statuses,
                bundled_ids_seen=bundled_ids_seen,
                nutrition_maps=nutrition_maps,
            )
            hard = suite_violations + craft_hard
            soft = craft_soft

            lines = r.get("ingredients", [])
            part_lines += len(lines)
            part_resolved += sum(
                1 for ln in lines if isinstance(ln.get("qty"), dict)
                and ln["qty"].get("kind") in ("weighed", "source_grams", "household")
                and oc.resolved_grams(ln) is not None)

            if rights_statuses.get(r.get("source_ref"), {}).get("status") == "clear":
                totals["rights_clear"] += 1
            if not hard:
                n_pass += 1
            for v in hard:
                print(f"HARD [{part}] {rid}: {v}")
            for v in soft:
                print(f"soft [{part}] {rid}: {v}")
            n_hard += len(hard)
            n_soft += len(soft)

        per_part[part] = {"recipes": len(recipes), "hard": n_hard, "soft": n_soft,
                          "lines": part_lines, "resolved": part_resolved}
        totals["hard"] += n_hard
        totals["soft"] += n_soft
        totals["pass"] += n_pass

    print("\n=== summary ===")
    for part, s in per_part.items():
        share = (100.0 * s["resolved"] / s["lines"]) if s["lines"] else 100.0
        print(f"{part}: {s['recipes']} recipes, hard={s['hard']}, soft={s['soft']}, "
              f"resolved-lines={share:.1f}%")
    print(f"TOTAL: {totals['recipes']} recipes, rights-clear={totals['rights_clear']}, "
          f"pass={totals['pass']}, hard={totals['hard']}, soft={totals['soft']}")
    if totals["recipes"] == 0:
        print("NOTE: no recipe files discovered yet")
    return 0 if totals["hard"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
