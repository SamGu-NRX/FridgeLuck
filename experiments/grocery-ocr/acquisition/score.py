#!/usr/bin/env python3
"""Score the harness predictions against derived targets and write score tables.

Arms:
  ocr_front / ocr_ingredients / ocr_nutrition  tesseract text through the harness
  reference                                    OFF ingredients_text through the harness

Target tiers (from prepare_inputs.py, resolved by the harness):
  primary  product name / brand-stripped name / generic name ids — the packaged item
  context  category leaf id — never the packaged item

Metrics (per arm x split x stratum, plus totals):
  cases                products in scope
  with_primary         products with >=1 primary target id
  item_hit             any detection id in primary ids (among with_primary)
  false_food_rate      mean detections per product not in primary+context ids
  nonfood_trigger      nonfood controls producing any detection
  bucket_counts        auto / confirm / possible across detections
  outside_curated      detections with ids outside the 50-id curated lexicon space

CER/WER: emitted as null with the reason — no defensible transcription gold exists
in this run (see METHOD.md; the brief only allows CER/WER where transcription gold
is defensible).
"""
import argparse
import csv
import json
import os
from collections import defaultdict

CURATED_MAX_ID = 50  # IngredientLexicon.displayNames ids 1..50


def load_jsonl(path):
    out = []
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--targets", required=True, help="harness targets output jsonl")
    ap.add_argument("--ocr", default=None, help="harness ocr output jsonl")
    ap.add_argument("--reference", default=None, help="harness reference output jsonl")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    meta = {}
    if args.manifest.endswith(".json"):
        with open(args.manifest, encoding="utf-8") as f:
            meta = {p["code"]: {"stratum": p["stratum"], "split": p["split"]}
                    for p in json.load(f)["products"]}
    else:
        with open(args.manifest, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                meta[row["code"]] = row

    primary, context = defaultdict(set), defaultdict(set)
    for rec in load_jsonl(args.targets):
        code = rec["image_id"].split("__")[0]
        for v in rec.get("targets", []):
            if not v.get("ingredient_id"):
                continue
            if v.get("tier") == "context":
                context[code].add(v["ingredient_id"])
            elif v.get("tier") == "primary":
                primary[code].add(v["ingredient_id"])

    def score_arm(records, arm_name):
        by_code = defaultdict(list)
        for rec in records:
            code = rec["image_id"].split("__")[0]
            by_code[code].append(rec)
        table = defaultdict(lambda: {"cases": 0, "with_primary": 0, "item_hit": 0,
                                     "detections": 0, "false_foods": 0,
                                     "false_food_products": 0, "nonfood_trigger": 0,
                                     "auto": 0, "confirm": 0, "possible": 0,
                                     "outside_curated": 0, "no_target": 0})
        per_product = []
        for code, recs in by_code.items():
            row = meta.get(code, {})
            stratum, split = row.get("stratum", "?"), row.get("split", "?")
            ids, det_details = set(), []
            for rec in recs:
                for d in rec.get("detections", []):
                    ids.add(d["ingredient_id"])
                    det_details.append(d)
            dets = det_details
            n_primary = len(primary.get(code, set()))
            item_hit = bool(ids & primary.get(code, set()))
            false_foods = sum(1 for d in dets
                              if d["ingredient_id"] not in primary.get(code, set())
                              and d["ingredient_id"] not in context.get(code, set()))
            buckets = defaultdict(int)
            for d in dets:
                buckets[d["bucket"]] += 1
            outside = sum(1 for d in dets if d["ingredient_id"] > CURATED_MAX_ID)

            keys = [("total", "all"), (split, split), (stratum, f"{split}:{stratum}")]
            for _, key in keys:
                t = table[key]
                t["cases"] += 1
                if n_primary:
                    t["with_primary"] += 1
                    t["item_hit"] += int(item_hit)
                else:
                    t["no_target"] += 1
                t["detections"] += len(dets)
                t["false_foods"] += false_foods
                t["false_food_products"] += int(bool(dets) and false_foods == len(dets))
                if stratum == "nonfood_control":
                    t["nonfood_trigger"] += int(bool(dets))
                t["auto"] += buckets.get("auto", 0)
                t["confirm"] += buckets.get("confirm", 0)
                t["possible"] += buckets.get("possible", 0)
                t["outside_curated"] += outside

            per_product.append({
                "code": code, "stratum": stratum, "split": split, "arm": arm_name,
                "primary_ids": sorted(primary.get(code, set())),
                "context_ids": sorted(context.get(code, set())),
                "detection_ids": sorted(ids),
                "item_hit": item_hit, "false_foods": false_foods,
                "detections": dets,
            })

        summary = {}
        for key, t in table.items():
            summary[key] = {
                "cases": t["cases"],
                "with_primary": t["with_primary"],
                "item_hit_rate": round(t["item_hit"] / t["with_primary"], 4) if t["with_primary"] else None,
                "false_foods_per_case": round(t["false_foods"] / t["cases"], 3) if t["cases"] else None,
                "products_all_false": t["false_food_products"],
                "nonfood_trigger": t["nonfood_trigger"] if "nonfood" in key else None,
                "buckets": {"auto": t["auto"], "confirm": t["confirm"], "possible": t["possible"]},
                "outside_curated": t["outside_curated"],
                "no_target_cases": t["no_target"],
            }
        with open(f"{args.out_dir}/per_product_{arm_name}.json", "w", encoding="utf-8") as f:
            json.dump(per_product, f, ensure_ascii=False, indent=1)
        return summary

    os.makedirs(args.out_dir, exist_ok=True)
    result = {
        "cer_wer": None,
        "cer_wer_reason": ("No defensible transcription gold exists in this run: scoring "
                           "OCR output against OFF's own ingredients_text would measure "
                           "tesseract-vs-crowd-transcription agreement, not recognition "
                           "accuracy. CER/WER requires device Vision traces or manual "
                           "transcription of the sampled images."),
    }
    result["reference"] = score_arm(load_jsonl(args.reference), "reference")
    if args.ocr:
        result["ocr"] = score_arm(load_jsonl(args.ocr), "ocr")

    with open(f"{args.out_dir}/scores.json", "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(json.dumps(result, indent=2)[:2000])


if __name__ == "__main__":
    main()
