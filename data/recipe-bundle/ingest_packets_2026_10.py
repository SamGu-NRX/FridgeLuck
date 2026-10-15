#!/usr/bin/env python3
"""Ingest the world-2026-10 and everyday-2026-10 packets into the corpus.

Integration-thread tooling. Never authors or edits recipe content: it
renumbers packet ids into the corpus's fl-original-* band (the compiler
derives catalog ids from the numeric suffix, and packet suffixes would
collide with fl-original-0001..0404), converts each packet's rights
manifest into the main manifest shape, and appends both to
data/recipes/corpus.jsonl and data/recipes/rights_manifest.json.

The packet->corpus id mapping is written to
data/recipes/evidence/ingest-2026-10-map.json so every catalog id stays
traceable to its packet id and commit.

Idempotent: refuses to run when packet ids are already present.
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
MAP_OUT = REPO / "data/recipes/evidence/ingest-2026-10-map.json"
WORLD = REPO / "data/recipe-sources/world-2026-10"
EVERYDAY = REPO / "data/recipe-sources/everyday-2026-10"

WORLD_REF = "obv/burst5-fridgeluck-rcp-originals-world at 1733f5f"
EVERYDAY_REF = "obv/burst5-fridgeluck-rcp-originals-everyday at 68c164de"

ID_RE = re.compile(r"^fl-original-(\d{4})$")


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
    if any(ID_RE.match(r["id"]) and int(ID_RE.match(r["id"]).group(1)) >= 405 for r in corpus):
        print("refusing: packet ids already present in the corpus", file=sys.stderr)
        return 1

    existing_ids = {r["id"] for r in corpus}
    titles = {norm_title(r["title"]) for r in corpus}
    nxt = max(int(ID_RE.match(r["id"]).group(1)) for r in corpus if ID_RE.match(r["id"])) + 1

    world_manifest = json.loads((WORLD / "evidence/originals-rights-manifest.json").read_text())
    everyday_manifest = json.loads((EVERYDAY / "rights_manifest.json").read_text())["records"]

    batches: list[tuple[list[dict], str, dict]] = [
        (load_jsonl(WORLD / "originals.jsonl"), "world-2026-10", world_manifest),
        (load_jsonl(EVERYDAY / "originals.jsonl"), "everyday-2026-10", everyday_manifest),
        (load_jsonl(EVERYDAY / "converted-144.jsonl"), "everyday-2026-10", everyday_manifest),
    ]

    def rights_for(rec: dict, packet: str, manifest: dict, new_id: str) -> dict:
        if packet == "world-2026-10":
            entry = manifest[rec["source_ref"]]  # keyed by "fl-world:<slug>"
            return {
                "source_id": new_id,
                "source_type": entry["rights_status"],
                "origin": f"{entry['author']}: {entry['basis']}",
                "license": "LicenseRef-FL-Original",
                "access_date": entry["date"],
                "permissions": {"text": True, "images": False, "modification": True,
                                "attribution": True, "caching": True, "offline_use": True},
                "license_evidence": (
                    f"data/recipe-sources/world-2026-10/evidence/originals-rights-manifest.json "
                    f"entry {rec['source_ref']} ({WORLD_REF}); ingested into the corpus as "
                    f"{new_id} by data/recipe-bundle/ingest_packets_2026_10.py"),
            }
        key = rec["id"] if rec["id"] in manifest else rec["source_ref"]
        if key not in manifest:
            raise SystemExit(f"{rec['id']}: no rights record for {key} — fail closed")
        entry = dict(manifest[key])
        entry["source_id"] = new_id
        entry["license_evidence"] = (
            f"{entry.get('license_evidence', '')} re-keyed to {new_id} from {key} "
            f"({EVERYDAY_REF}) by data/recipe-bundle/ingest_packets_2026_10.py")
        return entry

    new_records: list[tuple[dict, dict, dict]] = []  # (recipe, rights, mapping)
    skipped: list[dict] = []
    mapping_extra: dict[str, str] = {}
    for recs, packet, manifest in batches:
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
                mapping_extra = {}
                continue
            titles.add(norm_title(rec["title"]))
            existing_ids.add(new_id)
            out = dict(rec)
            out["id"] = new_id
            prov = out.get("provenance")
            if isinstance(prov, dict):
                out["provenance"] = {**prov, "packet_id": old_id}
            else:
                out["provenance"] = {"packet_id": old_id, "packet": packet}
            if "category" in out:
                # The bundle-v2 contract's collections enum (quick, budget,
                # one_pot, comfort, use_soon) does not cover the everyday
                # categories; the category stays packet-level corpus metadata
                # (carried in the mapping file), not a shipped collection.
                mapping_extra["category"] = out["category"]
                del out["category"]
            mapping = {
                "packet_id": old_id,
                "corpus_id": new_id,
                "packet": packet,
                "source_ref": rec["source_ref"],
                **mapping_extra,
            }
            mapping_extra = {}
            new_records.append((out, rights_for(rec, packet, manifest, new_id), mapping))

    print(f"to ingest: {len(new_records)} recipes, {len(skipped)} excluded "
          f"(fl-original-0405..{nxt - 1:04d})")
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
         "world_ref": WORLD_REF, "everyday_ref": EVERYDAY_REF,
         "mappings": [m for _, _, m in new_records],
         "excluded": skipped}, indent=1) + "\n")
    print(f"wrote {CORPUS.name}, rights_manifest.json, {MAP_OUT.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
