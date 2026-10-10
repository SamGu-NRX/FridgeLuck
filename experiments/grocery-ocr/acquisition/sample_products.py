#!/usr/bin/env python3
"""Deterministic stratified sampler over the OFF product-database parquet.

2026-06 snapshot schema notes (probed 2026-10-09, HF product-database main):
  product_name / generic_name / ingredients_text
      LIST of STRUCT(lang VARCHAR, text VARCHAR) — 'main' plus per-language entries;
      "main" is the contributor's own language and is NOT necessarily English.
  images
      LIST of STRUCT(key VARCHAR, imgid BIGINT, rev INT, sizes STRUCT(...), uploader,...)
  nutriments
      LIST of STRUCT(name VARCHAR, value, "100g", serving, unit, prepared_*)
  states_tags / categories_tags / labels_tags / countries_tags / food_groups_tags
      LIST of VARCHAR ("en:..." tags)
  brands / lang / quantity / code   VARCHAR; last_modified_t BIGINT

Everything product-identifying is hashed before selection, so the initial sample is
built blind; the manifest row order is a fixed function of the salt.
"""
import argparse
import csv
import json
import os
import random
import time

import duckdb

HF_BASE = "https://huggingface.co/datasets/openfoodfacts/product-database/resolve/main"
FOOD_URL = f"{HF_BASE}/food.parquet"
BEAUTY_URL = f"{HF_BASE}/beauty.parquet"

STRATA = [
    ("trace_warning",   110, "ingredients_text IS NOT NULL AND (lower(ingredients_text) LIKE '%may contain%' OR lower(ingredients_text) LIKE '%traces of%')"),
    ("parenth_subing",  130, "ingredients_text IS NOT NULL AND regexp_matches(ingredients_text, '\\([^)]{15,}\\)')"),
    ("percent_subing",  130, "ingredients_text IS NOT NULL AND ingredients_text LIKE '%%%'"),
    ("short_simple",    130, "ingredients_text IS NOT NULL AND length(ingredients_text) < 30"),
    ("short_parenth",   110, "ingredients_text IS NOT NULL AND length(ingredients_text) < 30 AND (ingredients_text LIKE '%(%' OR ingredients_text LIKE '%)%')"),
    ("mid_comma",      150, "ingredients_text IS NOT NULL AND length(ingredients_text) BETWEEN 30 AND 120 AND length(string_split_regex(ingredients_text, ',[ ]*')) BETWEEN 3 AND 6"),
    ("long_comma",      110, "ingredients_text IS NOT NULL AND length(ingredients_text) > 120"),
    ("name_only",       80, "ingredients_text IS NULL"),
    ("nonfood_control",  50, "FALSE"),
]
MAX_PER_STRATUM = 150

SIZE_ORDER = {"front": ["1000", "full", "400"], "ingredients": ["full", "1000", "400"], "nutrition": ["1000", "full", "400"]}

NAME_SQL = """COALESCE(
      (list_filter({col}, x -> x.lang = 'main')[1]).text,
      (list_filter({col}, x -> x.lang = 'en')[1]).text,
      {col}[1].text
    ) AS {alias}"""

# Language preference for ingredient text: prefer an English entry when present
# (many 'main'-language products also carry an 'en' translation), else main.
ING_SQL = """COALESCE(
      (list_filter(ingredients_text, x -> x.lang = 'en')[1]).text,
      (list_filter(ingredients_text, x -> x.lang = 'main')[1]).text,
      ingredients_text[1].text
    ) AS ingredients_text"""

def base_sql(salt: str, food_url: str) -> str:
    """salt must already be SQL-escaped; the URL may be remote or a local path."""
    return f"""
    WITH base AS (
      SELECT code, lang, brands, quantity, last_modified_t, rev,
        {NAME_SQL.format(col='product_name', alias='product_name')},
        {NAME_SQL.format(col='generic_name', alias='generic_name')},
        {ING_SQL},
        len(nutriments) > 0 AS has_nutriments,
        len(list_filter(images, x -> x.key LIKE 'nutrition%')) > 0 AS has_nutrition_img,
        to_json(images) AS images_json,
        to_json(categories_tags) AS categories_tags,
        to_json(labels_tags) AS labels_tags,
        to_json(states_tags) AS states_tags,
        to_json(countries_tags) AS countries_tags,
        to_json(food_groups_tags) AS food_groups_tags,
        md5(code || '{salt}') AS bucket
      FROM read_parquet('{food_url}')
      WHERE regexp_matches(code, '^[0-9]{{13}}$')
        AND len(list_filter(images, x -> x.key LIKE 'front%')) > 0
        AND last_modified_t >= 1500000000
        AND NOT COALESCE(list_contains(states_tags, 'en:obsolete'), false)
        AND len(list_filter(product_name, x -> x.lang = 'main' OR x.lang = 'en')) > 0
    ),
    shaped AS (
      SELECT *,
        CASE {"".join(f"WHEN {cond} THEN '{name}' " for name, _, cond in STRATA)}END AS stratum
      FROM base
    ),
    stratified AS (
      SELECT * FROM shaped WHERE stratum IS NOT NULL
    )
"""


def read_with_retry(con, sql, params, attempts=6):
    for attempt in range(1, attempts + 1):
        try:
            return con.execute(sql, params).fetchall()
        except Exception as exc:  # noqa: BLE001 - network/IO errors are expected here
            wait = min(30 * 2 ** (attempt - 1), 300)
            print(f"read attempt {attempt} failed ({str(exc)[:300]}); retrying in {wait}s", flush=True)
            time.sleep(wait)
    raise RuntimeError("query failed after retries")


def pick(images, role, lang, code):
    for key in (f"{role}_{lang}", role, f"{role}_en"):
        matches = [img for img in images if str(img.get("key", "")).lower() == key]
        if not matches:
            continue
        matches.sort(key=lambda img: (img.get("rev") or 0), reverse=True)
        sizes = matches[0].get("sizes") or {}
        for size in SIZE_ORDER.get(role, ["1000"]):
            entry = sizes.get(size)
            if entry and entry.get("url"):
                return {
                    "role": role, "key": matches[0].get("key"), "lang": lang, "rev": matches[0].get("rev"),
                    "size": size, "url": entry["url"], "image_id": matches[0].get("imgid"),
                    "w": entry.get("w"), "h": entry.get("h"),
                }
    return None


def to_json_safe(value):
    if value is None:
        return None
    if isinstance(value, (list, dict)):
        return json.dumps(value, ensure_ascii=False)
    return value


COLUMNS = ["code", "stratum", "split", "product_name", "generic_name", "brands", "lang",
           "quantity", "last_modified_t", "rev", "categories_tags", "labels_tags",
           "states_tags", "countries_tags", "food_groups_tags", "images_json",
           "has_nutriments", "has_nutrition_img", "ingredients_text",
           "front_url", "front_lang", "front_image_rev", "front_size", "front_image_id",
           "front_w", "front_h",
           "ingredients_url", "ingredients_lang", "ingredients_image_rev", "ingredients_size",
           "ingredients_image_id", "ingredients_w", "ingredients_h",
           "nutrition_url", "nutrition_lang", "nutrition_image_rev", "nutrition_size",
           "nutrition_image_id", "nutrition_w", "nutrition_h"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--salt", default="fl-grocery-ocr-2026-06-v1")
    ap.add_argument("--food-url", default=None, help="override food.parquet source (URL or local path)")
    ap.add_argument("--beauty-url", default=None, help="override beauty.parquet source")
    args = ap.parse_args()
    salt_sql = args.salt.replace("'", "''")

    os.makedirs(args.out_dir, exist_ok=True)
    con = duckdb.connect()
    # Bounded footprint: full parquet scans have starved the sandbox before.
    con.execute("SET enable_object_cache=true")
    con.execute("SET memory_limit='1500MB'")
    con.execute("SET threads=4")
    con.execute("SET temp_directory='/tmp/duckdb-spill'")

    beauty = read_with_retry(
        con,
        f"""
        SELECT code, product_name, brands, lang, images, last_modified_t, rev FROM (
          SELECT code,
            {NAME_SQL.format(col='product_name', alias='product_name').replace(' AS product_name', '')} AS product_name,
            brands, lang, images, last_modified_t, rev,
            md5(code || '{salt_sql}') AS bucket
          FROM read_parquet('{args.beauty_url or BEAUTY_URL}')
          WHERE regexp_matches(code, '^[0-9]{{13}}$')
            AND len(list_filter(images, x -> x.key LIKE 'front%')) > 0
            AND product_name IS NOT NULL AND length(product_name) >= 3
        ) ORDER BY bucket, code LIMIT 250
        """,
        [])

    # Materialize the filtered universe ONCE so the counts query and the
    # selection query each scan the temp table, not the 7.9 GB parquet.
    con.execute(f"CREATE TEMP TABLE stratified AS {base_sql(salt_sql, args.food_url or FOOD_URL)} SELECT * FROM stratified")

    universe = read_with_retry(
        con, "SELECT stratum, count(*) AS n FROM stratified GROUP BY 1 ORDER BY 1",
        [])

    rows = read_with_retry(
        con,
        "SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY stratum ORDER BY bucket, code) AS rn FROM stratified) WHERE rn <= ? ORDER BY stratum, rn",
        [MAX_PER_STRATUM])
    cols = [d[0] for d in con.description]
    by_stratum = {}
    for r in rows:
        d = dict(zip(cols, r))
        by_stratum.setdefault(d["stratum"], []).append(d)

    manifest = []
    for name, target, _cond in STRATA:
        pool = by_stratum.get(name, [])
        if name == "nonfood_control":
            for r in beauty:
                manifest.append({
                    "code": r[0], "stratum": name, "split": "dev",
                    "product_name": r[1], "generic_name": None, "brands": r[2],
                    "lang": r[3], "quantity": None, "last_modified_t": r[4], "rev": r[5],
                })
            continue
        random.Random(f"{args.salt}:{name}").shuffle(pool)
        for i, d in enumerate(pool[:min(target, MAX_PER_STRATUM)]):
            images = json.loads(d["images_json"] or "[]")
            entry = {
                "code": d["code"], "stratum": name,
                "split": "dev" if i < 0.15 * target else "test",
                "product_name": d["product_name"], "generic_name": d["generic_name"],
                "brands": d["brands"], "lang": d["lang"], "quantity": d["quantity"],
                "last_modified_t": d["last_modified_t"], "rev": d["rev"],
                "categories_tags": d["categories_tags"], "labels_tags": d["labels_tags"],
                "states_tags": d["states_tags"], "countries_tags": d["countries_tags"],
                "food_groups_tags": d["food_groups_tags"], "images_json": d["images_json"],
                "has_nutriments": d["has_nutriments"], "has_nutrition_img": d["has_nutrition_img"],
                "ingredients_text": d["ingredients_text"],
            }
            for role in ("front", "ingredients", "nutrition"):
                picked = pick(images, role, d["lang"], d["code"])
                entry[f"{role}_url"] = picked["url"] if picked else None
                entry[f"{role}_lang"] = picked["lang"] if picked else None
                entry[f"{role}_image_rev"] = picked["rev"] if picked else None
                entry[f"{role}_size"] = picked["size"] if picked else None
                entry[f"{role}_image_id"] = picked["image_id"] if picked else None
                entry[f"{role}_w"] = picked["w"] if picked else None
                entry[f"{role}_h"] = picked["h"] if picked else None
            manifest.append(entry)

    with open(os.path.join(args.out_dir, "manifest.csv"), "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(manifest)

    with open(os.path.join(args.out_dir, "universe_counts.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["stratum", "universe"])
        w.writerows(universe)

    print(f"manifest rows: {len(manifest)}")
    for name, target, _ in STRATA:
        n = sum(1 for m in manifest if m["stratum"] == name)
        print(f"  {name}: {n} / target {target}")


if __name__ == "__main__":
    main()
