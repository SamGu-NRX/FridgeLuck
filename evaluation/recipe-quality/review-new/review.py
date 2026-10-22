#!/usr/bin/env python3
"""A cook's review of the 60 newest catalog recipes (rcp-000935..rcp-000994).

Packet burst14-fridgeluck-review-new-recipes, based on alpha af856008.

The band is the two October 16 originals packets as shipped by the catalog
rebuild (#210): 30 breakfasts (data/recipe-sources/breakfast-2026-10, #201)
and 30 pantry lunches/dinners (data/recipe-sources/pantry-2026-10, #203).
They passed the mechanical gates only; nobody had read them as a cook would.

This harness lists the band reproducibly from the base corpus, recompiles
every record in memory with the repository's own compiler
(compile_bundle.compile_recipe) and the kcal state
burst14-fridgeluck-kcal-pins ships this wave (chicken_thighs /
chicken_thigh, white_rice, canned_tomatoes), runs the rubric's mechanical
checks by importing evaluation/recipe-quality/rubric/audit.py, and merges the
hand review below. It writes findings.json beside this script and prints the
verdict counts. Read-only over the corpus: nothing is compiled to disk.

Run:  python3 evaluation/recipe-quality/review-new/review.py
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PACKET = "burst14-fridgeluck-review-new-recipes"
BASE_COMMIT = "af85600867bc9f8d6a68963205e9d502c2dc3df7"
BAND_LO, BAND_HI = 935, 994
CORPUS = REPO / "data/recipes/corpus.jsonl"
FIXES = REPO / "data/recipes/fixes/review-new.json"
FINDINGS = Path(__file__).resolve().parent / "findings.json"

sys.path.insert(0, str(REPO / "data/recipes/tools"))
sys.path.insert(0, str(REPO / "evaluation/recipe-quality/rubric"))
import audit as rubric  # noqa: E402  (the rubric's mechanical sweep)
import compile_bundle as compiler  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402  (catalog-id mapping)

# The burst14-fridgeluck-kcal-pins nutrient rows this wave ships, per 100 g.
# Applied here in memory so kcal/sodium verdicts are judged against the wave's
# rows. These values are now committed on the branch's vocabulary, so the patch
# is a no-op there; the wave's cooked-rice decision (lead review of PR #221:
# cooked-rice lines on the rice key, cooked-form grams stored as
# dry-equivalent weights) ships in the compiler and vocabulary directly, and
# the findings' compiled_kcal/compiled_sodium annotations were re-recorded
# against that state on 2026-10-17 (verdicts unchanged), so verdicts are still
# judged against the numbers the app will actually show.
KCAL_ROWS = {
    "chicken_thighs": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                       "fat_g": 4.12, "sodium_mg": 95.0},
    "chicken_thigh": {"kcal": 121.0, "protein_g": 19.66, "carbs_g": 0.0,
                      "fat_g": 4.12, "sodium_mg": 95.0},
    "white_rice": {"kcal": 365.0, "protein_g": 7.13, "carbs_g": 79.95,
                   "fat_g": 0.66, "sodium_mg": 5.0},
    "canned_tomatoes": {"kcal": 32.0, "protein_g": 1.64, "carbs_g": 7.29,
                        "fat_g": 0.28, "sodium_mg": 186.0},
}

# Hand review, one entry per catalog id in the band. verdict is one of
# "cookable as written" / "needs a fix" / "should be cut". findings carry a
# rubric criterion (C1..C7, or "beyond" for plausibility checks outside the
# rubric), the line or step they are about, and the evidence.
HAND_REVIEW: dict[str, dict] = {
    "rcp-000935": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "ingredients[2] cooked white rice",
         "evidence": "kcal here uses the pinned dry white_rice row on a line measured as cooked rice; burst14-fridgeluck-kcal-pins owns that row, judge as cooked rice"}]},
    "rcp-000936": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 1",
         "evidence": "3 tablespoons of hot water loosen the sauce but water has no line; staple-water convention is inconsistent across the band"},
        {"criterion": "C4", "location": "step 3",
         "evidence": "the FSIS gate forces a fried egg to 160 °F, a hard yolk on a dish whose cuisine wants it runny; wording is honest but the dish changes"}]},
    "rcp-000937": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 1", "evidence": "soaking water has no line (staple convention)"}]},
    "rcp-000938": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 2", "evidence": "3 cups of water have no line (staple convention)"},
        {"criterion": "C7", "location": "step 2 vs minutes=15",
         "evidence": "8-minute congee from cooked rice plus a side pan of mushrooms is tight but workable"}]},
    "rcp-000939": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 2", "evidence": "thermometer check on bite-size salmon pieces is present and realistic at 145 °F"}]},
    "rcp-000940": {"verdict": "needs a fix", "findings": [
        {"criterion": "C7", "location": "step 3",
         "evidence": "high-heat shrimp reach the step's own 145 °F target in 2-3 minutes, not the stated 1 minute; the step contradicts its doneness requirement — fixed in review-new.json"},
        {"criterion": "C4", "location": "step 6",
         "evidence": "shrimp already held at 145 °F are reheated inside a folded crepe and asked to re-register 145 °F, which the resting crepe will not deliver"},
        {"criterion": "C1", "location": "step 6",
         "evidence": "'eat wraps of crepe and lettuce dipped in the sauce' is garbled assembly text a cook has to decode"}]},
    "rcp-000941": {"verdict": "cookable as written", "findings": [
        {"criterion": "C6", "location": "whole recipe",
         "evidence": "salt + chili heat + oil fat are present; acid absent, which reads slightly flat for a chilla — a squeeze of lime is the traditional fix, taste not defect"}]},
    "rcp-000942": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 3",
         "evidence": "temping a thin omelette to 160 °F is impractical at the stove; the gate-mandated wording survives, the cook will cook to look"}]},
    "rcp-000943": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "step 1 vs minutes=25",
         "evidence": "15-minute red-lentil simmer plus a side pan fits the 25-minute promise"}]},
    "rcp-000944": {"verdict": "cookable as written", "findings": [
        {"criterion": "C3", "location": "step 3",
         "evidence": "potato tender in 6 minutes under a lid assumes a small dice the step never states; a cook starting from whole potato will not get there"},
        {"criterion": "beyond", "location": "ingredients[0] flattened rice",
         "evidence": "flattened_rice has a vocabulary key but no per-100g row, so compiled kcal (219.6) understates the dish"}]},
    "rcp-000945": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "minutes=25",
         "evidence": "8 soften + 8 simmer + covered eggs ~6-8 leaves no prep room; a confident cook makes it, the promise is tight"}]},
    "rcp-000946": {"verdict": "cookable as written", "findings": [
        {"criterion": "C2", "location": "compiled kcal 118.8/serving",
         "evidence": "below the 150 kcal floor only because labneh (150 g) and zaatar have no per-100g rows; real dish is ~180-200 kcal — vocabulary gap, not a recipe defect"}]},
    "rcp-000947": {"verdict": "cookable as written", "findings": []},
    "rcp-000948": {"verdict": "cookable as written", "findings": [
        {"criterion": "C6", "location": "ingredients[1] harissa 20 g",
         "evidence": "20 g harissa across two servings is timid for a dish named after it; taste"}]},
    "rcp-000949": {"verdict": "cookable as written", "findings": []},
    "rcp-000950": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "step 1",
         "evidence": "200 g diced potato browned and tender in 10 minutes at medium heat is optimistic; 12-15 is the usual pan time"}]},
    "rcp-000951": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "ingredients[0] callaloo greens",
         "evidence": "callaloo_greens has a vocabulary key but no per-100g row; compiled kcal understates the plate"}]},
    "rcp-000952": {"verdict": "cookable as written", "findings": [
        {"criterion": "C5", "location": "ingredients[2] water 350 g",
         "evidence": "the shipped water vocabulary row (fdc 170132: 20 kcal, 2.08 g protein, 358 mg sodium per 100 g) is not water; it adds ~626 mg of the 650 mg/serving shown — vocabulary defect owned by burst14-fridgeluck-kcal-pins"}]},
    "rcp-000953": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 1", "evidence": "steps say 'the milk, eggs' plural against a one-egg line; harmless wording"},
        {"criterion": "C4", "location": "step 4",
         "evidence": "temping the center of a pancake to 160 °F is impractical; gate-mandated wording"}]},
    "rcp-000954": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 1",
         "evidence": "'blend everything' leaves every line un-referenced in step uses; compiler linkage artifact, the cook is not misled"}]},
    "rcp-000955": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "step 3 vs minutes=10",
         "evidence": "overnight chill against a 10-minute promise is the usual active-time convention for overnight oats; the step text says what it means"}]},
    "rcp-000956": {"verdict": "needs a fix", "findings": [
        {"criterion": "C7", "location": "step 3",
         "evidence": "a yolk in barely simmering water reaches the step's own 160 °F target in about 4-5 minutes, not the stated 3; the step contradicts its doneness requirement — fixed in review-new.json"}]},
    "rcp-000957": {"verdict": "cookable as written", "findings": [
        {"criterion": "C5", "location": "ingredients[2] water 120 g",
         "evidence": "~215 of the 295 mg/serving shown is phantom from the corrupt water vocabulary row"}]},
    "rcp-000958": {"verdict": "cookable as written", "findings": [
        {"criterion": "C5", "location": "ingredients[1] water 300 g",
         "evidence": "~534 of the 792.5 mg/serving shown is phantom from the corrupt water vocabulary row; the real custard is ~260 mg"},
        {"criterion": "C2", "location": "ingredients",
         "evidence": "150 g egg to 300 g water (1:2 by weight) is the classic steamed-custard ratio; amounts are right"}]},
    "rcp-000959": {"verdict": "cookable as written", "findings": [
        {"criterion": "C2", "location": "ingredients[0] glutinous rice 200 g",
         "evidence": "the line is rinsed and simmered (dry measure) but the glutinous_rice row is a cooked-rice row (96 kcal, 227 mg sodium per 100 g); true per-serving kcal ~460 vs 316 shown — vocabulary defect owned by burst14-fridgeluck-kcal-pins, whose four rows do not cover glutinous_rice"}]},
    "rcp-000960": {"verdict": "cookable as written", "findings": []},
    "rcp-000961": {"verdict": "cookable as written", "findings": [
        {"criterion": "C3", "location": "steps",
         "evidence": "textbook tortilla technique: low-heat potato cook, drain and keep the oil, flip-and-slide, rest stated"}]},
    "rcp-000962": {"verdict": "cookable as written", "findings": []},
    "rcp-000963": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=indian on a West African dish; the corpus taxonomy has six values and no african, so the packet squeezed it — taxonomy finding, no one-correct value exists"}]},
    "rcp-000964": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=italian on an Eastern European cottage-cheese bowl; same six-value taxonomy gap"}]},
    "rcp-000965": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "ingredients[0] rice 2.5 cup",
         "evidence": "the step offers cook-then-cool or day-old rice; only the day-old reading is cookable in 20 minutes, and 2.5 cups pinned at the FNDDS cooked-cup weight (158 g) is right only as cooked rice — flag for burst14-fridgeluck-kcal-pins to treat as a cooked-rice line"}]},
    "rcp-000966": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 3",
         "evidence": "no cook can thermometer egg ribbons in swirling soup; gate-mandated wording"},
        {"criterion": "C1", "location": "step 1",
         "evidence": "'the broth is lightly thickened' names broth as prose, not an ingredient; mechanical false positive"},
        {"criterion": "C2", "location": "ingredients[0] rice 0.5 cup in 2 cups water",
         "evidence": "ratio lands between soup and congee; readable as a light rice soup"}]},
    "rcp-000967": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "ingredients[0] rice 1 cup (158 g)",
         "evidence": "the line is rinsed and simmered (dry measure) but the conversion_ref pins the FNDDS cooked-rice cup (158 g, dry cup is ~185 g); rice mass understated ~15% across the pantry packet's rice lines — conversion-registry finding"},
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=italian on a plain buttered rice; defensible only as risotto-adjacent"}]},
    "rcp-000968": {"verdict": "cookable as written", "findings": []},
    "rcp-000969": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=mexican on chicken, rice, corn and butter; nothing Mexican in it, and no one-correct alternative exists in the six-value taxonomy"}]},
    "rcp-000970": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "step 3",
         "evidence": "blending half the corn assumes a blender; fine for the app's kitchen, worth a note"}]},
    "rcp-000971": {"verdict": "cookable as written", "findings": []},
    "rcp-000972": {"verdict": "cookable as written", "findings": [
        {"criterion": "C6", "location": "whole recipe",
         "evidence": "salt + cumin only: no acid and no fat in the dish (the packet's no-oil design); a chana saag wants tomato or lemon — taste, not a one-correct fix"}]},
    "rcp-000973": {"verdict": "cookable as written", "findings": []},
    "rcp-000974": {"verdict": "cookable as written", "findings": []},
    "rcp-000975": {"verdict": "cookable as written", "findings": []},
    "rcp-000976": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 2",
         "evidence": "'black beans with their liquid' implies canned; drains-or-not ambiguity is minor"}]},
    "rcp-000977": {"verdict": "cookable as written", "findings": []},
    "rcp-000978": {"verdict": "cookable as written", "findings": [
        {"criterion": "C3", "location": "step 2",
         "evidence": "'brown the chicken in a dry nonstick pot … scraping the browned bits free' — with no fat there is nothing to brown and no bits to scrape; the water-sauté works but the step promises a reaction it cannot deliver"}]},
    "rcp-000979": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 4",
         "evidence": "a thermometer check on canned tuna (already commercially sterilised) is meaningless; required_classes does not distinguish canned from raw fish"},
        {"criterion": "C2", "location": "step 3",
         "evidence": "half a cup of milk and 25 g butter thickened to coat-a-spoon in 2 minutes is optimistic; pasta water does the real work"}]},
    "rcp-000980": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "minutes=15",
         "evidence": "four dipped toasts fried in batches plus the tuna warm-up is tight against 15 minutes"}]},
    "rcp-000981": {"verdict": "cookable as written", "findings": []},
    "rcp-000982": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "step 1",
         "evidence": "a stated 12-minute boil implies small potatoes the step never sizes; 450 g whole would take much longer"}]},
    "rcp-000983": {"verdict": "cookable as written", "findings": [
        {"criterion": "C7", "location": "minutes=25",
         "evidence": "500 g potatoes boiled until knife-tender (size unstated) can exceed the promise if started whole; 000982's parallel step states ~12 minutes — ambiguous, not one-correct, left in findings"}]},
    "rcp-000984": {"verdict": "cookable as written", "findings": []},
    "rcp-000985": {"verdict": "cookable as written", "findings": []},
    "rcp-000986": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 3", "evidence": "thermometer check on canned tuna is meaningless (pre-sterilised)"}]},
    "rcp-000987": {"verdict": "cookable as written", "findings": [
        {"criterion": "C4", "location": "step 3", "evidence": "thermometer check on canned tuna is meaningless (pre-sterilised)"}]},
    "rcp-000988": {"verdict": "cookable as written", "findings": []},
    "rcp-000989": {"verdict": "cookable as written", "findings": [
        {"criterion": "C1", "location": "step 2",
         "evidence": "5 cups of water have no line (staple convention); congee ratio and the honest 45-minute claim are right"}]},
    "rcp-000990": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=italian on buttered oat porridge in the dinner slot; taxonomy squeeze again"}]},
    "rcp-000991": {"verdict": "cookable as written", "findings": [
        {"criterion": "beyond", "location": "cuisine",
         "evidence": "cuisine=italian on a baked oat custard; taxonomy squeeze again"}]},
    "rcp-000992": {"verdict": "cookable as written", "findings": []},
    "rcp-000993": {"verdict": "cookable as written", "findings": []},
    "rcp-000994": {"verdict": "cookable as written", "findings": []},
}


def load_corpus() -> tuple[dict[str, dict], dict[str, str]]:
    corpus: dict[str, dict] = {}
    raw: dict[str, str] = {}
    for line in CORPUS.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        corpus[rec["id"]] = rec
        raw[rec["id"]] = line
    return corpus, raw


def band_ids(corpus: dict[str, dict]) -> list[str]:
    ids = [rid for rid in corpus
           if BAND_LO <= int(vcorpus.catalog_id_for(rid).split("-")[1]) <= BAND_HI]
    return sorted(ids)


def patch_vocab(vocab_by_key: dict[str, dict]) -> dict[str, dict]:
    patched = {}
    for key, entry in vocab_by_key.items():
        row = KCAL_ROWS.get(key)
        if row:
            per = dict(entry.get("per_100g") or {})
            per.update(row)
            entry = {**entry, "per_100g": per}
        patched[key] = entry
    return patched


def sha_of(raw_line: str) -> str:
    return hashlib.sha256(raw_line.encode("utf-8")).hexdigest()


def main() -> int:
    corpus, raw = load_corpus()
    band = band_ids(corpus)
    if len(band) != BAND_HI - BAND_LO + 1:
        raise SystemExit(f"expected {BAND_HI - BAND_LO + 1} band recipes, found {len(band)}")

    mappings = json.loads((REPO / "data/ingredients/name-mappings.json")
                          .read_text(encoding="utf-8"))["mappings"]
    vocab_by_key = patch_vocab({e["key"]: e for e in json.loads(
        (REPO / "data/ingredients/vocabulary.json").read_text(encoding="utf-8"))["entries"]})
    rights = json.loads((REPO / "data/recipes/rights_manifest.json")
                        .read_text(encoding="utf-8"))["records"]
    ctx = vcorpus.load_rights_context()
    labels = {rid: compiler.rights_label_for(rec, ctx) for rid, rec in corpus.items()}

    audit_ctx = rubric.Context()
    for key, row in KCAL_ROWS.items():
        if key in audit_ctx.per100:
            per = dict(audit_ctx.per100[key] or {})
            per.update(row)
            audit_ctx.per100[key] = per

    recipes = []
    for rid in band:
        rec = corpus[rid]
        cid = vcorpus.catalog_id_for(rid)
        compiled = compiler.compile_recipe(rec, mappings, vocab_by_key, rights, labels)
        n = compiled["nutrition_per_serving"]
        sig = rubric.evaluate(rec, audit_ctx)
        hand = HAND_REVIEW.get(cid)
        if hand is None:
            raise SystemExit(f"no hand review for {cid}")
        flags = []
        if sig["uncovered_title_tokens"]:
            flags.append(f"title-uncovered={sig['uncovered_title_tokens']}")
        if sig["missing_food_in_steps"]:
            flags.append(f"missing-food={sig['missing_food_in_steps']}")
        if sig["unused_lines"]:
            flags.append(f"unused-lines={sig['unused_lines']}")
        if sig["visual_done_phrases"]:
            flags.append(f"visual-done={sig['visual_done_phrases']}")
        if sig["uncovered_fsis"]:
            flags.append(f"fsis-uncovered={sig['uncovered_fsis']}")
        if sig["preheat_after_bake"]:
            flags.append("preheat-after-bake")
        if sig["heat_before_prep"]:
            flags.append(f"heat-before-prep={sig['heat_before_prep']}")
        if sig["rest_after_meat"] is False:
            flags.append("no-rest-after-meat")
        if sig["timer_sum"] > sig["minutes"]:
            flags.append(f"timers={sig['timer_sum']}m>{sig['minutes']}m")
        recipes.append({
            "catalog_id": cid,
            "id": rid,
            "title": rec["title"],
            "verdict": hand["verdict"],
            "compiled_kcal_per_serving": n["kcal"],
            "compiled_sodium_mg_per_serving": n["sodium_mg"],
            "coverage": n["coverage"],
            "mechanical_flags": flags,
            "findings": hand["findings"],
            "before_sha256": sha_of(raw[rid]),
        })

    counts = {"cookable as written": 0, "needs a fix": 0, "should be cut": 0}
    for r in recipes:
        counts[r["verdict"]] += 1

    doc = {
        "packet": PACKET,
        "base_commit": BASE_COMMIT,
        "kcal_rows_applied": KCAL_ROWS,
        "counts": counts,
        "recipes": recipes,
    }
    FINDINGS.write_text(json.dumps(doc, indent=1, sort_keys=False) + "\n",
                        encoding="utf-8")
    print(f"band: {len(recipes)} recipes (rcp-{BAND_LO:06d}..rcp-{BAND_HI:06d})")
    print(json.dumps(counts, indent=1, sort_keys=True))
    print(f"fix file: {FIXES.name} — see REPORT.md for the taste findings")
    print(f"findings: {FINDINGS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
