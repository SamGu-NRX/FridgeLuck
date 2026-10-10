#!/usr/bin/env python3
"""Score Swift replay results against the hand-computed reference.

Reads data/replay-out/replay-results.json (produced by the SwiftReplay
package) plus data/histories.json and data/expected_current.json, and prints
the per-family arm comparison for the tool's report.

Checks (exit 1 on any failure):
  - replay-results.json exists, full (not REPLAY_FAST partial)
  - current arm matches expected_current.json on every scan of every seed
  - restart and database-reopen agreement hold on every seed/arm
"""

import json
import sys
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2]  # .../scan-correction-eval
DATA = TOOL / "data"
RESULTS = DATA / "replay-out" / "replay-results.json"
EXPECTED = DATA / "expected_current.json"
HISTORIES = DATA / "histories.json"


def main() -> None:
    if not RESULTS.exists():
        sys.exit(f"missing {RESULTS} (run the SwiftReplay package first)")
    results = json.loads(RESULTS.read_text())
    expected = json.loads(EXPECTED.read_text())
    histories = json.loads(HISTORIES.read_text())

    if len(results.get("results", [])) < 1200:
        sys.exit(f"results look partial: {len(results.get('results', []))} seed-results")

    schema = results.get("schema")
    if schema not in (1, 2):
        sys.exit(f"unknown results schema: {schema}")
    routed = schema >= 2

    total_scans = 0
    by_arm_family: dict[tuple[str, str], dict[str, int]] = {}
    problems: list[str] = []

    for row in results["results"]:
        arm, family, seed = row["arm"], row["family"], row["seed"]
        if not row["restartAgreement"]:
            problems.append(f"restart disagreement: {arm}/{family}/{seed}")
        if not row["dbReopenAgreement"]:
            problems.append(f"db-reopen disagreement: {arm}/{family}/{seed}")
        if arm == "current":
            key = f"{family}/{seed}"
            exp = [rec.get("decision") for rec in expected["seeds"][key]]
            got = [d.get("decision") for d in row["decisions"]]
            if exp != got:
                first = next(
                    (i for i, (a, b) in enumerate(zip(exp, got)) if a != b), None)
                problems.append(
                    f"current-policy divergence {key} at scan {first}: "
                    f"expected {exp[first]}, replayed {got[first]}")
        stats = by_arm_family.setdefault(
            (arm, family), {
                "scans": 0, "wrong": 0, "correct": 0, "abstained": 0,
                "auto": 0, "auto_correct": 0, "auto_wrong": 0,
                "auto_unresolved": 0, "confirm": 0, "possible": 0})
        for d in row["decisions"]:
            total_scans += 1
            stats["scans"] += 1
            if d.get("decision") is None:
                stats["abstained"] += 1
            elif d["decision"] == d["truth"]:
                stats["correct"] += 1
            else:
                stats["wrong"] += 1
            if routed:
                bucket = d.get("bucket")
                if bucket == "auto":
                    stats["auto"] += 1
                    if d.get("decision") is None:
                        stats["auto_unresolved"] += 1
                    elif d["decision"] == d["truth"]:
                        stats["auto_correct"] += 1
                    else:
                        stats["auto_wrong"] += 1
                elif bucket == "confirm":
                    stats["confirm"] += 1
                elif bucket == "possible":
                    stats["possible"] += 1

    n_scans = sum(
        len([e for e in h["events"] if e["type"] == "scan"])
        for h in histories["histories"])
    print(f"histories: {len(histories['histories'])}  total scans committed: {n_scans}")
    print(f"seed-results: {len(results['results'])}  scans replayed: {total_scans}")

    print(f"\n{'family':<18}{'arm':<17}{'scans':>6}{'wrong':>7}{'correct':>9}{'abstain':>9}")
    for (arm, family) in sorted(by_arm_family, key=lambda k: (k[1], k[0])):
        s = by_arm_family[(arm, family)]
        print(
            f"{family:<18}{arm:<17}{s['scans']:>6}{s['wrong']:>7}"
            f"{s['correct']:>9}{s['abstained']:>9}")

    if routed:
        print(
            "\nConfidenceRouter effects (schema 2; auto-add is the only "
            "bucket that takes effect without the user):")
        print(
            f"{'family':<18}{'arm':<17}{'autoAdd':>8}{'ok':>6}{'WRONG':>7}"
            f"{'unres':>7}{'confirm':>9}{'possible':>9}")
        for (arm, family) in sorted(by_arm_family, key=lambda k: (k[1], k[0])):
            s = by_arm_family[(arm, family)]
            print(
                f"{family:<18}{arm:<17}{s['auto']:>8}{s['auto_correct']:>6}"
                f"{s['auto_wrong']:>7}{s['auto_unresolved']:>7}"
                f"{s['confirm']:>9}{s['possible']:>9}")
    else:
        print("\nschema-1 results: learner-only (no ConfidenceRouter routing)")

    if problems:
        print("\nFAILURES:")
        for p in problems[:10]:
            print(" -", p)
        sys.exit(1)
    print("\nall checks passed: current arm matches hand-computed reference; "
          "restart and db-reopen agreement hold everywhere")


if __name__ == "__main__":
    main()
