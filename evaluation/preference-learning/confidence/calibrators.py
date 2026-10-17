"""Alternative calibrators for Part 0: isotonic (PAVA) and a small logistic.

Both operate on (score, truth) pairs from the replay and are evaluated two ways:
- IN-SAMPLE: fit and evaluated on the same 12 reverse-meal episodes (flattering).
- LEAVE-ONE-OUT (LOO): refit without each episode, predict it. LOO is the
  honest number at n=12; the gap between the two is itself reported.
Decision rule for alternatives: the service's own thresholds
(overall >= 0.84 and min adjusted >= 0.62 -> exact; overall >= 0.57 -> review)
applied to the geometric mean of the calibrated per-signal scores, so arms
differ only in the score source (documented in FINDINGS.md).
"""

from __future__ import annotations

import math


def pava(y: list[float]) -> list[float]:
    """Pool-adjacent-violators isotonic regression, unit weights, L2 loss.
    Returns the non-decreasing fitted values (block means) for y in input order."""
    if not y:
        return []
    blocks: list[list[float]] = [[v] for v in y]
    i = 0
    while i < len(blocks) - 1:
        if sum(blocks[i]) / len(blocks[i]) > sum(blocks[i + 1]) / len(blocks[i + 1]):
            blocks[i] = blocks[i] + blocks[i + 1]
            del blocks[i + 1]
            if i > 0:
                i -= 1
        else:
            i += 1
    fitted: list[float] = []
    for block in blocks:
        fitted.extend([sum(block) / len(block)] * len(block))
    return fitted


def isotonic_fit(x: list[float], y: list[float]) -> list[tuple[float, float]]:
    """Fit isotonic regression of y on x (sorted by x). Returns [(x, fitted)]
    knots; predict via `isotonic_predict`."""
    order = sorted(range(len(x)), key=lambda i: x[i])
    xs = [x[i] for i in order]
    ys = [y[i] for i in order]
    fitted = pava(ys)
    return list(zip(xs, fitted))


def isotonic_predict(knots: list[tuple[float, float]], x_new: float) -> float:
    """Step prediction from isotonic knots: the fitted value of the last knot
    with x <= x_new; below the first knot use the first fitted value (a floor),
    above the last use the last (a ceiling)."""
    value = knots[0][1]
    for xi, fi in knots:
        if x_new >= xi:
            value = fi
        else:
            break
    return value


def logistic_fit(X: list[list[float]], y: list[float], lam: float = 1.0, iters: int = 200, lr: float = 0.5):
    """L2-regularised logistic regression (intercept unpenalised), full-batch
    gradient descent with backtracking-free fixed lr on standardized-scale
    features (callers standardize). lam is the L2 penalty per weight.
    Returns (weights, intercept)."""
    n = len(X)
    d = len(X[0])
    w = [0.0] * d
    b = 0.0
    for _ in range(iters):
        gw = [0.0] * d
        gb = 0.0
        for i in range(n):
            z = b + sum(w[j] * X[i][j] for j in range(d))
            p = 1.0 / (1.0 + math.exp(-max(min(z, 30.0), -30.0)))
            err = p - y[i]
            for j in range(d):
                gw[j] += err * X[i][j]
            gb += err
        for j in range(d):
            gw[j] = gw[j] / n + lam * w[j] / n
        gb /= n
        w = [w[j] - lr * gw[j] for j in range(d)]
        b -= lr * gb
    return w, b


def logistic_predict(X: list[list[float]], model) -> list[float]:
    w, b = model
    out = []
    for row in X:
        z = b + sum(w[j] * row[j] for j in range(len(w)))
        p = 1.0 / (1.0 + math.exp(-max(min(z, 30.0), -30.0)))
        out.append(p)
    return out


def geo_mean_signal_scores(scores: list[float], weights: list[float]) -> float:
    """The service's overall-score reduction (Swift assess lines 122-127)
    applied to arbitrary per-signal scores: exp(sum(w*log(max(s,1e-4)))/sum(w))."""
    total_w = sum(weights)
    log_sum = sum(w * math.log(max(s, 0.0001)) for s, w in zip(scores, weights))
    return math.exp(log_sum / max(total_w, 0.0001))
