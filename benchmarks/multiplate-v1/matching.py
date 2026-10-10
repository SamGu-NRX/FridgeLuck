"""Box matching primitives for the multi-plate benchmark.

Coordinates are (xmin, ymin, xmax, ymax), any consistent unit.

- `iou` is the exact intersection-over-union.
- `match_detections` pairs detections with ground-truth boxes of the same
  category. `optimal=True` solves the maximum-total-IoU bipartite assignment
  (Hungarian, scipy), the standard DETR-style evaluation; the greedy variant
  (highest-confidence first) is the classic baseline, kept for comparison.
  Both threshold candidate pairs at `iou_threshold` (default 0.5).

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

    if optimal and _HAS_SCIPY and dets and gts:
        m = iou_matrix(dets, gts)
        for i, d in enumerate(dets):
            for j, g in enumerate(gts):
                if d["label"] != g["label"]:
                    m[i, j] = 0.0
        m[m < iou_threshold] = 0.0
        if m.any():
            rows, cols = linear_sum_assignment(-m)
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
