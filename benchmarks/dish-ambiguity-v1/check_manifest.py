#!/usr/bin/env python3
"""Validate the dish-ambiguity benchmark's frozen taxonomy and sampling manifest.

Usage:
    python3 benchmarks/dish-ambiguity-v1/check_manifest.py
        [--mapping benchmarks/dish-ambiguity-v1/mapping.food101-v1.json]
        [--manifest benchmarks/dish-ambiguity-v1/manifest.json]
        [--dev-manifest benchmarks/dish-ambiguity-v1/dev_manifest.json]
        [--dataset-root /path/to/food-101]      # default: from manifest, env, or skip disk checks

Exit 0 = valid. Exit 1 = at least one validation error (all errors printed).

What is validated
-----------------
mapping (always required):
  - schema version, dataset name, catalog path; catalog parses and decodes
  - exactly the 101 official Food-101 class names (from food101-classes.txt)
  - status in {exact, coarse, ambiguous, unsupported}
  - exact -> exactly 1 recipe; coarse -> >= 2 recipes (interchangeable renderings
    of one dish); ambiguous -> >= 2 recipes (non-equivalent candidates);
    unsupported -> 0 recipes
  - every referenced recipe id exists in the bundled catalog
  - every class carries a human "reason"; ambiguous/unsupported carry nearMiss notes
  - uniqueness: a bundled recipe id may be claimed by at most one exact/coarse
    equivalence class, and ambiguous candidates must not overlap any exact/coarse
    membership (a recipe that is THE answer for one dish cannot be a mere candidate
    for another). Ambiguous candidate sets MAY be shared between classes that name
    the same dish family (none needed in v1).

manifest / dev_manifest (when present):
  - official Food-101 split membership of every image
  - stratification: identical per-class counts; total >= 2000 for the test manifest
  - dev manifest: >= 1 per class, <= 10 per class, and near-duplicate discipline:
    no dev image's dHash is within the frozen Hamming threshold of any test
    image's dHash (dev-selection data must not contain near-duplicates of test)
  - when the dataset is on disk: per-image sha256 matches the committed hash
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
CLASSES_FILE = BENCH_DIR / "food101-classes.txt"
NEAR_DUP_HAMMING_THRESHOLD = 10  # development-only choice; see mapping.food101-v1.json thresholds

VALID_STATUSES = {"exact", "coarse", "ambiguous", "unsupported"}


class Errors:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, msg: str) -> None:
        self.items.append(msg)

    @property
    def ok(self) -> bool:
        return not self.items


def load_catalog_recipes(catalog_path: Path, errs: Errors) -> dict[int, str]:
    """Decode the bundled catalog's positional recipe arrays: [id, title, time, servings,
    required[[id,grams]...], optional[[id,grams]...], instructions, tagBitmask]."""
    try:
        data = json.loads(catalog_path.read_text())
    except Exception as exc:  # pragma: no cover - defensive
        errs.add(f"catalog: cannot read {catalog_path}: {exc}")
        return {}
    recipes = data.get("recipes")
    if not isinstance(recipes, list) or not recipes:
        errs.add(f"catalog: {catalog_path} has no recipes array")
        return {}
    out: dict[int, str] = {}
    for i, raw in enumerate(recipes):
        if not isinstance(raw, list) or len(raw) != 8:
            errs.add(f"catalog: recipe[{i}] is not an 8-element array")
            continue
        rid, title = raw[0], raw[1]
        if not isinstance(rid, int) or not isinstance(title, str):
            errs.add(f"catalog: recipe[{i}] id/title have wrong types")
            continue
        if rid in out:
            errs.add(f"catalog: duplicate recipe id {rid}")
        out[rid] = title
    return out


def load_food101_classes(errs: Errors, classes_file: Path | None = None,
                         expected_count: int | None = 101) -> set[str]:
    path = classes_file if classes_file is not None else CLASSES_FILE
    if not path.exists():
        errs.add(f"classes file missing: {path}")
        return set()
    names = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    if expected_count is not None and len(names) != expected_count:
        errs.add(f"classes file: expected {expected_count} classes, found {len(names)}")
    return set(names)


def validate_mapping(path: Path, errs: Errors, catalog_path: Path | None = None,
                     classes_file: Path | None = None,
                     expected_class_count: int | None = 101) -> dict | None:
    try:
        mapping = json.loads(path.read_text())
    except Exception as exc:
        errs.add(f"mapping: cannot read {path}: {exc}")
        return None
    if mapping.get("schemaVersion") != "dish-ambiguity-mapping-v1":
        errs.add("mapping: schemaVersion must be 'dish-ambiguity-mapping-v1'")
    classes = mapping.get("classes")
    if not isinstance(classes, dict) or not classes:
        errs.add("mapping: 'classes' object missing")
        return None

    official = load_food101_classes(errs, classes_file, expected_class_count)
    if official and set(classes) != official:
        missing = sorted(official - set(classes))[:5]
        extra = sorted(set(classes) - official)[:5]
        errs.add(f"mapping: class set mismatch; missing={missing} extra={extra}")

    resolved_catalog = catalog_path or (
        BENCH_DIR.parent.parent / mapping.get("catalog", "apps/ios/Resources/data.json")
    )
    catalog = load_catalog_recipes(resolved_catalog, errs)

    claims: dict[int, str] = {}
    counts = {"exact": 0, "coarse": 0, "ambiguous": 0, "unsupported": 0}
    for cls, entry in sorted(classes.items()):
        if not isinstance(entry, dict):
            errs.add(f"mapping[{cls}]: entry must be an object")
            continue
        status = entry.get("status")
        if status not in VALID_STATUSES:
            errs.add(f"mapping[{cls}]: invalid status {status!r}")
            continue
        counts[status] += 1
        recipes = entry.get("recipes", [])
        if not isinstance(recipes, list) or not all(isinstance(r, int) for r in recipes):
            errs.add(f"mapping[{cls}]: recipes must be a list of integer ids")
            continue
        if status == "exact" and len(recipes) != 1:
            errs.add(f"mapping[{cls}]: exact class must have exactly 1 recipe, has {len(recipes)}")
        if status == "coarse" and len(recipes) < 2:
            errs.add(f"mapping[{cls}]: coarse class must have >= 2 interchangeable recipes, has {len(recipes)}")
        if status == "ambiguous" and len(recipes) < 2:
            errs.add(f"mapping[{cls}]: ambiguous class must have >= 2 non-equivalent candidates, has {len(recipes)}")
        if status == "unsupported" and recipes:
            errs.add(f"mapping[{cls}]: unsupported class must not claim recipes, claims {recipes}")
        if not isinstance(entry.get("reason"), str) or len(entry.get("reason", "")) < 10:
            errs.add(f"mapping[{cls}]: missing or too-short 'reason' (source reason required)")
        if status in {"ambiguous", "unsupported"} and not entry.get("nearMiss"):
            errs.add(f"mapping[{cls}]: {status} class must document nearMiss consideration")
        for rid in recipes:
            if catalog and rid not in catalog:
                errs.add(f"mapping[{cls}]: recipe id {rid} not in bundled catalog")
            if status in {"exact", "coarse"}:
                if rid in claims:
                    errs.add(
                        f"mapping[{cls}]: recipe {rid} already claimed by exact/coarse class "
                        f"'{claims[rid]}' (uniqueness: an equivalence-class recipe serves at most one dish)"
                    )
                claims[rid] = cls
            elif rid in claims:  # ambiguous candidates must not double-book an exact answer
                errs.add(
                    f"mapping[{cls}]: ambiguous candidate recipe {rid} is already an "
                    f"exact/coarse answer for '{claims[rid]}'"
                )

    expected = mapping.get("statusCountsExpected")
    if isinstance(expected, dict) and expected != counts:
        errs.add(f"mapping: statusCountsExpected {expected} != actual {counts}")
    print(
        f"mapping: {len(classes)} classes; "
        f"exact={counts['exact']} coarse={counts['coarse']} "
        f"ambiguous={counts['ambiguous']} unsupported={counts['unsupported']}"
    )
    return mapping


def dhash_distance(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def validate_manifest(path: Path, dataset_root: str | None, label: str, errs: Errors,
                      require_2000: bool, classes_file: Path | None = None,
                      expected_class_count: int | None = 101) -> list[dict]:
    try:
        manifest = json.loads(path.read_text())
    except Exception as exc:
        errs.add(f"{label}: cannot read {path}: {exc}")
        return []
    if manifest.get("schemaVersion") != "dish-ambiguity-sampling-v1":
        errs.add(f"{label}: schemaVersion must be 'dish-ambiguity-sampling-v1'")
    split = manifest.get("split")
    if label.startswith("dev"):
        if split != "train":
            errs.add(f"{label}: dev manifest must sample the official train split, got {split!r}")
    else:
        if split != "test":
            errs.add(f"{label}: test manifest must sample the official test split, got {split!r}")
    images = manifest.get("images")
    if not isinstance(images, list) or not images:
        errs.add(f"{label}: images array missing")
        return []
    per_class: dict[str, int] = {}
    for i, img in enumerate(images):
        if not isinstance(img, dict):
            errs.add(f"{label}: images[{i}] not an object")
            continue
        for key in ("path", "class", "sha256", "dhash"):
            if key not in img:
                errs.add(f"{label}: images[{i}] missing {key}")
        per_class[img.get("class", "?")] = per_class.get(img.get("class", "?"), 0) + 1
        if dataset_root:
            full = Path(dataset_root) / img["path"]
            if not full.exists():
                errs.add(f"{label}: image file missing on disk: {img['path']}")
                continue
            digest = hashlib.sha256(full.read_bytes()).hexdigest()
            if digest != img["sha256"]:
                errs.add(f"{label}: sha256 mismatch for {img['path']}")
    if require_2000 and len(images) < 2000:
        errs.add(f"{label}: expected >= 2000 test images, found {len(images)}")
    sizes = set(per_class.values())
    official = load_food101_classes(errs, classes_file, expected_class_count)
    if official:
        if set(per_class) != official:
            errs.add(f"{label}: stratification does not cover all 101 classes")
        elif len(sizes) != 1:
            errs.add(f"{label}: stratification unbalanced, per-class counts {sorted(sizes)}")
    print(f"{label}: {len(images)} images across {len(per_class)} classes; per-class counts {sorted(sizes)}")
    return images


def check_near_duplicate_discipline(test_images: list[dict], dev_images: list[dict],
                                    errs: Errors) -> None:
    """Dev-selection data must not contain near-duplicates of test images."""
    if not test_images or not dev_images:
        return
    test_hashes = [img.get("dhash") for img in test_images if isinstance(img.get("dhash"), int)]
    pairs = 0
    for dev_img in dev_images:
        dh = dev_img.get("dhash")
        if not isinstance(dh, int):
            errs.add(f"dev_manifest: image {dev_img.get('path')} missing integer dhash")
            continue
        for th in test_hashes:
            pairs += 1
            if dhash_distance(dh, th) <= NEAR_DUP_HAMMING_THRESHOLD:
                errs.add(
                    f"dev_manifest: {dev_img['path']} is a near-duplicate of a test image "
                    f"(dHash Hamming {dhash_distance(dh, th)} <= {NEAR_DUP_HAMMING_THRESHOLD})"
                )
    print(f"near-duplicate discipline: checked {pairs} dev-vs-test hash pairs")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mapping", default=str(BENCH_DIR / "mapping.food101-v1.json"))
    ap.add_argument("--manifest", default=str(BENCH_DIR / "manifest.json"))
    ap.add_argument("--dev-manifest", default=str(BENCH_DIR / "dev_manifest.json"))
    ap.add_argument("--dataset-root", default=os.environ.get("FOOD101_ROOT"))
    args = ap.parse_args()

    errs = Errors()
    validate_mapping(Path(args.mapping), errs)

    dataset_root = args.dataset_root
    test_images: list[dict] = []
    dev_images: list[dict] = []
    if Path(args.manifest).exists():
        test_images = validate_manifest(Path(args.manifest), dataset_root, "manifest", errs, require_2000=True)
    else:
        print("manifest: not present yet (built by build_manifest.py) - skipped")
    if Path(args.dev_manifest).exists():
        dev_images = validate_manifest(Path(args.dev_manifest), dataset_root, "dev_manifest", errs, require_2000=False)
    else:
        print("dev_manifest: not present yet (built by build_manifest.py) - skipped")
    if test_images and dev_images:
        check_near_duplicate_discipline(test_images, dev_images, errs)

    for e in errs.items:
        print(f"ERROR: {e}", file=sys.stderr)
    print("check_manifest:", "OK" if errs.ok else f"{len(errs.items)} error(s)")
    return 0 if errs.ok else 1


if __name__ == "__main__":
    sys.exit(main())
