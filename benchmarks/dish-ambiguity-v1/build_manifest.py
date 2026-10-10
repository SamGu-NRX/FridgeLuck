#!/usr/bin/env python3
"""Build the stratified sampling manifests for the dish-ambiguity benchmark.

Usage:
    python3 benchmarks/dish-ambiguity-v1/build_manifest.py --dataset-root /path/to/food-101

Produces (committed artifacts, dataset itself is NOT committed):
    manifest.json      25 images per class from the OFFICIAL test split  (2525 total)
    dev_manifest.json  6 images per class from the OFFICIAL train split,
                       minus near-duplicates of any test image (dev-only threshold
                       choices must not be tuned on test-lookalike data)

Both files record, per image: path (relative to dataset root), class, official-split
membership, sha256 of the file bytes, and a 64-bit dHash for near-duplicate checks.
Sampling is seeded and deterministic (numpy default_rng(seed=20261010), images
sorted before sampling so the manifest is reproducible from the dataset alone).
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

BENCH_DIR = Path(__file__).resolve().parent
SEED = 20261010
TEST_PER_CLASS = 25          # 101 * 25 = 2525 >= 2000 required
DEV_PER_CLASS = 6            # dev pool for threshold selection (small, disposable)
NEAR_DUP_HAMMING_THRESHOLD = 10  # dev-only choice; frozen in mapping.food101-v1.json


def dhash(path: Path) -> int:
    """64-bit difference hash: 9x8 grayscale resize, horizontal gradient sign."""
    with Image.open(path) as im:
        g = im.convert("L").resize((9, 8), Image.LANCZOS)
    arr = np.asarray(g, dtype=np.int16)
    return int.from_bytes(np.packbits(arr[:, 1:] > arr[:, :-1]).tobytes(), "big")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_split(root: Path, split: str) -> dict[str, list[str]]:
    txt = root / "meta" / f"{split}_list.txt"
    per_class: dict[str, list[str]] = defaultdict(list)
    for line in txt.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        cls, rel = line.split("/")
        per_class[cls].append(rel)
    return per_class


def build(root: Path, split: str, per_class_n: int, rng: np.random.Generator) -> list[dict]:
    per_class = read_split(root, split)
    classes = sorted((root / "meta" / "classes.txt").read_text().splitlines())
    assert set(classes) == set(per_class), "class list mismatch between meta files"
    out = []
    for cls in classes:  # sorted order -> deterministic
        rels = sorted(per_class[cls])
        idx = rng.permutation(len(rels))[:per_class_n]
        for i in idx:
            rel = rels[int(i)]
            full = root / "images" / f"{rel}.jpg"
            out.append({
                "path": f"images/{rel}.jpg",
                "class": cls,
                "split": split,
                "sha256": sha256(full),
                "dhash": dhash(full),
            })
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset-root", required=True)
    args = ap.parse_args()
    root = Path(args.dataset_root)

    # Test sample first (fixed seed), then dev sample from the train split.
    test = build(root, "test", TEST_PER_CLASS, np.random.default_rng(SEED))
    dev = build(root, "train", DEV_PER_CLASS, np.random.default_rng(SEED + 1))

    # Near-duplicate discipline: drop dev images too close to ANY test image.
    test_hashes = [img["dhash"] for img in test]
    kept, dropped = [], []
    for img in dev:
        dists = [bin(img["dhash"] ^ th).count("1") for th in test_hashes]
        if min(dists) <= NEAR_DUP_HAMMING_THRESHOLD:
            dropped.append({"path": img["path"], "minHamming": min(dists)})
        else:
            kept.append(img)

    for name, images, split in (("manifest.json", test, "test"), ("dev_manifest.json", kept, "train")):
        payload = {
            "schemaVersion": "dish-ambiguity-sampling-v1",
            "dataset": "food-101",
            "datasetRoot": str(root),
            "seed": SEED if name == "manifest.json" else SEED + 1,
            "split": split,
            "sampling": f"{TEST_PER_CLASS if name == 'manifest.json' else DEV_PER_CLASS} per class, sorted order, seeded shuffle",
            "nearDupPolicy": {
                "hash": "64-bit dHash (9x8 grayscale horizontal gradient)",
                "hammingThreshold": NEAR_DUP_HAMMING_THRESHOLD,
                "developmentOnly": True,
                "note": "threshold chosen during development on dev data; dev images within "
                        "threshold of any test image are dropped from dev_manifest.json",
            },
            "images": images,
        }
        (BENCH_DIR / name).write_text(json.dumps(payload, indent=1))
        print(f"wrote {name}: {len(images)} images")
    (BENCH_DIR / "dev-near-duplicates-dropped.json").write_text(json.dumps(dropped, indent=1))
    print(f"dev near-duplicates of test dropped: {len(dropped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
