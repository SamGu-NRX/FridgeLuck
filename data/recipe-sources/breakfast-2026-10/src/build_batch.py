#!/usr/bin/env python3
"""Compile the breakfast-2026-10 source module into RS v1 records.

Inputs:  src/recipes_breakfast.py, src/fndds_registry.py,
         data/recipe-sources/world-2026-10/src/safety_lines.py (pinned),
         suite recipes linter (RS_SUITE_DIR, default /tmp/fl-suite/evaluation/
         suites/recipes) for the canon rulebook and exact safety matchers,
         evidence/allergen-classes-extension.json (classification rows for
         names outside the suite fixture's alias table),
         data/ingredients/name-mappings.json + vocabulary.json (the app's
         composition-class vocabulary, for the report's diet-composition
         lines — the same classes the catalog compiler derives claims from).
Output:  originals.jsonl (one RS v1 record per line, deterministic order) and
         build-report.json (safety attachment log, coverage counts, diet-
         composition lines, vocabulary gap list).

Safety attachment mirrors the suite linter's own derivation (_r3_safety),
copied from the world-2026-10 compiler (see that file for the derivation
notes). The build fails loudly on any gap.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
WORLD_SRC = PKG.parent / "world-2026-10" / "src"
REPO = PKG.parents[2]
sys.path.insert(0, str(WORLD_SRC))
sys.path.insert(0, str(HERE))

import fndds_registry as registry  # noqa: E402  (this packet's registry)
import safety_lines  # noqa: E402  (pinned, world-2026-10/src)

SUITE = Path(os.environ.get("RS_SUITE_DIR",
                            "/tmp/fl-suite/evaluation/suites/recipes"))
sys.path.insert(0, str(SUITE))
import rs  # noqa: E402  (suite linter: canon rulebook + exact matchers)

import recipes_breakfast  # noqa: E402

MODULES = [recipes_breakfast]

# RS v1 six-value cuisine vocabulary, extended to cover this packet's
# regions. american and british -> american (shared porridge/toast/egg
# pantry); indian -> indian; mediterranean -> mediterranean. Lossy by design
# (the compatibility facet stays lossy); rationale recorded in the README.
CUISINE_MAP = {
    "korean": "asian", "japanese": "asian", "chinese": "asian",
    "thai": "asian", "vietnamese": "asian",
    "middle_eastern": "mediterranean", "north_african": "mediterranean",
    "mediterranean": "mediterranean",
    "indian": "indian",
    "west_african": "indian",
    "caribbean": "american",
    "american": "american",
    "british": "american",
    "latin_american": "mexican",
    "eastern_european": "italian",
}

FNDDS_TABLE = Path(os.environ.get("FNDDS_TABLE", "/tmp/mck.json"))
EXTENSION_TABLE = PKG / "evidence" / "allergen-classes-extension.json"

# Ingredients that make a recipe non-vegetarian (beyond canon-classified
# flesh): animal-derived seasonings and stocks. Used for the REPORT's
# vegetarian share only; never attached to records as claims.
ANIMAL_NAMES = {
    "nuoc mam", "fish sauce", "hao you", "dashi", "broth", "stock",
    "beef broth", "pork cracklings", "anchovies", "fish cake",
    "shiitake dashi", "worcestershire sauce", "gelatin", "lard", "bacon",
    "salted duck egg",
}

# Vocabulary composition classes that block diet claims (fail-closed):
# the catalog derives vegan/vegetarian/gluten-free from these same classes.
NON_VEGAN_CLASSES = {"meat", "fish", "shellfish", "egg", "animal_product"}
NON_VEGETARIAN_CLASSES = {"meat", "fish", "shellfish"}


def load_vocab() -> tuple[dict, dict]:
    """name-mappings surface -> key, and key -> vocabulary entry."""
    mappings = json.loads(
        (REPO / "data" / "ingredients" / "name-mappings.json").read_text())
    surface_map = mappings.get("mappings", mappings)
    vocab = json.loads(
        (REPO / "data" / "ingredients" / "vocabulary.json").read_text())
    entries = {e["key"]: e for e in vocab.get("entries", [])}
    return surface_map, entries


def diet_composition(ingredient_names: list[str], surface_map: dict,
                     entries: dict) -> dict:
    """Composition-derived claim feasibility for one recipe's lines.

    Mirrors the catalog compiler's fail-closed derivation: a line whose
    surface name does not resolve in name-mappings, or whose vocabulary
    entry carries the 'unknown' marker, blocks every claim for the recipe.
    """
    has_unknown = False
    non_vegan = False
    non_veg = False
    non_gf = False
    unresolved = []
    for name in ingredient_names:
        hit = surface_map.get(str(name).lower())
        key = hit.get("key") if hit else None
        entry = entries.get(key) if key else None
        if not entry:
            unresolved.append(name)
            has_unknown = True
            continue
        classes = set(entry.get("classes", []))
        if "unknown" in classes:
            has_unknown = True
        if classes & NON_VEGAN_CLASSES:
            non_vegan = True
        if classes & NON_VEGETARIAN_CLASSES:
            non_veg = True
        if "gluten" in classes:
            non_gf = True
    return {
        "vegan_known": bool(not has_unknown and not non_vegan),
        "vegetarian_known": bool(not has_unknown and not non_veg),
        "gluten_free_known": bool(not has_unknown and not non_gf),
        "unknown_lines": sorted(set(unresolved)),
    }


def load_fndds_index() -> dict[tuple[str, str], dict]:
    data = json.loads(FNDDS_TABLE.read_text())
    idx = {}
    for row in data["portions"]:
        food = " ".join(str(row.get("food", "")).split()).lower()
        idx.setdefault((food, str(row.get("unit", "")).strip()), row)
    return idx


def load_classification_table() -> dict:
    fixture = json.loads((WORLD_SRC / "allergens.json").read_text())
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
    rid = f"fl-bfast-{idx:04d}"
    slug = re.sub(r"[^a-z0-9]+", "-", entry["title"].lower()).strip("-")
    lines = []
    conv_rows: dict[str, dict] = {}
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
        "source_ref": f"fl-breakfast:{slug}",
        "provenance": {
            "source": ("authored original recipe — FridgeLuck "
                       "breakfast-2026-10 packet (no third-party text)"),
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
    surface_map, entries = load_vocab()

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
    diet = []
    for r in records:
        comp = diet_composition([l["name"] for l in r["ingredients"]],
                                surface_map, entries)
        diet.append({"id": r["id"], "title": r["title"],
                     "minutes": r["minutes"], **comp})
    report = {
        "recipes": len(records),
        "ingredient_lines": n_lines,
        "resolved_lines": resolved,
        "unknown_lines": n_lines - resolved,
        "vegetarian_count": veg,
        "vegetarian_share": round(veg / len(records), 3),
        "slots": slots,
        "cuisines": cuisines,
        "fast15_count": sum(1 for r in records if r["minutes"] <= 15),
        "diet_composition": diet,
        "canon": canon_desc,
        "safety_notes": notes_by_id,
    }
    (PKG / "build-report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"built {len(records)} recipes -> {out}")
    print(f"lines: {resolved}/{n_lines} resolved; vegetarian {veg}"
          f"/{len(records)}; fast15 {report['fast15_count']}"
          f"; vegan-or-gf-known "
          f"{sum(1 for d in diet if d['vegan_known'] or d['gluten_free_known'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
