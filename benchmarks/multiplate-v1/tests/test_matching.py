"""Counterexample tests for matching.py: exact IoU, duplicates, greedy vs optimal."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from matching import iou, match_detections  # noqa: E402


def det(label, box, confidence=1.0):
    return {"label": label, "box": box, "confidence": confidence}


def gt(label, box):
    return {"label": label, "box": box}


class TestExactIou:
    def test_identical_boxes(self):
        assert iou((0, 0, 1, 1), (0, 0, 1, 1)) == 1.0

    def test_exact_fraction(self):
        # inter = 1, union = 4 + 4 - 1 = 7
        assert iou((0, 0, 2, 2), (1, 1, 3, 3)) == pytest.approx(1 / 7)

    def test_disjoint(self):
        assert iou((0, 0, 1, 1), (2, 2, 3, 3)) == 0.0

    def test_touching_edges_do_not_intersect(self):
        assert iou((0, 0, 1, 1), (1, 0, 2, 1)) == 0.0

    def test_degenerate_zero_area(self):
        assert iou((0, 0, 0, 0), (0, 0, 1, 1)) == 0.0

    def test_half_overlap(self):
        assert iou((0, 0, 2, 1), (1, 0, 3, 1)) == pytest.approx(1 / 3)


class TestExactIoUThresholding:
    def test_below_threshold_no_match(self):
        # IoU = 1/7 ~ 0.143 < 0.5
        d = [det("Cake", (0, 0, 2, 2))]
        g = [gt("Cake", (1, 1, 3, 3))]
        r = match_detections(d, g, iou_threshold=0.5)
        assert r["true_positives"] == 0 and r["missed"] == [0]

    def test_threshold_is_inclusive(self):
        d = [det("Cake", (0, 0, 2, 1))]
        g = [gt("Cake", (1, 0, 3, 1))]
        r = match_detections(d, g, iou_threshold=1 / 3)
        assert r["true_positives"] == 1

    def test_class_mismatch_never_matches(self):
        d = [det("Cake", (0, 0, 1, 1))]
        g = [gt("Pizza", (0, 0, 1, 1))]
        r = match_detections(d, g, iou_threshold=0.5)
        assert r["true_positives"] == 0
        assert r["false_positives"] == 1


class TestDuplicateDetections:
    def test_duplicate_on_single_gt(self):
        box = (0.0, 0.0, 1.0, 1.0)
        d = [det("Cake", box, 0.9), det("Cake", box, 0.8)]
        g = [gt("Cake", box)]
        r = match_detections(d, g, iou_threshold=0.5)
        assert r["true_positives"] == 1
        assert r["false_positives"] == 1
        assert r["matched_gt"] == {0}

    def test_duplicate_does_not_displace_true_positive(self):
        d = [
            det("Cake", (0.0, 0.0, 1.0, 1.0), 0.9),
            det("Cake", (0.05, 0.05, 1.05, 1.05), 0.95),
        ]
        g = [gt("Cake", (0.0, 0.0, 1.0, 1.0))]
        r = match_detections(d, g, iou_threshold=0.5)
        assert r["true_positives"] == 1
        assert r["false_positives"] == 1
        assert r["matches"] == [(0, 0, 1.0)]


class TestGreedyVersusOptimal:
    def test_count_first_beats_max_sum_iou(self):
        # Regression: maximizing summed IoU can undercount valid matches.
        # Equal 2x2 boxes offset by 0.5 have IoU 0.6; offset by 1.0, IoU 1/3.
        #   d0=(0,0,2,2)   g0=(0,0,2,2)    d0-g0 = 1.0
        #   d1=(.5,0,2.5,2) g1=(.5,0,2.5,2) d1-g1 = 1.0
        #   d2=(-.5,0,1.5,2) g2=(1,0,3,2)
        #   d2-g0 = 0.6, d0-g1 = 0.6, d1-g2 = 0.6; every other pair < 0.5.
        # So a count-3 assignment totals 1.8 while (d0,g0)+(d1,g1) totals
        # 2.0 — a maximum-total-IoU assignment drops the third valid match.
        # Match count must win; total IoU only breaks ties.
        dets = [
            det("Pizza", (0.0, 0.0, 2.0, 2.0)),
            det("Pizza", (0.5, 0.0, 2.5, 2.0)),
            det("Pizza", (-0.5, 0.0, 1.5, 2.0)),
        ]
        gts = [
            gt("Pizza", (0.0, 0.0, 2.0, 2.0)),
            gt("Pizza", (0.5, 0.0, 2.5, 2.0)),
            gt("Pizza", (1.0, 0.0, 3.0, 2.0)),
        ]
        res = match_detections(dets, gts, iou_threshold=0.5, optimal=True)
        assert res["true_positives"] == 3
        assert {i for i, _, _ in res["matches"]} == {0, 1, 2}
        assert res["matched_gt"] == {0, 1, 2}
        # total IoU across the chosen matches is the count-maximal 1.8
        assert sum(v for _, _, v in res["matches"]) == pytest.approx(1.8)

    def test_optimal_raises_without_scipy_instead_of_claiming_optimal(self, monkeypatch):
        # The summary must never claim optimal-mode matching that did not
        # run: with the exact solver unavailable, optimal=True refuses.
        import matching

        monkeypatch.setattr(matching, "_HAS_SCIPY", False)
        with pytest.raises(RuntimeError, match="optimal"):
            match_detections(
                [det("Pizza", (0.0, 0.0, 1.0, 1.0))],
                [gt("Pizza", (0.0, 0.0, 1.0, 1.0))],
                iou_threshold=0.5,
                optimal=True,
            )


    def test_optimal_recovers_two_matches_greedy_loses_one(self):
        """det A (higher confidence) best-matches GT1 and steals it from det B,
        whose only viable partner is GT1. Greedy: 1 TP. Optimal: 2 TPs."""
        A = det("Cake", (0.0, 0.0, 1.0, 1.0), 0.95)
        B = det("Cake", (0.3, 0.0, 1.0, 1.0), 0.90)  # identical to GT1 -> iou 1.0
        GT1 = gt("Cake", (0.3, 0.0, 1.0, 1.0))  # iou(A,·) = 0.7
        GT2 = gt("Cake", (0.0, 0.25, 1.0, 1.25))  # iou(A,·) = 0.6
        assert iou(A["box"], GT1["box"]) == pytest.approx(0.7)
        assert iou(A["box"], GT2["box"]) == pytest.approx(0.6)
        g = match_detections([A, B], [GT1, GT2], iou_threshold=0.5, optimal=False)
        o = match_detections([A, B], [GT1, GT2], iou_threshold=0.5, optimal=True)
        assert g["true_positives"] == 1  # A steals GT1 (0.7); B left unmatched
        assert o["true_positives"] == 2  # A->GT2 (0.51), B->GT1 (1.0)
        assert not o["missed"]

    def test_optimal_never_fewer_matches_than_greedy_on_random_boards(self):
        import random

        rng = random.Random(1234)
        for _ in range(50):
            d, g = [], []
            for _i in range(4):
                x, y = rng.random() * 2, rng.random() * 2
                d.append(det("Cake", (x, y, x + 0.8, y + 0.8), rng.random()))
            for _j in range(4):
                x, y = rng.random() * 2, rng.random() * 2
                g.append(gt("Cake", (x, y, x + 0.8, y + 0.8)))
            gr = match_detections(d, g, iou_threshold=0.3, optimal=False)
            op = match_detections(d, g, iou_threshold=0.3, optimal=True)
            assert op["true_positives"] >= gr["true_positives"]
            assert gr["true_positives"] <= min(len(d), len(g))

    def test_optimal_same_class_only(self):
        d = [det("Pizza", (0, 0, 1, 1), 0.9)]
        g = [gt("Cake", (0, 0, 1, 1)), gt("Pizza", (0, 0, 1, 1))]
        r = match_detections(d, g, iou_threshold=0.5, optimal=True)
        assert r["matches"] == [(0, 1, 1.0)]
