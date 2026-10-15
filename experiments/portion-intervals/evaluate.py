#!/usr/bin/env python3
"""Interval-method evaluation over PR41's frozen portion-estimation outputs.

Run from the repository root:
    python3 experiments/portion-intervals/evaluate.py \
        --seed 20261010 --out experiments/portion-intervals/results

Read-only w.r.t. experiments/nutrition5k-portion. Refuses to run without the
declared protocol (NOMINAL_LEVELS.json, committed BEFORE any test scoring).

Arms. All calibration uses development rows only. Per-record development
predictions were never committed by PR41, so an interval method that needs
them can run only for the median estimator, whose predictions ARE the frozen
constants:

- dev_residual  empirical |y - pred| quantiles over ALL eligible dev rows,
                NO finite-sample correction (expected to undercover on test;
                that is the measured finding, not a bug).
- split_conformal  grouped cluster-level split conformal on dev plate
                clusters (seeded split, cluster score = mean |residual|,
                (n+1) correction counting clusters).
- fixed_width   absolute half-widths from the declared grid; no nominal
                level (undercoverage is None by construction).
- rgb / foodlist / rgbd conformal + dev-residual arms: UNAVAILABLE --
                dev predictions for those estimators were never committed;
                reported as such, never fabricated.

Scoring. Two-sided interval [pred - w, pred + w]; covered iff lo <= y <= hi.
Zero-truth dishes are excluded from coverage denominators and counted.
Populations follow the committed estimates file (rgb_test, depth_test,
rgb_test_plausible) plus the rgb_test_straddle_excluded sensitivity
population, which removes the two inherited official-split-straddling test
dishes (see reader.cluster_straddle_details).
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import reader  # noqa: E402
import protocol  # noqa: E402

REPO = HERE.parents[1]
N5K = REPO / "experiments" / "nutrition5k-portion"

STRADDLE_TEST_DISHES = {
    "dish_1558641200",
    "dish_1559844490",
}  # inherited official-split straddles; see reader.cluster_straddle_details

CLUSTER_SIZE: dict[str, int] = {}


def point_metrics(estimate_rows: list[dict]) -> dict:
    """MAE / RMSE / median abs error per (population, arm, target)."""
    groups: dict[tuple, list[float]] = defaultdict(list)
    for r in estimate_rows:
        groups[(r["population"], r["arm"], r["target"])].append(abs(r["y_pred"] - r["y_true"]))
    out = {}
    for key in sorted(groups):
        errs = sorted(groups[key])
        n = len(errs)
        out["|".join(key)] = {
            "n": n,
            "mae": sum(errs) / n,
            "rmse": (sum(e * e for e in errs) / n) ** 0.5,
            "median_abs_error": protocol.empirical_quantile(errs, 0.5),
        }
    return out


def build_widths(target_rows: list[dict], frozen: dict, levels_cfg: dict, seed: int) -> tuple[dict, dict]:
    """Width schedules per method arm. Returns (arms, arm_status).

    arms: method -> target -> {label -> half-width}; label is the nominal
    level for calibrated methods, the half-width itself for fixed widths.
    arm_status: method key -> {"status": "ok"|"unavailable", ...}.
    """
    levels = [float(v) for v in levels_cfg["nominal_levels"]]
    conformal_fraction = float(levels_cfg["conformal_calibration_fraction"])
    arms: dict = defaultdict(dict)
    status: dict = {}
    dev_rows = [r for r in target_rows if r["my_split"] == "dev"]

    # Median estimator: dev predictions are the frozen constants, so dev
    # residuals ARE derivable from committed artifacts.
    medians = frozen["arms"]["median"]["train_medians"]
    status["dev_residual"] = {"status": "ok", "dev_counts": {}}
    status["split_conformal"] = {"status": "ok", "dev_counts": {}}
    for tgt, spec in reader.TARGETS.items():
        pred = float(medians[tgt])
        widths, counts = protocol.dev_residual_widths(dev_rows, spec, pred, levels)
        arms["dev_residual"][tgt] = {str(level): w for level, w in widths.items()}
        status["dev_residual"]["dev_counts"][tgt] = counts

        cluster_scores, counts2 = protocol.split_cluster_calibration(
            dev_rows, spec, lambda r, p=pred: p, conformal_fraction, seed
        )
        arms["split_conformal"][tgt] = {
            str(level): protocol.conformal_width(cluster_scores, level) for level in levels
        }
        status["split_conformal"]["dev_counts"][tgt] = counts2
        status["split_conformal"][f"n_calibration_clusters_{tgt}"] = len(cluster_scores)

    # Image estimators: PR41 never committed per-record development
    # predictions for them, so calibrated intervals are unavailable.
    for arm in ("rgb", "foodlist", "rgbd"):
        reason = (
            f"PR41 commits no per-record development predictions for the {arm} "
            "estimator (test-only estimates, aggregate dev metrics, and no "
            "fitted model artifact), so calibration scores cannot be derived "
            "without re-fitting the owned model, which this study refuses to do."
        )
        status[f"dev_residual[{arm}]"] = {"status": "unavailable", "reason": reason}
        status[f"split_conformal[{arm}]"] = {"status": "unavailable", "reason": reason}

    # Fixed absolute half-widths from the declared grid: no calibration needed.
    arms["fixed_width"] = {
        tgt: {str(w): float(w) for w in widths}
        for tgt, widths in levels_cfg["fixed_widths"].items()
    }
    status["fixed_width"] = {"status": "ok", "note": "no nominal level; undercoverage is None"}

    return dict(arms), status


def score_intervals(estimate_rows: list[dict], arms: dict, levels: list[float]) -> list[dict]:
    """Per-record interval scoring across populations / estimator arms / methods / targets."""
    results = []
    levels = [float(v) for v in levels]
    straddle_rows = [r for r in estimate_rows if r["dish_id"] not in STRADDLE_TEST_DISHES]
    sources: dict[str, list[dict]] = {"*_all": estimate_rows, "*_straddle_excluded": straddle_rows}

    populations = sorted({r["population"] for r in estimate_rows})
    # Sensitivity population: rgb_test minus the two inherited straddle dishes.
    scored_pops = populations + ["rgb_test_straddle_excluded"]

    for pop in scored_pops:
        if pop == "rgb_test_straddle_excluded":
            rows_pop = [r for r in straddle_rows if r["population"] == "rgb_test"]
        else:
            rows_pop = [r for r in sources["*_all"] if r["population"] == pop]
        if not rows_pop:
            continue
        for estimator_arm in sorted({r["arm"] for r in rows_pop}):
            rows_arm = [r for r in rows_pop if r["arm"] == estimator_arm]
            for tgt in sorted(reader.TARGETS):
                rows_t = [r for r in rows_arm if r["target"] == tgt]
                if not rows_t:
                    continue
                # Calibrated methods exist only for the median estimator
                # (the only one with derivable dev predictions).
                methods = (
                    ["dev_residual", "split_conformal", "fixed_width"]
                    if estimator_arm == "median"
                    else ["fixed_width"]
                )
                for method in methods:
                    for label, half_width in sorted(arms[method][tgt].items(), key=lambda kv: float(kv[0])):
                        level = float(label) if method in ("dev_residual", "split_conformal") else None
                        records = []
                        n_zero_excluded = 0
                        for r in rows_t:
                            if r["y_true"] <= 0:
                                n_zero_excluded += 1
                                continue
                            lo, hi = r["y_pred"] - half_width, r["y_pred"] + half_width
                            records.append(
                                {
                                    "dish_id": r["dish_id"],
                                    "plate_cluster": r["plate_cluster"],
                                    "covered": lo <= r["y_true"] <= hi,
                                    "width": 2.0 * half_width,
                                    "stratum": protocol.stratum_label(CLUSTER_SIZE[r["plate_cluster"]]),
                                }
                            )
                        stats = protocol.coverage_stats(records, level=level)
                        by_stratum = {
                            st: protocol.coverage_stats(
                                [x for x in records if x["stratum"] == st], level=level
                            )
                            for st in ("size1", "size_ge2")
                        }
                        results.append(
                            {
                                "population": pop,
                                "estimator_arm": estimator_arm,
                                "target": tgt,
                                "method": method,
                                "width_label": label,
                                "half_width": half_width,
                                "nominal_level": level,
                                "n_zero_excluded": n_zero_excluded,
                                **stats,
                                "by_stratum": by_stratum,
                            }
                        )
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=20261010)
    ap.add_argument("--out", type=Path, default=HERE / "results")
    args = ap.parse_args()

    levels_cfg = protocol.load_nominal_levels()  # refuses undeclared files
    frozen = json.loads((N5K / "FROZEN_CONFIG.json").read_text())

    target_rows = reader.load_targets(N5K / "data" / "dish_targets.csv")
    estimate_rows = reader.load_estimates(N5K / "outputs" / "estimates_test.csv", target_rows)
    reader.split_provenance(target_rows, estimate_rows)

    # Plate-cluster sizes within the scored set (strata definition).
    for r in estimate_rows:
        CLUSTER_SIZE[r["plate_cluster"]] = CLUSTER_SIZE.get(r["plate_cluster"], 0) + 1

    arms, arm_status = build_widths(target_rows, frozen, levels_cfg, args.seed)
    results = score_intervals(estimate_rows, arms, levels_cfg["nominal_levels"])
    pm = point_metrics(estimate_rows)

    args.out.mkdir(parents=True, exist_ok=True)
    payload = {
        "experiment": "portion-intervals",
        "seed": args.seed,
        "protocol": levels_cfg,
        "arm_status": arm_status,
        "point_metrics": pm,
        "interval_results": results,
    }
    out_json = args.out / "interval_results.json"
    out_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    out_csv = args.out / "interval_summary.csv"
    cols = [
        "population", "estimator_arm", "target", "method", "width_label",
        "nominal_level", "n_eval", "n_zero_excluded", "coverage",
        "undercoverage", "mean_width", "median_width",
    ]
    with open(out_csv, "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writerow(cols)
        for r in results:
            w.writerow([
                r["population"], r["estimator_arm"], r["target"], r["method"], r["width_label"],
                "" if r["nominal_level"] is None else r["nominal_level"],
                r["n_eval"], r["n_zero_excluded"],
                "" if r["coverage"] is None else round(r["coverage"], 4),
                "" if r["undercoverage"] is None else round(r["undercoverage"], 4),
                "" if r["mean_width"] is None else round(r["mean_width"], 4),
                "" if r["median_width"] is None else round(r["median_width"], 4),
            ])

    n_unavailable = sum(1 for s in arm_status.values() if s["status"] == "unavailable")
    print(f"scored {len(results)} (population, arm, method, width) cells")
    print(f"point metrics for {len(pm)} (population, arm, target) cells")
    print(f"arms: {len(arm_status)} total, {n_unavailable} unavailable (no dev predictions committed)")
    print(f"wrote {out_json.resolve().relative_to(REPO.resolve())} and {out_csv.resolve().relative_to(REPO.resolve())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
