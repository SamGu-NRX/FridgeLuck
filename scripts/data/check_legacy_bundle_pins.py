#!/usr/bin/env python3
"""Verify the pinned legacy bundle corpus for the bundled-data refresh.

Adoption trusts these pins as the exact payloads a past public release
hydrated from, so a silent byte flip or a drifted row count would
corrupt ownership decisions on device. This script re-derives every
manifest claim from the files on disk and fails with a nonzero exit if
anything is inconsistent.

Checks, per pin:
  - both payload files exist and hash to the manifest's SHA-256 values
  - bundleId is the first 16 hex chars of the data payload's hash
  - the catalog export parses, carries the 14 canonical columns, and
    its row count matches expectedCatalogRowCount
  - the data payload parses as {tags, ingredients, recipes}

Usage:
  python3 scripts/data/check_legacy_bundle_pins.py \
    --pins apps/ios/Resources/LegacyBundles
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

CATALOG_KEYS = [
  "fdcId", "name", "calories", "protein", "carbs", "fat", "fiber",
  "sugar", "sodium", "notes", "description", "categoryLabel",
  "spriteGroup", "spriteKey",
]
CATALOG_NUMERIC_KEYS = [
  "calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium",
]


def sha256_hex(data: bytes) -> str:
  return hashlib.sha256(data).hexdigest()


def check_pin(pin: dict, pins_dir: Path, errors: list[str]) -> dict:
  slug = pin.get("slug", "<missing slug>")

  data_file = pin.get("dataFile")
  if not data_file:
    errors.append(f"{slug}: manifest pin has no dataFile")
  else:
    data_path = pins_dir / data_file
    if not data_path.is_file():
      errors.append(f"{slug}: pinned data payload {data_file} is missing")
    else:
      actual = sha256_hex(data_path.read_bytes())
      expected = pin.get("dataSha256")
      if actual != expected:
        errors.append(
          f"{slug}: data payload hash mismatch: manifest {expected}, actual {actual}"
        )
      bundle_id = pin.get("bundleId")
      if bundle_id != actual[:16]:
        errors.append(
          f"{slug}: bundleId mismatch: manifest {bundle_id}, "
          f"first 16 of data hash {actual[:16]}"
        )
      try:
        payload = json.loads(data_path.read_text(encoding="utf-8"))
        tags = payload["tags"]
        ingredients = payload["ingredients"]
        recipes = payload["recipes"]
        if not isinstance(tags, list) or not isinstance(ingredients, dict) or not isinstance(recipes, list):
          raise TypeError("wrong container types")
      except (json.JSONDecodeError, KeyError, TypeError) as exc:
        errors.append(f"{slug}: pinned data payload does not match the data.json shape: {exc}")
      else:
        print(f"{slug}: data payload {data_file} sha256={actual} "
              f"ingredients={len(ingredients)} recipes={len(recipes)} tags={len(tags)}")

  catalog_file = pin.get("catalogExportFile")
  if not catalog_file:
    errors.append(f"{slug}: manifest pin has no catalogExportFile")
  else:
    catalog_path = pins_dir / catalog_file
    if not catalog_path.is_file():
      errors.append(f"{slug}: pinned catalog export {catalog_file} is missing")
    else:
      actual = sha256_hex(catalog_path.read_bytes())
      expected = pin.get("catalogExportSha256")
      if actual != expected:
        errors.append(
          f"{slug}: catalog export hash mismatch: manifest {expected}, actual {actual}"
        )
      try:
        export = json.loads(catalog_path.read_text(encoding="utf-8"))
        rows = export["rows"]
        if not isinstance(rows, list):
          raise TypeError("rows is not a list")
        for index, row in enumerate(rows):
          if set(row.keys()) != set(CATALOG_KEYS):
            raise TypeError(f"row {index} has keys {sorted(row.keys())}")
          for key in CATALOG_NUMERIC_KEYS:
            if not isinstance(row[key], (int, float)):
              raise TypeError(f"row {index}: {key} is not numeric")
      except (json.JSONDecodeError, KeyError, TypeError) as exc:
        errors.append(f"{slug}: pinned catalog export is malformed: {exc}")
      else:
        print(f"{slug}: catalog export {catalog_file} sha256={actual} rows={len(rows)}")
        expected_rows = pin.get("expectedCatalogRowCount")
        if expected_rows != len(rows):
          errors.append(
            f"{slug}: catalog row count mismatch: manifest {expected_rows}, actual {len(rows)}"
          )

  return {"slug": slug}


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument(
    "--pins",
    default="apps/ios/Resources/LegacyBundles",
    help="Directory holding manifest.json and the pinned payloads",
  )
  args = parser.parse_args()
  pins_dir = Path(args.pins)

  manifest_path = pins_dir / "manifest.json"
  if not manifest_path.is_file():
    print(f"error: no manifest at {manifest_path}", file=sys.stderr)
    return 1
  try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
  except json.JSONDecodeError as exc:
    print(f"error: manifest at {manifest_path} does not parse: {exc}", file=sys.stderr)
    return 1
  if manifest.get("version") != 1:
    print(f"error: unsupported manifest version {manifest.get('version')!r}", file=sys.stderr)
    return 1

  errors: list[str] = []
  pins = manifest.get("pins")
  if not isinstance(pins, list) or not pins:
    errors.append("manifest carries no pins")
  else:
    slugs = [pin.get("slug") for pin in pins if isinstance(pin, dict)]
    if len(slugs) != len(set(slugs)):
      errors.append(f"manifest has duplicate pin slugs: {slugs}")
    for pin in manifest["pins"]:
      if not isinstance(pin, dict):
        errors.append(f"manifest pin entry is not an object: {pin!r}")
        continue
      check_pin(pin, pins_dir, errors)

  if errors:
    for error in errors:
      print(f"error: {error}", file=sys.stderr)
    print(f"FAILED: {len(errors)} problem(s) in {pins_dir}", file=sys.stderr)
    return 1
  print(f"OK: {len(pins)} pin(s) verified in {pins_dir}")
  return 0


if __name__ == "__main__":
  sys.exit(main())
