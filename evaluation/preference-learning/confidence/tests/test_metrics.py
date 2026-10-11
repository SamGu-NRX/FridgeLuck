"""Metric correctness on tiny hand-computed cases (behavior, not implementation)."""

from __future__ import annotations

import pytest

from metrics import (
    brier,
    cumulative_mode_error_rate,
    decision_counts,
    ece,
    reliability_curve,
    stabilization_episode,
)


def test_ece_perfect_calibration():
    # Single-element bins measure |truth - score|, so exact agreement is zero.
    assert ece([0.9, 0.8, 0.2, 0.1], [0.9, 0.8, 0.2, 0.1]) == 0.0
    # Balanced binary pair inside one bin: conf 0.5 == acc 0.5.
    assert ece([0.5, 0.5], [1.0, 0.0]) == 0.0


def test_ece_single_bin_hand_value():
    # All scores in [0.5,0.6): bin 5. scores 0.55,0.55; truths 1,0.
    # conf = 0.55, acc = 0.5 -> ECE = 1.0 * |0.5 - 0.55| = 0.05.
    assert ece([0.55, 0.55], [1.0, 0.0]) == pytest.approx(0.05)


def test_ece_two_bins_hand_value():
    # bin 9 [0.9,1.0): score 0.95 truth 0 -> conf .95 acc 0 -> gap .95
    # bin 0 [0,0.1): score 0.05 truth 1 -> gap .95
    # ECE = (0.5*.95 + 0.5*.95) = 0.95.
    assert ece([0.95, 0.05], [0.0, 1.0]) == 0.95


def test_ece_rejects_out_of_range():
    import pytest

    with pytest.raises(ValueError):
        ece([1.2], [1.0])
    with pytest.raises(ValueError):
        ece([], [])


def test_reliability_curve_bins():
    curve = reliability_curve([0.95, 0.05], [0.0, 1.0])
    b9 = next(b for b in curve if b["bin"] == 9)
    b0 = next(b for b in curve if b["bin"] == 0)
    assert b9["count"] == 1 and b9["mean_score"] == 0.95 and b9["mean_truth"] == 0.0
    assert b0["count"] == 1 and b0["mean_score"] == 0.05 and b0["mean_truth"] == 1.0
    empty = next(b for b in curve if b["bin"] == 5)
    assert empty["count"] == 0 and empty["mean_score"] is None


def test_brier_hand_value():
    # (0.9-1)^2 and (0.2-0)^2 -> (0.01 + 0.04)/2 = 0.025
    assert brier([0.9, 0.2], [1.0, 0.0]) == 0.025


def test_decision_counts_hand_case():
    records = [
        {"mode": "exact", "truth": 1.0, "hard_fail": False},  # exact_right
        {"mode": "exact", "truth": 0.0, "hard_fail": False},  # exact_wrong
        {"mode": "estimate_only", "truth": 1.0, "hard_fail": False},  # estimate_fn
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},  # neither error
        {"mode": "estimate_only", "truth": 0.0, "hard_fail": True},  # excluded
    ]
    c = decision_counts(records)
    assert c["n"] == 4
    assert c["exact_n"] == 2 and c["exact_right"] == 1 and c["exact_wrong"] == 1
    assert c["exact_precision"] == 0.5
    assert c["estimate_fn"] == 1
    assert c["review_n"] == 1
    assert c["mode_errors"] == 2
    assert c["mode_error_rate"] == 0.5


def test_cumulative_series_and_stabilization():
    records = [
        {"mode": "estimate_only", "truth": 1.0, "hard_fail": False},  # err 1/1 = 1.0
        {"mode": "exact", "truth": 1.0, "hard_fail": False},  # 1/2 = 0.5
        {"mode": "review_required", "truth": 0.0, "hard_fail": False},  # 1/3 = 0.333
        {"mode": "exact", "truth": 1.0, "hard_fail": False},  # 1/4 = 0.25 <= bar
        {"mode": "review_required", "truth": 0.0, "hard_fail": False},  # 1/5 = 0.2
    ]
    series = cumulative_mode_error_rate(records)
    assert series == [1.0, 0.5, 1 / 3, 0.25, 0.2]
    assert stabilization_episode(records) == 4


def test_stabilization_never_reached():
    records = [
        {"mode": "exact", "truth": 0.0, "hard_fail": False},
        {"mode": "exact", "truth": 0.0, "hard_fail": False},
        {"mode": "exact", "truth": 0.0, "hard_fail": False},
    ]
    assert stabilization_episode(records) is None


def test_stabilization_resets_after_late_violation():
    # Reaches 0.25 at ep 4, then a wrong-exact at ep 5 pushes cumulative to 2/5=0.4;
    # recovery to <=0.25 only at ep 8 (2/8=0.25) and it must hold to the end.
    records = [
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "exact", "truth": 1.0, "hard_fail": False},  # 0 errors / 4
        {"mode": "exact", "truth": 0.0, "hard_fail": False},  # 1/5 = 0.2 fine
        {"mode": "exact", "truth": 0.0, "hard_fail": False},  # 2/6 = 0.333 > bar
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},  # 2/7 = 0.286
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},  # 2/8 = 0.25
    ]
    assert stabilization_episode(records) == 8


def test_trailing_stabilization_needs_window_and_hold():
    from metrics import trailing_stabilization_episode

    # ep1 review-on-correct: window [ep1] too small (1 sample) -> no.
    # ep2: window [1,2] 0 errors -> 0.0 <= 0.25; ep3 0/3; ep4 0/4 -> first
    # qualifying k with >=2 window samples and held to end = 2.
    records = [
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
    ]
    assert trailing_stabilization_episode(records) == 2

    # Two errors in a trailing window reset the hold (one error in four is
    # exactly AT the 0.25 bar and does not violate it). Errors at eps 5-6:
    # k=5 window [2..5] 1/4 holds; k=6 [3..6] 2/4=0.5 resets; k=7 [4..7]
    # 2/4; k=8 [5..8] 2/4; k=9 [6..9] 1/4 qualifies and k=10 [7..10] 0/4
    # holds -> 9.
    records += [
        {"mode": "exact", "truth": 0.0, "hard_fail": False},   # ep5 err
        {"mode": "exact", "truth": 0.0, "hard_fail": False},   # ep6 err
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
        {"mode": "review_required", "truth": 1.0, "hard_fail": False},
    ]
    assert trailing_stabilization_episode(records) == 9
