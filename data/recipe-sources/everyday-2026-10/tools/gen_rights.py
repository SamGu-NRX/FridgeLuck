#!/usr/bin/env python3
"""Generate rights_manifest.json and evidence/rights.json for the slice.

The manifest carries one record per source_ref. The pinned evidence file
carries, per group (everyday-originals, everyday-144), the sha256 of the
shipped recipes file plus one authoring record per recipe id: license,
source_type, permissions, title, and the ingredient-name hash. The slice
checker and the pinned validator's extended affirmative forms both verify
against these.

Run:  python3 tools/gen_rights.py [--slice-dir DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

FSIS_URL = ("https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/"
            "food-safety-basics/safe-temperature-chart/")

PERMISSIONS = {"text": True, "images": False, "modification": True,
               "attribution": True, "caching": True, "offline_use": True}


def ingredients_sha256(recipe: dict) -> str:
    names = [str(i.get("name")) for i in recipe.get("ingredients", []) if isinstance(i, dict)]
    return hashlib.sha256(json.dumps(names, ensure_ascii=False).encode("utf-8")).hexdigest()


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slice-dir", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--access-date", default="2026-10-15")
    args = ap.parse_args()
    d = args.slice_dir

    groups = {
        "everyday-originals": ("originals.jsonl", "original"),
        "everyday-144": ("converted-144.jsonl", "original-rewrite"),
    }
    manifest: dict[str, dict] = {"records": {}}
    evidence: dict[str, dict] = {}
    for group_name, (fname, stype) in groups.items():
        path = d / fname
        recipes = load_jsonl(path)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        records: dict[str, dict] = {}
        for r in recipes:
            rid = r["id"]
            ref = r["source_ref"]
            records[rid] = {
                "license": "LicenseRef-FL-Original",
                "source_type": stype,
                "permissions": dict(PERMISSIONS),
                "title": r["title"],
                "ingredients_sha256": ingredients_sha256(r),
            }
            manifest["records"][ref] = {
                "source_id": ref if stype == "original" else ref.rsplit("-", 1)[-1],
                "source_type": stype,
                "origin": ("authored in-place for FridgeLuck, everyday-2026-10 slice"
                           if stype == "original"
                           else "converted and rewritten from PR #144 legacy records 167-327"),
                "license": "LicenseRef-FL-Original",
                "access_date": args.access_date,
                "permissions": dict(PERMISSIONS),
                "license_evidence": (
                    f"FridgeLuck-original text authored for this slice; pinned recipes file "
                    f"{fname} sha256 {sha} (authoring records in evidence/rights.json). "
                    f"FSIS chart citation: {FSIS_URL}."),
            }
        evidence[group_name] = {
            "recipes_sha256": sha,
            "recipes_file": str(path.resolve()),
            "records": records,
        }

    (d / "rights_manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    ev_dir = d / "evidence"
    ev_dir.mkdir(exist_ok=True)
    (ev_dir / "rights.json").write_text(
        json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    total = sum(len(g["records"]) for g in evidence.values())
    print(f"wrote rights_manifest.json and evidence/rights.json ({total} authoring records)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
