"""Tests for the two verdict policies (policy.py).

The measured policy pins the stratum-blind control semantics:
  - tau_high always admits food
  - a produced food label below the admit bar is never folded into "empty"
    - it becomes "unknown" and the scorer counts it as a false addition
  - only no-produced-food with score <= tau_low is "empty"

The oracle policy pins the PRIVILEGED semantics (it additionally reads the
frozen stratum):
  - opaque_unknown is never certainly empty below tau_high (closed boxes,
    sealed containers: "unknown", at any score)
  - only empty_visible with no produced food and score <= tau_low is "empty"
  - a missed food_control is a recall loss, never a certain-empty verdict
"""
import pytest

from policy import POLICIES, verdict, verdict_measured, verdict_oracle

TAU_HIGH = 0.7
TAU_LOW = 0.2


# ------------------------------------------------------- measured policy --


def test_measured_food_admitted_at_or_above_tau_high():
    assert verdict_measured(TAU_HIGH, TAU_HIGH, TAU_LOW) == "food"
    assert verdict_measured(0.99, TAU_HIGH, TAU_LOW, produced_food=False) == "food"


def test_measured_produced_food_below_bar_is_unknown_not_empty():
    assert verdict_measured(0.1, TAU_HIGH, TAU_LOW, produced_food=True) == "unknown"


def test_measured_certain_empty_at_or_below_tau_low():
    assert verdict_measured(0.0, TAU_HIGH, TAU_LOW) == "empty"
    assert verdict_measured(TAU_LOW, TAU_HIGH, TAU_LOW) == "empty"  # inclusive ceiling
    assert verdict_measured(TAU_LOW + 1e-9, TAU_HIGH, TAU_LOW) == "unknown"


def test_measured_unknown_fills_the_gap():
    assert verdict_measured((TAU_LOW + TAU_HIGH) / 2, TAU_HIGH, TAU_LOW) == "unknown"


def test_measured_takes_no_stratum_argument():
    # enforced at the signature level: there is no stratum parameter to pass
    import inspect

    assert "stratum" not in inspect.signature(verdict_measured).parameters


# --------------------------------------------------------- oracle policy --


def test_oracle_food_admitted_at_or_above_tau_high_on_any_stratum():
    for stratum in ("empty_visible", "opaque_unknown", "food_control"):
        assert verdict_oracle(stratum, TAU_HIGH, TAU_HIGH, TAU_LOW) == "food"
        assert verdict_oracle(stratum, 0.99, TAU_HIGH, TAU_LOW, produced_food=False) == "food"


def test_oracle_opaque_unknown_is_never_certainly_empty():
    # even a zero score on a closed container stays unknown below tau_high
    assert verdict_oracle("opaque_unknown", 0.0, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict_oracle("opaque_unknown", TAU_LOW, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict_oracle("opaque_unknown", 0.69, TAU_HIGH, TAU_LOW) == "unknown"


def test_oracle_produced_food_below_bar_is_unknown_not_empty():
    for stratum in ("empty_visible", "opaque_unknown"):
        assert verdict_oracle(stratum, 0.1, TAU_HIGH, TAU_LOW, produced_food=True) == "unknown"


def test_oracle_certain_empty_only_for_visible_empty_low_score():
    assert verdict_oracle("empty_visible", 0.0, TAU_HIGH, TAU_LOW) == "empty"
    assert verdict_oracle("empty_visible", TAU_LOW, TAU_HIGH, TAU_LOW) == "empty"  # inclusive ceiling
    assert verdict_oracle("empty_visible", 0.2 + 1e-9, TAU_HIGH, TAU_LOW) == "unknown"


def test_oracle_food_control_below_bar_is_unknown_not_empty():
    # a missed control is a recall loss, never a certain-empty verdict
    assert verdict_oracle("food_control", 0.0, TAU_HIGH, TAU_LOW) == "unknown"
    assert verdict_oracle("food_control", TAU_LOW, TAU_HIGH, TAU_LOW) == "unknown"


# ------------------------------------------------------------ dispatch ----


def test_dispatch_covers_every_policy_name():
    assert set(POLICIES) == {"measured", "oracle"}
    for policy in POLICIES:
        v = verdict(policy, "empty_visible", 0.0, TAU_HIGH, TAU_LOW)
        assert v in ("food", "empty", "unknown")


def test_dispatch_rejects_unknown_policy():
    with pytest.raises(ValueError):
        verdict("cheating", "empty_visible", 0.0, TAU_HIGH, TAU_LOW)
