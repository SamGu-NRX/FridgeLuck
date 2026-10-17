#!/usr/bin/env python3
"""kcal audit: per-serving kcal of every recipe at two vocabulary states.

The PR #192 re-pin of catalog ingredient rows to different USDA FDC rows
re-sourced the vocabulary's per-100 g nutrition for several keys from rows
that describe a different preparation form than the recipes measure, and the
#210 corpus rebuild changed the corpus between 9e4a3af5 and af856008, so the
original 9e4a3af5 basis of this audit is no longer reproducible from the
committed corpus (the audit's snapshot was rebased; see
kcal_prev_af856008.json's note).

This script recompiles the bundle IN MEMORY with the real compiler
(data/recipes/tools/compile_bundle.py, imported, never copied) at two
vocabulary states:

  prev   the af856008 (pre-#205/#222) per-100 g rows for the re-sourced keys
         and the af856008 cooked-rice name mappings, taken from
         evaluation/kcal-audit/kcal_prev_af856008.json (extracted with
         `git show af856008:...`; the corpus, rights and compiler are
         unchanged af856008..this branch, so this state reproduces the
         previously published bundle's kcal exactly -- asserted in
         test_kcal_audit.py)
  fixed  the committed vocabulary and name mappings on this branch, i.e.
         exactly what ships: the four nutrient-row re-choices plus the
         lead-review cooked-rice decision (cooked-rice lines resolve to the
         rice key with dry-equivalent grams; the cooked_rice key is removed)

and prints, per recipe that moves more than 40 percent at the fixed state,
its kcal per serving at prev / fixed plus the deciding lines.

Identity pins follow the lead review of PR #221: cooked-rice lines resolve
to the rice key (matching and pantry deduction keep working against the
user's rice stock), their corpus-pinned cooked-form grams are stored as
dry-equivalent weights (one sourced factor, 365/129 = 2.83, the energy ratio
of fdc 168877 dry vs fdc 2708403 cooked; USDA puts the cooked:white ratio at
about 2.8x), and the cooked_rice key is removed from the shipped vocabulary
-- the calories come out right on the dry-rice row and the display text is
the recipe's own.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "data/recipes/tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from pipeline.normalize import normalize_name  # noqa: E402
from validate_corpus import catalog_id_for, load_rights_context  # noqa: E402
from compile_bundle import compile_recipe, rights_label_for  # noqa: E402

HERE = Path(__file__).resolve().parent
SNAPSHOT = HERE / "kcal_prev_af856008.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
MAPPINGS = REPO / "data/ingredients/name-mappings.json"

# Keys whose per-100 g nutrition and identity row this branch re-chose or
# whose mapping was rerouted, relative to af856008.
DRIFTED_KEYS = [
    "lentils", "chicken_thighs", "chicken_thigh", "sugar", "white_rice",
    "canned_tomatoes", "banana", "cinnamon", "almonds", "bacon",
    "heavy_cream", "pork_chop",
]

# The nutrient-row re-choices this branch ships (they are applied to
# data/ingredients/vocabulary.json; the entries below carry the citation for
# the audit report and are verified against the curated catalog in
# test_kcal_audit.py). fdc_id here is the NUTRIENT row the per-100 g values
# are re-sourced from; except for cooked_rice the vocabulary's identity
# fdc_id pin stays as #192 set it. All values are verbatim USDA FoodData
# Central bulk-CSV rows (SR Legacy 2018-04 / FNDDS), mirrored by the same
# fdc_id rows in scripts/data/catalog/usda_curated_ingredients.json.
AUDIT_DECISIONS = {
    "chicken_thighs": {
        "nutrient_fdc_id": 173627,
        "source": "SR Legacy 173627 'Chicken, broilers or fryers, dark meat, thigh, meat only, raw'",
        "reason": "every corpus line measures raw boneless skinless thigh (pieces of 110 g); the pinned FNDDS row is cooked, skin eaten",
        "per_100g": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                     "fat_g": 4.12, "fiber_g": 0.0, "sugar_g": 0.0,
                     "sodium_mg": 95.0},
    },
    "chicken_thigh": {
        "nutrient_fdc_id": 173627,
        "source": "SR Legacy 173627 'Chicken, broilers or fryers, dark meat, thigh, meat only, raw'",
        "reason": "corpus lines measure raw thigh (purchase weights 400-700 g and pieces); the pinned FNDDS row is cooked, skin eaten",
        "per_100g": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                     "fat_g": 4.12, "fiber_g": 0.0, "sugar_g": 0.0,
                     "sodium_mg": 95.0},
    },
    "white_rice": {
        "nutrient_fdc_id": 168877,
        "source": "SR Legacy 168877 'Rice, white, long-grain, regular, raw, enriched'",
        "reason": "62 of 64 corpus lines measure dry rice by cups (dry_rice_cup, 185 g); the pinned FNDDS row is cooked; the cooked-rice lines resolve to the rice key with dry-equivalent grams after this branch's lead-review change, so no cooked-rice line is priced here",
        "per_100g": {"kcal": 365.0, "protein_g": 7.13, "carbs_g": 79.95,
                     "fat_g": 0.66, "fiber_g": 1.3, "sugar_g": 0.12,
                     "sodium_mg": 5.0},
    },
    "canned_tomatoes": {
        "nutrient_fdc_id": 170501,
        "source": "SR Legacy 170501 'Tomatoes, crushed, canned'",
        "reason": "corpus lines use the as-sold canned product (crushed/chopped); the pinned FNDDS row is 'canned, cooked' with 3 g fat/100 g from cooking",
        "per_100g": {"kcal": 32.0, "protein_g": 1.64, "carbs_g": 7.29,
                     "fat_g": 0.28, "fiber_g": 1.9, "sugar_g": 4.4,
                     "sodium_mg": 186.0},
    },
}

# Keys whose af856008 row this branch KEEPS (the row matches how recipes
# measure the line, or the move is a wrong-identity correction that must
# stand).
KEPT = {
    "lentils": "all 5 corpus lines measure dry lentils by cup and simmer them from dry; 352 (Lentils, raw) is the honest row; the old 106 was lentil SPROUTS (fdc 168427)",
    "sugar": "lines are granulated sugar by tsp/tbsp; 387 (Sugars, granulated) is the honest row; the old 94 was Sugar Apple, a fruit (fdc 168175)",
    "banana": "old row was Banana Pepper, a pepper (fdc 169394); 89 (Bananas, raw) is the honest row",
    "cinnamon": "old row was frosted Cinnamon buns (fdc 167940); 247 (Spices, cinnamon, ground) is the honest row",
    "almonds": "old row was the blanched-only variant; 579 (Nuts, almonds) matches whole almonds by cup; the 2 percent move is the variant correction",
    "bacon": "old row was Bacon bits; both corpus lines ship no grams (unknown mass) and contribute no nutrition either way",
    "heavy_cream": "old 340 vs 343.31 (Foundation row): a 1 percent row correction, tbsp line weight unchanged",
    "pork_chop": "lines measure raw pieces (~170 g); the pinned FNDDS as-consumed row (183) is kept as the closest cited row; the raw loin twin is within about 7 percent and no recipe approaches the gate",
}

# The cooked-rice routing decision (lead review of PR #221). Not a nutrient-row
# re-choice: the identity plan changes (cooked-rice lines resolve to the rice
# key) and the line grams carry the preparation correction.
ROUTING_DECISION = (
    "cooked-rice lines ('cooked rice', 'cooked white rice', 'cooked basmati "
    "rice') resolve to the rice key with their corpus-pinned cooked-form grams "
    "stored as dry-equivalent weights (one sourced factor, 2.8295 = 365/129, "
    "the energy ratio of fdc 168877 dry vs fdc 2708403 cooked; USDA puts the "
    "cooked:white dry-weight ratio at about 2.8x); the cooked_rice key is "
    "removed from the shipped vocabulary. Matching and pantry deduction keep "
    "working against the user's rice stock, the calories come out right on the "
    "dry-rice row, and the step and ingredient display text stays as the "
    "recipe wrote it (lead review of PR #221: with the reviewed reroute, the "
    "iOS walked-kitchen test read 'missing Cooked rice' for a rice-stocked "
    "kitchen and the Rice shortfall disappeared)."
)

SWING_THRESHOLD = 0.40  # same gate as validate_bundle.KCAL_DRIFT_THRESHOLD


def kcal_swing(old: float, new: float) -> float:
    """Same swing semantics as validate_bundle.kcal_swing."""
    if old == 0:
        return 0.0 if new == 0 else float("inf")
    return abs(new - old) / old


def _patched_vocab(base: dict, patches: dict) -> dict:
    """Deep-ish copy of the vocabulary entries with per_100g/fdc_id patches."""
    by_key = {k: dict(e) for k, e in base.items()}
    for key, patch in patches.items():
        e = by_key[key]
        if patch.get("per_100g") is not None:
            e["per_100g"] = dict(patch["per_100g"])
        if patch.get("fdc_id") is not None:
            e["fdc_id"] = patch["fdc_id"]
        if patch.get("fdc_ref") is not None:
            e["fdc_ref"] = patch["fdc_ref"]
    return by_key


def _patched_mappings(base: dict, overrides: dict) -> dict:
    """Copy of the mappings with af856008 records substituted for the rerouted names."""
    out = {k: dict(v) for k, v in base.items()}
    out.update({k: dict(v) for k, v in overrides.items()})
    return out


def load_states() -> dict[str, dict[str, dict]]:
    """The two vocabulary states as key -> entry dicts.

    prev = af856008 committed state; fixed = this branch's committed state.
    The fixed state carries no patches: applying the audit to it changes
    nothing (asserted in test_kcal_audit.py).
    """
    snap = json.load(SNAPSHOT.open())
    committed = {e["key"]: dict(e) for e in json.load(VOCAB.open())["entries"]}
    prev_patches = {k: {"per_100g": snap["drifted_keys_per_100g"][k],
                        "fdc_id": snap["drifted_keys_fdc_id"][k],
                        "fdc_ref": snap["drifted_keys_fdc_ref"].get(k)}
                    for k in DRIFTED_KEYS}
    prev = _patched_vocab(committed, prev_patches)
    # The prev state is af856008 exactly: no dry_equivalent declarations (this
    # branch introduces them) and the cooked_rice entry the branch removes,
    # restored verbatim from the snapshot.
    for entry in prev.values():
        entry.pop("dry_equivalent", None)
    prev["cooked_rice"] = {
        "key": "cooked_rice",
        "fdc_id": snap["drifted_keys_fdc_id"]["cooked_rice"],
        "fdc_ref": snap["drifted_keys_fdc_ref"].get("cooked_rice"),
        "per_100g": dict(snap["drifted_keys_per_100g"]["cooked_rice"]),
    }
    return {
        "prev": prev,
        "fixed": committed,
    }


def compile_states() -> dict[str, dict[str, float]]:
    """catalog_id -> {state: kcal per serving}, compiled with the real compiler.

    The prev state also restores the af856008 cooked-rice name mappings, so
    the fidelity assert holds even though this branch reroutes three names.
    """
    corpus = [json.loads(line)
              for line in (REPO / "data/recipes/corpus.jsonl")
              .read_text(encoding="utf-8").splitlines() if line.strip()]
    snap = json.load(SNAPSHOT.open())
    mappings_fixed = json.load(MAPPINGS.open())["mappings"]
    mappings_prev = _patched_mappings(mappings_fixed, snap["name_overrides"])
    rights = json.load((REPO / "data/recipes/rights_manifest.json")
                       .open())["records"]
    ctx = load_rights_context()
    labels = {rec["id"]: rights_label_for(rec, ctx) for rec in corpus}

    states = load_states()
    out: dict[str, dict[str, float]] = {}
    for rec in corpus:
        rid = catalog_id_for(rec["id"])
        out[rid] = {}
        for name, vocab in states.items():
            mappings = mappings_prev if name == "prev" else mappings_fixed
            compiled = compile_recipe(rec, mappings, vocab, rights, labels)
            out[rid][name] = compiled["nutrition_per_serving"]["kcal"]
    return out


def recipe_keys(rec: dict, mappings: dict) -> set[str]:
    """The vocabulary keys on a recipe's lines, resolved the compiler's way."""
    keys = set()
    for ing in rec["ingredients"]:
        m = mappings.get(normalize_name(ing["name"]), {})
        if m.get("key"):
            keys.add(m["key"])
    return keys


def main() -> int:
    snap = json.load(SNAPSHOT.open())
    prev_committed = snap["prev_kcal_per_serving"]

    corpus = [json.loads(line)
              for line in (REPO / "data/recipes/corpus.jsonl")
              .read_text(encoding="utf-8").splitlines() if line.strip()]
    mappings = json.load(MAPPINGS.open())["mappings"]
    rec_by_rid = {catalog_id_for(r["id"]): r for r in corpus}

    table = compile_states()

    # Fidelity: the in-memory prev state must reproduce the previously
    # published bundle (corpus/rights/compiler unchanged since af856008).
    max_delta = max(abs(table[rid]["prev"] - prev_committed[rid])
                    for rid in prev_committed)
    print(f"fidelity: in-memory prev compile vs committed af856008 bundle "
          f"max |delta| = {max_delta:.4f} kcal over {len(prev_committed)} recipes")
    if max_delta > 0.05:
        print("FAIL: prev state does not reproduce the published bundle; "
              "the comparison basis is broken")
        return 1

    # Summary of the re-sourced keys.
    print("\n== nutrient-row decisions (identity pins untouched except cooked-rice routing) ==")
    for key in DRIFTED_KEYS:
        if key in AUDIT_DECISIONS:
            d = AUDIT_DECISIONS[key]
            print(f"  RE-SOURCE {key:16s} -> fdc {d['nutrient_fdc_id']:7d}  "
                  f"{d['per_100g']['kcal']:.0f} kcal/100g  ({d['source']})")
        else:
            print(f"  KEEP      {key:16s} ({KEPT[key][:72]}...)")
    print("\n== cooked-rice routing (lead review of PR #221) ==")
    print(f"  ROUTING  {ROUTING_DECISION}")

    # Every recipe above the gate at the fixed state (vs af856008).
    print("\n== recipes above the 40 percent gate at the fixed state (vs af856008) ==")
    above: list[tuple[str, float, float, float, list[str]]] = []
    for rid in sorted(table):
        old, new = table[rid]["prev"], table[rid]["fixed"]
        swing = kcal_swing(old, new)
        if swing > SWING_THRESHOLD:
            keys = sorted(recipe_keys(rec_by_rid[rid], mappings)
                          & set(DRIFTED_KEYS))
            above.append((rid, old, new, swing, keys))
    for rid, old, new, swing, keys in above:
        sign = "+" if new > old else ("-" if new < old else "=")
        print(f"  {rid}  {old:7.1f} -> {new:7.1f} kcal/serving "
              f"({sign}{swing:.0%})  keys: {', '.join(keys)}")
    print(f"{len(above)} recipes above the gate at the fixed state")
    print("(each of these is exempted in data/recipe-bundle/"
          "nutrition-changes-2026-10.json, enforced by validate_bundle.py "
          "--previous --changes)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
