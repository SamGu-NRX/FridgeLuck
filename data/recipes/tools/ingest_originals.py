#!/usr/bin/env python3
"""Ingest data/recipes/originals/ (branch overhaul/original-recipes) into the corpus.

This task never authors, edits, or invents recipe content. It consumes the
originals task's three files read-only and merges them into
data/recipes/corpus.jsonl + rights_manifest.json through the same validation
path every licensed source went through (suite C's rs.py/rights.py/bands.py,
SCHEMA.md §8):

  1. originals rights manifest must validate 401/401 clear (rights.py);
  2. every recipe re-lints clean against THIS suite checkout (rs.py) with
     0 unchecked claims — a recipe that fails any re-check is stopped and
     reported, never passed through;
  3. dedupe: unique ids, no normalized-title or (title, core-ingredients)
     collision within the batch or against the corpus already in the file;
  4. one rights record per ingested recipe (source_type `original` or
     `original-rewrite` per the recipe's provenance, license
     LicenseRef-FL-Original, license_evidence pointing at the originals
     manifest/audit), permissions all true except `images` while no image
     ships.

Linter residue (`_classes` — computed scanner state the source task's
validation injected and should never have persisted) is stripped at
ingestion; that is validation hygiene, not recipe editing.

The tool is idempotent: it refuses to run when corpus.jsonl already holds
fl-original-* ids. Default is --check (write nothing); pass --write to write.

    python3 data/recipes/tools/ingest_originals.py \
        --suite-dir /tmp/suite/evaluation/suites/recipes \
        --originals /path/to/originals.jsonl \
        --originals-manifest /path/to/rights_manifest.json \
        --source-ref "overhaul/original-recipes at 607ef99" [--write]
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"

ORIGINAL_ID = re.compile(r"^fl-original-\d{4}$")
KNOWN_TOP_KEYS = {
    "rs_version", "id", "title", "cuisine", "meal_slots", "minutes",
    "servings", "ingredients", "steps", "source_ref", "claims", "provenance",
}
ACCESS_DATE = "2026-10-11"  # build date, matches the report's convention


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def core_set(recipe: dict[str, Any]) -> frozenset[str]:
    return frozenset(
        norm(i.get("name", "")) for i in recipe.get("ingredients", [])
        if isinstance(i, dict))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True,
                    help="extracted evaluation/suites/recipes (eval/scorecard-runner)")
    ap.add_argument("--originals", required=True, type=Path,
                    help="originals.jsonl extracted from overhaul/original-recipes")
    ap.add_argument("--originals-manifest", required=True, type=Path,
                    help="rights_manifest.json extracted from overhaul/original-recipes")
    ap.add_argument("--source-ref", required=True,
                    help="branch+head the originals came from (for license_evidence)")
    ap.add_argument("--write", action="store_true",
                    help="write corpus.jsonl + rights_manifest.json (default: check only)")
    args = ap.parse_args()

    sys.path.insert(0, args.suite_dir)
    import bands
    import rights as rights_mod
    import rs

    conversions = json.loads((Path(args.suite_dir) / "conversions.json").read_text())
    conversions = conversions.get("conversions", conversions)
    allergens = json.loads((Path(args.suite_dir) / "allergens.json").read_text())
    scanner = rs.AllergenScanner(allergens)

    stopped: list[str] = []

    # ---- current corpus state ---------------------------------------------
    corpus = [json.loads(l) for l in CORPUS.read_bytes().decode("utf-8").splitlines()
              if l.strip()]
    manifest = json.loads(MANIFEST.read_text())
    if any(str(r.get("id", "")).startswith("fl-original-") for r in corpus):
        print("REFUSING: corpus.jsonl already contains fl-original-* ids "
              "(ingestion is append-only and idempotent)")
        return 1
    corpus_ids = {r["id"] for r in corpus}
    corpus_keys = {(norm(r["title"]), core_set(r)) for r in corpus}
    corpus_titles = {norm(r["title"]) for r in corpus}

    # ---- originals inputs ---------------------------------------------------
    originals: list[dict[str, Any]] = []
    for lineno, line in enumerate(args.originals.read_bytes().decode("utf-8").splitlines(),
                                  start=1):
        if not line.strip():
            continue
        try:
            originals.append(json.loads(line))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            stopped.append(f"originals.jsonl line {lineno}: unparseable ({exc})")
    omanifest = json.loads(args.originals_manifest.read_text())
    ostatuses = rights_mod.validate_manifest(omanifest)
    o_clear = {ref for ref, s in ostatuses.items() if s["status"] == "clear"}
    print(f"originals: {len(originals)} recipes; rights manifest "
          f"{len(o_clear)}/{len(ostatuses)} clear")

    # ---- per-recipe re-checks ------------------------------------------------
    accepted: list[dict[str, Any]] = []
    batch_ids: set[str] = set()
    batch_keys: set[tuple[str, frozenset[str]]] = set()
    batch_titles: set[str] = set()
    for rec in originals:
        rid = rec.get("id", "?")
        problems: list[str] = []
        if rec.get("rs_version") != "1":
            problems.append("rs_version != '1'")
        if not isinstance(rid, str) or not ORIGINAL_ID.match(rid):
            problems.append(f"id {rid!r} does not match fl-original-<4 digits>")
        if rec.get("source_ref") != rid:
            problems.append("source_ref != id")
        extra = set(rec) - KNOWN_TOP_KEYS
        if extra - {"_classes"}:
            problems.append(f"unexpected top-level fields: {sorted(extra - {'_classes'})}")
        if rid not in o_clear:
            problems.append("rights record not clear in the originals manifest")
        if rid in corpus_ids or rid in batch_ids:
            problems.append("duplicate id (corpus or batch)")
        if not problems:
            t, c = norm(rec.get("title", "")), core_set(rec)
            if t in corpus_titles or t in batch_titles:
                problems.append(f"duplicate normalized title vs corpus/batch: {t!r}")
            elif (t, c) in corpus_keys or (t, c) in batch_keys:
                problems.append(f"duplicate (title, core-ingredients) vs corpus/batch: {t!r}")
        if problems:
            for p in problems:
                stopped.append(f"{rid}: {p}")
            continue

        # lint re-check on a deep copy (lint_corpus strips unchecked claims
        # in place; the strip count must be 0 for the recipe to pass through)
        work = copy.deepcopy(rec)
        work.pop("_classes", None)
        work["_classes"] = sorted(scanner.classes_for(work))
        lint = rs.lint_corpus(
            [work], cuisines=bands.CUISINE_SET, meal_slots=bands.SLOT_SET,
            conversions=conversions, allergen_scan=scanner)
        if lint["recipes_with_violations"]:
            for v in lint["recipes_with_violations"].get(rid, []):
                stopped.append(f"{rid}: linter: {v}")
            continue
        if lint["unchecked_claims"] or lint["stripped_claims"]:
            stopped.append(f"{rid}: {lint['unchecked_claims']} unchecked / "
                           f"{lint['stripped_claims']} stripped claim(s)")
            continue
        if "claims" in rec and rec["claims"] != work["claims"]:
            stopped.append(f"{rid}: claims changed under scanner recomputation")
            continue

        clean = copy.deepcopy(rec)
        clean.pop("_classes", None)  # linter residue, not recipe content
        accepted.append(clean)
        batch_ids.add(rid)
        batch_titles.add(norm(clean["title"]))
        batch_keys.add((norm(clean["title"]), core_set(clean)))

    print(f"accepted: {len(accepted)}/{len(originals)}; stopped: {len(stopped)}")
    for s in stopped:
        print(f"  STOPPED {s}")

    # ---- build the new manifest records --------------------------------------
    new_records: dict[str, dict[str, Any]] = {}
    for rec in accepted:
        rid = rec["id"]
        prov = rec.get("provenance") or {}
        rewrite_of = prov.get("rewrite_of") if isinstance(prov, dict) else None
        if isinstance(rewrite_of, int):
            source_type = "original-rewrite"
            origin = (f"FridgeLuck original expression (rewrite of bundled recipe "
                      f"{rewrite_of} in apps/ios/Resources/data.json, per provenance.rewrite_of)")
        else:
            source_type = "original"
            origin = ("FridgeLuck original expression authored for FridgeLuck "
                      "(task fl-original-recipes-f1)")
        new_records[rid] = {
            "source_id": rid,
            "source_type": source_type,
            "origin": origin,
            "license": "LicenseRef-FL-Original",
            "access_date": ACCESS_DATE,
            "license_evidence": (
                f"data/recipes/originals/rights_manifest.json record {rid} "
                f"(branch {args.source_ref}); ingested into the corpus after "
                f"re-verification (lint, claims, dedupe) this session"),
            "permissions": {
                "text": True, "images": False, "modification": True,
                "attribution": True, "caching": True, "offline_use": True,
            },
        }

    total = len(corpus) + len(accepted)
    kinds: dict[str, int] = {}
    for r in corpus + accepted:
        for i in r.get("ingredients", []):
            k = (i.get("qty") or {}).get("kind", "?")
            kinds[k] = kinds.get(k, 0) + 1
    print(f"combined corpus would be: {total} recipes; "
          f"manifest records: {len(manifest['records']) + len(new_records)}; "
          f"qty kinds: {dict(sorted(kinds.items()))}")
    if not accepted:
        print("nothing to ingest")
        return 0
    if not args.write:
        print("CHECK-ONLY: no files written")
        return 0

    # ---- write ----------------------------------------------------------------
    out_corpus = CORPUS.read_bytes().decode("utf-8")
    if not out_corpus.endswith("\n"):
        out_corpus += "\n"
    out_corpus += "".join(
        json.dumps(rec) + "\n" for rec in accepted)
    CORPUS.write_text(out_corpus, newline="\n")

    manifest["records"].update(new_records)
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    print(f"WROTE: corpus.jsonl now {total} recipes; rights_manifest.json now "
          f"{len(manifest['records'])} records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
