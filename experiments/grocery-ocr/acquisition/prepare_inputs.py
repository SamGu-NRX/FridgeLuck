#!/usr/bin/env python3
"""Build the harness input files from the manifest and OCR traces.

Emits, under --out-dir:
  harness_ocr_input.jsonl   OCR-arm records: one per (product, role) image, lines in
                            pixel coords plus image dims (harness normalizes to
                            Vision's bottom-left unit space).
  reference_input.jsonl     Reference arm: the OFF ingredients_text split into items,
                            each rendered as one synthetic stacked "line" (no
                            geometry signal — geometry is meaningless here).
  targets_input.jsonl       Target arm: product name variants (raw name, brand-
                            stripped name, generic name) per product, resolved by the
                            harness into USDA catalog ids.

Target-tier rules (documented assumptions, see METHOD.md):
  primary targets  = ids resolved from product_name, brand-stripped product_name,
                     generic_name (non-empty only)
  context targets  = ids resolved from the last categories_tags leaf (e.g. en:tomato-
                     ketchups), never counted as the packaged item
  ingredient text  = never a target; used only for the reference arm diagnostics
"""
import argparse
import csv
import json
import os
import re


def split_items(ingredients_text):
    if not ingredients_text:
        return []
    text = ingredients_text.replace("\n", ", ")
    items = re.split(r"[;,]|\band\b|(?<=[a-z\)])\s+(?=[A-Z(])", text)
    cleaned = []
    for item in items:
        item = item.strip().strip("·.-: ")
        item = re.sub(r"^\d+(\.\d+)?\s*%?\s*", "", item)
        if len(item) >= 2:
            cleaned.append(item)
    return cleaned


def name_variants(row):
    variants = []
    name = (row.get("product_name") or "").strip()
    generic = (row.get("generic_name") or "").strip()
    brands = [b.strip() for b in (row.get("brands") or "").split(",") if b.strip()]
    if name:
        variants.append(name)
    if brands and name:
        brand = brands[0]
        stripped = re.sub(re.escape(brand), "", name, flags=re.IGNORECASE).strip(" -–,")
        if stripped and stripped.lower() != name.lower() and len(stripped) >= 3:
            variants.append(stripped)
    if generic and generic.lower() != name.lower():
        variants.append(generic)
    return variants


def category_leaf(row):
    tags = row.get("categories_tags") or ""
    for tag in reversed([t for t in tags.split(",") if t]):
        leaf = re.sub(r"^[a-z]{2,5}:", "", tag).replace("-", " ").strip()
        if leaf:
            return leaf
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--ocr-traces", default=None, help="ocr_lines.jsonl from ocr_baseline.py")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    # Accept either the sampler's manifest.csv or the canonical manifest.json.
    if args.manifest.endswith(".json"):
        with open(args.manifest, encoding="utf-8") as f:
            raw = json.load(f)["products"]
        rows = [{
            "code": p["code"], "stratum": p["stratum"], "split": p["split"],
            "product_name": "", "generic_name": "", "brands": "",
            "ingredients_text": p.get("reference_text") or "",
            "categories_tags": "",
        } for p in raw]
        # json manifest lacks name metadata (name variants come from the csv in
        # acquisition dir); rebuild them from build_manifest source data when present.
        csv_path = os.path.join(os.path.dirname(os.path.abspath(args.manifest)), "data", "manifest.csv")
        if os.path.exists(csv_path):
            with open(csv_path, newline="", encoding="utf-8") as f:
                by_code = {r["code"]: r for r in csv.DictReader(f)}
            for r in rows:
                full = by_code.get(r["code"], {})
                r["product_name"] = full.get("product_name", "")
                r["generic_name"] = full.get("generic_name", "")
                r["brands"] = full.get("brands", "")
                r["categories_tags"] = full.get("categories_tags", "")
    else:
        rows = []
        with open(args.manifest, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))

    with open(f"{args.out_dir}/targets_input.jsonl", "w", encoding="utf-8") as out:
        for row in rows:
            entries = [{"text": v, "tier": "primary"} for v in name_variants(row)]
            leaf = category_leaf(row)
            if leaf:
                entries.append({"text": leaf, "tier": "context"})
            if not entries:
                continue
            out.write(json.dumps({
                "image_id": f"{row['code']}__targets",
                "code": row['code'],
                "texts": entries,
            }, ensure_ascii=False) + "\n")

    with open(f"{args.out_dir}/reference_input.jsonl", "w", encoding="utf-8") as out:
        for row in rows:
            items = split_items(row.get("ingredients_text") or "")
            if not items:
                continue
            lines = []
            for i, item in enumerate(items):
                y = 0.9 - 0.02 * i
                lines.append({"text": item, "x0": 10, "y0": 800 * (0.9 - 0.02 * i),
                              "x1": 990, "y1": 800 * (0.9 - 0.02 * i) + 14, "conf": None})
            out.write(json.dumps({
                "image_id": f"{row['code']}__reference",
                "code": row["code"], "role": "reference",
                "width": 1000, "height": 800,
                "lines": lines,
            }, ensure_ascii=False) + "\n")

    if args.ocr_traces and os.path.exists(args.ocr_traces):
        # One file per role so the runner can replay each OCR arm separately.
        per_role = {}
        with open(args.ocr_traces, encoding="utf-8") as fin:
            for line in fin:
                rec = json.loads(line)
                per_role.setdefault(rec["role"], []).append(rec)
        for role, recs in per_role.items():
            with open(f"{args.out_dir}/harness_ocr_input_{role}.jsonl", "w", encoding="utf-8") as out:
                for rec in recs:
                    out.write(json.dumps({
                        "image_id": f"{rec['code']}__{role}",
                        "code": rec["code"], "role": role,
                        "width": rec.get("width"), "height": rec.get("height"),
                        "lines": rec.get("lines", []),
                    }, ensure_ascii=False) + "\n")

    print("prepared inputs in", args.out_dir)


if __name__ == "__main__":
    main()
