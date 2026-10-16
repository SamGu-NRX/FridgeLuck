#!/usr/bin/env python3
"""Compile the world-2026-10 regional source modules into RS v1 records.

Inputs:  src/recipes_{east_asia,south_east_asia,mena,americas_europe}.py
         src/fndds_registry.py, src/safety_lines.py
         suite recipes linter (RS_SUITE_DIR, default /tmp/fl-suite/evaluation/
         suites/recipes) for the canon rulebook and the exact safety matchers
         the scored-tree linter runs.
         data/recipe-sources/world-2026-10/evidence/allergen-classes-extension.json
         (authored classification rows for names outside the suite fixture's
         alias vocabulary; see README "Classification table").
Output:  originals.jsonl (one RS v1 record per line, deterministic order) and
         build-report.json (per-recipe safety attachment log, coverage counts,
         vocabulary gap list).

Safety attachment mirrors the suite linter's own derivation (_r3_safety):
required classes come from the classification table's ingredient classes,
the canon rulebook's per-ingredient and per-title classes, and reheat flags.
Every required class must be covered by a check step whose text names a
cook-visible thermometer reading of at least the class minimum (the same
binding patterns rs.py applies), and whole-cut classes must state the
required rest in the instruction text. The build fails loudly on any gap.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(HERE))

import fndds_registry as registry  # noqa: E402
import safety_lines  # noqa: E402

SUITE = Path(os.environ.get("RS_SUITE_DIR",
                            "/tmp/fl-suite/evaluation/suites/recipes"))
sys.path.insert(0, str(SUITE))
import rs  # noqa: E402  (suite linter: canon rulebook + exact matchers)

import recipes_east_asia  # noqa: E402
import recipes_south_east_asia  # noqa: E402
import recipes_mena  # noqa: E402
import recipes_americas_europe  # noqa: E402

MODULES = [recipes_east_asia, recipes_south_east_asia,
           recipes_mena, recipes_americas_europe]

# RS v1 six-value cuisine vocabulary. The compatibility facet is lossy by
# design: world_cuisine (the extension field) carries the true cuisine.
# Mapping rationale = shared staple pantry / technique family, recorded in
# the README; a spec revision should extend the vocabulary instead.
CUISINE_MAP = {
    "korean": "asian", "japanese": "asian", "chinese": "asian",
    "thai": "asian", "vietnamese": "asian",
    "middle_eastern": "mediterranean", "north_african": "mediterranean",
    "west_african": "indian",
    "caribbean": "american",
    "latin_american": "mexican",
    "eastern_european": "italian",
}

FNDDS_TABLE = Path(os.environ.get("FNDDS_TABLE", "/tmp/mck.json"))
EXTENSION_TABLE = PKG / "evidence" / "allergen-classes-extension.json"

# Ingredients that make a recipe non-vegetarian (beyond canon-classified
# flesh): animal-derived seasonings and stocks. Used for the REPORT's
# vegetarian share only; never attached to records as claims.
ANIMAL_NAMES = {
    "nuoc mam", "hao you", "dashi", "broth", "stock", "beef broth",
    "pork cracklings", "anchovies", "fish cake", "shiitake dashi",
    "worcestershire sauce", "gelatin", "lard", "bacon", "salted duck egg",
}


def load_fndds_index() -> dict[tuple[str, str], dict]:
    data = json.loads(FNDDS_TABLE.read_text())
    idx = {}
    for row in data["portions"]:
        food = " ".join(str(row.get("food", "")).split()).lower()
        key = (food, str(row.get("unit", "")).strip())
        idx.setdefault(key, row)
    return idx


def load_classification_table() -> dict:
    """Suite fixture table extended with the packet's authored rows."""
    fixture = json.loads((SUITE / "allergens.json").read_text())
    merged = json.loads(json.dumps(fixture))  # deep copy
    if EXTENSION_TABLE.is_file():
        ext = json.loads(EXTENSION_TABLE.read_text())
        for alias, key in ext.get("ingredient_aliases", {}).items():
            merged["ingredient_aliases"][alias] = key
        for key, row in ext.get("ingredients", {}).items():
            merged["ingredients"].setdefault(key, row)
    return merged


def build_class_keywords(canon: rs.CanonRulebook, rules_path: Path) -> dict[str, list[str]]:
    """class -> ingredient-style keywords (doneness topic, non-dish words)."""
    data = json.loads(rules_path.read_text())
    out: dict[str, list[str]] = {}
    dish_words = ("casserole", "lasagne", "lasagna", "gratin", "hotdish",
                  "bake", "shepherd")
    for rule in data["rules"]:
        if rule.get("topic") != "doneness":
            continue
        cls = rule.get("food_class")
        if not cls:
            continue
        for kw in rule.get("match_keywords", []) or []:
            if any(d in kw.lower() for d in dish_words):
                continue
            out.setdefault(cls, []).append(str(kw).lower())
    return out


def resolve_household(name: str, unit: str, fndds: dict, gaps: list[str]):
    """(line_name, unit) -> (conversion_ref, row_payload, grams)."""
    key = (name.strip().lower(), unit)
    entry = registry.DIRECT.get(key) or registry.DERIVED.get(key)
    if entry is None:
        gaps.append(f"{name!r} unit {unit!r}: no registry row")
        return None
    derived_mult = None
    if key in registry.DERIVED:
        fndds_food, fndds_unit, derived_mult = entry
    else:
        fndds_food, fndds_unit = entry
    row = fndds.get((fndds_food.lower(), fndds_unit))
    if row is None:
        gaps.append(f"{name!r} unit {unit!r}: FNDDS row missing for "
                    f"({fndds_food!r}, {fndds_unit!r})")
        return None
    gpu = float(row["grams"]) / float(row["magnitude"])
    if derived_mult:
        gpu *= derived_mult
    ref = f"fndds:{row['fdcId']}"
    evidence = (f"FNDDS 2024-10-31 portion row fdcId {row['fdcId']} "
                f"('{row['food']}', {row['unit']}): {row['grams']} g per "
                f"{row['magnitude']} {row['unit']}(s); pinned by "
                f"MassConversionKit (FridgeLuck PR #50, branch "
                f"obv/fl-l2-mass-evidence)")
    if derived_mult:
        evidence += (f"; derived: 1 {unit} = {derived_mult} {fndds_unit} "
                     "(arithmetic on the pinned row)")
    payload = {"unit": unit, "grams_per_unit": round(gpu, 4),
               "source": registry.SOURCE_NAME, "evidence": evidence}
    return ref, payload


def compile_recipe(entry: dict, idx: int, canon: rs.CanonRulebook,
                   class_kw: dict[str, list[str]], fndds: dict,
                   gaps: list[str]) -> tuple[dict | None, list[str]]:
    """One source entry -> RS record + per-recipe build notes."""
    errors: list[str] = []
    rid = f"fl-world-{idx:04d}"
    slug = re.sub(r"[^a-z0-9]+", "-", entry["title"].lower()).strip("-")
    lines = []
    conv_rows: dict[str, dict] = {}
    conv_refs: dict[str, dict] = {}
    for name, qty in entry["ingredients"]:
        if qty[0] == "g":
            lines.append({"name": name,
                          "qty": {"kind": "source_grams", "grams": qty[1]}})
        elif qty[0] == "hh":
            _, value, unit = qty
            res = resolve_household(name, unit, fndds, gaps)
            if res is None:
                continue
            ref, payload = res
            grams = round(float(value) * payload["grams_per_unit"], 1)
            lines.append({"name": name,
                          "qty": {"kind": "household", "value": value,
                                  "unit": unit, "grams": grams,
                                  "conversion_ref": ref}})
            row = conv_rows.setdefault(ref, {
                "ref": ref, "ingredient": [], "unit": unit,
                "grams_per_unit": payload["grams_per_unit"],
                "source": payload["source"], "evidence": payload["evidence"]})
            if name not in row["ingredient"]:
                row["ingredient"].append(name)
            if unit != row["unit"]:
                errors.append(f"{name!r}: unit {unit!r} disagrees with row "
                              f"{ref} unit {row['unit']!r}")
        elif qty[0] == "u":
            lines.append({"name": name,
                          "qty": {"kind": "unknown", "note": qty[1]}})
        else:
            errors.append(f"{name!r}: unknown qty form {qty!r}")
    if errors or gaps:
        return None, errors

    steps = [{"text": t} for t in entry["steps"]]

    # -- required safety classes (mirror of the linter's derivation) --------
    ing_names = [l["name"] for l in lines]
    scanner = CLASS_SCANNER
    allergen_classes, unknown_names = scanner.classify(
        {"ingredients": [{"name": n} for n in ing_names]})
    required: dict[str, dict[str, float]] = {}

    def require(cls: str) -> None:
        if cls not in rs.RS_SAFETY_CLASSES:
            return
        cur = required.setdefault(cls, {"temp_f": canon.class_min_f[cls],
                                        "rest": canon.class_rest_min[cls]})
        cur["temp_f"] = max(cur["temp_f"], canon.class_min_f[cls])
        cur["rest"] = max(cur["rest"], canon.class_rest_min[cls])

    for cls in allergen_classes:
        if cls in rs.INGREDIENT_SAFETY_CLASSES:
            require(cls)
    for name in ing_names:
        for cls in canon.classes_for_name(name):
            require(cls)
    for cls in canon.classes_for_title(entry["title"]):
        require(cls)

    unresolved = sorted(n for n in unknown_names
                        if not canon.classes_for_name(n))
    if unresolved:
        errors.append(f"unresolved ingredient names (not in the merged "
                      f"classification table and no canon class): {unresolved}")

    # -- attach one check per required class --------------------------------
    claimed: set[int] = set()
    notes: list[dict] = []
    for cls in sorted(required):
        need = required[cls]
        kws = class_kw.get(cls, [])
        keyword_hits = []
        reading_hits = []
        for i, step in enumerate(steps):
            text = str(step["text"])
            reading = rs._text_internal_reading_f(text)
            if reading is None or reading < need["temp_f"]:
                continue
            if i in claimed:
                continue
            if any(re.search(rf"\b{re.escape(kw)}\b", text.lower())
                   for kw in kws):
                keyword_hits.append(i)
            else:
                reading_hits.append(i)
        pick = (keyword_hits or reading_hits or [None])[0]
        if pick is None:
            errors.append(f"required class {cls} (min {need['temp_f']:.0f} F) "
                          f"has no step with a cook-visible thermometer "
                          f"reading of at least the minimum")
            continue
        text = str(steps[pick]["text"])
        stated_rest = rs._stated_rest(steps[pick])
        if need["rest"] and (stated_rest is None or stated_rest < need["rest"]):
            errors.append(f"check step for {cls} states no {need['rest']:.0f}-"
                          f"minute rest in its text: \"{text[:80]}...\"")
        steps[pick]["safety"] = {"class": cls,
                                 "temp_f": rs._text_internal_reading_f(text),
                                 "method": "thermometer",
                                 "source": safety_lines.FSIS_SOURCE}
        claimed.add(pick)
        notes.append({"class": cls, "step": pick,
                      "temp_f": steps[pick]["safety"]["temp_f"],
                      "rest_stated": stated_rest,
                      "matched_by": "keyword" if keyword_hits else "reading"})

    # -- doneness by colour/time on steps of recipes with required classes --
    if required:
        for i, step in enumerate(steps):
            m = rs._COLOUR_OR_TIME_DONENESS.search(str(step["text"]))
            if m:
                errors.append(f"step[{i}] uses colour/time doneness wording "
                              f"({m.group(0)!r}) without a thermometer: "
                              f"\"{str(step['text'])[:80]}...\"")
        for i, step in enumerate(steps):
            if rs._REHEAT_TEXT.search(str(step["text"])):
                errors.append(f"step[{i}] reads as reheating but the packet "
                              f"authors no reheat steps")
    if errors:
        return None, errors

    record = {
        "rs_version": "1",
        "id": rid,
        "title": entry["title"],
        "cuisine": CUISINE_MAP[entry["region"]],
        "world_cuisine": entry["region"],
        "meal_slots": list(entry["slots"]),
        "minutes": entry["minutes"],
        "servings": entry["servings"],
        "ingredients": lines,
        "steps": steps,
        "source_ref": f"fl-world:{slug}",
        "provenance": {
            "source": ("authored original recipe — FridgeLuck "
                       "world-2026-10 packet (no third-party text)"),
            "quantity_note": ("source_grams lines carry the recipe-stated "
                              "metric mass; household lines cite the pinned "
                              "FNDDS conversion row carried in the record's "
                              "conversions; unknown lines are genuinely "
                              "unquantified (to taste / for frying)"),
        },
        "conversions": conv_rows,
    }
    return record, notes


CLASS_SCANNER = None  # set in main()


def main() -> int:
    global CLASS_SCANNER
    canon, canon_desc = rs.CanonRulebook.load(None)
    if canon is None:
        print(f"BUILD FAILED: {canon_desc}", file=sys.stderr)
        return 2
    print(f"canon: {canon_desc}")

    table = load_classification_table()
    CLASS_SCANNER = rs.AllergenScanner(table, facts=None,
                                       facts_reason="packet ships no claims")

    fndds = load_fndds_index()
    class_kw = build_class_keywords(canon, SUITE / "canon" / "rules.json")

    records, notes_by_id, all_gaps, all_errors = [], {}, [], []
    idx = 0
    for module in MODULES:
        for entry in module.RECIPES:
            idx += 1
            gaps: list[str] = []
            rec, notes = compile_recipe(entry, idx, canon, class_kw, fndds,
                                        gaps)
            all_gaps.extend(f"{entry['title']}: {g}" for g in gaps)
            if rec is None:
                all_errors.append(f"{entry['title']}: " + "; ".join(notes))
            else:
                records.append(rec)
                notes_by_id[rec["id"]] = notes

    if all_gaps:
        print(f"BUILD FAILED — {len(all_gaps)} evidence gap(s):",
              file=sys.stderr)
        for g in sorted(set(all_gaps)):
            print("  " + g, file=sys.stderr)
    if all_errors:
        print(f"BUILD FAILED — {len(all_errors)} recipe error(s):",
              file=sys.stderr)
        for e in all_errors:
            print("  " + e, file=sys.stderr)
    if all_gaps or all_errors:
        return 1

    out = PKG / "originals.jsonl"
    with out.open("w") as fh:
        for rec in records:
            fh.write(json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n")

    # report
    n_lines = sum(len(r["ingredients"]) for r in records)
    resolved = sum(1 for r in records for l in r["ingredients"]
                   if l["qty"]["kind"] != "unknown")
    veg = 0
    for r in records:
        animal = False
        for l in r["ingredients"]:
            nm = l["name"].lower()
            classes = set()
            key = table["ingredient_aliases"].get(nm)
            if key:
                classes |= set(table["ingredients"].get(key, {}).get("classes", []))
            classes |= canon.classes_for_name(nm)
            if classes & {"meat_poultry", "meat_ground", "meat_whole_cut_pork",
                          "meat_whole_cut_red", "flesh_fish", "flesh_shellfish"} \
               or nm in ANIMAL_NAMES:
                animal = True
                break
        if not animal:
            veg += 1
    slots = {}
    cuisines = {}
    for r in records:
        for s in r["meal_slots"]:
            slots[s] = slots.get(s, 0) + 1
        cuisines[r["cuisine"]] = cuisines.get(r["cuisine"], 0) + 1
    report = {
        "recipes": len(records),
        "ingredient_lines": n_lines,
        "resolved_lines": resolved,
        "unknown_lines": n_lines - resolved,
        "vegetarian_count": veg,
        "vegetarian_share": round(veg / len(records), 3),
        "slots": slots,
        "cuisines": cuisines,
        "canon": canon_desc,
        "safety_notes": notes_by_id,
    }
    (PKG / "build-report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"built {len(records)} recipes -> {out}")
    print(f"lines: {resolved}/{n_lines} resolved; vegetarian {veg}"
          f"/{len(records)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
