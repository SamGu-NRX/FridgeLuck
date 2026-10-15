#!/usr/bin/env python3
"""Validate the frozen nonfood-rejection-v1 manifest.

Checks (each failure lists the offending image ids; exit 0 clean, exit 1
with a report otherwise; validate() is importable for the pytest suite):

  structure          meta block, required fields, known role/stratum/split
                     values, stratum<->role consistency
  counts             exactly 300 empty_visible + 300 opaque_unknown + 600
                     food_control; 150/150/300 per split
  unique_images      every image_id appears exactly once
  licenses           license is the CC-BY 2.0 URL and author +
                     author_profile_url are non-empty (per-image attribution)
  group_binding      a photographer group_id and a series_id must each live
                     in exactly one split (dev or test), never both
  match_pairs        every negative has a pair_id; every pair is exactly one
                     negative + one food_control, same split; match_key and
                     match_quality recorded; every food_control is paired
  stratum_binding    empty_visible must have context labels and NO occluder
                     labels; opaque_unknown must have >=1 occluder label;
                     food_control must have >=1 food label
  image_hashes       when the image cache is available, every stored sha256
                     is recomputed from the cached file bytes — mismatch means
                     the file is not the pinned image (planted-swap detection)
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

STRATA = {"empty_visible", "opaque_unknown", "food_control"}
SPLITS = {"dev", "test"}
CC_BY = "https://creativecommons.org/licenses/by/2.0/"
EXPECTED_COUNTS = {"empty_visible": 300, "opaque_unknown": 300, "food_control": 600}


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def validate(manifest, cache_dir=None, expected_counts=EXPECTED_COUNTS):
    """Returns (failures, counts). failures is a list of 'check: detail'."""
    failures = []
    counts = {s: 0 for s in STRATA}

    if not isinstance(manifest, dict) or "images" not in manifest or "meta" not in manifest:
        return ["structure: manifest must have meta and images"], counts

    images = manifest["images"]
    meta = manifest["meta"]
    for key in ("name", "license_note", "source_urls", "eligible_and_ambiguous_counts", "split_rule"):
        if key not in meta:
            failures.append(f"structure: meta missing {key}")

    seen = {}
    for i, r in enumerate(images):
        tag = f"images[{i}] {r.get('image_id', '<missing>')}"
        img_id = r.get("image_id")
        if not img_id or not isinstance(img_id, str) or len(img_id) != 16:
            failures.append(f"structure: {tag} bad image_id")
            continue
        if img_id in seen:
            failures.append(f"unique_images: {img_id} appears at index {seen[img_id]} and {i}")
        seen[img_id] = i

        stratum = r.get("stratum")
        if stratum not in STRATA:
            failures.append(f"structure: {tag} unknown stratum {stratum!r}")
            continue
        counts[stratum] += 1
        role = r.get("role")
        want_role = "food_control" if stratum == "food_control" else "negative"
        if role != want_role:
            failures.append(f"structure: {tag} stratum {stratum} must have role {want_role}, got {role!r}")
        if r.get("split") not in SPLITS:
            failures.append(f"structure: {tag} split must be dev|test, got {r.get('split')!r}")

        if r.get("license") != CC_BY:
            failures.append(f"licenses: {tag} license is {r.get('license')!r}, want CC-BY 2.0")
        if not r.get("author") or not r.get("author_profile_url"):
            failures.append(f"licenses: {tag} missing author or author_profile_url")

        if not r.get("group_id") or not r.get("series_id"):
            failures.append(f"group_binding: {tag} missing group_id or series_id")

        ctx = r.get("context_labels") or []
        occ = r.get("occluder_labels") or []
        food = r.get("food_labels") or []
        if stratum == "empty_visible":
            if not ctx:
                failures.append(f"stratum_binding: {tag} empty_visible needs >=1 context label")
            if occ:
                failures.append(f"stratum_binding: {tag} empty_visible must have no occluder labels: {occ}")
        elif stratum == "opaque_unknown":
            if not occ:
                failures.append(f"stratum_binding: {tag} opaque_unknown needs >=1 occluder label")
        elif stratum == "food_control" and not food:
            failures.append(f"stratum_binding: {tag} food_control needs >=1 food label")

        for k in ("sha256", "s3_url", "match_key"):
            if not r.get(k):
                failures.append(f"structure: {tag} missing {k}")
        if r.get("sha256") and (len(r["sha256"]) != 64 or not all(c in "0123456789abcdef" for c in r["sha256"])):
            failures.append(f"structure: {tag} sha256 is not a lowercase hex digest")

    for s, want in expected_counts.items():
        if counts[s] != want:
            failures.append(f"counts: stratum {s} has {counts[s]} images, want exactly {want}")
    per_split = defaultdict(int)
    for r in images:
        if r.get("stratum") in expected_counts and r.get("split") in SPLITS:
            per_split[(r["stratum"], r["split"])] += 1
    for s, want in expected_counts.items():
        for split in SPLITS:
            if per_split[(s, split)] != want // 2:
                failures.append(
                    f"counts: stratum {s} split {split} has {per_split[(s, split)]} images, "
                    f"want exactly {want // 2}"
                )

    # group binding: group_id and series_id each confined to one split
    for field in ("group_id", "series_id"):
        spans = defaultdict(set)
        for r in images:
            if r.get(field) and r.get("split") in SPLITS:
                spans[r[field]].add(r["split"])
        bad = sorted(k for k, v in spans.items() if len(v) > 1)
        if bad:
            failures.append(f"group_binding: {len(bad)} {field} values span dev and test, e.g. {bad[:5]}")

    # match pairs
    pair_members = defaultdict(list)
    for r in images:
        if r.get("pair_id"):
            pair_members[r["pair_id"]].append(r)
    paired_controls = {r["pair_id"] for r in images if r["role"] == "negative" and r.get("pair_id")}
    for r in images:
        tag = f"image {r.get('image_id')}"
        if r["role"] == "negative" and not r.get("pair_id"):
            failures.append(f"match_pairs: {tag} negative has no pair_id")
        if r["role"] == "food_control" and not r.get("pair_id"):
            failures.append(f"match_pairs: {tag} food_control has no pair_id")
        if r["role"] == "food_control" and r.get("pair_id") and r["pair_id"] not in paired_controls:
            failures.append(f"match_pairs: food_control {r['image_id']} never paired")
    for pid, members in pair_members.items():
        roles = sorted(m["role"] for m in members)
        if roles != ["food_control", "negative"]:
            failures.append(f"match_pairs: pair {pid} has roles {roles}, want one of each")
            continue
        if members[0]["split"] != members[1]["split"]:
            failures.append(f"match_pairs: pair {pid} spans splits {members[0]['split']}/{members[1]['split']}")
        if not members[0].get("match_quality"):
            failures.append(f"match_pairs: pair {pid} missing match_quality")

    # image hashes against the cache
    if cache_dir is not None:
        for r in images:
            p = Path(cache_dir) / "images" / r["subset"] / f"{r['image_id']}.jpg"
            if not p.exists():
                failures.append(f"image_hashes: {r['image_id']} missing from cache {cache_dir}")
                continue
            if _sha256(p) != r.get("sha256"):
                failures.append(f"image_hashes: {r['image_id']} sha256 mismatch - file is not the pinned image")
    return failures, counts


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest", default=str(Path(__file__).resolve().parent / "manifest.json"))
    ap.add_argument("--cache-dir", default=None, help="image cache root (images/<subset>/<id>.jpg); hash check runs when provided")
    args = ap.parse_args()

    manifest = json.load(open(args.manifest))
    failures, counts = validate(manifest, cache_dir=args.cache_dir)
    print(f"counts: {counts}")
    if failures:
        print(f"FAIL: {len(failures)} problems")
        for f in failures[:50]:
            print(f"  - {f}")
        if len(failures) > 50:
            print(f"  ... and {len(failures) - 50} more")
        raise SystemExit(1)
    print("manifest OK")


if __name__ == "__main__":
    main()
