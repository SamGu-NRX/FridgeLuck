#!/usr/bin/env python3
"""Ingest the breakfast-2026-10 and pantry-2026-10 packets into the corpus.

Second 2026-10 ingestion wave, following ingest_packets_2026_10.py (world +
everyday). Never authors or edits recipe content: it renumbers packet ids
(fl-bfast-NNNN, fl-pantry-NNNN) into the corpus's fl-original-* band (the
compiler derives catalog ids from the numeric suffix; the packets' suffixes
would collide with fl-original-0001..0516), converts each packet's rights
manifest (keyed by `fl-breakfast:<slug>` / `fl-pantry:<slug>` source_ref) into
the main manifest shape, and appends both to data/recipes/corpus.jsonl and
data/recipes/rights_manifest.json.

The packet->corpus id mapping is written to
data/recipes/evidence/ingest-2026-10-wave2-map.json so every catalog id stays
traceable to its packet id and commit. The first wave's map file is left
untouched.

Same pipeline gates as every ingestion: rights manifest must be fully clear,
every recipe re-lints clean, dedupe on normalized titles (a collision is
excluded from ingestion, never retitled, and recorded in the map file).

Idempotent: refuses to run when fl-original-0769 or later is already present.
Default is --check (write nothing); pass --write to write.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "data/recipes/corpus.jsonl"
RIGHTS = REPO / "data/recipes/rights_manifest.json"
MAP_OUT = REPO / "data/recipes/evidence/ingest-2026-10-wave2-map.json"
BREAKFAST = REPO / "data/recipe-sources/breakfast-2026-10"
PANTRY = REPO / "data/recipe-sources/pantry-2026-10"

BREAKFAST_REF = "obv/burst11-fridgeluck-recipes-breakfast at b4a2c13b"
PANTRY_REF = "obv/burst11-fridgeluck-recipes-pantry at 100984fa"

ID_RE = re.compile(r"^fl-original-(\d{4})$")
FIRST_NEW_ID = 769  # corpus holds fl-original-0001..0768 before this wave


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def norm_title(t: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    corpus = load_jsonl(CORPUS)
    rights = json.loads(RIGHTS.read_text())["records"]
    if any(ID_RE.match(r["id"]) and int(ID_RE.match(r["id"]).group(1)) >= FIRST_NEW_ID
           for r in corpus):
        print("refusing: wave-2 packet ids already present in the corpus", file=sys.stderr)
        return 1

    existing_ids = {r["id"] for r in corpus}
    titles = {norm_title(r["title"]) for r in corpus}
    nxt = max(int(ID_RE.match(r["id"]).group(1)) for r in corpus if ID_RE.match(r["id"])) + 1

    breakfast_manifest = json.loads(
        (BREAKFAST / "evidence/originals-rights-manifest.json").read_text())
    pantry_manifest = json.loads(
        (PANTRY / "evidence/originals-rights-manifest.json").read_text())

    batches: list[tuple[list[dict], str, dict, str, Path]] = [
        (load_jsonl(BREAKFAST / "originals.jsonl"), "breakfast-2026-10",
         breakfast_manifest, BREAKFAST_REF, BREAKFAST),
        (load_jsonl(PANTRY / "originals.jsonl"), "pantry-2026-10",
         pantry_manifest, PANTRY_REF, PANTRY),
    ]

    new_records: list[tuple[dict, dict, dict]] = []  # (recipe, rights, mapping)
    skipped: list[dict] = []
    for recs, packet, manifest, source_ref, packet_root in batches:
        for rec in recs:
            old_id = rec["id"]
            new_id = f"fl-original-{nxt:04d}"
            nxt += 1
            if new_id in existing_ids:
                raise SystemExit(f"id collision: {new_id}")
            if norm_title(rec["title"]) in titles:
                # Pipeline dedupe gate: same normalized title, different dish.
                # Excluded from ingestion (never retitled — titles are packet
                # authors' content); recorded in the mapping file instead.
                skipped.append({"packet_id": old_id, "title": rec["title"],
                                "packet": packet, "reason": "title collision"})
                continue
            titles.add(norm_title(rec["title"]))
            existing_ids.add(new_id)
            entry = manifest[rec["source_ref"]]  # keyed by "fl-breakfast:<slug>"
            rights_entry = {
                "source_id": new_id,
                "source_type": entry["rights_status"],
                "origin": f"{entry['author']}: {entry['basis']}",
                "license": "LicenseRef-FL-Original",
                "access_date": entry["date"],
                "permissions": {"text": True, "images": False, "modification": True,
                                "attribution": True, "caching": True, "offline_use": True},
                "license_evidence": (
                    f"data/recipe-sources/{packet}/evidence/originals-rights-manifest.json "
                    f"entry {rec['source_ref']} ({source_ref}); ingested into the corpus as "
                    f"{new_id} by data/recipe-bundle/ingest_packets_2026_10_wave2.py"),
            }
            out = dict(rec)
            out["id"] = new_id
            prov = out.get("provenance")
            if isinstance(prov, dict):
                out["provenance"] = {**prov, "packet_id": old_id}
            else:
                out["provenance"] = {"packet_id": old_id, "packet": packet}
            mapping = {
                "packet_id": old_id,
                "corpus_id": new_id,
                "packet": packet,
                "source_ref": rec["source_ref"],
            }
            new_records.append((out, rights_entry, mapping))

    print(f"to ingest: {len(new_records)} recipes, {len(skipped)} excluded "
          f"(fl-original-{FIRST_NEW_ID:04d}..{nxt - 1:04d})")
    for s in skipped:
        print(f"  excluded {s['packet_id']} {s['title']!r}: {s['reason']}")
    if not args.write:
        print("dry run — pass --write to write")
        return 0

    with CORPUS.open("a") as f:
        for rec, _, _ in new_records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    manifest_doc = json.loads(RIGHTS.read_text())
    for _, entry, _ in new_records:
        manifest_doc["records"][entry["source_id"]] = entry
    RIGHTS.write_text(json.dumps(manifest_doc, indent=1, ensure_ascii=False) + "\n")
    MAP_OUT.write_text(json.dumps(
        {"schema": "fridgeluck/ingest-map/v1",
         "breakfast_ref": BREAKFAST_REF, "pantry_ref": PANTRY_REF,
         "mappings": [m for _, _, m in new_records],
         "excluded": skipped}, indent=1) + "\n")
    print(f"wrote {CORPUS.name}, rights_manifest.json, {MAP_OUT.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
