#!/usr/bin/env python3
"""Deprecated wrapper.

Use:
- `uv run usda build-sqlite`
- `uv run usda validate`
- `uv run usda report`
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def _run_usda(args: list[str]) -> int:
    data_dir = Path(__file__).resolve().parent
    uv_bin = data_dir / ".venv" / "bin" / "uv"
    uv_cmd = str(uv_bin) if uv_bin.exists() else "uv"
    command = [
        uv_cmd,
        "run",
        "--project",
        str(data_dir),
        "python",
        str(data_dir / "usda.py"),
        *args,
    ]
    return subprocess.run(command, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="DEPRECATED: use `uv run usda build-sqlite`.")
    parser.add_argument("--in-catalog")
    parser.add_argument("--out-json")
    parser.add_argument("--out-sqlite", default="FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite")
    parser.add_argument("--out-report", default="scripts/data/.cache/usda_pipeline_report.md")
    parser.add_argument("--canonical", default="scripts/data/catalog/usda_curated_ingredients.json")
    args = parser.parse_args()

    print("[deprecated] build_usda_catalog_sqlite.py -> usda build-sqlite + validate + report", file=sys.stderr)

    code = _run_usda(["validate", "--canonical", args.canonical])
    if code != 0:
        return code
    code = _run_usda(["build-sqlite", "--canonical", args.canonical, "--out", args.out_sqlite])
    if code != 0:
        return code
    return _run_usda(["report", "--canonical", args.canonical, "--out", args.out_report])


if __name__ == "__main__":
    raise SystemExit(main())
