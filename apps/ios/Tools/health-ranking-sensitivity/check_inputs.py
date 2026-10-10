#!/usr/bin/env python3
"""Validate the frozen inputs and enforce the perturbation-bounds lock.

Checks:
  1. frozen_matrix.json schema: required fields, types, finiteness.
  2. Unknown/missing macro handling: missing, null, non-numeric, or unrecognized
     macro fields are LOUD errors, never silent coercion. Exact zeros are real
     measured zeros and pass.
  3. perturbation_bounds.json consistency with uncertainty_assumptions.json:
     every applied bound must equal the cited/assumed bound, and every entry must
     be either sourced (with a citation) or explicitly flagged judgment_call.
  4. Bound lock: when outputs/manifest.json exists, sha256 of the bounds file,
     the assumptions file, and the frozen matrix must match the checksums recorded
     in the manifest - i.e. inputs were not edited after outputs were generated.

Exit code 0 = clean; 1 = validation failure (loud).
"""

import hashlib
import json
import math
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
INPUTS = HERE / "inputs"

MACRO_KEYS = ("calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g",
              "sodium_mg")

RECIPE_KEYS = ("id", "title", "purpose", "time_minutes", "tags", "matched_required",
               "total_required", "matched_optional", "missing_required_count",
               "personal_score", "macros_per_serving", "notes")

PROFILE_KEYS = ("id", "name", "goal", "daily_calories", "protein_pct", "carbs_pct",
                "fat_pct")

VALID_GOALS = {"general", "weight_loss", "muscle_gain", "maintenance"}

VALID_TAGS = {"quick", "vegetarian", "vegan", "asian", "breakfast", "budget",
              "comfort", "mediterranean", "mexican", "high_protein", "low_carb",
              "one_pot"}

NUTRIENT_KEYS = ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium")


class ValidationFailure(Exception):
    pass


def fail(msg):
    raise ValidationFailure(msg)


def require_number(value, where, allow_none=False):
    if allow_none and value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{where}: expected a number, got {value!r} "
             f"(type {type(value).__name__}) - unknown/missing values must fail "
             "loudly, not be coerced")
    value = float(value)
    if not math.isfinite(value):
        fail(f"{where}: non-finite number {value!r}")
    return value


def safe(fn, *args, **kwargs):
    """Run fn, converting ValidationFailure into a returned problem string."""
    try:
        return fn(*args, **kwargs)
    except ValidationFailure as exc:
        return [str(exc)]


def validate_matrix(matrix):
    problems = []

    if matrix.get("schema_version") != 1:
        problems.append(f"frozen matrix: unexpected schema_version {matrix.get('schema_version')!r}")

    recipes = matrix.get("recipes")
    if not isinstance(recipes, list) or not recipes:
        problems.append("frozen matrix: 'recipes' must be a non-empty list")
        recipes = []

    ids = set()
    for recipe in recipes:
        rid = recipe.get("id", "<no id>")
        for key in RECIPE_KEYS:
            if key not in recipe:
                problems.append(f"recipe {rid}: missing required key {key!r}")
        if rid in ids:
            problems.append(f"recipe {rid}: duplicate id")
        ids.add(rid)

        time_minutes = recipe.get("time_minutes")
        if isinstance(time_minutes, bool) or not isinstance(time_minutes, int) or time_minutes < 0:
            problems.append(f"recipe {rid}: time_minutes must be a non-negative int, got {time_minutes!r}")

        tags = recipe.get("tags")
        if not isinstance(tags, list) or any(t not in VALID_TAGS for t in tags):
            problems.append(f"recipe {rid}: tags must be a list of known tags, got {tags!r}")

        for key in ("matched_required", "total_required", "matched_optional",
                    "missing_required_count"):
            v = recipe.get(key)
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                problems.append(f"recipe {rid}: {key} must be a non-negative int, got {v!r}")
        matched, total = recipe.get("matched_required"), recipe.get("total_required")
        if isinstance(matched, int) and isinstance(total, int) and matched > total:
            problems.append(f"recipe {rid}: matched_required ({matched}) > total_required ({total})")

        personal = safe(require_number, recipe.get("personal_score"),
                        f"recipe {rid}.personal_score")
        if isinstance(personal, list):
            problems.extend(personal)
        elif not (-1.0 <= personal <= 1.0):
            problems.append(f"recipe {rid}: personal_score {personal} outside documented [-1.0, 1.0] range")

        macros = recipe.get("macros_per_serving")
        if not isinstance(macros, dict):
            problems.append(f"recipe {rid}: macros_per_serving must be an object")
            continue
        for key in MACRO_KEYS:
            if key not in macros:
                problems.append(
                    f"recipe {rid}: macro {key!r} MISSING - unknown/missing values must "
                    "fail loudly, not be silently coerced")
        for key in macros:
            if key not in MACRO_KEYS:
                problems.append(
                    f"recipe {rid}: UNKNOWN macro field {key!r} - fail loudly instead of "
                    "guessing how to treat it")
        for key in MACRO_KEYS:
            if key in macros:
                v = safe(require_number, macros[key], f"recipe {rid}.macros.{key}")
                if isinstance(v, list):
                    problems.extend(v)
                elif v is not None and v < 0:
                    problems.append(f"recipe {rid}: macro {key} is negative ({v})")

    profiles = matrix.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        problems.append("frozen matrix: 'profiles' must be a non-empty list")
        profiles = []
    profile_ids = set()
    for profile in profiles:
        pid = profile.get("id", "<no id>")
        if pid in profile_ids:
            problems.append(f"profile {pid}: duplicate id")
        profile_ids.add(pid)
        for key in PROFILE_KEYS:
            if key not in profile:
                problems.append(f"profile {pid}: missing required key {key!r}")
        if profile.get("goal") not in VALID_GOALS:
            problems.append(f"profile {pid}: unknown goal {profile.get('goal')!r}")
        daily = profile.get("daily_calories", "<missing>")
        if daily is not None:
            if isinstance(daily, bool) or not isinstance(daily, int) or daily <= 0:
                problems.append(
                    f"profile {pid}: daily_calories must be a positive int or null, got {daily!r}")
        pct_sum = 0.0
        for key in ("protein_pct", "carbs_pct", "fat_pct"):
            v = safe(require_number, profile.get(key), f"profile {pid}.{key}")
            if isinstance(v, list):
                problems.extend(v)
            else:
                pct_sum += v
        if pct_sum and abs(pct_sum - 1.0) > 1e-9:
            problems.append(f"profile {pid}: macro pcts sum to {pct_sum!r}, expected 1.0")

    return problems


def canonical_sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_bounds_vs_assumptions(bounds, assumptions):
    problems = []

    for envelope in ("plausible", "stress"):
        nut = bounds.get(envelope, {}).get("nutrients_pct")
        if not isinstance(nut, dict):
            problems.append(f"bounds: missing {envelope}.nutrients_pct")
            continue
        for key in NUTRIENT_KEYS:
            if key not in nut:
                problems.append(f"bounds: {envelope}.nutrients_pct missing {key!r}")
                continue
            v = nut[key]
            if isinstance(v, bool) or not isinstance(v, (int, float)) or not (0 < v < 100):
                problems.append(f"bounds: {envelope}.{key} = {v!r} is not a sensible percent bound (0,100)")

        portion = bounds.get(envelope, {}).get("portion_scale_pct")
        if isinstance(portion, bool) or not isinstance(portion, (int, float)) or not (0 < portion < 100):
            problems.append(f"bounds: {envelope}.portion_scale_pct = {portion!r} is not a sensible percent bound (0,100)")

    assump = assumptions.get("nutrients", {})
    for envelope, status_key, bound_key in (
        ("plausible", "plausible_status", "plausible_bound_pct"),
        ("stress", "stress_status", "stress_bound_pct"),
    ):
        for key in NUTRIENT_KEYS + ("portion_scale",):
            entry = assump.get(key)
            if not isinstance(entry, dict):
                problems.append(f"assumptions: missing nutrient entry {key!r}")
                continue
            applied = (bounds.get(envelope, {}).get("portion_scale_pct") if key == "portion_scale"
                       else bounds.get(envelope, {}).get("nutrients_pct", {}).get(key))
            cited = entry.get(bound_key)
            if applied is None or cited is None:
                problems.append(f"assumptions/bounds mismatch: {envelope}.{key} "
                                f"(applied={applied!r}, cited={cited!r})")
                continue
            if float(applied) != float(cited):
                problems.append(
                    f"assumptions/bounds MISMATCH: {envelope}.{key} bounds file applies "
                    f"{applied} but assumptions file records {cited}")
            status = entry.get(status_key)
            if status not in ("sourced", "sourced_with_bridging_judgment",
                              "judgment_call", "sourced_tail_used_as_judgment"):
                problems.append(f"assumptions: {envelope}.{key} has unrecognized status {status!r}")
            if status == "judgment_call":
                basis_key = "plausible_basis" if envelope == "plausible" else "stress_basis"
                if not entry.get(basis_key):
                    problems.append(
                        f"assumptions: {envelope}.{key} is a judgment_call but lacks an explicit basis")
            elif envelope == "plausible":
                citation = entry.get("plausible_citation") or entry.get("bridging_judgment")
                if not citation:
                    problems.append(f"assumptions: {envelope}.{key} claims sourced but has no citation")

    if not bounds.get("locked"):
        problems.append("bounds: file must be marked locked:true")
    if not bounds.get("locked_before_outputs"):
        problems.append("bounds: locked_before_outputs must be true (bounds are fixed before output inspection)")
    if not isinstance(bounds.get("draw_seed"), int):
        problems.append("bounds: draw_seed must be an int")

    arms = bounds.get("arms")
    if not isinstance(arms, list) or not any(a.get("id") == "control" for a in (arms or [])):
        problems.append("bounds: 'arms' must include a 'control' (unchanged) arm")
    else:
        ids = [a.get("id") for a in arms]
        if len(ids) != len(set(ids)):
            problems.append("bounds: duplicate arm ids")
        for arm in arms:
            if not isinstance(arm.get("draws"), int) or arm.get("draws", 0) < 1:
                problems.append(f"bounds: arm {arm.get('id')!r} needs draws >= 1")
            if arm.get("stress") and not arm.get("id", "").startswith("stress"):
                problems.append(f"bounds: arm {arm.get('id')!r} uses stress bounds without the stress label")

    return problems


def validate_lock(manifest_path: pathlib.Path):
    """If outputs exist, verify inputs were not edited after outputs were generated."""
    if not manifest_path.exists():
        return ([], [f"note: no outputs manifest at {manifest_path} - lock check deferred "
                     "(first run: bounds are being locked now)"])
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    recorded = manifest.get("inputs_checksums", {})
    problems = []
    notes = []
    for name, path in (
        ("perturbation_bounds.json", INPUTS / "perturbation_bounds.json"),
        ("uncertainty_assumptions.json", INPUTS / "uncertainty_assumptions.json"),
        ("frozen_matrix.json", INPUTS / "frozen_matrix.json"),
    ):
        actual = canonical_sha256(path)
        if name not in recorded:
            problems.append(f"lock: manifest has no checksum for {name}")
        elif recorded[name] != actual:
            problems.append(
                f"LOCK VIOLATION: {name} changed AFTER outputs were generated "
                f"(manifest {recorded[name][:16]}... != current {actual[:16]}...)")
        else:
            notes.append(f"lock ok: {name} sha256 {actual[:16]}... matches manifest")
    return problems, notes


def main() -> int:
    problems = []
    notes = []

    try:
        matrix = json.loads((INPUTS / "frozen_matrix.json").read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FATAL: frozen_matrix.json is not valid JSON: {exc}", file=sys.stderr)
        return 1
    try:
        bounds = json.loads((INPUTS / "perturbation_bounds.json").read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FATAL: perturbation_bounds.json is not valid JSON: {exc}", file=sys.stderr)
        return 1
    try:
        assumptions = json.loads((INPUTS / "uncertainty_assumptions.json").read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FATAL: uncertainty_assumptions.json is not valid JSON: {exc}", file=sys.stderr)
        return 1

    problems.extend(validate_matrix(matrix))
    problems.extend(validate_bounds_vs_assumptions(bounds, assumptions))
    lock_problems, lock_notes = validate_lock(HERE / "outputs" / "manifest.json")
    problems.extend(lock_problems)
    notes.extend(lock_notes)

    print("check_inputs.py")
    print(f"  recipes validated: {len(matrix.get('recipes', []))}")
    print(f"  profiles validated: {len(matrix.get('profiles', []))}")
    print(f"  arms: {len(bounds.get('arms', []))} (control + "
          f"{sum(1 for a in bounds.get('arms', []) if a.get('stress'))} stress-labeled)")
    for note in notes:
        print(f"  {note}")
    if problems:
        print(f"FAILED with {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("  ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
