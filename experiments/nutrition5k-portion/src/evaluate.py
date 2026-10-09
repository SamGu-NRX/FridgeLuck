"""One-shot test evaluation of all frozen arms, with uncertainty and cross-checks.

Populations:
  rgb_test          official rgb_test plates with overhead rgb.png (= the 507
                    official depth_test plates; the 202 rgb_test dishes without
                    overhead imagery cannot be evaluated in any imagery arm)
  depth_test        identical plate set -- rgb and rgbd arms are compared
                    head-to-head on exactly the same dishes
  rgb_test_plausible sensitivity view: rgb_test minus implausible targets

Outputs (committed):
  outputs/estimates_test.csv        per-plate predictions for every arm
  outputs/metrics_test.csv          point metrics + 95% plate-level bootstrap CIs
  outputs/bootstrap_draws.csv       raw bootstrap draws (mass & energy MAE)
  outputs/official_format_predictions.csv + official_eval_crosscheck.json
                                    predictions scored by the OFFICIAL
                                    compute_eval_statistics.py for definition parity
"""

from __future__ import annotations

import csv
import json
import subprocess
import sys
import time
from pathlib import Path

import joblib
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import scorer  # noqa: E402
from build_dataset import CAL_PLAUSIBLE_KCAL, MASS_PLAUSIBLE_G  # noqa: E402

WORK = Path("/home/user/work/n5k-data")
EXPERIMENT = Path(__file__).resolve().parents[1]
OUT = EXPERIMENT / "outputs"
RAW = Path("/home/user/work/n5k-data/raw")


def main() -> int:
    frozen = json.loads((EXPERIMENT / "FROZEN_CONFIG.json").read_text())
    assert frozen["frozen_before_test_run"] is True
    bundle = joblib.load(WORK / "models.joblib")
    models, medians, vocab = bundle["models"], bundle["medians"], bundle["vocab"]

    data = np.load(WORK / "features.npz", allow_pickle=False)
    dish_ids = [str(d) for d in data["dish_ids"]]
    rgb, depth = data["rgb"], data["depth"]
    has_depth = ~np.isnan(depth[:, 0])
    id_to_idx = {d: i for i, d in enumerate(dish_ids)}

    rows = list(csv.DictReader((EXPERIMENT / "data" / "dish_targets.csv").open()))
    meta = {r["dish_id"]: r for r in rows}
    ingredients = {
        r["dish_id"]: (r["ingredient_names"].split("|") if r["ingredient_names"] else [])
        for r in rows
    }

    def foodlist_matrix(ids: list[str]) -> np.ndarray:
        m = np.zeros((len(ids), len(vocab) + 2))
        col = {n: j for j, n in enumerate(vocab)}
        for i, d in enumerate(ids):
            for n in ingredients[d]:
                if n in col:
                    m[i, col[n]] = 1.0
            m[i, -2] = m[i, : len(vocab)].sum()
            m[i, -1] = len(ingredients[d])
        return m

    def X_for(family: str, ids: list[str]) -> np.ndarray:
        idx = np.array([id_to_idx[d] for d in ids])
        if family == "rgb":
            return rgb[idx]
        if family == "rgbd":
            return np.hstack([rgb[idx], depth[idx]])
        if family == "foodlist":
            return foodlist_matrix(ids)
        raise ValueError(family)

    targets = {
        "mass_g": ("total_mass_g", "mass"),
        "energy_kcal": ("total_calories_kcal", "energy"),
    }

    rgb_test = [d for d in dish_ids if meta[d]["my_split"] == "test"]
    depth_test = [
        d for d in rgb_test
        if meta[d]["official_depth_split"] == "test" and has_depth[id_to_idx[d]]
    ]
    plausible_test = [
        d for d in rgb_test
        if 0 < float(meta[d]["total_mass_g"]) <= MASS_PLAUSIBLE_G
        and 0 < float(meta[d]["total_calories_kcal"]) <= CAL_PLAUSIBLE_KCAL
    ]
    populations = {
        "rgb_test": (rgb_test, ["median", "rgb", "foodlist"]),
        "rgb_test_plausible": (plausible_test, ["median", "rgb", "foodlist"]),
        "depth_test": (depth_test, ["median", "rgb", "rgbd", "foodlist"]),
    }

    # Per-plate local predict latency (single rows, after an untimed warm-up).
    lat: dict[str, float] = {}
    warm = rgb_test[:10]
    for family in ("rgb", "foodlist"):
        if f"{family}::mass_g" not in models:
            continue
        Xw = X_for(family, warm)
        for tname in targets:
            models[f"{family}::{tname}"]["model"].predict(Xw)
    for family in ("rgb", "foodlist"):
        if f"{family}::mass_g" not in models:
            continue
        Xs = X_for(family, rgb_test[:200])
        for tname in targets:
            m = models[f"{family}::{tname}"]["model"]
            t0 = time.time()
            for i in range(Xs.shape[0]):
                m.predict(Xs[i : i + 1])
            lat[f"{family}::{tname}"] = round((time.time() - t0) * 1000 / Xs.shape[0], 2)

    est_rows = []
    metric_rows = []
    boot_draws = []
    for pop, (ids, arms) in populations.items():
        for tname, (col, kind) in targets.items():
            y = np.array([float(meta[d][col]) for d in ids])
            clusters = np.array([meta[d]["plate_cluster"] for d in ids])
            for arm in arms:
                key = f"{arm}::{tname}"
                if arm == "median":
                    pred = np.full(len(ids), medians[tname])
                else:
                    entry = models.get(key)
                    if entry is None:
                        continue
                    pred = np.clip(entry["model"].predict(X_for(arm, ids)), 0.0, None)
                for d, p in zip(ids, pred):
                    est_rows.append(
                        {"dish_id": d, "plate_cluster": meta[d]["plate_cluster"],
                         "population": pop, "arm": arm, "target": tname,
                         "y_true": float(meta[d][col]), "y_pred": round(float(p), 4)}
                    )
                mtr = scorer.full_metrics(y, pred, clusters, mass=(kind == "mass"))
                mtr.update({"population": pop, "arm": arm, "target": tname,
                            "predict_ms_per_plate": lat.get(key, "")})
                metric_rows.append(mtr)
                for bi, idx in enumerate(
                    scorer.cluster_bootstrap_indices(clusters, B=scorer.BOOTSTRAP_B, seed=scorer.SEED)
                ):
                    boot_draws.append(
                        {"population": pop, "arm": arm, "target": tname, "draw": bi,
                         "mae": float(np.abs(pred[idx] - y[idx]).mean())}
                    )

    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "estimates_test.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["dish_id", "plate_cluster", "population", "arm",
                                           "target", "y_true", "y_pred"])
        w.writeheader()
        w.writerows(est_rows)

    fixed = ["population", "arm", "target"]
    cols = sorted({k for r in metric_rows for k in r} - set(fixed))
    with (OUT / "metrics_test.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fixed + cols)
        w.writeheader()
        for r in metric_rows:
            w.writerow({k: (json.dumps(v) if isinstance(v, (list, tuple)) else v) for k, v in r.items()})

    with (OUT / "bootstrap_draws.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["population", "arm", "target", "draw", "mae"])
        w.writeheader()
        w.writerows(boot_draws)

    # Official-script cross-check: score rgb-arm predictions with the dataset's
    # own compute_eval_statistics.py to prove metric-definition parity.
    pred_by_dish = {(e["dish_id"], e["target"]): e["y_pred"] for e in est_rows
                    if e["population"] == "rgb_test" and e["arm"] == "rgb"}
    official_pred = OUT / "official_format_predictions.csv"
    official_gt = OUT / "official_format_groundtruth.csv"
    with official_pred.open("w", newline="") as fh:
        w = csv.writer(fh)
        for d in rgb_test:
            # macros not modeled: constant placeholders on both sides ONLY so the
            # official script runs (its MAE_% divides by the ground-truth mean of
            # every field); calories+mass columns are the compared values.
            w.writerow([d, pred_by_dish[(d, "energy_kcal")], pred_by_dish[(d, "mass_g")], 20, 20, 20])
    with official_gt.open("w", newline="") as fh:
        w = csv.writer(fh)
        for d in rgb_test:
            r = meta[d]
            w.writerow([d, r["total_calories_kcal"], r["total_mass_g"], 20, 20, 20])
    script = RAW / "compute_eval_statistics.py"
    if script.exists():
        res = subprocess.run(
            [sys.executable, str(script), str(official_gt), str(official_pred),
             str(OUT / "official_eval_crosscheck.json")],
            capture_output=True, text=True,
        )
        (OUT / "official_eval_crosscheck.stderr.txt").write_text(res.stderr)
        if res.returncode == 0:
            print("official cross-check:", (OUT / "official_eval_crosscheck.json").read_text()[:800])
        else:
            print("official cross-check FAILED:", res.stderr[-500:])

    print("EVALUATION COMPLETE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
