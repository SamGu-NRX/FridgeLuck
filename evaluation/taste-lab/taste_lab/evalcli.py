"""Offline evaluation CLI. Deterministic; one catalog pass per arm.

Usage:
  python -m taste_lab eval --catalog <data.json> --households 40 --days 30 --seed 7
  python -m taste_lab gate --catalog <data.json> --out results/app-pool
  python -m taste_lab validate-fixtures --catalog <data.json> --fixtures <dir>
  python -m taste_lab regenerate-fixtures --catalog <data.json> --out <dir>
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta
from typing import Dict, List, Optional

from .baselines import PopularityArm, ProfileOnlyArm, ResidualArm
from .engine import normalize_variant
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

# The ranking variants the gate compares. None is the shipped residual-v1
# math; the two specs are the churn-repair candidates from the task.
CHURN_BOUNDED_GRID = [1.0, 2.0, 3.0, 6.0]
SHRUNK_GRID = [2.0, 4.0, 8.0, 16.0]
TUNING_SEEDS = [7, 11]  # band/k are tuned here ONLY (held out: 13, 17, 19)
HELD_OUT_SEEDS = [13, 17, 19]
GATE_SEEDS = TUNING_SEEDS + HELD_OUT_SEEDS
CHURN_LIMIT = 0.05  # Sam's decision rule band, read as top-10 churn vs rule

ARM_NAMES = ["residual", "profile_only", "popularity", "rule"]


def _variant_specs(band: Optional[float] = None, k: Optional[float] = None) -> List[Optional[dict]]:
    specs: List[Optional[dict]] = [None]  # the shipped residual arm
    if band is not None:
        specs.append({"name": "churn_bounded", "band": band})
    if k is not None:
        specs.append({"name": "shrunk", "k": k})
    return specs


def run_eval(
    catalog: Catalog,
    households_n: int,
    days: int,
    seed: int,
    pool_mode: str = "app",
    variant_specs: Optional[List[Optional[dict]]] = None,
) -> dict:
    variant_specs = variant_specs if variant_specs is not None else [None]
    variant_specs = [normalize_variant(s) for s in variant_specs]

    start = start_day()
    households = simulate(catalog, households_n, days, start, seed=seed, pool_mode=pool_mode)
    eval_at = (start + timedelta(days=days, hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    eval_dt = datetime.fromisoformat(eval_at.replace("Z", "+00:00"))

    # residual arms: the shipped math plus one per ranking variant
    residual_names = ["residual" if s is None else f"residual_{s['name']}" for s in variant_specs]
    arm_names = residual_names + ["profile_only", "popularity", "rule"]

    per_household: Dict[str, List[float]] = {name: [] for name in arm_names}
    churn: Dict[str, List[float]] = {name: [] for name in arm_names}
    n_flippable: Dict[str, int] = {name: 0 for name in residual_names}

    for h in households:
        rule = RuleRanker(catalog, goal=h.goal, staples_as_optional=(pool_mode == "app"))
        arms = {
            "profile_only": ProfileOnlyArm(catalog, rule),
            "popularity": PopularityArm(catalog, rule),
            "rule": rule,
        }
        for name, spec in zip(residual_names, variant_specs):
            arms[name] = ResidualArm(catalog, rule, variant=spec)
        events = sorted(h.events, key=lambda e: (e["at"], e["id"]))
        # Every arm observes the SAME complete stream (the replay), then
        # ranks at eval time; the residual arm's decay is what makes history
        # recency-aware. No arm sees the household's latent preferences.
        for arm in arms.values():
            arm.observe(events, h.exposures)

        utilities = utility_table(h)
        pantry = h.pantry
        pool = h.candidate_pool(pantry)
        if len(pool) < 5:
            continue

        rule_scores = rule.rule_scores(pool, pantry, eval_dt)
        rankings: Dict[str, List[str]] = {
            name: arm.rank(pool, pantry, eval_dt) for name, arm in arms.items()
        }

        for name in arm_names:
            ranked = rankings[name]
            per_household[name].append(ndcg_at_k(ranked, utilities, k=10))
            churn[name].append(top10_churn(rankings["rule"], ranked, k=10))

        for name in residual_names:
            pa, n = pairwise_accuracy_on_flippable(rankings[name], utilities, rule_scores, margin=2.0)
            if n > 0:
                n_flippable[name] += n
                per_household.setdefault(f"_pairwise_{name}", []).append(pa)

    report: dict = {
        "config": {
            "households": households_n,
            "days": days,
            "seed": seed,
            "evalAt": eval_at,
            "poolMode": pool_mode,
        },
        "metrics": {},
    }
    for name in arm_names:
        mean, low, high = bootstrap_ci(per_household[name], seed=seed)
        report["metrics"][name] = {
            "ndcg10_mean": round(mean, 6),
            "ndcg10_ci": [round(low, 6), round(high, 6)],
            "top10_churn_vs_rule_mean": round(sum(churn[name]) / max(len(churn[name]), 1), 6),
        }
    # Paired residual-vs-rule difference with bootstrap CI, per residual arm.
    for name in residual_names:
        d_mean, d_low, d_high = paired_bootstrap_difference(
            per_household[name], per_household["rule"], seed=seed
        )
        report["metrics"][f"{name}_vs_rule_delta"] = {
            "mean": round(d_mean, 6),
            "ci": [round(d_low, 6), round(d_high, 6)],
        }
        pw = per_household.get(f"_pairwise_{name}", [])
        report["metrics"][f"{name}_pairwise_flippable"] = {
            "mean": round(sum(pw) / max(len(pw), 1), 6),
            "pairs_observed": n_flippable[name],
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
    entries = engine.rank(rule_scores, doc["evalAt"], variant=doc.get("variant"))
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
    pool_mode: str = "app",
    variant: Optional[dict] = None,
) -> int:
    """Writes one golden fixture: household `household` of a `sim_households`-
    household, 10-day run at `seed`. The committed set is one fixture per eval
    seed — hh00/seed 7, hh01/seed 11, hh23/seed 13. `pool_mode` selects the
    simulator setup (the fixtures are generated in `app` mode so the events
    arise the way they do in the product); `variant` pins the ranking variant
    the fixture expects (absent = the shipped residual math)."""
    import os

    from .engine import TasteResidualEngine

    os.makedirs(fixtures_dir, exist_ok=True)
    households = simulate(
        catalog, max(sim_households, household + 1), 10, start_day(), seed=seed, pool_mode=pool_mode
    )
    eval_at = (start_day() + timedelta(days=10, hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    count = 0
    for h in households[household : household + 1]:
        rule = RuleRanker(catalog, goal=h.goal, staples_as_optional=(pool_mode == "app"))
        engine = TasteResidualEngine(
            {rid: r.features for rid, r in catalog.recipes.items()},
            name_of=catalog.feature_names,
        )
        engine.ingest(h.events, h.exposures)
        pantry = h.pantry
        pool = h.candidate_pool(pantry)
        rule_scores = rule.rule_scores(pool, pantry, datetime.fromisoformat(eval_at.replace("Z", "+00:00")))
        entries = engine.rank(rule_scores, eval_at, variant=variant)
        ranking = [e.to_json({"id": e.recipe_id}) for e in entries]
        rendered, hidden = engine.profile(eval_at)
        path = os.path.join(fixtures_dir, f"golden-{h.id}.json")
        from .sim import write_golden_fixture

        write_golden_fixture(
            path, h, eval_at, rendered, hidden, ranking, rule_scores, variant=variant
        )
        count += 1
    return count


def gate(out_prefix: str, catalog: Catalog, households_n: int, days: int) -> dict:
    """The full re-gate: tune each variant's parameter on the TUNING seeds
    (7, 11) only, then evaluate the shipped residual plus both tuned variants
    on every gate seed. Tuning objective per variant: among grid values whose
    churn stays within CHURN_LIMIT on BOTH tuning seeds, take the best mean
    NDCG delta vs rule; ties break by lower churn, then by the smaller
    parameter (the more conservative bound). Held-out seeds never influence
    the choice."""
    import os

    os.makedirs(os.path.dirname(out_prefix) or ".", exist_ok=True)

    def tune(name: str, grid: List[float]) -> dict:
        rows = []
        for value in grid:
            spec = {"name": name, "band" if name == "churn_bounded" else "k": value}
            per_seed = []
            for seed in TUNING_SEEDS:
                report = run_eval(
                    catalog,
                    households_n,
                    days,
                    seed,
                    pool_mode="app",
                    variant_specs=[{"name": name, **spec}],
                )
                metrics = report["metrics"][f"residual_{name}"]
                per_seed.append(
                    {
                        "delta": report["metrics"][f"residual_{name}_vs_rule_delta"]["mean"],
                        "churn": metrics["top10_churn_vs_rule_mean"],
                    }
                )
            mean_delta = sum(r["delta"] for r in per_seed) / len(per_seed)
            mean_churn = sum(r["churn"] for r in per_seed) / len(per_seed)
            feasible = all(r["churn"] <= CHURN_LIMIT for r in per_seed)
            rows.append(
                {
                    "value": value,
                    "mean_delta": round(mean_delta, 6),
                    "mean_churn": round(mean_churn, 6),
                    "churn_within_limit": feasible,
                    "per_seed": per_seed,
                }
            )
            print(
                f"  tune {name}={value}: delta {mean_delta:+.4f} churn {mean_churn:.4f} "
                f"{'ok' if feasible else 'OVER LIMIT'}"
            )
        passing = [r for r in rows if r["churn_within_limit"]]
        pool = passing if passing else rows  # if nothing passes, say so and fall through
        best = min(
            pool,
            key=lambda r: (-r["mean_delta"], r["mean_churn"], r["value"]),
        )
        return {
            "name": name,
            "chosen": best["value"],
            "any_passing": bool(passing),
            "grid": rows,
        }

    print("tuning churn_bounded band on seeds", TUNING_SEEDS)
    band_tune = tune("churn_bounded", CHURN_BOUNDED_GRID)
    print("tuning shrunk k on seeds", TUNING_SEEDS)
    k_tune = tune("shrunk", SHRUNK_GRID)

    band, k = band_tune["chosen"], k_tune["chosen"]
    per_seed: Dict[int, dict] = {}
    for seed in GATE_SEEDS:
        print(f"evaluating seeds={seed} ({households_n} households x {days} days)")
        report = run_eval(
            catalog,
            households_n,
            days,
            seed,
            pool_mode="app",
            variant_specs=[
                None,
                {"name": "churn_bounded", "band": band},
                {"name": "shrunk", "k": k},
            ],
        )
        per_seed[seed] = report
        with open(f"{out_prefix}-seed{seed}.json", "w") as f:
            json.dump(report, f, indent=2)
            f.write("\n")

    def arm_verdict(name: str) -> dict:
        held_out = []
        for seed in HELD_OUT_SEEDS:
            m = per_seed[seed]["metrics"]
            delta = m[f"{name}_vs_rule_delta"]
            churn_mean = m[name]["top10_churn_vs_rule_mean"]
            held_out.append(
                {
                    "seed": seed,
                    "delta_ci_low": delta["ci"][0],
                    "churn": churn_mean,
                    "ci_above_zero": delta["ci"][0] > 0,
                    "churn_within_limit": churn_mean <= CHURN_LIMIT,
                }
            )
        passed = all(r["ci_above_zero"] and r["churn_within_limit"] for r in held_out)
        return {"arm": name, "held_out": held_out, "passes": passed}

    gate_doc = {
        "config": {
            "catalog": "apps/ios/Resources/RecipeCatalog/recipes-v2.json",
            "households": households_n,
            "days": days,
            "seeds": GATE_SEEDS,
            "tuning_seeds": TUNING_SEEDS,
            "held_out_seeds": HELD_OUT_SEEDS,
            "poolMode": "app",
            "churn_limit": CHURN_LIMIT,
            "decision_rule": (
                "an arm passes when, on EACH held-out seed (13, 17, 19), the paired "
                "delta-vs-rule bootstrap CI lower bound is above 0 AND top-10 churn "
                "vs the rule order is <= 0.05"
            ),
        },
        "tuning": {"churn_bounded": band_tune, "shrunk": k_tune},
        "verdicts": [
            arm_verdict("residual"),
            arm_verdict("residual_churn_bounded"),
            arm_verdict("residual_shrunk"),
        ],
    }
    with open(f"{out_prefix}-gate.json", "w") as f:
        json.dump(gate_doc, f, indent=2)
        f.write("\n")
    for v in gate_doc["verdicts"]:
        print(
            f"  {v['arm']}: {'PASSES' if v['passes'] else 'fails'} — "
            + "; ".join(
                f"seed {r['seed']} ci_low {r['delta_ci_low']:+.4f} churn {r['churn']:.4f}"
                for r in v["held_out"]
            )
        )
    return gate_doc


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="taste_lab")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_eval = sub.add_parser("eval", help="run the offline campaign and print a report")
    p_eval.add_argument("--catalog", required=True)
    p_eval.add_argument("--households", type=int, default=40)
    p_eval.add_argument("--days", type=int, default=30)
    p_eval.add_argument("--seed", type=int, default=7)
    p_eval.add_argument("--pool-mode", choices=["app", "legacy"], default="app")
    p_eval.add_argument("--out", help="write the report JSON here as well")

    p_gate = sub.add_parser("gate", help="tune the variants on seeds 7/11 and run the five-seed gate")
    p_gate.add_argument("--catalog", required=True)
    p_gate.add_argument("--households", type=int, default=40)
    p_gate.add_argument("--days", type=int, default=30)
    p_gate.add_argument("--out-prefix", required=True, help="prefix for per-seed JSONs and the gate summary")

    p_val = sub.add_parser("validate-fixtures", help="check committed golden fixtures replay exactly")
    p_val.add_argument("--catalog", required=True)
    p_val.add_argument("--fixtures", required=True)

    p_reg = sub.add_parser("regenerate-fixtures", help="regenerate golden fixtures from the simulator")
    p_reg.add_argument("--catalog", required=True)
    p_reg.add_argument("--out", required=True)
    p_reg.add_argument("--seed", type=int, default=7)
    p_reg.add_argument("--household", type=int, default=0)
    p_reg.add_argument("--sim-households", type=int, default=2)
    p_reg.add_argument("--pool-mode", choices=["app", "legacy"], default="app")
    p_reg.add_argument("--variant", choices=["churn_bounded", "shrunk"], help="pin the ranking variant the fixture expects")
    p_reg.add_argument("--band", type=float, default=None)
    p_reg.add_argument("--k", type=float, default=None)

    args = parser.parse_args(argv)
    catalog = load_catalog(args.catalog)

    if args.cmd == "eval":
        report = run_eval(
            catalog, args.households, args.days, args.seed, pool_mode=args.pool_mode
        )
        text = json.dumps(report, indent=2)
        print(text)
        if args.out:
            with open(args.out, "w") as f:
                f.write(text + "\n")
        return 0
    if args.cmd == "gate":
        gate(args.out_prefix, catalog, args.households, args.days)
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
        variant = None
        if args.variant == "churn_bounded":
            variant = {"name": "churn_bounded", "band": args.band if args.band is not None else 2.0}
        elif args.variant == "shrunk":
            variant = {"name": "shrunk", "k": args.k if args.k is not None else 4.0}
        n = regenerate(
            args.out,
            catalog,
            args.seed,
            household=args.household,
            sim_households=args.sim_households,
            pool_mode=args.pool_mode,
            variant=variant,
        )
        print(f"wrote {n} fixtures to {args.out}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
