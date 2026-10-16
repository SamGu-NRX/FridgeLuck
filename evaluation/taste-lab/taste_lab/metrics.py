"""Offline evaluation metrics with bootstrap intervals.

Relevance is the household's latent utility (simulator ground truth), never
anything the ranking arms can see.
"""

from __future__ import annotations

import math
import random
from typing import Dict, Sequence, Tuple


def ndcg_at_k(ranked: Sequence[str], utilities: Dict[str, float], k: int = 10) -> float:
    """NDCG@k with exponential gain over latent utilities normalized to [0, 1]."""
    if not utilities:
        return 0.0
    lo, hi = min(utilities.values()), max(utilities.values())
    span = hi - lo

    def norm(u: float) -> float:
        return (u - lo) / span if span > 0 else 0.5

    def dcg(order: Sequence[str]) -> float:
        total = 0.0
        for i, rid in enumerate(order[:k]):
            rel = norm(utilities.get(rid, lo))
            total += (2.0**rel - 1.0) / math.log2(i + 2)
        return total

    ideal = sorted(utilities, key=lambda rid: (-utilities[rid], rid))
    return dcg(list(ranked)) / dcg(ideal)


def pairwise_accuracy_on_flippable(
    ranked: Sequence[str],
    utilities: Dict[str, float],
    rule_scores: Dict[str, float],
    margin: float = 2.0,
) -> Tuple[float, int]:
    """Fraction of correctly ordered pairs among feasible recipes whose rule
    scores are within `margin` points — the pairs the residual layer is
    allowed to flip (SPEC 0: "small evidence nudges but never overturns ...
    against rule-score gaps of 2-3 points"). Latent ties are skipped."""
    position = {rid: i for i, rid in enumerate(ranked)}
    correct = 0
    total = 0
    ids = [rid for rid in ranked if rid in utilities]
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            a, b = ids[i], ids[j]
            if abs(rule_scores[a] - rule_scores[b]) > margin:
                continue
            u_diff = utilities[a] - utilities[b]
            if u_diff == 0:
                continue
            # correct if the arm's order agrees with the latent order
            ordered_higher_first = position[a] < position[b]
            latent_higher_a = u_diff > 0
            if ordered_higher_first == latent_higher_a:
                correct += 1
            total += 1
    if total == 0:
        return 0.5, 0
    return correct / total, total


def top10_churn(ranked_a: Sequence[str], ranked_b: Sequence[str], k: int = 10) -> float:
    """Symmetric difference of the two top-k sets, as a fraction of k."""
    a = set(ranked_a[:k])
    b = set(ranked_b[:k])
    if k == 0:
        return 0.0
    return len(a.symmetric_difference(b)) / k


def bootstrap_ci(
    values: Sequence[float],
    reps: int = 2000,
    seed: int = 0,
    confidence: float = 0.95,
) -> Tuple[float, float, float]:
    """Percentile bootstrap CI of the mean. Deterministic given the seed."""
    if not values:
        return 0.0, 0.0, 0.0
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(reps):
        sample = [values[rng.randrange(n)] for _ in range(n)]
        means.append(sum(sample) / n)
    means.sort()
    alpha = (1.0 - confidence) / 2.0
    low = means[max(0, int(math.floor(alpha * reps)))]
    high = means[min(reps - 1, int(math.ceil((1 - alpha) * reps)) - 1)]
    mean = sum(values) / n
    return mean, low, high


def paired_bootstrap_difference(
    a: Sequence[float],
    b: Sequence[float],
    reps: int = 2000,
    seed: int = 0,
    confidence: float = 0.95,
) -> Tuple[float, float, float]:
    """CI of mean(a - b) with paired resampling (same indices for both arms —
    households are the pairing unit)."""
    assert len(a) == len(b), "paired arms must have per-household entries"
    diffs = [x - y for x, y in zip(a, b)]
    return bootstrap_ci(diffs, reps=reps, seed=seed, confidence=confidence)
