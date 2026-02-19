#!/usr/bin/env python3
"""Deprecated wrapper.

Use `uv run usda fetch-candidates` instead.
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
    parser = argparse.ArgumentParser(description="DEPRECATED: use `uv run usda fetch-candidates`.")
    parser.add_argument("--api-key")
    parser.add_argument("--extra-query", action="append", default=[])
    parser.add_argument("--extra-query-file")
    parser.add_argument("--add-fdc-id", action="append", type=int, default=[])
    parser.add_argument("--raw-catalog")
    parser.add_argument("--curated-json")
    parser.add_argument("--data-json")
    parser.add_argument("--only-extra-queries", action="store_true")
    parser.add_argument("--max-passes")
    parser.add_argument("--delay-sec")
    parser.add_argument("--out", default="scripts/data/.cache/candidates/deprecated_backfill_run.json")
    args = parser.parse_args()

    print("[deprecated] backfill_usda_common_ingredients.py -> usda fetch-candidates", file=sys.stderr)

    command = ["fetch-candidates", "--out", args.out]
    if args.api_key:
        command.extend(["--api-key", args.api_key])
    if args.extra_query_file:
        command.extend(["--query-file", args.extra_query_file])
    for q in args.extra_query:
        command.extend(["--query", q])
    for v in args.add_fdc_id:
        command.extend(["--fdc-id", str(v)])

    return _run_usda(command)


if __name__ == "__main__":
    raise SystemExit(main())
