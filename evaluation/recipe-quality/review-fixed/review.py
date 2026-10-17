#!/usr/bin/env python3
"""A cook's review of the 189 agent-fixed catalog recipes (burst14).

On Oct 16 the agent-written fix packets amounts-a (#196), amounts-b (#195) and
rubric (#197) changed 189 corpus recipes. Before anyone outside the team cooks
from them, this script lists the review set reproducibly, recompiles each
current corpus record in memory with the real compiler
(data/recipes/tools/compile_bundle.py) and the four kcal rows
burst14-fridgeluck-kcal-pins replaces (#205: chicken thighs, dry white rice,
canned tomatoes), and runs the rubric's mechanical checks by importing the
rubric's audit.py.

Read-only: it writes nothing but findings.json beside this script.

Usage:
    python3 evaluation/recipe-quality/review-fixed/review.py
"""
from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]  # evaluation/recipe-quality/review-fixed -> repo root
sys.path.insert(0, str(REPO / "data/recipes/tools"))
sys.path.insert(0, str(REPO / "evaluation/recipe-quality/rubric"))

import compile_bundle as compiler  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402
import audit  # noqa: E402  (the rubric's mechanical sweep)

PACKET = "burst14-fridgeluck-review-fixed-recipes"
FIX_FILES = ["amounts-a.json", "amounts-b.json", "rubric.json"]
FIX_DIR = REPO / "data/recipes/fixes"

# Recipes whose cooked-rice lines burst14-fridgeluck-kcal-pins owns; this
# review stays out of them. Rice lines are judged as cooked rice.
SKIP_CATALOG_IDS = {
    "rcp-000573", "rcp-000580", "rcp-000586", "rcp-000589", "rcp-000599",
    "rcp-000605", "rcp-000610", "rcp-000631", "rcp-000634", "rcp-000645",
    "rcp-000649", "rcp-000652", "rcp-000686", "rcp-000722",
}

# The per-100g rows burst14-fridgeluck-kcal-pins replaces (#205). Applied
# in memory so every kcal judgment in this review already prices them.
# fdc 173627 (chicken thighs, raw), fdc 168877 (white rice, dry),
# fdc 170501 (canned tomatoes).
KCAL_PIN_ROWS = {
    "chicken_thighs": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                       "fat_g": 4.12, "sodium_mg": 95.0},
    "chicken_thigh": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                      "fat_g": 4.12, "sodium_mg": 95.0},
    "white_rice": {"kcal": 365.0, "protein_g": 7.13, "carbs_g": 79.95,
                   "fat_g": 0.66, "sodium_mg": 5.0},
    "canned_tomatoes": {"kcal": 32.0, "protein_g": 1.64, "carbs_g": 7.29,
                        "fat_g": 0.28, "sodium_mg": 186.0},
}

# Plausibility bands beyond the rubric: per-serving protein from the
# (raw-basis) rows, for a main (lunch/dinner slot).
PROTEIN_MIN, PROTEIN_MAX = 110.0, 225.0
KCAL_MIN, KCAL_MAX = 150.0, 1300.0
SODIUM_MAX = 2300.0


def base_commit() -> str:
    return subprocess.run(["git", "rev-parse", "alpha"], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout.strip()


def review_set() -> tuple[dict[str, str], dict[str, bool]]:
    """corpus id -> packet file, and id -> changes_rights_pin, from the three
    applied packets. One recipe, one decision — two files fixing one id is an
    error the applier also refuses."""
    by_id: dict[str, str] = {}
    pins: dict[str, bool] = {}
    for name in FIX_FILES:
        doc = json.loads((FIX_DIR / name).read_text(encoding="utf-8"))
        assert doc["schema"] == "fridgeluck/corpus-fixes/v1"
        for fix in doc["fixes"]:
            fid = fix["id"]
            if fid in by_id:
                raise SystemExit(f"two packets fix {fid}")
            by_id[fid] = name
            pins[fid] = bool(fix.get("changes_rights_pin"))
    return by_id, pins


def compile_inputs() -> dict:
    """The real compiler's own inputs, built exactly as compile_bundle.main
    builds them (labels from the release gate, legacy links attached)."""
    mappings = json.loads((REPO / "data/ingredients/name-mappings.json")
                          .read_text(encoding="utf-8"))["mappings"]
    vocab = json.loads((REPO / "data/ingredients/vocabulary.json")
                       .read_text(encoding="utf-8"))["entries"]
    vocab_by_key = {e["key"]: copy.deepcopy(e) for e in vocab}
    for key, row in KCAL_PIN_ROWS.items():
        vocab_by_key[key]["per_100g"].update(row)
    # compile_recipe looks up a rights record by source_ref or recipe id and
    # reads only its "origin" (the bundle's rights.evidence string). This
    # review recompiles in memory and never writes a bundle, so each recipe
    # carries its own license evidence as origin.
    evidence = json.loads((REPO / "data/recipes/evidence/rights.json")
                          .read_text(encoding="utf-8"))
    origin = evidence["originals"]["records"].get(
        "fl-original-0001", {}).get("license_evidence",
        "LicenseRef-FL-Original")
    rights = {}
    for rec, _ in _corpus:
        entry = {"origin": origin}
        rights[rec["id"]] = entry
        if rec.get("source_ref"):
            rights[rec["source_ref"]] = entry
    ctx = vcorpus.load_rights_context()
    labels = {rec["id"]: compiler.rights_label_for(rec, ctx)
              for rec, _ in _corpus}
    for key, lid in compiler.legacy_ids_by_key().items():
        vocab_by_key[key]["legacy_id"] = lid
    return {"mappings": mappings, "vocab_by_key": vocab_by_key,
            "rights": rights, "labels": labels}


_corpus: list = []


def main() -> int:
    global _corpus
    recs, raw = audit.load_corpus()
    _corpus = [(r, raw[r["id"]]) for r in recs]
    by_id, pins = review_set()
    inputs = compile_inputs()

    audit_ctx = audit.Context()
    # same in-memory rows for the mechanical kcal/sodium arithmetic
    for key, row in KCAL_PIN_ROWS.items():
        audit_ctx.per100[key] = {**(audit_ctx.per100.get(key) or {}), **row}

    base = base_commit()
    recipes = []
    for fid, packet_name in sorted(by_id.items()):
        rec = next((r for r in recs if r["id"] == fid), None)
        entry: dict = {
            "id": fid,
            "catalog_id": vcorpus.catalog_id_for(fid),
            "title": rec["title"] if rec else None,
            "packet": packet_name,
            "changes_rights_pin": pins[fid],
            "before_sha256": hashlib.sha256(raw[fid].encode("utf-8")).hexdigest(),
        }
        if rec is None:
            entry["compile_ok"] = False
            entry["compile_error"] = "id not in corpus"
            recipes.append(entry)
            continue
        entry["servings"] = rec["servings"]
        entry["minutes"] = rec["minutes"]
        entry["meal_slots"] = rec["meal_slots"]
        try:
            compiled = compiler.compile_recipe(
                rec, inputs["mappings"], inputs["vocab_by_key"],
                inputs["rights"], inputs["labels"])
            entry["compile_ok"] = True
            n = compiled["nutrition_per_serving"]
            entry["nutrition_per_serving"] = n
            protein = n["protein_g"]
        except SystemExit as exc:
            entry["compile_ok"] = False
            entry["compile_error"] = str(exc)
            recipes.append(entry)
            continue

        mech = audit.evaluate(rec, audit_ctx)
        entry["audit"] = mech

        # Raw-basis protein-food grams per serving: the cook's "would this
        # feed N people" check. Sum of line grams whose vocabulary category
        # is a protein food (meat, fish, egg, dairy-protein), from the same
        # mapping the compiler uses.
        protein_food_g = 0.0
        for ing in rec["ingredients"]:
            norm = compiler.normalize_name(ing["name"])
            m = inputs["mappings"].get(norm)
            if not m:
                continue
            cat = inputs["vocab_by_key"].get(m["key"], {}).get("category")
            if cat in ("meat", "fish", "egg"):
                q = ing["qty"]
                g = q.get("grams") if q["kind"] != "unknown" else None
                if g:
                    protein_food_g += float(g)
        entry["protein_food_g_per_serving"] = round(
            protein_food_g / rec["servings"], 1) if rec["servings"] else None

        flags: list[str] = []
        if not (KCAL_MIN <= n["kcal"] <= KCAL_MAX):
            flags.append(f"C2 kcal per serving {n['kcal']} outside {KCAL_MIN:g}-{KCAL_MAX:g}")
        if n["sodium_mg"] > SODIUM_MAX:
            flags.append(f"C5 sodium per serving {n['sodium_mg']} mg over {SODIUM_MAX:g}")
        if mech["missing_food_in_steps"]:
            flags.append("C1 step names food with no line: "
                         + ", ".join(mech["missing_food_in_steps"]))
        if mech["uncovered_title_tokens"]:
            flags.append("C1 title tokens no line covers: "
                         + ", ".join(mech["uncovered_title_tokens"]))
        if mech["unused_lines"]:
            flags.append("C1 lines no step uses: " + ", ".join(mech["unused_lines"]))
        if mech["visual_done_phrases"]:
            flags.append("C4 visual doneness beside the thermometer: "
                         + ", ".join(mech["visual_done_phrases"]))
        if mech["uncovered_fsis"]:
            flags.append("C4 uncovered FSIS classes: "
                         + ", ".join(mech["uncovered_fsis"]))
        if mech["preheat_after_bake"]:
            flags.append("C3 preheat after the bake/roast")
        if mech["heat_before_prep"]:
            flags.append("C3 heat before prep: "
                         + ", ".join(mech["heat_before_prep"]))
        if mech["timer_sum"] > mech["minutes"] * 1.25:
            flags.append(f"C7 timers {mech['timer_sum']} min vs {mech['minutes']} min promise")
        slots = {s.lower() for s in rec["meal_slots"]}
        pfp = entry["protein_food_g_per_serving"]
        if slots & {"lunch", "dinner"} and pfp is not None:
            if not (PROTEIN_MIN <= pfp <= PROTEIN_MAX):
                flags.append(
                    f"C2 raw protein food {pfp} g/serving outside "
                    f"{PROTEIN_MIN:g}-{PROTEIN_MAX:g} for a main")
        entry["red_flags"] = flags
        recipes.append(entry)

    skipped = sorted(SKIP_CATALOG_IDS
                     & {vcorpus.catalog_id_for(fid) for fid in by_id})
    doc = {
        "packet": PACKET,
        "base_commit": base,
        "review_set": len(by_id),
        "kcal_pin_rows_applied": sorted(KCAL_PIN_ROWS),
        "skipped_burst14_kcal_pins_catalog_ids": skipped,
        "recipes": recipes,
    }
    out = HERE / "findings.json"
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n",
                   encoding="utf-8")
    n_flags = sum(1 for r in recipes if r.get("red_flags"))
    print(f"{len(recipes)} recipes reviewed, {n_flags} with red flags "
          f"-> {out.relative_to(REPO)}")
    for r in recipes:
        if r.get("red_flags"):
            print(f"  {r['catalog_id']} {r['title']!r}: {len(r['red_flags'])} flag(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
