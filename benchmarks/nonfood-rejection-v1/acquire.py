#!/usr/bin/env python3
"""Download the sampled Open Images images and hash-pin them.

Reads a sample plan CSV (image_id, subset, stratum) in priority order,
fetches each image from the frozen Open Images S3 copy, verifies the bytes
decode as an image, records sha256 + dimensions, and writes fetch_log.json.
Re-runs skip already-logged ids.

Images are cached OUTSIDE the repo (NONFOOD_CACHE, default
~/.cache/fridgeluck-nonfood); the repo gets only hashes and URLs, mirroring
the FoodSeg103 convention that pixel data is never committed.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

CACHE = Path(
    os.environ.get("NONFOOD_CACHE", Path.home() / ".cache" / "fridgeluck-nonfood")
)
S3 = "https://open-images-dataset.s3.amazonaws.com"
WORKERS = 24


def fetch_one(row):
    img_id, subset = row["image_id"], row["subset"]
    url = f"{S3}/{subset}/{img_id}.jpg"
    rec = {"image_id": img_id, "subset": subset, "url": url}
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            data = resp.read()
        im = Image.open(io.BytesIO(data))
        im.verify()  # decode check
        with Image.open(io.BytesIO(data)) as im2:
            width, height = im2.size
        out_path = Path(CACHE) / "images" / subset / f"{img_id}.jpg"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(data)
        rec.update(
            status="ok",
            sha256=hashlib.sha256(data).hexdigest(),
            bytes=len(data),
            width=width,
            height=height,
        )
    except Exception as e:  # noqa: BLE001 - log any failure, never crash the batch
        rec.update(status="error", error=f"{type(e).__name__}: {e}")
    return rec


def main():
    plan = sys.argv[1] if len(sys.argv) > 1 else str(CACHE / "sample_plan.csv")
    rows = list(csv.DictReader(open(plan)))
    log_path = CACHE / "fetch_log.json"
    done = {}
    if log_path.exists():
        done = {r["image_id"]: r for r in json.load(open(log_path))}
        rows = [r for r in rows if r["image_id"] not in done]
    print(f"fetching {len(rows)} images (already logged: {len(done)})")

    with ThreadPoolExecutor(WORKERS) as ex:
        for i, rec in enumerate(ex.map(fetch_one, rows)):
            done[rec["image_id"]] = rec
            if (i + 1) % 200 == 0:
                ok = sum(1 for r in done.values() if r.get("status") == "ok")
                print(f"  {i + 1}/{len(rows)} this run; {ok} ok cumulative")
                json.dump(list(done.values()), open(log_path, "w"))

    json.dump(list(done.values()), open(log_path, "w"))
    ok = sum(1 for r in done.values() if r.get("status") == "ok")
    print(f"done: {ok} ok / {len(done)} logged total -> {log_path}")


if __name__ == "__main__":
    main()
