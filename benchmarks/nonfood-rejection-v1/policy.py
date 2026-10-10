#!/usr/bin/env python3
"""Empty / unknown / food verdict policies for nonfood-rejection-v1.

Two policies map arm output to one of three verdicts:

  food     score >= tau_high — admit the image as containing food
  empty    no produced food, score <= tau_low — the only path to a
           certain-empty verdict
  unknown  everything else, including produced food below the admit bar
           (produced food is never silently discarded into "empty"; it is
           flagged and counted as a false addition by the scorer)

verdict_measured — the headline policy. Reads ONLY arm output (food score,
produced flag) and the dev-selected thresholds. It cannot see the image's
stratum, role, or any other ground-truth field: predictions are invariant
under any relabeling of the manifest's truth columns, which
tests/test_policy_blindness.py pins with a truth-mutation test.

verdict_oracle — an explicitly PRIVILEGED upper bound. It additionally
reads the frozen stratum, so it can protect opaque-unknown images (never
certainly empty at any score) and restrict certain-empty to visibly-empty
images. That is target information the production pipeline does not have
at prediction time (it would have to know it cannot see inside a closed
box before deciding to look), so oracle numbers are reported separately
and never mixed with measured ones.

tau_high / tau_low are selected on dev groups only (see score.py; dev
ground truth is allowed there — it is training/selection, not prediction)
and are always passed explicitly; there are no silent defaults.
"""

VERDICTS = ("food", "empty", "unknown")

POLICIES = ("measured", "oracle")


def verdict_measured(food_score, tau_high, tau_low, produced_food=False):
    """Stratum-blind verdict: arm output and dev-selected thresholds only.

    food_score      arm's food evidence score in [0, 1]
    tau_high        admit-food threshold (from dev groups)
    tau_low         certain-empty ceiling (from dev groups)
    produced_food   True when the arm produced >=1 food label that resolved
                    to an ingredient through the base resolver
    """
    if food_score >= tau_high:
        return "food"
    if produced_food:
        return "unknown"
    if food_score <= tau_low:
        return "empty"
    return "unknown"


def verdict_oracle(stratum, food_score, tau_high, tau_low, produced_food=False):
    """Privileged verdict: as measured, but it also sees the frozen stratum.

    stratum         frozen manifest stratum (empty_visible | opaque_unknown |
                    food_control). PRIVILEGED input — the measured policy
                    must not and does not receive it.
    """
    if food_score >= tau_high:
        return "food"
    if produced_food:
        return "unknown"
    if stratum == "opaque_unknown":
        return "unknown"
    if stratum == "empty_visible" and food_score <= tau_low:
        return "empty"
    return "unknown"


def verdict(policy, stratum, food_score, tau_high, tau_low, produced_food=False):
    """Dispatch on policy name; POLICIES lists the valid names."""
    if policy == "measured":
        return verdict_measured(food_score, tau_high, tau_low, produced_food)
    if policy == "oracle":
        return verdict_oracle(stratum, food_score, tau_high, tau_low, produced_food)
    raise ValueError(f"unknown policy {policy!r}; expected one of {POLICIES}")
