#!/usr/bin/env python3
"""Validate the frozen grocery-OCR manifest.

Checks (each failure lists the offending codes):
  structure            meta block, unique non-empty codes, known alignment values
  duplicate_groups     a code must appear exactly once; codes are the product group key
  front_image          every product has a front entry
  alignment_consistent aligned requires ingredient reference text AND an ingredients
                       image with a hash; metadata_only must NOT claim one;
                       unresolved requires a fetch failure on the front image
  image_hashes         when the cache is available, every ok fetch's stored sha256 is
                       recomputed from the file bytes — mismatch means the image is not
                       the one pinned (planted-swap detection)

Exit 0 when clean; exit 1 with a report otherwise. Importable validate() is used by
tests/experiments/grocery-ocr/tests to prove planted corruptions fail.
"""
import argparse
import hashlib
import json
import os
import re

EAN13 = re.compile(r"^\d{13}$")
ALIGNMENTS = {"aligned", "metadata_only", "unresolved"}


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _ext_for(role):
    return "jpg"


def validate(manifest, cache_dir=None):
    """Returns (failures, counts). failures is a list of 'check: detail' strings."""
    failures = []
    counts = {"aligned": 0, "metadata_only": 0, "unresolved": 0}

    if not isinstance(manifest, dict) or "products" not in manifest or "meta" not in manifest:
        return ["structure: manifest must have meta and products"], dict(counts)

    seen = {}
    for i, p in enumerate(manifest["products"]):
        code = p.get("code", "")
        tag = f"products[{i}] {code or '<missing>'}"
        if not EAN13.match(str(code)):
            failures.append(f"structure: {tag} code is not a 13-digit EAN")
            continue
        if code in seen:
            failures.append(f"duplicate_groups: {code} appears at index {seen[code]} and {i}")
        seen[code] = i
        if not p.get("stratum") or p.get("split") not in ("dev", "test"):
            failures.append(f"structure: {tag} missing stratum/split")
        rev = p.get("revision") or {}
        if rev.get("rev") is None and rev.get("last_modified_t") is None:
            failures.append(f"structure: {tag} missing product revision")
        src = p.get("source") or {}
        if not src.get("license") or not src.get("attribution"):
            failures.append(f"structure: {tag} missing permission/attribution")
        if p.get("alignment") not in ALIGNMENTS:
            failures.append(f"structure: {tag} unknown alignment {p.get('alignment')!r}")
            continue
        counts[p["alignment"]] += 1

        roles = p.get("roles") or {}
        if not roles.get("front", {}).get("url"):
            failures.append(f"front_image: {tag} has no front image")
        has_text = bool(p.get("reference_text"))
        ing = roles.get("ingredients") or {}
        ing_hashed = bool(ing.get("sha256")) and ing.get("fetch_status") == "ok"
        if p["alignment"] == "aligned":
            if not has_text:
                failures.append(f"alignment_consistent: {tag} claims aligned without reference text")
            if not ing_hashed:
                failures.append(f"alignment_consistent: {tag} claims aligned without a hashed ingredients image")
            if ing.get("url") and "ingredients" not in str(ing.get("url", "")) and not ing_hashed:
                failures.append(f"unsupported_transcription: {tag} aligned claim not backed by image+text")
        if p["alignment"] == "metadata_only" and ing_hashed and has_text:
            failures.append(f"alignment_consistent: {tag} has text+image but is marked metadata_only")
        if p["alignment"] == "unresolved":
            front_status = (roles.get("front") or {}).get("fetch_status")
            if front_status == "ok":
                failures.append(f"alignment_consistent: {tag} unresolved but front fetch ok")

    if cache_dir and os.path.isdir(cache_dir):
        for i, p in enumerate(manifest["products"]):
            for role, entry in (p.get("roles") or {}).items():
                if entry.get("fetch_status") != "ok" or not entry.get("sha256"):
                    continue
                path = os.path.join(cache_dir, f"{p['code']}__{role}.{_ext_for(role)}")
                if not os.path.exists(path):
                    failures.append(f"image_hashes: {p['code']} {role} pinned but file missing from cache")
                    continue
                actual = _sha256(path)
                if actual != entry["sha256"]:
                    failures.append(f"image_hashes: {p['code']} {role} sha256 mismatch "
                                    f"(manifest {entry['sha256'][:12]} vs file {actual[:12]})")
    return failures, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--cache", default=None, help="image cache dir to verify pinned hashes against")
    ap.add_argument("--counts-out", default=None)
    args = ap.parse_args()

    with open(args.manifest, encoding="utf-8") as f:
        manifest = json.load(f)
    failures, counts = validate(manifest, cache_dir=args.cache)
    print("alignment counts:", json.dumps(counts))
    if failures:
        print(f"FAIL: {len(failures)} problem(s)")
        for f_ in failures[:40]:
            print(" -", f_)
        if len(failures) > 40:
            print(f" ... and {len(failures) - 40} more")
        raise SystemExit(1)
    print("manifest OK")


if __name__ == "__main__":
    main()
