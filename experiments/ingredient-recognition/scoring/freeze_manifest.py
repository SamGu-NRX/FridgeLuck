#!/usr/bin/env python3
"""Freeze manifest.json from the build_manifest.py outputs + shard hashes.

Provenance chain:
  build_manifest.py  -> scoring/dataset/foodseg103_manifest.csv (+ stats)
  freeze_manifest.py -> manifest.json (committed, frozen)

Deterministic: same CSV + stats + shards always produce byte-identical
manifest.json (sorted shard names, stable row order).
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import sys
from pathlib import Path

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
DATASET_DIR = Path(
    os.environ.get("FOODSEG103_CACHE", str(Path.home() / ".cache" / "fridgeluck-foodseg103"))
)


def main() -> None:
    stats = json.loads((EXPERIMENT_ROOT / "scoring" / "dataset" / "manifest_stats.json").read_text())
    with (EXPERIMENT_ROOT / "scoring" / "dataset" / "foodseg103_manifest.csv").open() as f:
        rows = list(csv.DictReader(f))

    shards = {}
    for p in sorted(DATASET_DIR.glob("*.parquet")):
        shards[p.name] = {
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
            "bytes": p.stat().st_size,
        }
    if not shards:
        sys.exit(f"no parquet shards found in {DATASET_DIR}")

    tax = list(csv.DictReader((EXPERIMENT_ROOT / "taxonomy" / "foodseg103_to_catalog.csv").open()))
    kinds: dict[str, int] = {}
    prov: dict[str, int] = {}
    for r in tax:
        kinds[r["semantic_kind"]] = kinds.get(r["semantic_kind"], 0) + 1
        prov[r["resolution_provenance"]] = prov.get(r["resolution_provenance"], 0) + 1

    manifest = {
        "dataset": {
            "name": "FoodSeg103",
            "source": "https://huggingface.co/datasets/EduardoPacheco/FoodSeg103",
            "upstream": "https://research.cvr.ai/foodseg103",
            "license_note": (
                "Code and annotations Apache-2.0; images carry separate Recipe1M+ terms "
                "and are NOT committed. acquire.py downloads and hash-verifies them."
            ),
            "official_split": {"train": 4983, "validation": 2135},
            "shards": shards,
        },
        "eligibility": {
            "total_rows": stats["total_rows"],
            "eligible_rows": stats["total_rows"] - stats["mask_inconsistent_count"],
            "excluded_mask_inconsistent": stats["mask_inconsistent_count"],
            "near_duplicate_groups_ge2": stats["duplicate_groups_ge2"],
            "rows_in_near_duplicate_groups": stats["duplicate_rows_in_groups_ge2"],
            "cross_split_duplicate_groups": 0,
            "rule": (
                "Duplicate groups are same-split only; group members are scored "
                "together, never across splits."
            ),
        },
        "class_coverage": {
            "foodseg_classes": len(tax),
            "semantic_kinds": kinds,
            "resolver_provenance": prov,
            "per_class_instances": stats["per_class_instance_counts"],
        },
        "images": [
            {
                "split": r["split"],
                "image_id": r["image_id"],
                "sha256": r["sha256"],
                "width": int(r["width"]),
                "height": int(r["height"]),
                "classes_on_image": r["classes_on_image"],
                "mask_class_ids": r["mask_class_ids"],
                "mask_consistent": r["mask_consistent"] == "True",
                "dup_group": r["dup_group"] or None,
            }
            for r in rows
        ],
    }
    out = EXPERIMENT_ROOT / "manifest.json"
    out.write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"wrote {out} ({out.stat().st_size} bytes, {len(rows)} images)")


if __name__ == "__main__":
    main()
