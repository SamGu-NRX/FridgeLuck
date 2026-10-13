#!/usr/bin/env python3
"""Pinned read-only lineage audit of the repository's permitted manifests.

Reads audit/inputs.json, verifies every pin (file sha256, git blob SHA,
last-modifying commit) against the working tree, then runs the lineage
scanner over the pinned manifests. Produces:

- per-manifest census: record count and distinct image / product / group
  counts (distinct known content hashes, source ids, declared groups),
- cross-manifest / cross-group / cross-split source-reuse findings with
  example item ids,
- approximate declared-dHash flags kept strictly separate from exact
  duplicate detection.

Everything is offline: the only bytes read are files already committed in
this repository. No image acquisition, no recognition, datasets untouched.

Usage:
  python3 tools/food-manifest-lineage/audit/audit.py \
      [--inputs tools/food-manifest-lineage/audit/inputs.json] \
      [--out tools/food-manifest-lineage/audit/results.json]

Exit code 0 = pins verified and audit written.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from lineage.adapters import AdapterInput, run_adapter
from lineage.detectors import analyze
from lineage.records import UNKNOWN

MAX_EXAMPLE_FINDINGS = 25
MAX_EXAMPLES_PER_FINDING = 6


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def verify_pins(repo: Path, pins: dict) -> list:
    """Return list of pin failures; empty list means every pin matched."""
    failures = []
    for entry in pins["manifests"]:
        path = repo / entry["path"]
        if not path.is_file():
            failures.append(f"{entry['path']}: missing from working tree")
            continue
        data = path.read_bytes()
        actual_hash = hashlib.sha256(data).hexdigest()
        if actual_hash != entry["file_sha256"]:
            failures.append(f"{entry['path']}: file sha256 drift")
            continue
        actual_blob = git(repo, "rev-parse", f"HEAD:{entry['path']}")
        if actual_blob != entry["git_blob_sha"]:
            failures.append(f"{entry['path']}: git blob SHA drift")
        actual_commit = git(repo, "log", "-1", "--format=%H", "--", entry["path"])
        if actual_commit != entry["last_modified_commit"]:
            failures.append(f"{entry['path']}: last-modified commit drift")
    return failures


def make_blob_resolver(repo: Path):
    """Read-only resolver: hash bytes of files already committed in the repo."""

    def resolver(repo_path: str) -> bytes:
        target = (repo / repo_path).resolve()
        if not target.is_file():
            raise FileNotFoundError(repo_path)
        return target.read_bytes()

    return resolver


def census(records) -> dict:
    hashes = {r.content_hash for r in records if r.content_hash != UNKNOWN}
    sources = {r.source_id for r in records if r.source_id != UNKNOWN}
    groups = {r.declared_group for r in records if r.declared_group != UNKNOWN}
    return {
        "records": len(records),
        "distinct_content_hashes": len(hashes),
        "distinct_source_ids": len(sources),
        "distinct_declared_groups": len(groups),
        "image_records": sum(1 for r in records if r.kind == "image"),
        "product_records": sum(1 for r in records if r.kind == "product"),
        "unknown_source_id_records": sum(1 for r in records if r.source_id == UNKNOWN),
        "unknown_hash_records": sum(1 for r in records if r.content_hash == UNKNOWN),
        "records_with_declared_dhash": sum(1 for r in records if r.declared_dhash),
    }


def finding_summary(f, records_by_ref) -> dict:
    members = []
    for ref in f.member_refs[:MAX_EXAMPLES_PER_FINDING]:
        rec = records_by_ref[ref]
        members.append(
            {
                "item_ref": ref,
                "manifest": rec.manifest,
                "item_id": rec.item_id,
                "label": rec.label if rec.label != UNKNOWN else None,
                "declared_group": rec.declared_group
                if rec.declared_group != UNKNOWN
                else None,
                "source_id": rec.source_id if rec.source_id != UNKNOWN else None,
            }
        )
    return {
        "cluster_id": f.cluster_id,
        "size": f.size,
        "categories": f.categories,
        "transitive": f.transitive,
        "cross_manifest": f.cross_manifest,
        "cross_group": f.cross_group,
        "manifests": f.manifests,
        "declared_groups": f.declared_groups,
        "join_key_types": f.join_key_types,
        "examples": members,
    }


def approximate_dhash_flags(all_records) -> list:
    """Declared-dHash groups whose members are NOT proven identical bytes.

    Same canonical dHash alone is never treated as duplication; this only
    lists such groups so they can be reviewed separately.
    """
    groups: dict = {}
    for rec in all_records:
        if rec.declared_dhash:
            groups.setdefault(rec.declared_dhash, []).append(rec)
    flags = []
    for dhash, group in sorted(groups.items()):
        if len(group) < 2:
            continue
        known = {r.content_hash for r in group if r.content_hash != UNKNOWN}
        all_known = all(r.content_hash != UNKNOWN for r in group)
        if all_known and len(known) == 1:
            continue  # proven identical bytes; covered by exact duplicates
        flags.append(
            {
                "dhash": dhash,
                "item_refs": [r.item_ref for r in group],
                "distinct_known_sha256": sorted(known),
                "unknown_sha256_members": sum(
                    1 for r in group if r.content_hash == UNKNOWN
                ),
            }
        )
    return flags


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Pinned read-only manifest lineage audit")
    parser.add_argument(
        "--inputs",
        default=str(TOOLS_DIR / "audit" / "inputs.json"),
        help="path to pinned inputs.json",
    )
    parser.add_argument(
        "--out",
        default=str(TOOLS_DIR / "audit" / "results.json"),
        help="path to write results.json",
    )
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parents[3]
    inputs_path = Path(args.inputs).resolve()
    pins = json.loads(inputs_path.read_text(encoding="utf-8"))

    failures = verify_pins(repo, pins)
    if failures:
        for failure in failures:
            print(f"PIN DRIFT: {failure}", file=sys.stderr)
        print("FAIL: pinned manifests do not match the audit head", file=sys.stderr)
        return 2

    resolver = make_blob_resolver(repo)
    all_records = []
    manifest_census = []
    for entry in pins["manifests"]:
        inp = AdapterInput(
            name=entry["path"],
            kind=entry["kind"],
            adapter=entry["adapter"],
            options=entry.get("options"),
        )
        records = run_adapter(inp, (repo / entry["path"]).read_bytes(), resolver)
        all_records.extend(records)
        manifest_census.append(
            {
                "path": entry["path"],
                "adapter": entry["adapter"],
                "kind": entry["kind"],
                "git_blob_sha": entry["git_blob_sha"],
                "file_sha256": entry["file_sha256"],
                "last_modified_commit": entry["last_modified_commit"],
                "census": census(records),
            }
        )

    result = analyze(all_records)
    records_by_ref = {r.item_ref: r for r in all_records}
    findings = result.findings
    size_distribution = Counter(f.size for f in findings)
    example_findings = [
        finding_summary(f, records_by_ref)
        for f in findings
        if f.cross_manifest or f.transitive or f.cross_group
    ][:MAX_EXAMPLE_FINDINGS]

    approx = approximate_dhash_flags(all_records)

    totals = {
        "manifests": len(pins["manifests"]),
        "records": result.total_records,
        "multi_member_clusters": result.multi_member_clusters,
        "singletons": result.singletons,
        "exact_duplicate_clusters": result.counts["exact-duplicate"],
        "renamed_url_clusters": result.counts["renamed-url"],
        "source_reuse_clusters": result.counts["source-reuse"],
        "transitive_source_clusters": result.counts["transitive-source"],
        "cross_manifest_clusters": result.counts["cross-manifest"],
        "cross_group_clusters": result.counts["cross-group"],
        "unknown_content_hash_records": result.unobserved["unknown_content_hash_records"],
        "unknown_source_id_records": result.unobserved["unknown_source_id_records"],
        "declared_dhash_records": sum(1 for r in all_records if r.declared_dhash),
        "approximate_dhash_flags": len(approx),
    }

    out = {
        "audit_head": pins["audit_head"],
        "audit_branch": pins["audit_branch"],
        "pins_verified": True,
        "scope": (
            "offline; reads only files committed in this repository; "
            "no image acquisition, no recognition, datasets untouched"
        ),
        "totals": totals,
        "cluster_size_distribution": dict(sorted(size_distribution.items())),
        "manifest_census": manifest_census,
        "example_findings": example_findings,
        "approximate_dhash_flags": approx,
    }

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2) + "\n")

    print("lineage audit (pinned, read-only)")
    print(f"  manifests: {totals['manifests']}  records: {totals['records']}")
    print(
        f"  reuse clusters: {totals['multi_member_clusters']} "
        f"(exact-duplicate={totals['exact_duplicate_clusters']}, "
        f"renamed-url={totals['renamed_url_clusters']}, "
        f"source-reuse={totals['source_reuse_clusters']}, "
        f"transitive={totals['transitive_source_clusters']})"
    )
    print(
        f"  spans: cross-manifest={totals['cross_manifest_clusters']} "
        f"cross-group={totals['cross_group_clusters']}"
    )
    print(
        f"  approximate declared-dHash flags: {totals['approximate_dhash_flags']} "
        f"(kept separate from exact duplicates)"
    )
    print(f"  results: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
