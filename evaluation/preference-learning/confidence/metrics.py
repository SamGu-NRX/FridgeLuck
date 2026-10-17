"""Metrics for Part 0: calibration, decision quality, stabilization, drift.

Definitions fixed in advance (mirrors PR #53's pre-declared selection rule):

- ECE: equal-width 10-bin ECE over [0,1], sample-weighted.
- Decision quality on non-hard-fail episodes:
    exact_wrong   : mode == exact and truth == 0        (worst case)
    estimate_fn   : mode == estimate_only and truth == 1 (utility loss)
    mode_error    : exact_wrong or estimate_fn
    mode_error_rate = mode_error / n
- Useful-confidence bar (pre-declared): cumulative mode error rate <= 0.25
  ("at most one extreme misroute in four") and it must stay at or below the
  bar through the end of the replay. Stabilization = the first episode where
  the cumulative rate meets the bar and never leaves it.
- Drift recovery: same bar, measured from the change point.
- Intervals: percentile bootstrap, B=1000, rng seed 20261011, documented per
  experiment; the exchange unit is the episode (reverse-meal) or the history
  (correction histories), following PR #53's seed-grouped pattern.
"""

from __future__ import annotations

import random
from math import isfinite

MODE_ERROR_BAR = 0.25
BOOTSTRAP_B = 1000
BOOTSTRAP_SEED = 20261011
N_BINS = 10


def ece(scores, truths, n_bins: int = N_BINS) -> float:
    """Equal-width binned ECE. Scores outside [0,1] are a caller bug: raise."""
    n = len(scores)
    if n == 0:
        raise ValueError("ece: no samples")
    for s in scores:
        if not (isfinite(s) and 0.0 <= s <= 1.0):
            raise ValueError(f"ece: score {s} outside [0,1]")
    total = 0.0
    for b in range(n_bins):
        lo, hi = b / n_bins, (b + 1) / n_bins
        idx = [i for i, s in enumerate(scores) if (lo <= s < hi) or (b == n_bins - 1 and s == 1.0)]
        if not idx:
            continue
        conf = sum(scores[i] for i in idx) / len(idx)
        acc = sum(truths[i] for i in idx) / len(idx)
        total += (len(idx) / n) * abs(acc - conf)
    return total


def reliability_curve(scores, truths, n_bins: int = N_BINS) -> list[dict]:
    """Per-bin count, mean score, mean truth (equal-width over [0,1])."""
    out = []
    for b in range(n_bins):
        lo, hi = b / n_bins, (b + 1) / n_bins
        idx = [i for i, s in enumerate(scores) if (lo <= s < hi) or (b == n_bins - 1 and s == 1.0)]
        out.append(
            {
                "bin": b,
                "lo": lo,
                "hi": hi,
                "count": len(idx),
                "mean_score": (sum(scores[i] for i in idx) / len(idx)) if idx else None,
                "mean_truth": (sum(truths[i] for i in idx) / len(idx)) if idx else None,
            }
        )
    return out


def brier(scores, truths) -> float:
    return sum((s - t) ** 2 for s, t in zip(scores, truths)) / len(scores)


def decision_counts(records) -> dict:
    """Mode-vs-truth counts over non-hard-fail records (see module docstring)."""
    usable = [r for r in records if not r["hard_fail"]]
    n = len(usable)
    exact_wrong = sum(1 for r in usable if r["mode"] == "exact" and r["truth"] == 0.0)
    estimate_fn = sum(1 for r in usable if r["mode"] == "estimate_only" and r["truth"] == 1.0)
    exact_right = sum(1 for r in usable if r["mode"] == "exact" and r["truth"] == 1.0)
    review = sum(1 for r in usable if r["mode"] == "review_required")
    exact_n = sum(1 for r in usable if r["mode"] == "exact")
    estimate_n = sum(1 for r in usable if r["mode"] == "estimate_only")
    return {
        "n": n,
        "exact_n": exact_n,
        "exact_right": exact_right,
        "exact_wrong": exact_wrong,
        "exact_precision": (exact_right / exact_n) if exact_n else None,
        "estimate_n": estimate_n,
        "estimate_fn": estimate_fn,
        "review_n": review,
        "mode_errors": exact_wrong + estimate_fn,
        "mode_error_rate": (exact_wrong + estimate_fn) / n if n else None,
    }


def cumulative_mode_error_rate(records) -> list[float]:
    """Cumulative mode error rate after each record (non-hard-fail only)."""
    usable = [r for r in records if not r["hard_fail"]]
    out = []
    errors = 0
    for i, r in enumerate(usable, start=1):
        if (r["mode"] == "exact" and r["truth"] == 0.0) or (r["mode"] == "estimate_only" and r["truth"] == 1.0):
            errors += 1
        out.append(errors / i)
    return out


def stabilization_episode(records, bar: float = MODE_ERROR_BAR) -> int | None:
    """First 1-indexed episode where the cumulative mode error rate is <= bar
    and stays <= bar through the end. None if never reached."""
    series = cumulative_mode_error_rate(records)
    reached = None
    for i, rate in enumerate(series):
        if rate > bar:
            reached = None
        elif reached is None:
            reached = i + 1
    return reached


def trailing_stabilization_episode(records, bar: float = MODE_ERROR_BAR, window: int = 4) -> int | None:
    """First 1-indexed episode where the trailing-`window` mode error rate is
    <= bar and stays <= bar through the end. A window with fewer than 2
    usable samples does not qualify (a single lucky episode proves nothing).
    Unlike the cumulative version this is not trivially won by one correct
    first episode; a review-everything policy still passes trivially, which
    is why first_exact_episode is reported alongside it."""
    usable = [r for r in records if not r["hard_fail"]]
    reached = None
    for k in range(len(usable)):
        rate = None
        lo = max(0, k - window + 1)
        sub = usable[lo:k + 1]
        if len(sub) >= 2:
            errors = sum(1 for r in sub if (r["mode"] == "exact" and r["truth"] == 0.0) or (r["mode"] == "estimate_only" and r["truth"] == 1.0))
            rate = errors / len(sub)
        if rate is None or rate > bar:
            reached = None
        elif reached is None:
            reached = k + 1
    return reached


def first_exact_episode(records) -> int | None:
    """1-indexed position of the first usable exact-mode decision, or None.
    On extended replays this is the operational 'actions to useful
    confidence': how much feedback before the system acts on its own
    confidence (and whether that first act is right)."""
    for i, r in enumerate([r for r in records if not r["hard_fail"]]):
        if r["mode"] == "exact":
            return i + 1
    return None


def percentile_bootstrap_interval(values) -> dict:
    """Percentile interval over pre-computed per-replicate statistic values."""
    if not values:
        raise ValueError("no bootstrap replicates")
    ordered = sorted(values)
    lo = ordered[max(0, int(0.025 * len(ordered)) - 1)]
    hi = ordered[min(len(ordered) - 1, int(0.975 * len(ordered)))]
    return {"lo": lo, "hi": hi, "b": len(ordered), "seed": BOOTSTRAP_SEED}


def bootstrap_metric(records_fn, n_items: int, stat_fn, b: int = BOOTSTRAP_B, seed: int = BOOTSTRAP_SEED) -> dict:
    """Resample item indices with replacement; `records_fn(indices)` re-runs
    the online replay for the resampled order/composition; `stat_fn(records)`
    reduces to one number. Returns the percentile interval dict."""
    rng = random.Random(seed)
    values = []
    for _ in range(b):
        idx = [rng.randrange(n_items) for _ in range(n_items)]
        values.append(stat_fn(records_fn(idx)))
    return percentile_bootstrap_interval(values)
