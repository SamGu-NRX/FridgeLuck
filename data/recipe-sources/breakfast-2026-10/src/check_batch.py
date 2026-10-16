#!/usr/bin/env python3
"""Packet checker for the breakfast-2026-10 originals corpus.

Adapted from the world-2026-10 checker (same gate order and wording); the
suite modules (rs.py, bands.py, canon/, allergens.json) are NOT re-copied —
they are imported from the world packet's committed, unmodified suite copy
(data/recipe-sources/world-2026-10/src, suite @ 9d3a704). RS_SUITE_DIR
overrides for a scored-tree checkout.

Checks, in order:
  1. Record schema: RS v1 required fields, fl-bfast-NNNN id sequence, suite
     cuisine vocabulary, breakfast/lunch/dinner slots, cuisine <-> region
     mapping extended to this packet's four added regions (american,
     british, indian, mediterranean).
  2. Rights gate: every source_ref resolves in evidence/originals-rights-
     manifest.json with rights_status "original", named author, basis, date;
     no stale entries.
  3. Quantity evidence, recomputed independently from the pinned FNDDS
     extract through src/fndds_registry.py.
  4. The pinned suite linter over every record with the fixture allergen
     table merged with this packet's classification extension.
  5. Claims gate: the packet ships no diet/allergen claims.
  6. Release gates: vegetarian share >= 1/3; every extension-table row that
     assigns a safety class cites FSIS guidance; PLUS this packet's brief —
     at least 12 recipes at 15 minutes or less; more than 10 recipes with
     KNOWN ingredient composition that are intended vegan or gluten-free
     (derived fail-closed from the app's name-mappings + vocabulary
     composition classes, the same classes the catalog compiler derives
     claims from); no batch title collides with a title already in the
     repo recipe corpus.

Usage: python3 check_batch.py [--corpus originals.jsonl] [--quiet]
Exits 0 with a printed summary when clean; exits 1 listing violations.
run_check() is importable for the planted-failure tests in
test_check_batch.py.
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
sys.path.insert(0, str(Path(os.environ.get("RS_SUITE_DIR", str(WORLD_SRC)))))
sys.path.insert(0, str(HERE))

import bands  # noqa: E402  (suite: allowed cuisines, slots)
import rs  # noqa: E402  (pinned linter)

import fndds_registry as registry  # noqa: E402  (this packet's registry)
from build_batch import diet_composition, load_vocab  # noqa: E402

FNDDS_TABLE = Path(os.environ.get(
    "FNDDS_TABLE",
    str(PKG / "evidence" / "fndds-portions.json")))

REGIONS = {"korean", "japanese", "chinese", "thai", "vietnamese",
           "middle_eastern", "north_african", "west_african", "caribbean",
           "latin_american", "eastern_european",
           "american", "british", "indian", "mediterranean"}

ANIMAL_NAMES = {
    "nuoc mam", "fish sauce", "hao you", "dashi", "broth", "stock",
    "beef broth", "pork cracklings", "anchovies", "fish cake",
    "shiitake dashi", "worcestershire sauce", "gelatin", "lard", "bacon",
    "salted duck egg",
}

CORPUS_PATH = REPO / "data" / "recipes" / "corpus.jsonl"


def load_fndds_index() -> dict[tuple[str, str], dict]:
    data = json.loads(FNDDS_TABLE.read_text())
    idx = {}
    for row in data["portions"]:
        food = " ".join(str(row.get("food", "")).split()).lower()
        idx.setdefault((food, str(row.get("unit", "")).strip()), row)
    return idx


def merged_classification_table() -> dict:
    fixture = json.loads((Path(os.environ.get("RS_SUITE_DIR", str(WORLD_SRC)))
                          / "allergens.json").read_text())
    merged = json.loads(json.dumps(fixture))
    ext_path = PKG / "evidence" / "allergen-classes-extension.json"
    if ext_path.is_file():
        ext = json.loads(ext_path.read_text())
        for alias, key in ext.get("ingredient_aliases", {}).items():
            merged["ingredient_aliases"].setdefault(alias, key)
        for key, row in ext.get("ingredients", {}).items():
            merged["ingredients"].setdefault(key, row)
    return merged


def normalize_title(t: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def corpus_titles() -> set[str]:
    titles: set[str] = set()
    if CORPUS_PATH.is_file():
        for line in CORPUS_PATH.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            t = row.get("title") or row.get("name")
            if t:
                titles.add(normalize_title(str(t)))
    return titles


def run_check(records: list[dict], manifest: dict,
              fndds: dict[tuple[str, str], dict] | None = None,
              ) -> list[str]:
    """Return the list of packet violations (empty = clean)."""
    v: list[str] = []
    if fndds is None:
        fndds = load_fndds_index()
    surface_map, vocab_entries = load_vocab()

    # 1. schema and sequence ------------------------------------------------
    seen: set[str] = set()
    for n, r in enumerate(records, start=1):
        rid = r.get("id", "?")
        if rid != f"fl-bfast-{n:04d}":
            v.append(f"record[{n}]: id {rid!r} breaks the fl-bfast-NNNN "
                     f"sequence")
        if rid in seen:
            v.append(f"{rid}: duplicate record id")
        seen.add(rid)
        for field in rs.REQUIRED_RECIPE_FIELDS:
            if field not in r:
                v.append(f"{rid}: missing required field {field!r}")
        if r.get("rs_version") != rs.RS_VERSION:
            v.append(f"{rid}: rs_version {r.get('rs_version')!r} is not "
                     f"{rs.RS_VERSION!r}")
        if r.get("cuisine") not in bands.CUISINE_SET:
            v.append(f"{rid}: cuisine {r.get('cuisine')!r} outside the "
                     f"suite vocabulary")
        slots = r.get("meal_slots")
        if not isinstance(slots, list) or not set(slots) <= bands.SLOT_SET:
            v.append(f"{rid}: meal_slots {slots!r} outside the declared slots")
        wc = r.get("world_cuisine")
        if wc not in REGIONS:
            v.append(f"{rid}: world_cuisine {wc!r} is not a packet region")
        elif r.get("cuisine") != registry_cuisine(wc):
            v.append(f"{rid}: cuisine {r.get('cuisine')!r} does not match "
                     f"the region mapping for {wc!r}")
        mins = r.get("minutes")
        if not isinstance(mins, int) or mins <= 0:
            v.append(f"{rid}: minutes {mins!r} is not a positive integer")

    # 2. rights gate ---------------------------------------------------------
    for r in records:
        rid, ref = r.get("id", "?"), r.get("source_ref")
        entry = manifest.get(ref)
        if entry is None:
            v.append(f"{rid}: source_ref {ref!r} has no rights-manifest entry")
            continue
        if entry.get("rights_status") != "original":
            v.append(f"{rid}: rights_status {entry.get('rights_status')!r} "
                     f"is not 'original'")
        for field in ("author", "basis", "date"):
            if not str(entry.get(field, "")).strip():
                v.append(f"{rid}: rights-manifest entry {ref!r} missing "
                         f"{field!r}")
    stale = set(manifest) - {r.get("source_ref") for r in records}
    for ref in sorted(stale):
        v.append(f"rights manifest: entry {ref!r} covers no record in the "
                 f"corpus")

    # 3. quantity evidence, recomputed from the pinned FNDDS table ----------
    for r in records:
        rid = r.get("id", "?")
        for i, line in enumerate(r.get("ingredients", [])):
            name = line.get("name", "?")
            qty = line.get("qty") or {}
            kind = qty.get("kind")
            grams = qty.get("grams")
            if kind == "source_grams":
                if not isinstance(grams, (int, float)) or grams <= 0:
                    v.append(f"{rid}: ingredient[{i}] {name!r} source_grams "
                             f"{grams!r} is not a positive mass")
            elif kind == "unknown":
                if not str(qty.get("note", "")).strip():
                    v.append(f"{rid}: ingredient[{i}] {name!r} unknown "
                             f"quantity carries no note")
            elif kind == "household":
                unit = qty.get("unit")
                value = qty.get("value")
                ref = qty.get("conversion_ref")
                key = (name.strip().lower(), unit)
                entry = registry.DIRECT.get(key) or registry.DERIVED.get(key)
                if entry is None:
                    v.append(f"{rid}: ingredient[{i}] {name!r} unit {unit!r} "
                             f"has no registry row backing its conversion")
                    continue
                if key in registry.DERIVED:
                    ffood, funit, mult = entry
                else:
                    ffood, funit = entry
                    mult = None
                row = fndds.get((ffood.lower(), funit))
                if row is None:
                    v.append(f"{rid}: ingredient[{i}] {name!r} cites FNDDS "
                             f"food {ffood!r} unit {funit!r}, which has no "
                             f"row in the pinned table")
                    continue
                gpu = float(row["grams"]) / float(row["magnitude"])
                if mult:
                    gpu *= mult
                expect = round(float(value) * gpu, 1)
                if not isinstance(grams, (int, float)) or abs(
                        grams - expect) > 0.05:
                    v.append(f"{rid}: ingredient[{i}] {name!r} carries grams "
                             f"{grams!r}, but the pinned FNDDS row fdcId "
                             f"{row['fdcId']} supports {expect}")
                if not str(ref).startswith("fndds:") or \
                        ref != f"fndds:{row['fdcId']}":
                    v.append(f"{rid}: ingredient[{i}] {name!r} cites "
                             f"conversion_ref {ref!r}, which is not the "
                             f"pinned row fndds:{row['fdcId']} supporting it")
            else:
                v.append(f"{rid}: ingredient[{i}] {name!r} qty.kind "
                         f"{kind!r} is not quantity evidence")

    # 4. pinned linter --------------------------------------------------------
    canon, desc = rs.CanonRulebook.load(None)
    if canon is None:
        v.append(f"canon rulebook unavailable: {desc}")
        table = merged_classification_table()
    else:
        table = merged_classification_table()
        scan = rs.AllergenScanner(table, facts=None,
                                  facts_reason="packet ships no claims")
        rows: dict[str, dict] = {}
        for r in records:
            for ref, row in r.get("conversions", {}).items():
                rows.setdefault(ref, row)
        for r in records:
            for err in rs.lint_recipe(r, cuisines=bands.CUISINE_SET,
                                      meal_slots=bands.SLOT_SET,
                                      conversion_rows=rows,
                                      allergen_scan=scan, canon=canon):
                v.append(err)

    # 5. claims gate -----------------------------------------------------------
    for r in records:
        if r.get("claims"):
            v.append(f"{r.get('id', '?')}: ships claims the packet does not "
                     f"substantiate")

    # 6. release gates -----------------------------------------------------------
    n = len(records)
    if n == 0:
        v.append("corpus is empty")
        return v
    veg = sum(1 for r in records if is_vegetarian(r, table, canon))
    if veg * 3 < n:
        v.append(f"vegetarian share {veg}/{n} is below the required one third")
    ext_path = PKG / "evidence" / "allergen-classes-extension.json"
    if ext_path.is_file():
        ext = json.loads(ext_path.read_text())
        for key, row in ext.get("ingredients", {}).items():
            if row.get("classes") and "fsis" not in str(
                    row.get("note", "")).lower():
                v.append(f"classification extension: row {key!r} assigns a "
                         f"safety class without an FSIS-citing note")

    # 6b. brief-specific release gates ----------------------------------------
    fast = [r for r in records
            if isinstance(r.get("minutes"), int) and r["minutes"] <= 15]
    if len(fast) < 12:
        v.append(f"brief gate: only {len(fast)} recipes are 15 minutes or "
                 f"less; at least 12 are required")
    known_diet = 0
    for r in records:
        comp = diet_composition([l.get("name", "") for l in
                                 r.get("ingredients", [])],
                                surface_map, vocab_entries)
        if comp["vegan_known"] or comp["gluten_free_known"]:
            known_diet += 1
    if known_diet <= 10:
        v.append(f"brief gate: only {known_diet} recipes have known "
                 f"composition and are intended vegan or gluten-free; more "
                 f"than 10 are required")
    titles = [normalize_title(str(r.get("title", ""))) for r in records]
    dupes = {t for t in titles if titles.count(t) > 1}
    for t in sorted(dupes):
        v.append(f"brief gate: duplicate normalized title {t!r} inside the "
                 f"batch")
    corpus = corpus_titles()
    for r, t in zip(records, titles):
        if t in corpus:
            v.append(f"brief gate: {r.get('id', '?')} title "
                     f"{r.get('title')!r} collides with a title already in "
                     f"data/recipes/corpus.jsonl")
    return v


def registry_cuisine(region: str) -> str:
    return {"korean": "asian", "japanese": "asian", "chinese": "asian",
            "thai": "asian", "vietnamese": "asian",
            "middle_eastern": "mediterranean",
            "north_african": "mediterranean",
            "mediterranean": "mediterranean",
            "indian": "indian",
            "west_african": "indian",
            "caribbean": "american",
            "american": "american",
            "british": "american",
            "latin_american": "mexican",
            "eastern_european": "italian"}[region]


def is_vegetarian(record: dict, table: dict, canon=None) -> bool:
    for line in record.get("ingredients", []):
        name = str(line.get("name", "")).lower()
        key = table.get("ingredient_aliases", {}).get(name)
        classes = set(table.get("ingredients", {}).get(key, {})
                      .get("classes", [])) if key else set()
        if canon is not None:
            classes |= set(canon.classes_for_name(name))
        if classes & {"meat_poultry", "meat_ground", "meat_whole_cut_pork",
                      "meat_whole_cut_red", "flesh_fish", "flesh_shellfish"}:
            return False
        if name in ANIMAL_NAMES:
            return False
    return True


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=str(PKG / "originals.jsonl"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    records = [json.loads(line) for line in
               Path(args.corpus).read_text().splitlines() if line.strip()]
    manifest = json.loads(
        (PKG / "evidence" / "originals-rights-manifest.json").read_text())
    violations = run_check(records, manifest)

    canon, _ = rs.CanonRulebook.load(None)
    table = merged_classification_table()
    veg = sum(1 for r in records if is_vegetarian(r, table, canon))
    slots: dict[str, int] = {}
    for r in records:
        for s in r.get("meal_slots", []):
            slots[s] = slots.get(s, 0) + 1
    fast = sum(1 for r in records
               if isinstance(r.get("minutes"), int) and r["minutes"] <= 15)

    print(f"checked {len(records)} records")
    print(f"vegetarian {veg}/{len(records)} "
          f"({veg / max(len(records), 1):.1%}); slots {slots}; "
          f"fast15 {fast}")
    if violations:
        print(f"FAILED with {len(violations)} violation(s):")
        for x in violations:
            print("  " + x)
        return 1
    print("PASS: rights, quantities, pinned lint, and release gates all clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
