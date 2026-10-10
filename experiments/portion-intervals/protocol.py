"""Interval-method protocol: declared nominal levels, quantiles, conformal machinery.

NOMINAL_LEVELS.json is committed in Milestone 1, BEFORE any test-set scoring
(the git history is the declaration record); evaluate.py refuses to run
without it. All calibration here uses development data only -- official-test
predictions are consumed read-only for scoring, never for choosing widths or
levels.

Definitions fixed here (mirroring the locked scorer's conventions where they
overlap):

- empirical_quantile  linear-interpolation quantile (type 7, numpy default),
                      used by the development-residual method with NO
                      finite-sample correction (that absence is part of what
                      distinguishes it from split conformal).
- conformal_quantile  split-conformal order statistic ceil((n+1)*level) of n
                      calibration scores; returns +inf when the level is not
                      achievable with n points (calibration set too small) --
                      callers must surface that, never silently widen.
- Grouped split conformal
                      dev plate CLUSTERS are the exchangeable units: the
                      calibration half is drawn at the cluster level with a
                      seed, cluster score = mean |residual| within the
                      cluster, and the finite-sample correction counts
                      clusters. Rows of one physical plate never separate.
- Eligibility         mirrors the locked policy: zero targets (y <= 0) and
                      implausible targets (outside (0, cap]) are excluded
                      from calibration pools and counted, never deleted.
"""

from __future__ import annotations

import json
import math
import random
from collections import defaultdict
from pathlib import Path

LEVELS_FILE = Path(__file__).resolve().parent / "NOMINAL_LEVELS.json"


def load_nominal_levels(path: Path = LEVELS_FILE) -> dict:
    """Load the declared-before-scoring protocol file; refuse incomplete files."""
    data = json.loads(Path(path).read_text())
    if not data.get("declared_before_test_scoring"):
        raise ValueError("NOMINAL_LEVELS.json must set declared_before_test_scoring=true")
    levels = data["nominal_levels"]
    if not levels or not all(0.0 < float(v) < 1.0 for v in levels):
        raise ValueError(f"nominal_levels must be non-empty and inside (0,1): {levels!r}")
    if len(set(levels)) != len(levels):
        raise ValueError(f"nominal_levels must be distinct: {levels!r}")
    data["nominal_levels"] = [float(v) for v in levels]
    for tgt, widths in data["fixed_widths"].items():
        if not widths or not all(float(w) > 0 for w in widths):
            raise ValueError(f"fixed_widths[{tgt}] must be positive: {widths!r}")
    frac = float(data["conformal_calibration_fraction"])
    if not 0.0 < frac < 1.0:
        raise ValueError(f"conformal_calibration_fraction out of range: {frac!r}")
    return data


def empirical_quantile(sorted_vals: list[float], q: float) -> float:
    """Linear-interpolation empirical quantile of an ASCENDING, non-empty list."""
    n = len(sorted_vals)
    if n == 0:
        raise ValueError("empty sample")
    if not 0.0 <= q <= 1.0:
        raise ValueError(f"q out of range: {q!r}")
    if n == 1:
        return float(sorted_vals[0])
    pos = q * (n - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return float(sorted_vals[lo])
    frac = pos - lo
    return float(sorted_vals[lo]) * (1.0 - frac) + float(sorted_vals[hi]) * frac


def conformal_quantile(scores_sorted: list[float], level: float) -> float:
    """Split-conformal quantile with the finite-sample correction.

    Order statistic ceil((n+1)*level) of the n ascending calibration scores.
    Returns +inf when ceil((n+1)*level) > n: the level is not achievable with
    n calibration points, and the caller must report that rather than widen.
    """
    n = len(scores_sorted)
    if n == 0:
        raise ValueError("empty calibration scores")
    if not 0.0 < level < 1.0:
        raise ValueError(f"level out of range: {level!r}")
    k = math.ceil((n + 1) * level)
    if k > n:
        return math.inf
    return float(scores_sorted[k - 1])


def eligible_calibration_rows(dev_rows: list[dict], target_spec: dict) -> tuple[list[dict], dict]:
    """Split dev rows into an eligible calibration pool and exclusion counts.

    Mirrors the locked policy: rows with zero (y <= 0) or implausible
    (outside (lo, hi]) target values are excluded from calibration and
    counted -- never deleted from the underlying data.
    """
    lo, hi = target_spec["lo_exclusive"], target_spec["hi_inclusive"]
    col = target_spec["targets_column"]
    eligible = []
    n_zero = 0
    n_implausible = 0
    for r in dev_rows:
        y = float(r[col])
        if y <= 0:
            n_zero += 1
        elif not (lo < y <= hi):
            n_implausible += 1
        else:
            eligible.append(r)
    counts = {"n_dev_rows": len(dev_rows), "n_zero_excluded": n_zero, "n_implausible_excluded": n_implausible, "n_eligible": len(eligible)}
    return eligible, counts


def dev_residual_widths(dev_rows: list[dict], target_spec: dict, pred_value: float, levels: list[float]) -> tuple[dict[float, float], dict]:
    """Development-residual widths: empirical |y - pred| quantiles over ALL eligible dev rows.

    pred_value is the dev-time prediction; for the median arm it is the frozen
    constant (the only arm whose dev predictions are derivable from committed
    artifacts). Returns ({level: width}, eligibility counts).
    """
    eligible, counts = eligible_calibration_rows(dev_rows, target_spec)
    col = target_spec["targets_column"]
    scores = sorted(abs(float(r[col]) - pred_value) for r in eligible)
    widths = {level: empirical_quantile(scores, level) for level in levels}
    counts["calibration_records"] = len(scores)
    counts["calibration_clusters"] = len({r["plate_cluster"] for r in eligible})
    return widths, counts


def split_cluster_calibration(dev_rows: list[dict], target_spec: dict, predict_fn, calibration_fraction: float, seed: int) -> tuple[dict[str, float], dict]:
    """Grouped split-conformal calibration over dev plate clusters.

    Clusters are the exchangeable units: a seeded half of dev clusters forms
    the calibration pool (the rest is a holdout -- grouped, so no plate spans
    both sides), each cluster's score is the mean |y - pred| of its rows, and
    the conformal quantile counts clusters. Returns (cluster_id -> score,
    counts dict).
    """
    eligible, counts = eligible_calibration_rows(dev_rows, target_spec)
    col = target_spec["targets_column"]
    by_cluster: dict[str, list[float]] = defaultdict(list)
    for r in eligible:
        pred = predict_fn(r)
        by_cluster[r["plate_cluster"]].append(abs(float(r[col]) - pred))
    cluster_ids = sorted(by_cluster)
    rng = random.Random(seed)
    rng.shuffle(cluster_ids)
    k = round(len(cluster_ids) * calibration_fraction)
    cal_ids = set(cluster_ids[:k])
    scores = {c: sum(by_cluster[c]) / len(by_cluster[c]) for c in sorted(cal_ids)}
    counts["calibration_clusters"] = len(cal_ids)
    counts["holdout_clusters"] = len(cluster_ids) - len(cal_ids)
    counts["calibration_records"] = sum(len(by_cluster[c]) for c in cal_ids)
    counts["holdout_records"] = len(eligible) - counts["calibration_records"]
    return scores, counts


def conformal_width(cluster_scores: dict[str, float], level: float) -> float:
    """Conformal half-width from cluster-level scores (+inf if unachievable)."""
    return conformal_quantile(sorted(cluster_scores.values()), level)


def stratum_label(cluster_size: int) -> str:
    """Available plate strata on the scored set: singleton vs multi-dish plate."""
    return "size1" if cluster_size <= 1 else "size_ge2"


def coverage_stats(records: list[dict], level: float | None) -> dict:
    """Coverage / width / undercoverage over records with 'covered' and 'width'.

    undercoverage = level - coverage (positive: fewer intervals contain the
    truth than promised). level=None (fixed widths) leaves undercoverage None.
    """
    n = len(records)
    if n == 0:
        return {"n_eval": 0, "coverage": None, "mean_width": None, "median_width": None, "undercoverage": None}
    covered = sum(1 for r in records if r["covered"])
    widths = sorted(float(r["width"]) for r in records)
    cov = covered / n
    return {
        "n_eval": n,
        "coverage": cov,
        "mean_width": sum(widths) / n,
        "median_width": empirical_quantile(widths, 0.5),
        "undercoverage": (level - cov) if level is not None else None,
    }
