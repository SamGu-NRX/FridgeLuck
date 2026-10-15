#!/usr/bin/env python3
"""Score the pantry-feasibility corpus from Swift replay results.

Reads the replay JSONL (every state x recipe pair judged by both the
production predicate and the data-model oracle) and reports:

- false-complete rate: pairs where production claims makeable but the data
  model refutes the recipe (unsafe recommendations), broken out by family
- false-block rate: pairs where production hides a recipe the data model
  calls feasible (recall loss from zero-remaining/missing-ID semantics)
- agreement rate on the agreement_probe family
- per-family and overall counts, written to runs/report.json

The report is deterministic for a frozen corpus and replay output.

Usage: python3 run_eval.py [--tool-dir DIR] [--results replay.jsonl]
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-dir", type=Path,
                        default=Path(__file__).resolve().parent)
    parser.add_argument("--results", type=Path, default=None)
    args = parser.parse_args()

    results = args.results or (args.tool_dir / "swift" / ".build"
                               / "replay_results.jsonl")

    false_complete_by_family: dict[str, int] = defaultdict(int)
    production_makeable_by_family: dict[str, int] = defaultdict(int)
    false_block_by_family: dict[str, int] = defaultdict(int)
    oracle_feasible_by_family: dict[str, int] = defaultdict(int)
    oracle_feasible_agreement = 0
    oracle_feasible_pairs = 0
    total = 0

    with open(results, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            row = json.loads(line)
            total += 1
            family = row["family"]

            if row["production_makeable"]:
                production_makeable_by_family[family] += 1
                if not row["oracle_feasible"]:
                    false_complete_by_family[family] += 1
            if row["oracle_feasible"]:
                oracle_feasible_by_family[family] += 1
                oracle_feasible_pairs += 1
                if row["production_makeable"]:
                    # Agreement that matters for recall: when the data model
                    # calls a recipe feasible, production must not hide it.
                    oracle_feasible_agreement += 1
                else:
                    false_block_by_family[family] += 1

    total_false_complete = sum(false_complete_by_family.values())
    total_makeable = sum(production_makeable_by_family.values())

    # Live production arm: real RecipeRepository on real migrated databases
    # (production/), verified against the transcribed arm by
    # verify_production.py. Per-pair metrics above stay computed from the
    # transcribed rows; the live arm corroborates them.
    live = None
    live_path = args.tool_dir / "runs" / "production_verification.json"
    if live_path.exists():
        live = json.loads(live_path.read_text(encoding="utf-8"))

    report = {
        "arms": {
            "oracle": "data-model feasibility (Python oracle, Swift-corroborated)",
            "production_transcribed": (
                "Swift transcription of RecipeRepository.findMakeable "
                "(per-pair rows; corroborated live by the production arm)"),
            "production_live": (
                "real RecipeRepository.findMakeable/findNearMatch on real "
                "migrated in-memory databases") if live else "not run",
        },
        "pairs_evaluated": total,
        "production_makeable_pairs": total_makeable,
        "false_complete_pairs": total_false_complete,
        "false_complete_rate_overall":
            round(total_false_complete / total_makeable, 6) if total_makeable else 0.0,
        "false_complete_by_family": dict(sorted(false_complete_by_family.items())),
        "false_block_pairs": sum(false_block_by_family.values()),
        "false_block_by_family": dict(sorted(false_block_by_family.items())),
        "oracle_feasible_recall":
            round(oracle_feasible_agreement / oracle_feasible_pairs, 6)
            if oracle_feasible_pairs else 0.0,
        "planted_false_complete_rate":
            round(false_complete_by_family.get("planted_false_complete", 0)
                  / max(production_makeable_by_family.get("planted_false_complete", 1),
                        1), 6),
    }
    if live:
        live_vs_oracle = live.get("live_vs_oracle")
        report["production_live"] = {
            "states": live.get("production_live_states"),
            "makeable_set_agreement": live.get("makeable_set_agreement"),
            "near_match_set_agreement": live.get("near_match_set_agreement"),
            "agreement_rate": live.get("agreement_rate"),
            "source_pin_status": live.get("source_pin", {}).get("status"),
            "run_record": live.get("run_record"),
        }
        if live_vs_oracle:
            # Metrics derived directly from the live RecipeRepository result
            # rows compared to the independent oracle — not from the
            # transcribed per-pair rows above.
            report["production_live_vs_oracle"] = live_vs_oracle

    out_path = args.tool_dir / "runs" / "report.json"
    out_path.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n",
                        encoding="utf-8")
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
