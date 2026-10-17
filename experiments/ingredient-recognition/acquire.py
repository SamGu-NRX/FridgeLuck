#!/usr/bin/env python3
"""Acquire and validate FoodSeg103 for the ingredient-recognition benchmark.

    python3 experiments/ingredient-recognition/acquire.py \
        --manifest experiments/ingredient-recognition/manifest.json

Behavior:
  1. Reads the frozen manifest (shard names, sha256, byte sizes; per-image
     sha256; eligibility and class-coverage counts).
  2. For each shard: uses the local cache copy if present, otherwise downloads
     from the documented Hugging Face mirror. Verifies byte size and sha256;
     any mismatch is a hard failure (HashMismatch).
  3. Opens every shard and verifies: row counts per split match the manifest,
     every image's sha256 matches, and every row's classes_on_image matches.
  4. Verifies manifest self-consistency: near-duplicate groups never span
     splits (cross-split groups are a hard failure), and that no taxonomy row
     is labelled exact while listing ambiguous targets.
  5. Prints eligibility and class-coverage counts.

Images are downloaded to a local cache and never committed: FoodSeg103 code
and annotations are Apache-2.0 but the photos carry separate Recipe1M+ terms.

Exit code 0 = verified. Exit 1 = any mismatch (see printed reason).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

MIRROR = "https://huggingface.co/datasets/EduardoPacheco/FoodSeg103/resolve/main/data"
DEFAULT_CACHE = Path(
    os.environ.get("FOODSEG103_CACHE", str(Path.home() / ".cache" / "fridgeluck-foodseg103"))
)


class ValidationError(Exception):
    pass


class HashMismatch(ValidationError):
    pass


class CrossSplitGroup(ValidationError):
    pass


class AmbiguousMappingExact(ValidationError):
    pass


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_shard(name: str, expect_sha: str, expect_bytes: int, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / name
    if not dest.exists():
        url = f"{MIRROR}/{name}"
        print(f"downloading {url}")
        urllib.request.urlretrieve(url, dest)  # noqa: S310 (documented mirror)
    got_bytes = dest.stat().st_size
    if got_bytes != expect_bytes:
        raise HashMismatch(f"{name}: size {got_bytes} != manifest {expect_bytes}")
    got_sha = sha256_file(dest)
    if got_sha != expect_sha:
        raise HashMismatch(f"{name}: sha256 {got_sha} != manifest {expect_sha}")
    return dest


def open_parquet(path: Path):
    import pandas as pd

    return pd.read_parquet(path)


def validate_taxonomy(manifest_path: Path) -> dict[str, int]:
    tax_path = manifest_path.parent / "taxonomy" / "foodseg103_to_catalog.csv"
    kinds: dict[str, int] = {}
    with tax_path.open() as f:
        for row in csv.DictReader(f):
            kind = row["semantic_kind"]
            kinds[kind] = kinds.get(kind, 0) + 1
            if kind == "exact" and len([t for t in row["target_ingredient_ids"].split(";") if t.strip()]) > 1:
                raise AmbiguousMappingExact(
                    f"{row['class_name_raw']}: kind=exact but targets "
                    f"'{row['target_ingredient_ids']}' are ambiguous"
                )
    return kinds


def find_cross_split_groups(rows: list[dict]) -> dict[str, set[str]]:
    """Return {dup_group: {splits}} for every near-duplicate group spanning >1 split."""
    groups: dict[str, set[str]] = {}
    for r in rows:
        if r["dup_group"]:
            groups.setdefault(r["dup_group"], set()).add(r["split"])
    return {g: s for g, s in groups.items() if len(s) > 1}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--manifest",
        default=str(Path(__file__).resolve().parent / "manifest.json"),
        help="frozen manifest.json to validate against",
    )
    ap.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    ap.add_argument("--skip-image-hashes", action="store_true",
                    help="skip per-image sha256 (slow); shard hashes still verified")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    spec = manifest["dataset"]

    # 1. shards: fetch + hash-verify
    for name, entry in sorted(spec["shards"].items()):
        ensure_shard(name, entry["sha256"], entry["bytes"], args.cache_dir)
        print(f"ok shard {name}")

    # 2. row-level verification
    rows = manifest["images"]
    by_split: dict[str, int] = {}
    for r in rows:
        by_split[r["split"]] = by_split.get(r["split"], 0) + 1
    if by_split != spec["official_split"]:
        raise ValidationError(f"split counts {by_split} != manifest {spec['official_split']}")

    shard_for_split = {n: n.split("-")[0] for n in spec["shards"]}
    seen: set[tuple[str, str]] = set()
    if not args.skip_image_hashes:
        for name, split in sorted(shard_for_split.items()):
            df = open_parquet(args.cache_dir / name)
            for _, row in df.iterrows():
                image_id = str(row["id"])
                key = (split, image_id)
                if key in seen:
                    raise ValidationError(f"duplicate row {key}")
                seen.add(key)
                img_bytes = row["image"]["bytes"]
                sha = hashlib.sha256(img_bytes).hexdigest()
                mr = next(
                    (r for r in rows if r["split"] == split and r["image_id"] == image_id),
                    None,
                )
                if mr is None:
                    raise ValidationError(f"image {key} not in manifest")
                if mr["sha256"] != sha:
                    raise HashMismatch(f"image {key}: sha mismatch")
                classes = ",".join(
                    str(c) for c in row["classes_on_image"] if int(c) != 0
                )
                if mr["classes_on_image"] != classes:
                    raise ValidationError(f"image {key}: classes mismatch")
        if len(seen) != len(rows):
            raise ValidationError(f"verified {len(seen)} images, manifest has {len(rows)}")
    print(f"ok rows: {by_split} (per-image sha256 {'verified' if not args.skip_image_hashes else 'skipped'})")

    # 3. cross-split duplicate groups
    cross = find_cross_split_groups(rows)
    n_groups = len({r["dup_group"] for r in rows if r["dup_group"]})
    if cross:
        raise CrossSplitGroup(f"near-duplicate groups span splits: {list(cross)[:5]}")
    print(f"ok groups: {n_groups} near-duplicate groups, 0 cross-split")

    # 4. taxonomy ambiguity rule
    kinds = validate_taxonomy(Path(args.manifest))
    print(f"ok taxonomy semantic kinds: {kinds}")

    # 5. counts
    el, cc = manifest["eligibility"], manifest["class_coverage"]
    print("eligibility:", json.dumps(el, sort_keys=True))
    print("class_coverage:", json.dumps({k: v for k, v in cc.items() if k != "per_class_instances"}, sort_keys=True))
    print("VERIFIED: manifest matches downloaded shards")


if __name__ == "__main__":
    try:
        main()
    except ValidationError as e:
        print(f"FAILED: {e}", file=sys.stderr)
        sys.exit(1)
