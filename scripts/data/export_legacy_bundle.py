#!/usr/bin/env python3
"""Regenerate the pinned legacy bundle payloads for the bundled-data refresh.

Existing installs hydrated their recipe/ingredient rows from the bundle payloads
that were public in git history at the time. The refresh engine adopts those
legacy rows by matching them against pinned copies of those payloads, so every
bundle content version needs a pin here before it stops being the current one.

Outputs (committed, deterministic byte-for-byte):
  apps/ios/Resources/LegacyBundles/<slug>_data.json
  apps/ios/Resources/LegacyBundles/<slug>_usda_catalog_export.json
  apps/ios/Resources/LegacyBundles/manifest.json

Usage:
  python3 scripts/data/export_legacy_bundle.py \
    --slug v1 \
    --data-ref <git-ref-where-data.json-was-public> \
    [--repo-root /path/to/FridgeLuck]

Run from a checkout whose HEAD contains the payload you want to pin. The data
pin is read from the git object named by --data-ref (never from the working
tree, so accidental local edits cannot enter a pin).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

# The USDA catalog import (BundledDataLoaderUSDACatalog.swift) writes exactly
# these columns for catalog rows: nutrition from the source, notes verbatim,
# display metadata (description COALESCEd to ''), and NULL for
# typical_unit / storage_tip / pairs_with. The export must mirror that shape so
# canonical hashes computed on-device match the pinned payloads.
CATALOG_EXPORT_QUERY = """
SELECT
  id,
  name,
  calories,
  protein,
  carbs,
  fat,
  fiber,
  sugar,
  sodium,
  notes,
  COALESCE(description, '') AS description,
  category_label,
  sprite_group,
  sprite_key
FROM ingredients
ORDER BY id
"""


def git_show(repo_root: Path, ref: str, path: str) -> bytes:
  result = subprocess.run(
    ["git", "show", f"{ref}:{path}"],
    cwd=repo_root,
    check=True,
    stdout=subprocess.PIPE,
  )
  return result.stdout


def sha256_hex(data: bytes) -> str:
  return hashlib.sha256(data).hexdigest()


def export_catalog(catalog_path: Path) -> list[dict]:
  conn = sqlite3.connect(f"file:{catalog_path}?mode=ro", uri=True)
  try:
    rows = conn.execute(CATALOG_EXPORT_QUERY).fetchall()
  finally:
    conn.close()
  keys = [
    "fdcId", "name", "calories", "protein", "carbs", "fat", "fiber",
    "sugar", "sodium", "notes", "description", "categoryLabel",
    "spriteGroup", "spriteKey",
  ]
  return [dict(zip(keys, row)) for row in rows]


def json_bytes(payload) -> bytes:
  return (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--slug", required=True, help="Pin slug, e.g. v1")
  parser.add_argument(
    "--data-ref",
    required=True,
    help="Git ref whose apps/ios/Resources/data.json is the payload to pin",
  )
  parser.add_argument("--repo-root", default=None)
  args = parser.parse_args()

  repo_root = Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parents[2]
  data_path = "apps/ios/Resources/data.json"
  catalog_path = repo_root / "apps/ios/Resources/usda_ingredient_catalog.sqlite"
  out_dir = repo_root / "apps/ios/Resources/LegacyBundles"
  out_dir.mkdir(parents=True, exist_ok=True)

  data_bytes = git_show(repo_root, args.data_ref, data_path)
  catalog_rows = export_catalog(catalog_path)

  data_file = f"{args.slug}_data.json"
  catalog_file = f"{args.slug}_usda_catalog_export.json"

  (out_dir / data_file).write_bytes(data_bytes)
  (out_dir / catalog_file).write_bytes(
    json_bytes({"catalogSource": "usda_ingredient_catalog.sqlite", "rows": catalog_rows})
  )

  manifest = {
    "version": 1,
    "pins": [
      {
        "slug": args.slug,
        "bundleId": sha256_hex(data_bytes)[:16],
        "dataFile": data_file,
        "dataSha256": sha256_hex(data_bytes),
        "catalogExportFile": catalog_file,
        "catalogExportSha256": sha256_hex((out_dir / catalog_file).read_bytes()),
        "expectedCatalogRowCount": len(catalog_rows),
      }
    ],
  }
  (out_dir / "manifest.json").write_bytes(json_bytes(manifest))

  print(f"Pinned {args.slug}: data={data_file} sha256={manifest['pins'][0]['dataSha256'][:16]}... "
        f"catalogRows={len(catalog_rows)}")
  return 0


if __name__ == "__main__":
  sys.exit(main())
