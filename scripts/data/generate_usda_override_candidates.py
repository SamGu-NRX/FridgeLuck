#!/usr/bin/env python3
"""Deprecated wrapper.

Use `uv run usda export-batch`.
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
    parser = argparse.ArgumentParser(description="DEPRECATED: use `uv run usda export-batch`.")
    parser.add_argument("--batch-id", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--catalog", default="scripts/data/catalog/usda_curated_ingredients.json")
    parser.add_argument("--out-dir", default="scripts/data/review_batches")
    parser.add_argument("--candidates")
    args = parser.parse_args()

    out_path = f"{args.out_dir.rstrip('/')}/manual_batch_{args.batch_id:03d}.json"
    print("[deprecated] generate_usda_override_candidates.py -> usda export-batch", file=sys.stderr)

    command = [
        "export-batch",
        "--batch-id",
        str(args.batch_id),
        "--batch-size",
        str(args.batch_size),
        "--canonical",
        args.catalog,
        "--out",
        out_path,
    ]
    if args.candidates:
        command.extend(["--candidates", args.candidates])

    return _run_usda(command)


if __name__ == "__main__":
    raise SystemExit(main())
