"""Box matching primitives for the multi-plate benchmark.

Coordinates are (xmin, ymin, xmax, ymax), any consistent unit.

- `iou` is the exact intersection-over-union.
- `match_detections` pairs detections with ground-truth boxes of the same
  category. `optimal=True` solves the assignment exactly (Hungarian,
  scipy) with a **count-first objective**: maximize the *number* of valid
  same-category matches (IoU >= threshold) first, and use total IoU only
  as a tie-break. Maximizing summed IoU alone can undercount valid
  matches: at threshold 0.5, the IoU matrix [[1, .6, 0], [.6, 1, .6],
  [.6, 0, 0]] allows three valid matches totaling 1.8, but a
  maximum-total-IoU assignment picks two matches totaling 2.0. Match
  count is the quantity the metrics report on, so a valid match dropped
  to inflate summed IoU distorts precision/recall. If the exact solver
  (scipy) is unavailable, `optimal=True` **raises** rather than silently
  degrading: a summary must never claim optimal-mode matching it did not
  run. The greedy variant (highest-confidence first) is the classic
  baseline, kept for comparison. Both threshold candidate pairs at
  `iou_threshold` (default 0.5).

Duplicate detections (two detections on the same GT box) count as one true
positive plus one false positive — never two true positives.
"""

from __future__ import annotations

import numpy as np

try:  # scipy ships with the benchmark environment
    from scipy.optimize import linear_sum_assignment

    _HAS_SCIPY = True
except ImportError:  # pragma: no cover
    _HAS_SCIPY = False


def iou(a, b) -> float:
    ax0, ay0, ax1, ay1 = a
    bx0, by0, bx1, by1 = b
    ix0, iy0 = max(ax0, bx0), max(ay0, by0)
    ix1, iy1 = min(ax1, bx1), min(ay1, by1)
    iw, ih = max(0.0, ix1 - ix0), max(0.0, iy1 - iy0)
    inter = iw * ih
    union = (ax1 - ax0) * (ay1 - ay0) + (bx1 - bx0) * (by1 - by0) - inter
    return float(inter / union) if union > 0 else 0.0


def iou_matrix(dets, gts) -> np.ndarray:
    n, m = len(dets), len(gts)
    out = np.zeros((n, m))
    for i, d in enumerate(dets):
        for j, g in enumerate(gts):
            out[i, j] = iou(d["box"], g["box"])
    return out


def match_detections(dets, gts, iou_threshold: float = 0.5, optimal: bool = True):
    """Pair detections to same-category GT boxes.

    Each detection matches at most one GT box and vice versa. A GT box hit by
    two detections still credits only one true positive.

    Returns dict with:
      matches: list of (det_index, gt_index, iou)
      matched_gt: set of matched gt indices
      true_positives: == len(matches)
      false_positives: unmatched detections (includes duplicates)
      missed: gt indices with no detection
    """
    used_gts: set[int] = set()
    matches: list[tuple[int, int, float]] = []

    if optimal and dets and gts:
        if not _HAS_SCIPY:
            raise RuntimeError(
                "optimal=True requires scipy.optimize.linear_sum_assignment, "
                "which is unavailable in this environment. Refusing to score: "
                "the summary would claim optimal-mode matching it did not run. "
                "Install scipy or run with optimal=False (greedy baseline)."
            )
        m = iou_matrix(dets, gts)
        for i, d in enumerate(dets):
            for j, g in enumerate(gts):
                if d["label"] != g["label"]:
                    m[i, j] = 0.0
        m[m < iou_threshold] = 0.0
        if m.any():
            # Count-first objective: a valid match is worth (W + iou), an
            # invalid/filtered pair is forbidden. W > max possible total IoU
            # (< min(n, m) <= 1 each), so maximizing the assignment value
            # maximizes match count first and total IoU second. Pairs left
            # forbidden in the chosen assignment simply do not match.
            W = float(min(len(dets), len(gts))) + 1.0
            FORBIDDEN = 1e9
            cost = np.where(m > 0.0, -(W + m), FORBIDDEN)
            rows, cols = linear_sum_assignment(cost)
            for i, j in zip(rows, cols):
                if m[i, j] > 0:
                    matches.append((int(i), int(j), float(m[i, j])))
                    used_gts.add(int(j))
    else:
        order = sorted(
            range(len(dets)),
            key=lambda i: (-dets[i].get("confidence", 0.0), i),
        )
        for i in order:
            best, best_iou = None, iou_threshold
            for j in range(len(gts)):
                if j in used_gts or dets[i]["label"] != gts[j]["label"]:
                    continue
                v = iou(dets[i]["box"], gts[j]["box"])
                if v >= best_iou:
                    best, best_iou = j, v
            if best is not None:
                matches.append((i, best, best_iou))
                used_gts.add(best)

    matched_gt = {j for _, j, _ in matches}
    matched_dets = {i for i, _, _ in matches}
    return {
        "matches": matches,
        "matched_gt": matched_gt,
        "true_positives": len(matches),
        "false_positives": len(dets) - len(matched_dets),
        "missed": [j for j in range(len(gts)) if j not in matched_gt],
    }
