#!/usr/bin/env python3
"""Assemble the canonical manifest.json from the sampler and image-fetch outputs.

Input:  data/manifest.csv (sampler rows), data/image_hashes.csv (fetched hashes)
Output: manifest.json — meta block (salt, source, license, split rule) plus one
        product record per row with role images, revision, and an alignment class:

  aligned        reference text exists AND the ingredient-panel image for that
                 text was fetched and hashed — reference text is plausibly the
                 transcription OF the stored image
  metadata_only  no ingredient image: reference text (if any) is a metadata
                 field, not evidence tied to the stored image
  unresolved     front image missing or hash status not ok — the case cannot be
                 visually checked

Alignment is a data-provenance statement, not an accuracy claim.
"""
import argparse
import csv
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "acquisition"))
from sample_products import FOOD_URL, BEAUTY_URL  # noqa: E402

ROLE_COLS = {
    "front": ("front_url", "front_lang", "front_image_rev", "front_size", "front_image_id"),
    "ingredients": ("ingredients_url", "ingredients_lang", "ingredients_image_rev", "ingredients_size", "ingredients_image_id"),
    "nutrition": ("nutrition_url", "nutrition_lang", "nutrition_image_rev", "nutrition_size", "nutrition_image_id"),
}


def load_hashes(path):
    hashes = {}
    if path and os.path.exists(path):
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                hashes[(row["code"], row["role"])] = row
    return hashes


def classify(row, hashes):
    has_text = bool((row.get("ingredients_text") or "").strip())
    ing = hashes.get((row["code"], "ingredients"))
    ing_ok = ing is not None and ing.get("status") == "ok" and ing.get("sha256")
    front = hashes.get((row["code"], "front"))
    front_ok = front is not None and front.get("status") == "ok" and front.get("sha256")
    if not front_ok:
        return "unresolved", has_text
    if ing_ok and has_text:
        return "aligned", has_text
    return "metadata_only", has_text


def build(data_dir, out_path):
    with open(os.path.join(data_dir, "manifest.csv"), newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    hashes = load_hashes(os.path.join(data_dir, "image_hashes.csv"))

    products = []
    for row in rows:
        roles = {}
        for role, (url_c, lang_c, rev_c, size_c, id_c) in ROLE_COLS.items():
            h = hashes.get((row["code"], role))
            entry = {
                "url": row.get(url_c) or None,
                "lang": row.get(lang_c) or None,
                "image_rev": int(row[rev_c]) if row.get(rev_c) else None,
                "size": row.get(size_c) or None,
                "image_id": row.get(id_c) or None,
            }
            if h:
                entry["sha256"] = h.get("sha256") or None
                entry["bytes"] = int(h["bytes"]) if h.get("bytes") else None
                entry["fetch_status"] = h.get("status") or None
            roles[role] = entry
        alignment, has_text = classify(row, hashes)
        products.append({
            "code": row["code"],
            "stratum": row["stratum"],
            "split": row["split"],
            "revision": {
                "rev": int(row["rev"]) if row.get("rev") else None,
                "last_modified_t": int(row["last_modified_t"]) if row.get("last_modified_t") else None,
            },
            "source": {"database": "Open Food Facts", "license": "ODbL-1.0",
                       "attribution": "Open Food Facts contributors",
                       "url": FOOD_URL if row["stratum"] != "nonfood_control" else BEAUTY_URL},
            "reference_text": (row.get("ingredients_text") or "").strip() or None,
            "has_ingredient_reference_text": has_text,
            "alignment": alignment,
            "roles": roles,
        })

    manifest = {
        "meta": {
            "salt": os.environ.get("FL_SAMPLE_SALT", "fl-grocery-ocr-2026-06-v1"),
            "frozen_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "source": {"food_parquet": FOOD_URL, "beauty_parquet": BEAUTY_URL,
                       "dataset": "openfoodfacts/product-database (main branch export)"},
            "universe_counts": _load_universe(data_dir),
            "license": {
                "database": "ODbL 1.0 (Open Food Facts)",
                "attribution": "Images and metadata © Open Food Facts contributors, ODbL 1.0",
                "note": ("Derived experiment outputs are metrics and code only; product "
                         "images and text stay in the local cache and are not committed."),
            },
            "split_rule": "Within each stratum, salted md5 bucket order; first 15% dev, rest test. Nonfood controls are dev-only.",
            "counts": {
                "total": len(products),
                "aligned": sum(1 for p in products if p["alignment"] == "aligned"),
                "metadata_only": sum(1 for p in products if p["alignment"] == "metadata_only"),
                "unresolved": sum(1 for p in products if p["alignment"] == "unresolved"),
            },
        },
        "products": products,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print(f"manifest: {len(products)} products -> {out_path}")
    print(json.dumps(manifest["meta"]["counts"], indent=1))
    return manifest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True, help="dir with manifest.csv and image_hashes.csv")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    build(args.data_dir, args.out)


if __name__ == "__main__":
    main()
