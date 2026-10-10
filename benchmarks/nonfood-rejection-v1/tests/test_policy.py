"""Tests for the nonfood-rejection-v1 verdict policy (policy.py).

These pin the control semantics:
  - tau_high always admits food, on any stratum
  - opaque_unknown is never certainly empty below tau_high (closed boxes,
    sealed containers: "unknown", at any score)
  - a produced food label below the admit bar is never folded into "empty"
    — it becomes "unknown" and the scorer counts it as a false addition
  - only empty_visible with no produced food and score <= tau_low is "empty"
"""
import pytest

from policy import verdict

TAU_HIGH = 0.7
TAU_LOW = 0.2


def test_food_admitted_at_or_above_tau_high_on_any_stratum():
    for stratum in ("empty_visible", "opaque_unknown", "food_control"):
        assert verdict(stratum, TAU_HIGH, TAU_HIGH, TAU_LOW) == "food"
        assert verdict(stratum, 0.99, TAU_HIGH, TAU_LOW, produced_food=False) == "food"


def test_opaque_unknown_is_never_certainly_empty():
    # even a zero score on a closed container stays unknown below tau_high
    assert verdict("opaque_unknown", 0.0, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict("opaque_unknown", TAU_LOW, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict("opaque_unknown", 0.69, TAU_HIGH, TAU_LOW) == "unknown"


def test_produced_food_below_bar_is_unknown_not_empty():
    for stratum in ("empty_visible", "opaque_unknown"):
        assert verdict(stratum, 0.1, TAU_HIGH, TAU_LOW, produced_food=True) == "unknown"


def test_certain_empty_only_for_visible_empty_low_score():
    assert verdict("empty_visible", 0.0, TAU_HIGH, TAU_LOW) == "empty"
    assert verdict("empty_visible", TAU_LOW, TAU_HIGH, TAU_LOW) == "empty"  # inclusive ceiling
    assert verdict("empty_visible", 0.2 + 1e-9, TAU_HIGH, TAU_LOW) == "unknown"


def test_food_control_below_bar_is_unknown_not_empty():
    # a missed control is a recall loss, never a certain-empty verdict
    assert verdict("food_control", 0.0, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict("food_control", TAU_LOW, TAU_HIGH, TAU_LOW) == "unknown"


def test_unknown_fills_the_gap_between_tau_low_and_tau_high():
    assert verdict("empty_visible", (TAU_LOW + TAU_HIGH) / 2, TAU_HIGH, TAU_LOW) == "unknown"


def test_verdicts_exhaust_the_vocabulary():
    for score in (0.0, 0.1, 0.2, 0.35, 0.5, 0.7, 0.9, 1.0):
        for stratum in ("empty_visible", "opaque_unknown", "food_control"):
            for produced in (False, True):
                v = verdict(stratum, score, TAU_HIGH, TAU_LOW, produced_food=produced)
                assert v in ("food", "empty", "unknown")
