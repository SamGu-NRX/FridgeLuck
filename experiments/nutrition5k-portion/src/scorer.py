"""Metrics for portion estimation, with plate-level (cluster) bootstrap CIs.

Definitions (frozen before the test run; see FROZEN_CONFIG.json):

- MAE      mean(|y_hat - y|) over evaluated plates. Units: g (mass), kcal (energy).
- nMAE     sum(|y_hat - y|) / sum(y) over evaluated plates -- the official
           Nutrition5k "MAE_%" divided by 100 (compute_eval_statistics.py).
           This is a NORMALIZED MAE, not a MAPE; no per-plate percentage
           averaging is involved.
- bias     mean(y_hat - y); norm_bias = mean(y_hat - y) / mean(y).
- abs-err quantiles p50 / p90 over evaluated plates.
- rel-err  |y_hat - y| / y for y > 0 only; p50 / p90 reported.
- coverage fraction of evaluated plates with rel-err <= tol for tol in
           {0.10, 0.25, 0.50}; mass additionally with absolute error <=
           {25, 50, 100} g. Bands were declared before the test run.
- zero targets: y == 0 plates are kept in MAE / bias / nMAE, excluded from
           rel-err and coverage (undefined), and counted in `n_zero`.

Uncertainty: cluster bootstrap -- resample plate groups (plate_cluster ids)
with replacement B times; all rows of a group move together, so repeated
views of one physical plate never separate. 95% percentile intervals.
"""

from __future__ import annotations

from typing import Callable

import numpy as np

REL_TOLS = (0.10, 0.25, 0.50)
MASS_ABS_TOLS = (25.0, 50.0, 100.0)
BOOTSTRAP_B = 2000
SEED = 20261009


def _clean(y: np.ndarray, yhat: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    y = np.asarray(y, dtype=float)
    yhat = np.asarray(yhat, dtype=float)
    m = np.isfinite(y) & np.isfinite(yhat)
    return y[m], yhat[m]


def point_metrics(y: np.ndarray, yhat: np.ndarray) -> dict:
    y, yhat = _clean(y, yhat)
    n = y.size
    err = yhat - y
    abs_err = np.abs(err)
    rel_err = abs_err[y > 0] / y[y > 0]
    out = {
        "n": int(n),
        "n_zero": int((y <= 0).sum()),
        "mae": float(abs_err.mean()) if n else float("nan"),
        "nmae": float(abs_err.sum() / y.sum()) if y.sum() > 0 else float("nan"),
        "bias": float(err.mean()) if n else float("nan"),
        "norm_bias": float(err.mean() / y.mean()) if n and y.mean() != 0 else float("nan"),
        "abs_err_p50": float(np.percentile(abs_err, 50)) if n else float("nan"),
        "abs_err_p90": float(np.percentile(abs_err, 90)) if n else float("nan"),
        "rel_err_p50": float(np.percentile(rel_err, 50)) if rel_err.size else float("nan"),
        "rel_err_p90": float(np.percentile(rel_err, 90)) if rel_err.size else float("nan"),
    }
    for tol in REL_TOLS:
        out[f"coverage_rel_{int(tol*100)}pct"] = (
            float((rel_err <= tol).mean()) if rel_err.size else float("nan")
        )
    return out


def mass_extra_coverage(y: np.ndarray, yhat: np.ndarray) -> dict:
    y, yhat = _clean(y, yhat)
    abs_err = np.abs(yhat - y)
    return {
        f"coverage_abs_{int(t)}g": float((abs_err <= t).mean()) if y.size else float("nan")
        for t in MASS_ABS_TOLS
    }


def cluster_bootstrap_indices(
    clusters: np.ndarray, B: int = BOOTSTRAP_B, seed: int = SEED
) -> list[np.ndarray]:
    """B index-resamples at the plate-group level (rows of one cluster move together)."""
    clusters = np.asarray(clusters)
    uniq = np.unique(clusters)
    by_cluster = [np.where(clusters == c)[0] for c in uniq]
    rng = np.random.default_rng(seed)
    draws = []
    for _ in range(B):
        pick = rng.integers(0, len(uniq), size=len(uniq))
        draws.append(np.concatenate([by_cluster[i] for i in pick]))
    return draws


def bootstrap_ci(
    y: np.ndarray,
    yhat: np.ndarray,
    clusters: np.ndarray,
    stat: Callable[[np.ndarray, np.ndarray], float],
    B: int = BOOTSTRAP_B,
    seed: int = SEED,
) -> tuple[float, float]:
    y, yhat, clusters = (
        np.asarray(y, dtype=float),
        np.asarray(yhat, dtype=float),
        np.asarray(clusters),
    )
    ok = np.isfinite(y) & np.isfinite(yhat)
    y, yhat, clusters = y[ok], yhat[ok], clusters[ok]
    draws = cluster_bootstrap_indices(clusters, B=B, seed=seed)
    stats = []
    for idx in draws:
        val = stat(y[idx], yhat[idx])
        if np.isfinite(val):
            stats.append(val)
    lo, hi = np.percentile(stats, [2.5, 97.5])
    return float(lo), float(hi)


def full_metrics(y: np.ndarray, yhat: np.ndarray, clusters: np.ndarray, mass: bool = False) -> dict:
    """Point metrics plus 95% cluster-bootstrap CIs for the headline numbers."""
    out = point_metrics(y, yhat)
    if mass:
        out.update(mass_extra_coverage(y, yhat))
    pairs = {
        "mae": lambda a, b: np.abs(b - a).mean() if a.size else float("nan"),
        "nmae": lambda a, b: np.abs(b - a).sum() / a.sum() if a.sum() > 0 else float("nan"),
        "bias": lambda a, b: (b - a).mean() if a.size else float("nan"),
    }
    for name, stat in pairs.items():
        lo, hi = bootstrap_ci(y, yhat, clusters, stat)
        out[f"{name}_ci95"] = [lo, hi]
    return out
