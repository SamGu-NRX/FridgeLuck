#!/usr/bin/env python3
"""Fetch the pinned Open Food Facts images and record hashes.

Photographs stay out of the repository (licensing and size): this script records the
exact pinned URLs, byte counts and sha256 hashes so any replay can verify what was
scored. Politeness: small worker pool, retries with backoff, descriptive User-Agent
with a contact address, as OFF asks of bulk fetchers. Resumable: existing files are
re-hashed, not re-downloaded. URLs and image revisions are pinned in manifest.csv.

Usage: python3 fetch_images.py --manifest <dir>/manifest.csv --cache <imgcache> --out <dir>/image_hashes.csv
"""
import argparse
import csv
import hashlib
import os
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, urlopen

UA = ("FridgeLuck-ocr-experiment/1.0 "
      "(https://github.com/SamGu-NRX/FridgeLuck; contact sgu07966@gmail.com; obvious agent)")

ROLES = ("front", "ingredients", "nutrition")


def fetch(url, dest, retries=3):
    for attempt in range(retries):
        try:
            req = Request(url, headers={"User-Agent": UA, "Accept": "image/*"})
            with urlopen(req, timeout=120) as r:
                body = r.read()
            if not body or len(body) < 512:
                raise ValueError(f"suspiciously small body {len(body)}")
            with open(dest, "wb") as f:
                f.write(body)
            return hashlib.sha256(body).hexdigest(), len(body)
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(5 * (attempt + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--only-role", default=None)
    args = ap.parse_args()

    jobs = []
    with open(args.manifest, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            for role in ROLES:
                if args.only_role and role != args.only_role:
                    continue
                url = (row.get(f"{role}_url") or "").strip()
                if not url:
                    continue
                lang = (row.get(f"{role}_lang") or "").strip()
                rev = (row.get(f"{role}_image_rev") or "").strip()
                jobs.append({"code": row["code"], "role": role, "lang": lang, "rev": rev,
                             "url": url, "key": f"{role}_{lang}_{rev}"})

    done = {}
    if os.path.exists(args.out):
        with open(args.out, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row.get("status") == "ok":
                    done[(row["code"], row["role"])] = row

    os.makedirs(args.cache, exist_ok=True)

    def run(job):
        key = (job["code"], job["role"])
        if key in done:
            return done[key]
        dest = os.path.join(args.cache, f"{job['code']}__{job['key']}.jpg")
        if not os.path.exists(dest):
            try:
                sha, nbytes = fetch(job["url"], dest)
            except Exception as e:
                return {"code": job["code"], "role": job["role"], "lang": job["lang"],
                        "rev": job["rev"], "url": job["url"], "sha256": "", "bytes": 0,
                        "status": f"error: {str(e)[:120]}"}
        else:
            with open(dest, "rb") as f:
                body = f.read()
            sha, nbytes = hashlib.sha256(body).hexdigest(), len(body)
        return {"code": job["code"], "role": job["role"], "lang": job["lang"], "rev": job["rev"],
                "url": job["url"], "sha256": sha, "bytes": nbytes, "status": "ok"}

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for i, res in enumerate(pool.map(run, jobs)):
            results.append(res)
            if (i + 1) % 100 == 0:
                print(f"{i+1}/{len(jobs)} images done", flush=True)

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["code", "role", "lang", "rev", "url", "sha256", "bytes", "status"],
                           quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writeheader()
        w.writerows(results)
    ok = sum(1 for r in results if r["status"] == "ok")
    print(f"fetched {ok}/{len(results)} images")


if __name__ == "__main__":
    main()
