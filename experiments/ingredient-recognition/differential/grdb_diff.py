#!/usr/bin/env python3
"""Differential: real GRDB replay vs the Python catalog port.

The Swift replay package (apps/ios/Tools/catalog-resolver-replay) executes the
production IngredientCatalogResolver — mirrored byte-identically from the app
sources — over the shipped catalog through GRDB. This script answers the same
186 probe inputs with the Python port (resolution/app_resolution.py), pins the
committed Python answers in python_catalog_results.jsonl, and diffs the two
field by field. Any DIFF is a divergence between GRDB runtime behavior and the
port; the port is the thing to fix (the Swift side is production code).

Also enforces mirror integrity: sha256(repo production file) ==
sha256(committed mirror) == the hash pinned in SourceManifest.swift.

Usage:
  python3 grdb_diff.py [--write-port-outputs]

Exit 0 = zero diffs and mirror intact.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

EXPERIMENT = Path(__file__).resolve().parent.parent
REPO_ROOT = EXPERIMENT.parent.parent
DIFF_DIR = EXPERIMENT / "differential"
sys.path.insert(0, str(EXPERIMENT / "resolution"))

from app_resolution import IngredientCatalogResolver, USDA_DB  # noqa: E402

MIRROR = (
    REPO_ROOT / "apps/ios/Tools/catalog-resolver-replay"
    / "Sources/CatalogReplayCore/ProductionMirror"
)
REPLAY_RESULTS = DIFF_DIR / "grdb_replay_results.jsonl"
PORT_RESULTS = DIFF_DIR / "python_catalog_results.jsonl"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned_hash() -> str:
    """Read the hash refresh.sh generated into SourceManifest.swift."""
    text = (MIRROR / "SourceManifest.swift").read_text(encoding="utf-8")
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('"IngredientCatalogResolver.swift"'):
            return line.split('"')[3]
    raise SystemExit("SourceManifest.swift: pinned hash not found")


def port_rows() -> list[dict]:
    resolver = IngredientCatalogResolver(db_path=USDA_DB)
    rows = []
    for line in (DIFF_DIR / "probes.jsonl").read_text(encoding="utf-8").splitlines():
        probe = json.loads(line)
        exact = resolver.resolve(probe["input"], matching="exact")
        allow = resolver.resolve(probe["input"], matching="allowPrefix")
        from_text = resolver.resolve_from_text(probe["input"])
        rows.append(
            {
                "kind": probe["kind"],
                "input": probe["input"],
                "resolveExact": str(exact) if exact is not None else None,
                "resolveAllowPrefix": str(allow) if allow is not None else None,
                "resolveFromText": str(from_text) if from_text is not None else None,
                "displayNameExact": (
                    resolver.display_name(exact) if exact is not None else None
                ),
                "displayNameAllowPrefix": (
                    resolver.display_name(allow) if allow is not None else None
                ),
                "displayNameFromText": (
                    resolver.display_name(from_text) if from_text is not None else None
                ),
            }
        )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-port-outputs", action="store_true",
                        help="regenerate python_catalog_results.jsonl instead of reading it")
    args = parser.parse_args()

    problems: list[str] = []

    # mirror integrity
    upstream = REPO_ROOT / "apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift"
    mirror_file = MIRROR / "IngredientCatalogResolver.swift"
    upstream_hash, mirror_hash, pinned = sha256(upstream), sha256(mirror_file), pinned_hash()
    if not upstream.exists():
        problems.append(f"production resolver missing at {upstream}")
    else:
        if upstream_hash != pinned:
            problems.append(f"pinned hash {pinned} != upstream sha256 {upstream_hash} — mirror stale, rerun refresh.sh")
        if mirror_hash != pinned:
            problems.append("committed mirror copy differs from the pinned hash")
    meta = json.loads((DIFF_DIR / "grdb_replay_meta.json").read_text())
    if meta.get("sourceManifest", {}).get("IngredientCatalogResolver.swift") != pinned:
        problems.append("grdb_replay_meta.json records a different source hash than SourceManifest.swift")

    # replay rows present and probe-aligned
    replay = [json.loads(line) for line in REPLAY_RESULTS.read_text(encoding="utf-8").splitlines()]
    probes = [json.loads(line) for line in (DIFF_DIR / "probes.jsonl").read_text(encoding="utf-8").splitlines()]
    if [(r["kind"], r["input"]) for r in replay] != [(p["kind"], p["input"]) for p in probes]:
        problems.append("grdb_replay_results.jsonl does not answer probes.jsonl in order")
        print("FAILED:", *problems, sep="\n - ")
        raise SystemExit(1)

    if args.write_port_outputs:
        PORT_RESULTS.write_text(
            "".join(json.dumps(r, sort_keys=True) + "\n" for r in port_rows()),
            encoding="utf-8",
        )
    port = [json.loads(line) for line in PORT_RESULTS.read_text(encoding="utf-8").splitlines()]
    if len(port) != len(replay):
        problems.append(f"port outputs {len(port)} rows vs replay {len(replay)}")

    n_diff = 0
    for i, (mine, theirs) in enumerate(zip(port, replay)):
        if (mine["kind"], mine["input"]) != (theirs["kind"], theirs["input"]):
            problems.append(f"row {i}: probe mismatch between port and replay files")
            continue
        for key in sorted(set(mine) - {"kind", "input"}):
            if mine.get(key) != theirs.get(key):
                n_diff += 1
                print(f"DIFF row {i} ({theirs['kind']}:{theirs['input']!r}) {key}: "
                      f"grdb={theirs.get(key)!r} python={mine.get(key)!r}")

    stats = {
        "resolved_exact": sum(1 for r in replay if r["resolveExact"]),
        "resolved_prefix": sum(1 for r in replay if r["resolveAllowPrefix"]),
        "resolved_from_text": sum(1 for r in replay if r["resolveFromText"]),
    }
    print(f"probes={len(replay)} diffs={n_diff} grdb-resolved={stats}")
    if problems or n_diff:
        for p in problems:
            print(" -", p)
        raise SystemExit(1)
    print("OK: GRDB replay matches the Python port field-by-field; mirror hash intact")


if __name__ == "__main__":
    main()
