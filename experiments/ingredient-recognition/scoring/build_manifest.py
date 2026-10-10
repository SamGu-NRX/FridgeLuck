#!/usr/bin/env python3
"""Build the committed FoodSeg103 image manifest.

Reads the four downloaded parquet shards (train/validation), decodes every
image once, and emits:

- dataset/foodseg103_manifest.csv  (one row per image: split, image_id, sha256,
  dimensions, class ids from `classes_on_image`, mask-consistency flag,
  duplicate-group id from perceptual hashing)
- dataset/manifest_stats.json      (row counts, class distributions, duplicate
  groups, consistency failures)

Mask consistency rule: the set of nonzero class ids present in the `label`
mask PNG must equal the `classes_on_image` list for the same row.

Duplicate grouping: 8x8 pHash (DCT-II over a 32x32 grayscale resize), Hamming
distance <= 8 within the same split. Images are never committed to the repo —
only this manifest and stats.

The parquet shards live OUTSIDE the repo at /home/user/work/bench/dataset/
(local cache, see docs/DATA_SOURCES.md).
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
from PIL import Image

PARQUET_DIR = Path("/home/user/work/bench/dataset")
OUT_DIR = Path(__file__).resolve().parent / "dataset"


def _dct_matrix(n: int) -> np.ndarray:
    k = np.arange(n).reshape(-1, 1)
    r = np.arange(n).reshape(1, -1)
    m = np.cos((2 * r + 1) * k * np.pi / (2 * n))
    m[0, :] *= 1 / np.sqrt(2)
    return m * np.sqrt(2 / n)


_DCT32 = _dct_matrix(32)


def phash(gray32: np.ndarray) -> int:
    f = _DCT32 @ gray32 @ _DCT32.T
    block = f[:8, :8].flatten()  # low frequencies incl. DC
    med = np.median(block[1:])
    return int.from_bytes(np.packbits((block > med).astype(np.uint8)).tobytes(), "big")


def process_row(args: tuple) -> dict:
    split, image_id, image_bytes, mask_bytes, classes_on_image = args
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    mask = Image.open(io.BytesIO(mask_bytes))
    gray = img.resize((32, 32), Image.LANCZOS).convert("L")
    mask_values = set(np.asarray(mask).flatten().tolist()) - {0}
    return {
        "split": split,
        "image_id": int(image_id),
        "sha256": hashlib.sha256(image_bytes).hexdigest(),
        "width": img.width,
        "height": img.height,
        "classes_on_image": ",".join(str(c) for c in sorted(classes_on_image)),
        "mask_class_ids": ",".join(str(c) for c in sorted(mask_values)),
        "mask_consistent": mask_values == set(classes_on_image),
        "phash": phash(np.asarray(gray, dtype=np.float64)),
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tasks = []
    for split, pattern in [("validation", "validation-*.parquet"), ("train", "train-*.parquet")]:
        for shard in sorted(PARQUET_DIR.glob(pattern)):
            table = pq.read_table(shard)
            image_col = table.column("image")
            label_col = table.column("label")
            classes_col = table.column("classes_on_image")
            id_col = table.column("id")
            for i in range(table.num_rows):
                img_payload = image_col[i].as_py()
                mask_payload = label_col[i].as_py()
                # classes_on_image includes 0 (background) on nearly every row;
                # the manifest tracks ingredient classes only.
                classes = [c for c in classes_col[i].as_py() if c != 0]
                tasks.append(
                    (
                        split,
                        id_col[i].as_py(),
                        img_payload["bytes"],
                        mask_payload["bytes"],
                        classes,
                    )
                )

    with ProcessPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(process_row, tasks, chunksize=32))

    inconsistent = [(r["split"], r["image_id"]) for r in rows if not r["mask_consistent"]]

    # duplicate grouping: hamming <= 8, greedy in deterministic (split, id) order
    by_split: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_split[r["split"]].append(r)
    for split, srows in by_split.items():
        srows.sort(key=lambda r: r["image_id"])
        assigned: dict[int, list[dict]] = {}
        for r in srows:
            for ghash, members in assigned.items():
                if bin(r["phash"] ^ ghash).count("1") <= 8:
                    r["dup_group"] = f"{split[:2]}-{members[0]['image_id']}"
                    members.append(r)
                    break
            else:
                r["dup_group"] = f"{split[:2]}-{r['image_id']}"
                assigned[r["phash"]] = [r]

    fields = [
        "split", "image_id", "sha256", "width", "height",
        "classes_on_image", "mask_class_ids", "mask_consistent", "dup_group",
    ]
    out_csv = OUT_DIR / "foodseg103_manifest.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, quoting=csv.QUOTE_ALL)
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in fields})

    class_counts = Counter()
    for r in rows:
        for c in r["classes_on_image"].split(","):
            if c:
                class_counts[int(c)] += 1
    dup_groups = Counter(r["dup_group"] for r in rows)
    stats = {
        "splits": {s: len(by_split.get(s, [])) for s in ("validation", "train")},
        "total_rows": len(rows),
        "mask_inconsistent_count": len(inconsistent),
        "mask_inconsistent_examples": [list(k) for k in inconsistent[:20]],
        "duplicate_groups_ge2": sum(1 for c in dup_groups.values() if c >= 2),
        "duplicate_rows_in_groups_ge2": sum(c for c in dup_groups.values() if c >= 2),
        "per_class_instance_counts": {str(k): v for k, v in sorted(class_counts.items())},
    }
    (OUT_DIR / "manifest_stats.json").write_text(json.dumps(stats, indent=1))
    print(json.dumps({k: v for k, v in stats.items() if k != "per_class_instance_counts"}, indent=1))
    print("wrote", out_csv)


if __name__ == "__main__":
    main()
