"""Offline evaluation CLI. Deterministic; one catalog pass per arm.

Usage:
  python -m taste_lab eval --catalog <data.json> --households 40 --days 30 --seed 7
  python -m taste_lab validate-fixtures --catalog <data.json> --fixtures <dir>
  python -m taste_lab regenerate-fixtures --catalog <data.json> --out <dir>
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta
from typing import Dict, List

from .baselines import PopularityArm, ProfileOnlyArm, ResidualArm
from .features import Catalog, load_catalog
from .metrics import (
    bootstrap_ci,
    ndcg_at_k,
    paired_bootstrap_difference,
    pairwise_accuracy_on_flippable,
    top10_churn,
)
from .rules import RuleRanker
from .sim import simulate, start_day, utility_table

ARM_NAMES = ["residual", "profile_only", "popularity", "rule"]


def run_eval(catalog: Catalog, households_n: int, days: int, seed: int) -> dict:
    start = start_day()
    households = simulate(catalog, households_n, days, start, seed=seed)
    eval_at = (start + timedelta(days=days, hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    eval_dt = datetime.fromisoformat(eval_at.replace("Z", "+00:00"))

    per_household = {name: [] for name in ARM_NAMES}
    churn = {name: [] for name in ARM_NAMES}
    n_flippable = 0

    for h in households:
        rule = RuleRanker(catalog, goal=h.goal)
        arms = {
            "residual": ResidualArm(catalog, rule),
            "profile_only": ProfileOnlyArm(catalog, rule),
            "popularity": PopularityArm(catalog, rule),
            "rule": rule,
        }
        events = sorted(h.events, key=lambda e: (e["at"], e["id"]))
        # Every arm observes the SAME complete stream (the replay), then
        # ranks at eval time; the residual arm's decay is what makes history
        # recency-aware. No arm sees the household's latent preferences.
        for arm in arms.values():
            arm.observe(events, h.exposures)

        utilities = utility_table(h)
        pantry = h.pantry
        feasible = h.feasible_recipes(pantry)
        if len(feasible) < 5:
            continue

        rule_scores = rule.rule_scores(feasible, pantry, eval_dt)
        rankings: Dict[str, List[str]] = {
            name: arm.rank(feasible, pantry, eval_dt) for name, arm in arms.items()
        }

        for name in ARM_NAMES:
            ranked = rankings[name]
            per_household[name].append(ndcg_at_k(ranked, utilities, k=10))
            churn[name].append(top10_churn(rankings["rule"], ranked, k=10))

        pa, n = pairwise_accuracy_on_flippable(rankings["residual"], utilities, rule_scores, margin=2.0)
        if n > 0:
            n_flippable += n
            per_household.setdefault("_pairwise", []).append(pa)

    report: dict = {
        "config": {"households": households_n, "days": days, "seed": seed, "evalAt": eval_at},
        "metrics": {},
    }
    for name in ARM_NAMES:
        mean, low, high = bootstrap_ci(per_household[name], seed=seed)
        report["metrics"][name] = {
            "ndcg10_mean": round(mean, 6),
            "ndcg10_ci": [round(low, 6), round(high, 6)],
            "top10_churn_vs_rule_mean": round(sum(churn[name]) / max(len(churn[name]), 1), 6),
        }
    # Paired residual-vs-rule difference with bootstrap CI.
    d_mean, d_low, d_high = paired_bootstrap_difference(
        per_household["residual"], per_household["rule"], seed=seed
    )
    report["metrics"]["residual_vs_rule_delta"] = {
        "mean": round(d_mean, 6),
        "ci": [round(d_low, 6), round(d_high, 6)],
    }
    pw = per_household.get("_pairwise", [])
    report["metrics"]["residual_pairwise_flippable"] = {
        "mean": round(sum(pw) / max(len(pw), 1), 6),
        "pairs_observed": n_flippable,
    }
    return report


def load_fixtures(fixtures_dir: str, catalog: Catalog):
    import os

    fixtures = []
    for fn in sorted(os.listdir(fixtures_dir)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(fixtures_dir, fn)) as f:
            doc = json.load(f)
        fixtures.append(doc)
    return fixtures


def validate_fixture(doc: dict, catalog: Catalog) -> List[str]:
    from .engine import TasteResidualEngine

    problems: List[str] = []
    engine = TasteResidualEngine(
        {rid: r.features for rid, r in catalog.recipes.items()},
        name_of=catalog.feature_names,
    )
    engine.ingest(doc["events"], doc["exposures"], doc.get("statements", []))
    rule_scores = {rid: float(v) for rid, v in doc["ruleScores"].items()}
    entries = engine.rank(rule_scores, doc["evalAt"])
    got_ranking = [e.recipe_id for e in entries]
    expected_ranking = [r["recipe"]["id"] for r in doc["expected"]["ranking"]]
    if got_ranking != expected_ranking:
        problems.append(f"{doc['name']}: ranking mismatch\n  expected {expected_ranking}\n  got      {got_ranking}")
    got_profile, got_hidden = engine.profile(doc["evalAt"])
    exp_profile = doc["expected"]["profile"]
    if [s.get("id") for s in got_profile] != [s.get("id") for s in exp_profile]:
        problems.append(f"{doc['name']}: profile statement mismatch")
    return problems


def regenerate(
    fixtures_dir: str,
    catalog: Catalog,
    seed: int,
    household: int = 0,
    sim_households: int = 2,
) -> int:
    """Writes one golden fixture: household `household` of a `sim_households`-
    household, 10-day run at `seed`. The committed set is one fixture per eval
    seed — hh00/seed 7, hh01/seed 11, hh23/seed 13 — mirroring the legacy
    catalog's fixture naming."""
    import os

    from .engine import TasteResidualEngine

    os.makedirs(fixtures_dir, exist_ok=True)
    households = simulate(catalog, max(sim_households, household + 1), 10, start_day(), seed=seed)
    eval_at = (start_day() + timedelta(days=10, hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    count = 0
    for h in households[household : household + 1]:
        rule = RuleRanker(catalog, goal=h.goal)
        engine = TasteResidualEngine(
            {rid: r.features for rid, r in catalog.recipes.items()},
            name_of=catalog.feature_names,
        )
        engine.ingest(h.events, h.exposures)
        pantry = h.pantry
        feasible = h.feasible_recipes(pantry)
        rule_scores = rule.rule_scores(feasible, pantry, datetime.fromisoformat(eval_at.replace("Z", "+00:00")))
        entries = engine.rank(rule_scores, eval_at)
        ranking = [e.to_json({"id": e.recipe_id}) for e in entries]
        rendered, hidden = engine.profile(eval_at)
        path = os.path.join(fixtures_dir, f"golden-{h.id}.json")
        from .sim import write_golden_fixture

        write_golden_fixture(path, h, eval_at, rendered, hidden, ranking, rule_scores)
        count += 1
    return count


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="taste_lab")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_eval = sub.add_parser("eval", help="run the offline campaign and print a report")
    p_eval.add_argument("--catalog", required=True)
    p_eval.add_argument("--households", type=int, default=40)
    p_eval.add_argument("--days", type=int, default=30)
    p_eval.add_argument("--seed", type=int, default=7)
    p_eval.add_argument("--out", help="write the report JSON here as well")

    p_val = sub.add_parser("validate-fixtures", help="check committed golden fixtures replay exactly")
    p_val.add_argument("--catalog", required=True)
    p_val.add_argument("--fixtures", required=True)

    p_reg = sub.add_parser("regenerate-fixtures", help="regenerate golden fixtures from the simulator")
    p_reg.add_argument("--catalog", required=True)
    p_reg.add_argument("--out", required=True)
    p_reg.add_argument("--seed", type=int, default=7)
    p_reg.add_argument("--household", type=int, default=0)
    p_reg.add_argument("--sim-households", type=int, default=2)

    args = parser.parse_args(argv)
    catalog = load_catalog(args.catalog)

    if args.cmd == "eval":
        report = run_eval(catalog, args.households, args.days, args.seed)
        text = json.dumps(report, indent=2)
        print(text)
        if args.out:
            with open(args.out, "w") as f:
                f.write(text + "\n")
        return 0
    if args.cmd == "validate-fixtures":
        problems = []
        for doc in load_fixtures(args.fixtures, catalog):
            problems.extend(validate_fixture(doc, catalog))
        if problems:
            print("FIXTURE FAILURES:")
            for p in problems:
                print("  -", p)
            return 1
        print("All fixtures replay exactly.")
        return 0
    if args.cmd == "regenerate-fixtures":
        n = regenerate(
            args.out, catalog, args.seed, household=args.household, sim_households=args.sim_households
        )
        print(f"wrote {n} fixtures to {args.out}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
