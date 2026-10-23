#!/usr/bin/env python3
"""Validator for data/kitchen-knowledge/packs/*.json (python3, stdlib only).

Checks:
- every file parses to the envelope schema {"schemaVersion":1,"kind":...,"retrieved":...,"data":{...}}
- ids are unique (pack ids globally across files; source ids and region ids per file)
- every citationId (pack-level, item-level, and region definitionCitation) resolves to a
  data.sources record with non-empty url, retrieved (YYYY-MM-DD), and licence
- every usdaFdcId is an int that either exists in the bundled catalog sqlite
  (apps/ios/Resources/usda_ingredient_catalog.sqlite, opened read-only) or is listed in
  UNVERIFIED_IDS below with a reason
- budget packs: item sums stay under budgetUsd; totalCostUsd matches the item sum;
  quantityKg present and positive
- seasonal packs: months 1-12 all present for every region, exactly one pack per
  region per month, non-empty produce lists

Usage: python3 validate.py            (from anywhere; paths resolved relative to this file)
Exit code 0 = all green.
"""
import json
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACKS_DIR = os.path.dirname(HERE)                      # data/kitchen-knowledge/packs
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(PACKS_DIR)))  # packs -> kitchen-knowledge -> data -> repo root
CATALOG = os.path.join(REPO_ROOT, "apps/ios/Resources/usda_ingredient_catalog.sqlite")

FILES = {
    "budget_packs.json": "budget-packs",
    "food_bank_packs.json": "food-bank-packs",
    "seasonal_packs.json": "seasonal-packs",
    "use_it_up_packs.json": "use-it-up-packs",
}

# Explicit allowlist of USDA fdcIds NOT present in the bundled catalog sqlite.
# Each entry must carry a reason. Additions require a retrieval receipt (FDC API query
# with URL and date) recorded in SOURCES.md or the pack notes.
UNVERIFIED_IDS = {
    173744: "Kidney beans, mature seeds, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); "
            "absent from the bundled 800-row catalog sqlite.",
    171722: "Cranberries, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); "
            "absent from the bundled 800-row catalog sqlite.",
    175199: "Beans, pinto, mature seeds, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); "
            "absent from the bundled 800-row catalog sqlite.",
    171287: "Eggs, whole, raw, fresh - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog only carries "
            "egg (whole, raw, frozen, salted).",
    171265: "Milk, whole, 3.25% milkfat - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog only carries "
            "1%/2%/skim rows.",
    173944: "Bananas, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); absent from the bundled catalog sqlite.",
    174924: "Bread, white, commercially prepared (untoasted) - verified via USDA FDC API SR Legacy "
            "search (api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); absent from the bundled catalog sqlite.",
    169143: "Beans, snap, green, canned, drained solids - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog has no canned green bean row.",
    169214: "Corn, sweet, yellow, canned, drained solids - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog has no canned corn row.",
    175175: "Salmon, pink, canned, drained solids - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog has no canned salmon row.",
    169917: "Oranges, raw, navels - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog only carries "
            "Valencia/Florida orange rows.",
    169291: "Squash, summer, zucchini, includes skin, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog only carries baby zucchini.",
    168482: "Sweet potato, raw, unprepared - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog only carries baked/boiled/canned/frozen sweet potato rows.",
    171719: "Cherries, sweet, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite.",
    169998: "Corn, sweet, yellow, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog only carries sweet white corn.",
    174673: "Grapefruit, raw, pink and red, all areas - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite.",
    169961: "Beans, snap, green, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog has no fresh green bean row.",
    168448: "Pumpkin, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog only carries pumpkin seeds.",
    167755: "Raspberries, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog only carries raspberry juice/puree.",
    169703: "Rice, brown, long-grain, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite.",
    170052: "Tomatoes, red, ripe, canned, stewed - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); bundled "
            "catalog carries crushed/sauce/puree but not a plain canned tomato row.",
    169105: "Tangerines (mandarin oranges), raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite.",
    173946: "Blackberries, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite.",
    171711: "Blueberries, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); absent from the bundled catalog sqlite.",
    174683: "Grapes, raw - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); absent from the bundled catalog sqlite.",
    173904: "Cereals, oats, regular and quick, not fortified, dry - verified via USDA FDC API SR Legacy "
            "search (api.nal.usda.gov/fdc/v1, retrieved 2026-10-11); bundled catalog carries oat bran "
            "and oat flour but no plain rolled-oats row.",
    169655: "Sugars, granulated - verified via USDA FDC API SR Legacy search "
            "(api.nal.usda.gov/fdc/v1, quoted description match, retrieved 2026-10-11); absent from "
            "the bundled catalog sqlite. (Used only in a budget-pack note; sugar itself was priced "
            "but excluded from packs.)",
}

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MONTH_RE = re.compile(r"^\d{4}-\d{2}$")

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def load_catalog_ids():
    if not os.path.exists(CATALOG):
        err(f"catalog sqlite not found at {CATALOG}")
        return set()
    conn = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    try:
        rows = conn.execute("SELECT fdc_id FROM ingredient_catalog").fetchall()
    finally:
        conn.close()
    return {r[0] for r in rows}


def check_envelope(name, doc, expected_kind):
    if not isinstance(doc, dict):
        err(f"{name}: top level is not an object")
        return None
    if doc.get("schemaVersion") != 1:
        err(f"{name}: schemaVersion != 1")
    if doc.get("kind") != expected_kind:
        err(f"{name}: kind {doc.get('kind')!r} != {expected_kind!r}")
    if not DATE_RE.match(str(doc.get("retrieved", ""))):
        err(f"{name}: retrieved is not YYYY-MM-DD: {doc.get('retrieved')!r}")
    data = doc.get("data")
    if not isinstance(data, dict):
        err(f"{name}: data is not an object")
        return None
    sources = data.get("sources")
    if not isinstance(sources, list) or not sources:
        err(f"{name}: data.sources missing or empty")
        return data, {}
    smap = {}
    seen = set()
    for s in sources:
        if not isinstance(s, dict) or "id" not in s:
            err(f"{name}: malformed source record {s!r}")
            continue
        sid = s["id"]
        if sid in seen:
            err(f"{name}: duplicate source id {sid}")
        seen.add(sid)
        for field in ("title", "url", "retrieved", "licence"):
            if not s.get(field):
                err(f"{name}: source {sid} missing {field}")
        if s.get("retrieved") and not DATE_RE.match(str(s["retrieved"])):
            err(f"{name}: source {sid} retrieved not YYYY-MM-DD: {s['retrieved']!r}")
        smap[sid] = s
    return data, smap


def check_citation(name, smap, cid, where):
    if cid not in smap:
        err(f"{name}: {where} cites unknown citationId {cid!r}")


def check_key(name, key, where):
    if not isinstance(key, str) or not key.strip():
        err(f"{name}: {where} has empty ingredientKey")
    elif key != key.lower():
        err(f"{name}: {where} ingredientKey not lowercase: {key!r}")


def check_fdc(name, catalog_ids, fdc, where):
    if not isinstance(fdc, int):
        err(f"{name}: {where} usdaFdcId is not an int: {fdc!r}")
        return
    if fdc not in catalog_ids and fdc not in UNVERIFIED_IDS:
        err(f"{name}: {where} usdaFdcId {fdc} not in bundled catalog and not allowlisted")


def validate_budget(name, doc, catalog_ids):
    data, smap = check_envelope(name, doc, "budget-packs")
    if data is None or isinstance(data, tuple):
        data, smap = data if isinstance(data, tuple) else (data, {})
    if not data:
        return
    if data.get("region") != "United States, national average":
        err(f"{name}: region not national average")
    if not MONTH_RE.match(str(data.get("priceDate", ""))):
        err(f"{name}: data.priceDate not YYYY-MM: {data.get('priceDate')!r}")
    pack_ids = set()
    for p in data.get("packs", []):
        pid = p.get("id")
        if pid in pack_ids:
            err(f"{name}: duplicate pack id {pid}")
        pack_ids.add(pid)
        if not p.get("region"):
            err(f"{name}/{pid}: missing region")
        if not MONTH_RE.match(str(p.get("priceDate", ""))):
            err(f"{name}/{pid}: priceDate not YYYY-MM")
        if not isinstance(p.get("budgetUsd"), (int, float)):
            err(f"{name}/{pid}: budgetUsd not numeric")
        n_items = len(p.get("items", []))
        if not 6 <= n_items <= 10:
            err(f"{name}/{pid}: item count {n_items} outside 6-10")
        total = 0.0
        for it in p.get("items", []):
            where = f"{pid}/{it.get('ingredientKey')}"
            check_key(name, it.get("ingredientKey"), where)
            check_fdc(name, catalog_ids, it.get("usdaFdcId"), where)
            if not it.get("quantity"):
                err(f"{name}: {where} missing quantity")
            kg = it.get("quantityKg")
            if not isinstance(kg, (int, float)) or kg <= 0:
                err(f"{name}: {where} quantityKg not positive: {kg!r}")
            price = it.get("priceUsd")
            if not isinstance(price, (int, float)) or price <= 0:
                err(f"{name}: {where} priceUsd not positive: {price!r}")
            else:
                total += price
            if it.get("priceSourceId") != "s1":
                err(f"{name}: {where} priceSourceId != s1")
        for cid in p.get("citationIds", []):
            check_citation(name, smap, cid, f"pack {pid}")
        total = round(total, 4)
        if abs(total - p.get("totalCostUsd", -1)) > 0.0005:
            err(f"{name}/{pid}: totalCostUsd {p.get('totalCostUsd')} != item sum {total}")
        if total > p.get("budgetUsd", 0) + 1e-9:
            err(f"{name}/{pid}: item sum {total} exceeds budget {p.get('budgetUsd')}")
    return pack_ids


def validate_food_bank(name, doc, catalog_ids):
    data, smap = check_envelope(name, doc, "food-bank-packs")
    if not data:
        return
    pack_ids = set()
    for p in data.get("packs", []):
        pid = p.get("id")
        if pid in pack_ids:
            err(f"{name}: duplicate pack id {pid}")
        pack_ids.add(pid)
        if not p.get("distributionNote"):
            err(f"{name}/{pid}: missing distributionNote")
        items = p.get("items", [])
        if not 3 <= len(items) <= 30:
            err(f"{name}/{pid}: item count {len(items)} outside 3-30")
        for it in items:
            where = f"{pid}/{it.get('ingredientKey')}"
            check_key(name, it.get("ingredientKey"), where)
            check_fdc(name, catalog_ids, it.get("usdaFdcId"), where)
            if not it.get("typicalForm"):
                err(f"{name}: {where} missing typicalForm")
            if not it.get("citationIds"):
                err(f"{name}: {where} has no citationIds")
            for cid in it.get("citationIds", []):
                check_citation(name, smap, cid, where)
        for cid in p.get("citationIds", []):
            check_citation(name, smap, cid, f"pack {pid}")
    return pack_ids


def validate_seasonal(name, doc, catalog_ids):
    data, smap = check_envelope(name, doc, "seasonal-packs")
    if not data:
        return
    region_ids = set()
    for r in data.get("regions", []):
        rid = r.get("id")
        if rid in region_ids:
            err(f"{name}: duplicate region id {rid}")
        region_ids.add(rid)
        if not r.get("states"):
            err(f"{name}/region {rid}: missing states mapping")
        check_citation(name, smap, r.get("definitionCitation"), f"region {rid}")
    if not 4 <= len(region_ids) <= 6:
        err(f"{name}: region count {len(region_ids)} outside 4-6")
    seen_region_months = set()
    for m in data.get("months", []):
        month = m.get("month")
        if month not in range(1, 13):
            err(f"{name}: month out of range: {month!r}")
            continue
        for p in m.get("packs", []):
            rid = p.get("regionId")
            where = f"month {month}/{rid}"
            if rid not in region_ids:
                err(f"{name}: {where} unknown regionId")
            key = (month, rid)
            if key in seen_region_months:
                err(f"{name}: duplicate pack for {where}")
            seen_region_months.add(key)
            if not p.get("produce"):
                err(f"{name}: {where} has empty produce list")
            for pr in p.get("produce", []):
                check_key(name, pr.get("ingredientKey"), f"{where}/{pr.get('ingredientKey')}")
                check_fdc(name, catalog_ids, pr.get("usdaFdcId"), f"{where}/{pr.get('ingredientKey')}")
            for cid in p.get("citationIds", []):
                check_citation(name, smap, cid, where)
    for rid in region_ids:
        for month in range(1, 13):
            if (month, rid) not in seen_region_months:
                err(f"{name}: missing pack for month {month}, region {rid}")
    if len(seen_region_months) != len(region_ids) * 12:
        err(f"{name}: expected {len(region_ids) * 12} region-month packs, found {len(seen_region_months)}")


def validate_use_it_up(name, doc, catalog_ids):
    data, smap = check_envelope(name, doc, "use-it-up-packs")
    if not data:
        return
    pack_ids = set()
    for p in data.get("packs", []):
        pid = p.get("id")
        if pid in pack_ids:
            err(f"{name}: duplicate pack id {pid}")
        pack_ids.add(pid)
        if not p.get("situation"):
            err(f"{name}/{pid}: missing situation")
        tactic = p.get("tactic", "")
        if not isinstance(tactic, str) or len(tactic.split()) < 30:
            err(f"{name}/{pid}: tactic shorter than 30 words")
        for ing in p.get("ingredients", []):
            where = f"{pid}/{ing.get('ingredientKey')}"
            check_key(name, ing.get("ingredientKey"), where)
            check_fdc(name, catalog_ids, ing.get("usdaFdcId"), where)
        for cid in p.get("citationIds", []):
            check_citation(name, smap, cid, f"pack {pid}")
    if not 8 <= len(pack_ids) <= 10:
        err(f"{name}: pack count {len(pack_ids)} outside 8-10")
    return pack_ids


def main():
    catalog_ids = load_catalog_ids()
    all_pack_ids = {}
    for fname, kind in FILES.items():
        path = os.path.join(PACKS_DIR, fname)
        if not os.path.exists(path):
            err(f"missing file: {fname}")
            continue
        try:
            with open(path) as f:
                doc = json.load(f)
        except json.JSONDecodeError as e:
            err(f"{fname}: JSON parse error: {e}")
            continue
        if kind == "budget-packs":
            all_pack_ids[fname] = validate_budget(fname, doc, catalog_ids)
        elif kind == "food-bank-packs":
            all_pack_ids[fname] = validate_food_bank(fname, doc, catalog_ids)
        elif kind == "seasonal-packs":
            all_pack_ids[fname] = validate_seasonal(fname, doc, catalog_ids)
        elif kind == "use-it-up-packs":
            all_pack_ids[fname] = validate_use_it_up(fname, doc, catalog_ids)

    # cross-file pack id uniqueness
    seen = {}
    for fname, ids in all_pack_ids.items():
        if not ids:
            continue
        for pid in ids:
            if pid in seen:
                err(f"duplicate pack id across files: {pid} in {fname} and {seen[pid]}")
            seen[pid] = fname

    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        print(f"FAIL: {len(errors)} error(s)")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("PASS: all pack files green")
    print(f"  catalog fdc ids: {len(catalog_ids)}; allowlisted: {len(UNVERIFIED_IDS)}")
    for fname, ids in all_pack_ids.items():
        print(f"  {fname}: {len(ids) if ids else 0} pack id(s)")


if __name__ == "__main__":
    main()
