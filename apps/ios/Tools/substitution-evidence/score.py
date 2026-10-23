#!/usr/bin/env python3
"""Score the substitution evidence set into a report, and verify reports.

Usage:
    python3 score.py                       # print + write reports/evidence_report.json
    python3 score.py --verify-report PATH  # recompute and compare exactly

The report is deterministic. --verify-report recomputes it from the evidence
CSVs and fails unless the stored report is exactly equal (deep equality on the
parsed JSON, with ratios kept as exact fractions serialized as strings).
"""
import argparse
import csv
import json
import sys
from fractions import Fraction
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
EVIDENCE_DIR = TOOL_DIR / "evidence"
REPORTS_DIR = TOOL_DIR / "reports"
sys.path.insert(0, str(TOOL_DIR / "tools"))
from build_cases import build_cases  # noqa: E402
from extract_production_map import parse_service  # noqa: E402

REPO_ROOT = TOOL_DIR.parents[3]


def ratio_fraction(num: int, den: int) -> str:
    """Exact ratio as a fraction string, e.g. 35/227."""
    f = Fraction(num, den) if den else Fraction(0)
    return f"{f.numerator}/{f.denominator}" if den else "0/0"


def build_report():
    service_pairs, region_hash = parse_service(
        REPO_ROOT / "apps/ios/Platform/Persistence/Services/SubstitutionService.swift"
    )
    cases = build_cases(REPO_ROOT)

    verdict_counts = {}
    function_counts = {}
    per_pair = {}
    ratio_conflicts = []
    for c in cases:
        verdict_counts[c["verdict"]] = verdict_counts.get(c["verdict"], 0) + 1
        function_counts[c["context_function"]] = function_counts.get(c["context_function"], 0) + 1
        pid = c["pair_id"]
        pp = per_pair.setdefault(
            pid,
            {
                "pair_id": pid,
                "original": c["original_name"],
                "substitute": c["substitute_name"],
                "production_ratio": c["production_ratio"],
                "contexts": 0,
                "verdicts": {},
                "functions": {},
            },
        )
        pp["contexts"] += 1
        pp["verdicts"][c["verdict"]] = pp["verdicts"].get(c["verdict"], 0) + 1
        pp["functions"][c["context_function"]] = pp["functions"].get(c["context_function"], 0) + 1

    with (EVIDENCE_DIR / "pair_evidence.csv").open(newline="", encoding="utf-8") as f:
        pair_evidence = {r["pair_id"]: r for r in csv.DictReader(f)}
    for pid, ev in sorted(pair_evidence.items()):
        if ev["ratio_status"] == "conflict":
            ratio_conflicts.append(
                {
                    "pair_id": pid,
                    "production_ratio": ev["production_ratio"],
                    "expected_ratio": ev["expected_ratio"],
                    "note": ev["assessment"],
                }
            )

    total = len(cases)
    sourced = verdict_counts.get("verified", 0)
    function_supported = sourced + verdict_counts.get("partial", 0)
    report = {
        "schema": "fl-substitution-eval/v1",
        "pairs_total": len(service_pairs),
        "pairs_evidence_rows": len(pair_evidence),
        "contexts_total": total,
        "verdict_counts": dict(sorted(verdict_counts.items())),
        "function_counts": dict(sorted(function_counts.items())),
        "sourced_ratio": {
            "verified": sourced,
            "total": total,
            "fraction": ratio_fraction(sourced, total),
        },
        "function_supported_ratio": {
            "supported": function_supported,
            "total": total,
            "fraction": ratio_fraction(function_supported, total),
        },
        "unverified_or_unsupported": verdict_counts.get("unverified", 0)
        + verdict_counts.get("unsupported", 0),
        "per_pair": [per_pair[k] for k in sorted(per_pair)],
        "ratio_conflicts": ratio_conflicts,
        "source_region_sha256": region_hash,
        "caveats": [
            "Source agreement proves neither taste quality nor allergen cross-contact safety.",
            "Function labels are keyword-based over bundled recipe steps; 'unknown' functions are left unverified.",
            "USDA household-mass tables are referenced, not duplicated.",
        ],
    }
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify-report", metavar="PATH", default=None)
    args = ap.parse_args()

    report = build_report()
    if args.verify_report:
        stored = json.loads(Path(args.verify_report).read_text())
        if stored == report:
            print("VERIFY OK: recomputed report matches", args.verify_report)
            return 0
        # Point out the first differing top-level key for debuggability.
        diffs = [k for k in sorted(set(stored) | set(report))
                 if stored.get(k) != report.get(k)]
        print(f"VERIFY FAILED: differs in keys {diffs}")
        for k in diffs[:5]:
            print(f"  {k}: stored={json.dumps(stored.get(k))[:200]}")
            print(f"  {k}: actual={json.dumps(report.get(k))[:200]}")
        return 1

    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    out = REPORTS_DIR / "evidence_report.json"
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"\nwrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
