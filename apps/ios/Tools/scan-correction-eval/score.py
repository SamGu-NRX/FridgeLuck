#!/usr/bin/env python3
"""Milestone 3 scoring for scan-correction-eval.

Consumes the SwiftReplay output (data/replay-out/replay-results.json, 1,200
seed-results over 300 committed histories x 4 arms) and produces the formal
report:

  - Policy selection uses DEVELOPMENT families ONLY.
  - The held-out family (heldout-combined) is scored after selection and is
    never read during it.
  - Uncertainty comes from a seed-grouped bootstrap (families resample their
    own seeds with replacement; seeds are the exchange unit — every decision
    from one seed moves together).
  - --verify-report re-hashes the frozen replay results and recomputes every
    number in an existing report; any tampering or dropped case refuses.

Selection rule (fixed before looking at held-out, recorded here): maximize
net auto-corrections = correctAuto - wrongAuto summed over development
families. Tie-break: fewer wrongAuto, then arm name ascending. It prices one
wrong silent auto-correction exactly equal to one correct one —
conservative by design; the report also prints the uncollapsed trade-off
table so a reader can price it differently.
"""

import hashlib
import json
import random
import sys
from pathlib import Path

TOOL = Path(__file__).resolve().parent
RESULTS = TOOL / "data" / "replay-out" / "replay-results.json"
REPORT = TOOL / "data" / "replay-out" / "score-report.json"

HELD_OUT = "heldout-combined"
B_BOOTSTRAP = 1_000
BOOTSTRAP_SEED = 20261010
REPORT_VERSION = 1


def load_results():
    if not RESULTS.exists():
        sys.exit(f"missing {RESULTS} (run the SwiftReplay package first)")
    raw = RESULTS.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    data = json.loads(raw)
    return raw, digest, data


def row_stats(row):
    stats = {"scans": 0, "wrong": 0, "correct": 0, "abstained": 0}
    for d in row["decisions"]:
        stats["scans"] += 1
        if d.get("decision") is None:
            stats["abstained"] += 1
        elif d["decision"] == d["truth"]:
            stats["correct"] += 1
        else:
            stats["wrong"] += 1
    return stats


def per_seed_family(data):
    """{(family, seed, arm): stats} — the bootstrap exchange units."""
    table = {}
    for row in data["results"]:
        key = (row["family"], row["seed"], row["arm"])
        table[key] = row_stats(row)
    return table


def sum_stats(stats_list):
    total = {"scans": 0, "wrong": 0, "correct": 0, "abstained": 0}
    for s in stats_list:
        for k in total:
            total[k] += s[k]
    return total


def select_arm(table, families):
    """Selection rule from the module docstring. Dev families only."""
    dev_keys = [k for k in table if k[0] in families]
    arms = sorted({k[2] for k in dev_keys})
    scored = []
    for arm in arms:
        agg = sum_stats([table[k] for k in dev_keys if k[2] == arm])
        net = agg["correct"] - agg["wrong"]
        scored.append((-net, agg["wrong"], arm))  # sort asc
    scored.sort()
    return scored[0][2], scored


def bootstrap_interval(table, families, arm, rng, b=B_BOOTSTRAP):
    """Seed-grouped percentile bootstrap over family totals."""
    seeds_by_family = {
        fam: sorted({k[1] for k in table if k[0] == fam and k[2] == arm})
        for fam in families
    }
    keys = {
        fam: [(fam, seed, arm) for seed in seeds]
        for fam, seeds in seeds_by_family.items()
    }
    samples = {"scans": [], "wrong": [], "correct": [], "abstained": []}
    for _ in range(b):
        agg = sum_stats(
            table[rng.choice(keys[fam])] for fam in families for _ in keys[fam]
        )
        for k in samples:
            samples[k].append(agg[k])

    def interval(values):
        values = sorted(values)
        lo = values[int(0.025 * b)]
        hi = values[min(b, int(0.975 * b) + 1) - 1]
        return [lo, hi]

    return {k: interval(v) for k, v in samples.items()}


def arm_report(table, families, arm, rng):
    agg = sum_stats(
        [table[k] for k in table if k[0] in families and k[2] == arm]
    )
    return {
        "totals": agg,
        "bootstrap_95": bootstrap_interval(table, families, arm, rng),
    }


def build_report(digest, data, b=B_BOOTSTRAP, seed=BOOTSTRAP_SEED):
    table = per_seed_family(data)
    all_families = sorted({k[0] for k in table})
    if HELD_OUT not in all_families:
        sys.exit(f"held-out family {HELD_OUT} missing from results")
    dev_families = [f for f in all_families if f != HELD_OUT]
    arms = sorted({k[2] for k in table})

    selected, selection_table = select_arm(table, dev_families)

    rng = random.Random(seed)
    report = {
        "report_version": REPORT_VERSION,
        "results_sha256": digest,
        "results_count": len(data["results"]),
        "selection_rule": "max dev net auto-corrections (correct - wrong); tie: fewer wrong, then arm name",
        "bootstrap": {"resamples": b, "seed": seed, "unit": "seed (grouped by family)"},
        "development_families": dev_families,
        "held_out_family": HELD_OUT,
        "selected_arm": selected,
        "selection_dev_table": [
            {"arm": arm, **sum_stats(
                [table[k] for k in table if k[0] in dev_families and k[2] == arm])}
            for _, _, arm in selection_table
        ],
        "held_out": {
            arm: arm_report(table, [HELD_OUT], arm, rng) for arm in arms
        },
    }
    return report


def write_report(report):
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def verify_report():
    if not REPORT.exists():
        sys.exit(f"missing {REPORT} (run score.py without --verify-report first)")
    stored = json.loads(REPORT.read_text())
    raw, digest, data = load_results()
    recomputed = build_report(
        digest, data, b=stored["bootstrap"]["resamples"], seed=stored["bootstrap"]["seed"])
    problems = []
    if stored.get("results_sha256") != digest:
        problems.append("replay results hash mismatch (results changed or tampered)")
    if stored.get("results_count") != len(data["results"]):
        problems.append("seed-result count changed")
    if stored != recomputed:
        problems.append("report does not match recomputation from committed results")
    if problems:
        sys.exit("VERIFY FAILED: " + "; ".join(problems))
    print("verify OK: report matches committed results and recomputation")


def print_report(report):
    print(f"results: {report['results_count']} seed-results  sha256 {report['results_sha256'][:16]}…")
    print(f"selection rule: {report['selection_rule']}")
    print(f"selected arm (dev only): {report['selected_arm']}")
    print("\ndev selection table (net = correct - wrong):")
    for row in sorted(report["selection_dev_table"], key=lambda r: r["arm"]):
        net = row["correct"] - row["wrong"]
        print(f"  {row['arm']:16} scans {row['scans']:5}  wrong {row['wrong']:4}"
              f"  correct {row['correct']:4}  abstain {row['abstained']:4}  net {net:5}")
    print(f"\nheld-out ({report['held_out_family']}) with 95% seed-grouped bootstrap:")
    ho = report["held_out"]
    for arm in sorted(ho):
        tot, ci = ho[arm]["totals"], ho[arm]["bootstrap_95"]
        print(f"  {arm:16} wrong {tot['wrong']:3} CI {ci['wrong']}  "
              f"correct {tot['correct']:3} CI {ci['correct']}  "
              f"abstain {tot['abstained']:3} CI {ci['abstained']}")


def main():
    args = sys.argv[1:]
    if "--verify-report" in args:
        verify_report()
        return
    raw, digest, data = load_results()
    report = build_report(digest, data)
    write_report(report)
    print_report(report)
    print(f"\nreport written to {REPORT}")


if __name__ == "__main__":
    main()
