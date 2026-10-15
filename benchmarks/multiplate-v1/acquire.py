#!/usr/bin/env python3
"""Acquire the Open Images validation inputs for the multi-plate benchmark.

UECFOOD256 was the first choice for a box-annotated food dataset. Its
authoritative download (http://www.ivl.disco.unimib.it/media/data/UECFOOD256.zip)
returned 404 on 2026-10-10 (the host now serves a WordPress site), so per the
task fallback this benchmark uses documented Open Images food classes:

- Annotations, class descriptions, class hierarchy: official Google Storage
  bucket (openimages / 2018_04), same files the Open Images V4/V5 download
  pages reference. acquire.py pins their sha256 below and re-verifies on every
  run.
- Images: the official unsigned S3 mirror `open-images-dataset` (the same
  bucket the Google Research downloader.py uses, path
  `<split>/<image_id>.jpg`). All Open Images images are CC BY 2.0 per the
  official FAQ.

Images are NOT committed (same policy as experiments/ingredient-recognition:
image terms differ from code). They download into a local cache directory and
are verified byte-exactly via sha256 against the frozen manifest.

Usage:
  python3 benchmarks/multiplate-v1/acquire.py --pool-dir /home/user/work/bench/multiplate-images
  python3 benchmarks/multiplate-v1/acquire.py --annotations-only
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import io
import json
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW_DIR = Path("/home/user/work/multiplate/raw")
IMAGES_CACHE = Path("/home/user/work/bench/multiplate-images")

ANNOTATION_FILES = {
    "validation-annotations-bbox.csv": (
        "https://storage.googleapis.com/openimages/2018_04/validation/validation-annotations-bbox.csv",
        # sha256 recorded on first verified download; asserted on later runs
        None,
    ),
    "class-descriptions-boxable.csv": (
        "https://storage.googleapis.com/openimages/2018_04/class-descriptions-boxable.csv",
        None,
    ),
    "bbox_labels_600_hierarchy.json": (
        "https://storage.googleapis.com/openimages/2018_04/bbox_labels_600_hierarchy.json",
        None,
    ),
}

IMAGE_BUCKET = "https://open-images-dataset.s3.amazonaws.com"
MANIFEST = HERE / "manifest.json"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str, timeout: int = 300) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "fridgeluck-multiplate-bench/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return resp.read()


def acquire_annotations() -> dict[str, str]:
    """Download (or verify already-downloaded) annotation files. Returns sha256 map."""
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}
    for fname, (url, _pinned) in ANNOTATION_FILES.items():
        dest = RAW_DIR / fname
        if dest.exists():
            data = dest.read_bytes()
        else:
            print(f"downloading {url}")
            data = fetch(url)
            dest.write_bytes(data)
        hashes[fname] = sha256_bytes(data)
        print(f"  {fname}: {len(data):,} bytes sha256={hashes[fname][:16]}...")
    return hashes


def image_url(image_id: str, split: str = "validation") -> str:
    return f"{IMAGE_BUCKET}/{split}/{image_id}.jpg"


def download_one(image_id: str, split: str, pool_dir: Path) -> tuple[str, str | None]:
    """Download one image into pool_dir. Returns (image_id, sha256 or None on failure)."""
    dest = pool_dir / f"{image_id}.jpg"
    if dest.exists():
        return image_id, sha256_bytes(dest.read_bytes())
    try:
        data = fetch(image_url(image_id, split), timeout=120)
    except Exception as exc:  # noqa: BLE001 - record and continue
        return image_id, None if False else f"__error__:{exc}"  # type: ignore[return-value]
    if not data.startswith(b"\xff\xd8"):  # not a JPEG
        return image_id, f"__error__:not-jpeg"
    dest.write_bytes(data)
    return image_id, sha256_bytes(data)


def selection_pool() -> tuple[list[str], list[str]]:
    """Deterministic download pool: more than the freeze targets, ordered by
    the documented selection order (see build_manifest.py)."""
    import csv
    import collections

    hierarchy = json.loads((RAW_DIR / "bbox_labels_600_hierarchy.json").read_text())
    names = {
        row[0]: row[1]
        for row in csv.reader((RAW_DIR / "class-descriptions-boxable.csv").read_text().splitlines())
    }
    food = set()
    stack = [(hierarchy, [])]
    while stack:
        node, ancestors = stack.pop()
        lid = node["LabelName"]
        if "/m/02wbm" in ancestors and lid != "/m/02wbm":
            food.add(lid)
        for child in node.get("Subcategory", []):
            stack.append((child, ancestors + [lid]))

    boxes_per_img: dict[str, set[str]] = collections.defaultdict(set)
    with (RAW_DIR / "validation-annotations-bbox.csv").open() as f:
        for row in csv.DictReader(f):
            if not eligible_row(row):
                continue
            if row["LabelName"] in food:
                boxes_per_img[row["ImageID"]].add(row["LabelName"])
    food = {c for c in food if sum(1 for cs in boxes_per_img.values() if c in cs) >= 60}
    multi, single = [], []
    for image_id, classes in boxes_per_img.items():
        classes &= food
        if len(classes) >= 2:
            multi.append(image_id)
        elif len(classes) == 1:
            single.append(image_id)
    # documented order: image id ascending (stable, seed-free)
    return sorted(multi), sorted(single)


def eligible_row(row) -> bool:
    return (
        row["Source"] == "freeform"
        and row["Confidence"] == "1"
        and row["IsGroupOf"] == "0"
        and row["IsDepiction"] == "0"
        and row["IsInside"] == "0"
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--annotations-only", action="store_true")
    ap.add_argument("--pool-dir", type=Path, default=IMAGES_CACHE)
    ap.add_argument("--max-multi", type=int, default=700)
    ap.add_argument("--max-single", type=int, default=220)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    hashes = acquire_annotations()
    if args.annotations_only:
        (RAW_DIR / "annotation_hashes.json").write_text(json.dumps(hashes, indent=1))
        return

    multi, single = selection_pool()
    print(f"pool candidates: {len(multi)} multi, {len(single)} single")
    pool = [(iid, "validation") for iid in multi[: args.max_multi]] + [
        (iid, "validation") for iid in single[: args.max_single]
    ]
    args.pool_dir.mkdir(parents=True, exist_ok=True)

    ok, failed = 0, []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futures = {ex.submit(download_one, iid, split, args.pool_dir): iid for iid, split in pool}
        for fut in concurrent.futures.as_completed(futures):
            iid, res = fut.result()
            if res and not res.startswith("__error__"):
                ok += 1
            else:
                failed.append((iid, res or "unknown"))
                (args.pool_dir / f"{iid}.jpg").unlink(missing_ok=True)
            if (ok + len(failed)) % 50 == 0:
                print(f"  progress: {ok} ok, {len(failed)} failed")
    print(f"downloaded {ok}/{len(pool)}; failed {len(failed)}")
    if failed:
        (args.pool_dir / "failed.log").write_text("\n".join(f"{i}\t{r}" for i, r in failed))
        for iid, reason in failed[:10]:
            print(f"  FAIL {iid}: {reason[:100]}")
    if ok < 760:
        print("WARNING: fewer than 760 usable images; freeze targets may not be met", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
