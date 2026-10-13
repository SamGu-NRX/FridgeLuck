#!/usr/bin/env python3
"""Compact per-manifest lineage report with proposed (never applied) repairs.

Runs the same pinned, read-only scan as audit.py over audit/inputs.json and
produces:

- a compact per-manifest census (records, distinct source ids / declared
  groups, unknown counters, image vs product split),
- proposed owner-specific repairs derived mechanically from the findings:
  align-group conflicts, within-manifest duplicate rows, orphan source
  references, and label drift. Proposals are informational — the tool
  never modifies any manifest or dataset.
- report/summary.md, a deterministic human rendering.

--verify-report regenerates both files in memory and requires them to be
byte-identical to the committed copies (the report contains no timestamps,
so regeneration is deterministic by construction).

Usage:
  python3 tools/food-manifest-lineage/report.py \
      [--inputs tools/food-manifest-lineage/audit/inputs.json] \
      [--report-dir tools/food-manifest-lineage/report] \
      [--verify-report]

Exit codes: 0 = report written (or verified); 2 = pin drift or verification
mismatch.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))
AUDIT_DIR = TOOLS_DIR / "audit"
if str(AUDIT_DIR) not in sys.path:
    sys.path.insert(0, str(AUDIT_DIR))

from lineage.adapters import AdapterInput, run_adapter
from lineage.detectors import analyze
from lineage.records import UNKNOWN

from audit import make_blob_resolver, verify_pins

CATALOG_MARKER = "usda_curated_ingredients.json"
MAX_EXAMPLES = 20


def scan(inputs_path: Path):
    """Run the pinned scan; returns (pins, records)."""
    repo = Path(__file__).resolve().parents[2]
    pins = json.loads(inputs_path.read_text(encoding="utf-8"))
    failures = verify_pins(repo, pins)
    if failures:
        for failure in failures:
            print(f"PIN DRIFT: {failure}", file=sys.stderr)
        raise SystemExit(2)
    resolver = make_blob_resolver(repo)
    records = []
    for entry in pins["manifests"]:
        inp = AdapterInput(
            name=entry["path"],
            kind=entry["kind"],
            adapter=entry["adapter"],
            options=entry.get("options"),
        )
        records.extend(run_adapter(inp, (repo / entry["path"]).read_bytes(), resolver))
    return pins, records


def census(records) -> list:
    """Compact per-manifest census, deterministic order."""
    by_manifest: dict = {}
    for rec in records:
        by_manifest.setdefault(rec.manifest, []).append(rec)
    rows = []
    for path in sorted(by_manifest):
        recs = by_manifest[path]
        sources = {r.source_id for r in recs if r.source_id != UNKNOWN}
        groups = {r.declared_group for r in recs if r.declared_group != UNKNOWN}
        rows.append(
            {
                "path": path,
                "records": len(recs),
                "image_records": sum(1 for r in recs if r.kind == "image"),
                "product_records": sum(1 for r in recs if r.kind == "product"),
                "distinct_source_ids": len(sources),
                "distinct_declared_groups": len(groups),
                "unknown_source_id_records": sum(
                    1 for r in recs if r.source_id == UNKNOWN
                ),
                "unknown_hash_records": sum(1 for r in recs if r.content_hash == UNKNOWN),
            }
        )
    return rows


def proposed_repairs(records, result) -> dict:
    """Mechanical, sorted repair proposals. Informational only."""
    records_by_ref = {r.item_ref: r for r in records}

    # 1. align-group: cross-group clusters with a canonical catalog group.
    align = []
    for f in result.findings:
        if not f.cross_group:
            continue
        members = [records_by_ref[ref] for ref in f.member_refs]
        known_groups = sorted(
            {m.declared_group for m in members if m.declared_group != UNKNOWN}
        )
        if len(known_groups) < 2:
            continue
        catalog_members = [m for m in members if m.manifest.endswith(CATALOG_MARKER)]
        canonical = sorted({m.declared_group for m in catalog_members}) or None
        conflicts = [
            {
                "manifest": m.manifest,
                "item_id": m.item_id,
                "declared_group": m.declared_group,
            }
            for m in sorted(members, key=lambda r: (r.manifest, r.item_ref))
            if m.declared_group != UNKNOWN
            and (canonical is None or m.declared_group not in canonical)
        ]
        align.append(
            {
                "cluster_id": f.cluster_id,
                "canonical_group": canonical,
                "declared_groups": known_groups,
                "conflicts": conflicts[:MAX_EXAMPLES],
                "conflict_count": len(conflicts),
            }
        )
    align.sort(key=lambda a: (a["canonical_group"] is None, a["cluster_id"]))

    # 2. within-manifest duplicate rows (same source id twice in one file).
    within = []
    pair_counts = Counter(
        (r.manifest, r.source_id) for r in records if r.source_id != UNKNOWN
    )
    for (manifest, source_id), count in sorted(pair_counts.items()):
        if count > 1:
            members = [
                r
                for r in records
                if r.manifest == manifest and r.source_id == source_id
            ]
            within.append(
                {
                    "manifest": manifest,
                    "source_id": source_id,
                    "rows": count,
                    "item_ids": sorted(r.item_id for r in members)[:MAX_EXAMPLES],
                }
            )

    # 3. orphan source ids: referenced outside the catalog but not in it.
    catalog_ids = {
        r.source_id for r in records if r.manifest.endswith(CATALOG_MARKER)
    }
    orphans = {}
    for r in sorted(records, key=lambda r: (r.manifest, r.item_ref)):
        if r.source_id == UNKNOWN or r.source_id in catalog_ids:
            continue
        entry = orphans.setdefault(r.source_id, {"first_manifest": r.manifest, "labels": set()})
        if r.label != UNKNOWN:
            entry["labels"].add(r.label)
    orphan_list = [
        {
            "source_id": sid,
            "first_manifest": entry["first_manifest"],
            "labels": sorted(entry["labels"])[:MAX_EXAMPLES],
        }
        for sid, entry in sorted(orphans.items())
    ]

    # 4. label drift: same source id declared under >=2 distinct labels.
    drift = []
    by_source: dict = {}
    for r in records:
        if r.source_id != UNKNOWN:
            by_source.setdefault(r.source_id, []).append(r)
    for sid in sorted(by_source):
        labels = sorted({r.label for r in by_source[sid] if r.label != UNKNOWN})
        if len(labels) < 2:
            continue
        drift.append({"source_id": sid, "labels": labels[:MAX_EXAMPLES]})

    def pack(entries: list, note: str) -> dict:
        return {
            "count": len(entries),
            "examples": entries[:MAX_EXAMPLES],
            "note": note,
        }

    return {
        "align_group": pack(
            align,
            "same upstream product declared under different groups; canonical group is the catalog's when present",
        ),
        "within_manifest_duplicate": pack(
            within,
            "same source id appears on multiple rows inside one manifest; candidate for upsert-style dedupe",
        ),
        "orphan_source": pack(
            orphan_list,
            "source ids referenced outside the catalog but absent from it; add to the catalog or drop the reference",
        ),
        "label_drift": pack(
            drift,
            "same source id declared under multiple labels; pick a canonical display name",
        ),
    }


def build_report(pins, records, result) -> dict:
    return {
        "audit_head": pins["audit_head"],
        "audit_branch": pins["audit_branch"],
        "scope": (
            "read-only; reads only files committed in this repository; "
            "repairs are proposals and nothing is modified"
        ),
        "totals": {
            "manifests": len(pins["manifests"]),
            "records": result.total_records,
            "multi_member_clusters": result.multi_member_clusters,
            "singletons": result.singletons,
            "unknown_source_id_records": result.unobserved["unknown_source_id_records"],
            "unknown_content_hash_records": result.unobserved[
                "unknown_content_hash_records"
            ],
        },
        "census": census(records),
        "proposed_repairs": proposed_repairs(records, result),
    }


def render_summary(report: dict) -> str:
    lines = [
        "# Lineage report (compact)",
        "",
        f"Audit head: `{report['audit_head']}` on branch `{report['audit_branch']}`.",
        "",
        "| manifest | records | images | products | distinct src ids | distinct groups | unknown src | unknown hash |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for row in report["census"]:
        lines.append(
            f"| {row['path']} | {row['records']} | {row['image_records']} "
            f"| {row['product_records']} | {row['distinct_source_ids']} "
            f"| {row['distinct_declared_groups']} | {row['unknown_source_id_records']} "
            f"| {row['unknown_hash_records']} |"
        )
    t = report["totals"]
    lines += [
        "",
        f"Totals: {t['manifests']} manifests, {t['records']} records, "
        f"{t['multi_member_clusters']} reuse clusters, {t['singletons']} singletons.",
        "",
        "## Proposed repairs (informational — nothing is modified)",
        "",
    ]
    for name, pack in report["proposed_repairs"].items():
        lines.append(f"### {name} — {pack['count']} candidate(s)")
        lines.append("")
        lines.append(f"{pack['note']}.")
        lines.append("")
        if pack["examples"]:
            lines.append("```json")
            lines.append(json.dumps(pack["examples"][:5], indent=2))
            lines.append("```")
        else:
            lines.append("No candidates.")
        lines.append("")
    lines.append(
        "Unobserved lineage: records with unknown source ids or hashes are "
        "counted but never joined, so they generate no repairs."
    )
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Compact lineage report with proposed repairs")
    parser.add_argument(
        "--inputs",
        default=str(AUDIT_DIR / "inputs.json"),
        help="path to pinned inputs.json",
    )
    parser.add_argument(
        "--report-dir",
        default=str(TOOLS_DIR / "report"),
        help="directory for report.json and summary.md",
    )
    parser.add_argument(
        "--verify-report",
        action="store_true",
        help="regenerate and require byte-identical match with committed report",
    )
    args = parser.parse_args(argv)

    pins, records = scan(Path(args.inputs).resolve())
    result = analyze(records)
    report = build_report(pins, records, result)
    summary = render_summary(report)
    report_json = json.dumps(report, indent=2) + "\n"

    report_dir = Path(args.report_dir).resolve()
    report_path = report_dir / "report.json"
    summary_path = report_dir / "summary.md"

    if args.verify_report:
        mismatches = []
        if report_path.read_text(encoding="utf-8") != report_json:
            mismatches.append(str(report_path))
        if summary_path.read_text(encoding="utf-8") != summary:
            mismatches.append(str(summary_path))
        if mismatches:
            for m in mismatches:
                print(f"VERIFY MISMATCH: {m}", file=sys.stderr)
            print("FAIL: committed report does not match regeneration", file=sys.stderr)
            return 2
        print("report verify: OK (regeneration is byte-identical)")
        return 0

    report_dir.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report_json, encoding="utf-8")
    summary_path.write_text(summary, encoding="utf-8")

    print("lineage report (pinned, read-only)")
    print(f"  manifests: {report['totals']['manifests']}  records: {report['totals']['records']}")
    for name, pack in report["proposed_repairs"].items():
        print(f"  proposed {name}: {pack['count']}")
    print(f"  report: {report_path}")
    print(f"  summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
