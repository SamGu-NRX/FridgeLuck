"""Fit portion models on official-train plates and select on the dev carve.

Protocol (frozen before the test run):
- Fit only on my_split == "train" plates (a plate-cluster-clean 85% of the
  official rgb_train pool); implausible targets are excluded from fitting.
- Model selection uses ONLY the dev carve (my_split == "dev"); no official-test
  plate is touched here.
- The chosen estimator per (family, target) is refit on train+dev and written
  to models.joblib; every choice is recorded in FROZEN_CONFIG.json.

Arms:
  median     -- per-target median of the training set (no features).
  rgb        -- 134 handcrafted RGB features (Ridge vs HistGradientBoosting).
  rgbd       -- RGB + 12 raw-depth features, fit/evaluated on plates with depth.
  foodlist   -- PRIVILEGED: ingredient-name multi-hot (information a meal
                photo does not contain). Labeled privileged everywhere.

Energy/mass targets: total_calories_kcal (kcal) and total_mass_g (grams),
modeled as separate regressions.
"""

from __future__ import annotations

import csv
import json
import sys
from collections import Counter
from pathlib import Path

import joblib
import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.linear_model import RidgeCV
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from build_dataset import CAL_PLAUSIBLE_KCAL, MASS_PLAUSIBLE_G, SEED  # noqa: E402

WORK = Path("/home/user/work/n5k-data")
EXPERIMENT = Path(__file__).resolve().parents[1]
OUT = EXPERIMENT / "outputs"

ALPHAS = np.logspace(-2, 4, 13)
HGBR_KWARGS = dict(
    loss="absolute_error",
    learning_rate=0.05,
    max_iter=400,
    max_leaf_nodes=31,
    l2_regularization=1.0,
    early_stopping=True,
    n_iter_no_change=15,
    validation_fraction=0.1,
    random_state=SEED,
)


def make_ridge() -> Pipeline:
    return Pipeline(
        [
            ("imp", SimpleImputer(strategy="median")),
            ("sc", StandardScaler()),
            ("m", RidgeCV(alphas=ALPHAS, cv=5)),
        ]
    )


def make_hgbr() -> HistGradientBoostingRegressor:
    return HistGradientBoostingRegressor(**HGBR_KWARGS)


def load_table() -> list[dict]:
    with (EXPERIMENT / "data" / "dish_targets.csv").open() as fh:
        return list(csv.DictReader(fh))


def main() -> int:
    data = np.load(WORK / "features.npz", allow_pickle=False)
    dish_ids = [str(d) for d in data["dish_ids"]]
    rgb = data["rgb"]
    depth = data["depth"]
    has_depth = ~np.isnan(depth[:, 0])
    id_to_idx = {d: i for i, d in enumerate(dish_ids)}

    rows = load_table()
    split = {r["dish_id"]: r["my_split"] for r in rows}
    mass = {r["dish_id"]: float(r["total_mass_g"]) for r in rows}
    cal = {r["dish_id"]: float(r["total_calories_kcal"]) for r in rows}
    ingredients = {
        r["dish_id"]: (r["ingredient_names"].split("|") if r["ingredient_names"] else [])
        for r in rows
    }

    train_ids = [d for d in dish_ids if split[d] == "train"]
    dev_ids = [d for d in dish_ids if split[d] == "dev"]
    train_dev_ids = [d for d in dish_ids if split[d] in ("train", "dev")]

    # Privileged food-list vocabulary: training names only (top 400 by frequency).
    freq = Counter(n for d in train_ids for n in ingredients[d])
    vocab = [name for name, _ in freq.most_common(400)]

    def foodlist_matrix(ids: list[str]) -> np.ndarray:
        m = np.zeros((len(ids), len(vocab) + 2))
        name_to_col = {n: j for j, n in enumerate(vocab)}
        for i, d in enumerate(ids):
            for n in ingredients[d]:
                if n in name_to_col:
                    m[i, name_to_col[n]] = 1.0
            m[i, -2] = m[i, : len(vocab)].sum()
            m[i, -1] = len(ingredients[d])
        return m

    fit_pools = {
        "rgb": train_ids,
        "rgbd": [d for d in train_ids if has_depth[id_to_idx[d]]],
        "foodlist": train_ids,
    }
    dev_pools = {
        "rgb": dev_ids,
        "rgbd": [d for d in dev_ids if has_depth[id_to_idx[d]]],
        "foodlist": dev_ids,
    }

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
        "mass_g": lambda d: mass[d],
        "energy_kcal": lambda d: cal[d],
    }
    plausible = {
        "mass_g": lambda d: 0 < mass[d] <= MASS_PLAUSIBLE_G,
        "energy_kcal": lambda d: 0 < cal[d] <= CAL_PLAUSIBLE_KCAL,
    }

    dev_records = []
    models: dict[tuple[str, str], dict] = {}
    medians: dict[str, float] = {}

    for tname, getter in targets.items():
        tvals = np.array([getter(d) for d in train_ids])
        plaus = np.array([plausible[tname](d) for d in train_ids])
        medians[tname] = float(np.median(tvals[plaus]))
        dev_records.append(
            {"arm": "median", "estimator": "constant", "target": tname,
             "fit_n": int(plaus.sum()), "dev_mae": "", "note": "fit on my-train median"}
        )

    for family in ("rgb", "rgbd", "foodlist"):
        for tname, getter in targets.items():
            fit_use = [d for d in fit_pools[family] if plausible[tname](d)]
            Xf = X_for(family, fit_use)
            yf = np.array([getter(d) for d in fit_use])
            dev_use = list(dev_pools[family])  # dev keeps implausible rows (mirrors test)
            Xd = X_for(family, dev_use)
            yd = np.array([getter(d) for d in dev_use])
            best = None
            for est_name, mk in (("ridge", make_ridge), ("hgbr", make_hgbr)):
                m = mk()
                m.fit(Xf, yf)
                pred_dev = np.clip(m.predict(Xd), 0.0, None)
                dev_mae = float(np.abs(pred_dev - yd).mean())
                dev_records.append(
                    {"arm": family, "estimator": est_name, "target": tname,
                     "fit_n": int(len(fit_use)), "dev_mae": dev_mae, "note": ""}
                )
                if best is None or dev_mae < best[0]:
                    best = (dev_mae, est_name)
            # Refit the chosen estimator on train+dev (still no test data).
            final_ids = [d for d in train_dev_ids if plausible[tname](d)]
            pool_for_family = (
                [d for d in final_ids if has_depth[id_to_idx[d]]] if family == "rgbd" else final_ids
            )
            m_final = (make_ridge if best[1] == "ridge" else make_hgbr)()
            m_final.fit(X_for(family, pool_for_family), np.array([getter(d) for d in pool_for_family]))
            models[(family, tname)] = {
                "estimator": best[1],
                "model": m_final,
                "dev_mae": best[0],
                "final_fit_n": len(pool_for_family),
                "dev_eval_n": len(dev_use),
            }
            print(f"selected {family}/{tname}: {best[1]} (dev MAE {best[0]:.2f})", flush=True)

    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "dev_metrics.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["arm", "estimator", "target", "fit_n", "dev_mae", "note"])
        w.writeheader()
        w.writerows(dev_records)

    joblib.dump(
        {"models": {f"{k[0]}::{k[1]}": v for k, v in models.items()},
         "medians": medians, "vocab": vocab},
        WORK / "models.joblib",
    )

    frozen = {
        "frozen_before_test_run": True,
        "seed": SEED,
        "view_policy": "single calibrated overhead realsense frame (rgb.png; + depth_raw.png for the rgbd arm); side-angle videos unused",
        "targets": {
            "mass_g": {"unit": "grams", "plausible_range": [0, MASS_PLAUSIBLE_G], "fit_exclusions": "outside range"},
            "energy_kcal": {"unit": "kcal", "plausible_range": [0, CAL_PLAUSIBLE_KCAL], "fit_exclusions": "outside range"},
        },
        "arms": {
            "median": {"kind": "baseline", "train_medians": medians},
            "rgb": {"features": "134 handcrafted RGB", "candidates": ["ridge", "hgbr"]},
            "rgbd": {"features": "134 RGB + 12 depth", "candidates": ["ridge", "hgbr"],
                     "note": "fit and evaluated only where raw depth exists (official depth split)"},
            "foodlist": {"features": f"multi-hot of {len(vocab)} train-vocab ingredient names + count + n_ingredients",
                         "candidates": ["ridge", "hgbr"], "privileged": True,
                         "privileged_reason": "requires the ingredient list, which a meal photo does not contain"},
        },
        "estimators": {"ridge": {"alphas_logspace": [-2, 4, 13], "cv": 5, "imputer": "median", "scaler": "standard"},
                       "hgbr": HGBR_KWARGS},
        "selection_rule": "per (family, target): lowest dev MAE; refit chosen estimator on train+dev",
        "splits": {"official": "rgb_train/rgb_test + depth_train/depth_test from the nutrition5k_dataset bucket",
                   "dev": "plate clusters carved from official rgb_train (seed 20261009); clusters straddling official splits excluded from dev"},
        "scoring": {"nmae": "sum|err|/sum(y); NOT MAPE", "rel_tols": [0.10, 0.25, 0.50],
                    "mass_abs_tols_g": [25, 50, 100],
                    "zero_targets": "kept in MAE/bias/nMAE; excluded from rel-err and coverage; counted",
                    "bootstrap": {"type": "cluster (plate) level", "B": 2000, "seed": SEED}},
        "vision_endpoint": {"model_default": "gemini-2.5-flash",
                            "budget_declared": {"max_images": 250, "spend_ceiling_usd": 2.0},
                            "status": "NOT EXECUTED - no GEMINI_API_KEY / Vertex credentials in the environment",
                            "note": "reported separately from local arms when run"},
    }
    (EXPERIMENT / "FROZEN_CONFIG.json").write_text(json.dumps(frozen, indent=2))
    print("FROZEN_CONFIG.json + models.joblib written", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
