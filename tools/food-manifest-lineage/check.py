#!/usr/bin/env python3
"""Contract-fixture check for the FridgeLuck manifest lineage scanner.

Plants exact duplicates, renamed URLs and transitive source relationships
in synthetic manifests shaped exactly like the repository's real public
food manifests, then verifies that:

1. every planted relationship is detected (expectations), and
2. every planted false-positive control stays quiet — similar-but-distinct
   items sharing only surface features (same class, same sprite group,
   same subdirectory, unknown keys) must not join.

Usage:
  python3 tools/food-manifest-lineage/check.py \
      --fixture tools/food-manifest-lineage/fixtures/contracts.json

Exit code 0 = all expectations satisfied and no control flagged.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from lineage.adapters import ADAPTERS, AdapterInput, run_adapter
from lineage.detectors import analyze
from lineage.records import UNKNOWN

EXPECTATION_KEYS = (
    "total_records",
    "multi_member_clusters",
    "exact_duplicate_clusters",
    "renamed_url_clusters",
    "source_reuse_clusters",
    "transitive_source_clusters",
    "cross_manifest_clusters",
    "cross_group_clusters",
)


def result_counts(result) -> dict:
    return {
        "total_records": result.total_records,
        "multi_member_clusters": result.multi_member_clusters,
        "exact_duplicate_clusters": result.counts["exact-duplicate"],
        "renamed_url_clusters": result.counts["renamed-url"],
        "source_reuse_clusters": result.counts["source-reuse"],
        "transitive_source_clusters": result.counts["transitive-source"],
        "cross_manifest_clusters": result.counts["cross-manifest"],
        "cross_group_clusters": result.counts["cross-group"],
    }


def run_check(contracts_path: Path):
    contracts = json.loads(contracts_path.read_text(encoding="utf-8"))
    base_dir = contracts_path.parent

    records = []
    for entry in contracts["fixtures"]:
        inp = AdapterInput(
            name=entry["name"],
            kind=entry["kind"],
            adapter=entry["adapter"],
            declared_revision=entry.get("declared_revision") or UNKNOWN,
            options=entry.get("options"),
        )
        if inp.adapter not in ADAPTERS:
            raise KeyError(f"unknown adapter {inp.adapter!r} in {entry['name']}")
        raw = (base_dir / entry["file"]).read_bytes()
        records.extend(run_adapter(inp, raw, blob_resolver=None))

    result = analyze(records)
    return contracts, records, result, result_counts(result)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Lineage contract-fixture check")
    parser.add_argument(
        "--fixture",
        required=True,
        help="path to contracts.json (default: fixtures/contracts.json)",
    )
    args = parser.parse_args(argv)

    contracts_path = Path(args.fixture).resolve()
    try:
        contracts, records, result, counts = run_check(contracts_path)
    except Exception as exc:  # noqa: BLE001 - CLI boundary
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    failures = []
    expectations = contracts.get("expectations", {})
    checked = 0
    satisfied = 0
    for key in EXPECTATION_KEYS:
        if key not in expectations:
            continue
        checked += 1
        if counts[key] == expectations[key]:
            satisfied += 1
        else:
            failures.append(
                f"expectation {key}: expected {expectations[key]}, got {counts[key]}"
            )

    quiet_refs = contracts.get("controls", {}).get("quiet_item_refs", [])
    flagged = sorted(
        {ref for f in result.findings for ref in f.member_refs if ref in set(quiet_refs)}
    )
    if flagged:
        failures.append(f"false-positive controls flagged: {flagged}")

    print("lineage contract check")
    print(f"  fixtures: {len(contracts['fixtures'])} manifests, {len(records)} records")
    print(
        "  detections: "
        f"exact-duplicate={counts['exact_duplicate_clusters']} "
        f"renamed-url={counts['renamed_url_clusters']} "
        f"source-reuse={counts['source_reuse_clusters']} "
        f"transitive-source={counts['transitive_source_clusters']}"
    )
    print(
        f"  spans: cross-manifest={counts['cross_manifest_clusters']} "
        f"cross-group={counts['cross_group_clusters']}"
    )
    print(
        f"  expectations: {satisfied}/{checked} satisfied "
        f"({counts['multi_member_clusters']} reuse clusters over "
        f"{counts['total_records']} records)"
    )
    print(f"  false-positive controls: {len(flagged)}/{len(quiet_refs)} flagged")
    if failures:
        for failure in failures:
            print(f"  FAIL: {failure}")
        print("FAIL")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
