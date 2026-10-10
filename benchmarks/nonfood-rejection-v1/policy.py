#!/usr/bin/env python3
"""Empty / unknown / food verdict policy for nonfood-rejection-v1.

The policy maps one image's arm output (produced food labels, food score)
plus its frozen stratum to one of three verdicts:

  food     score >= tau_high — admit the image as containing food
  empty    stratum empty_visible, no produced food, score <= tau_low — the
           only path to a certain-empty verdict
  unknown  everything else, including:
           - opaque_unknown strata at ANY score: a closed box or sealed
             container must never be called certainly empty
           - empty_visible images where the pipeline produced a food label
             below the admit bar: produced food is never silently discarded
             into "empty" (it is flagged and counted as a false addition by
             the scorer)

tau_high / tau_low are selected on dev groups only (see score.py) and are
always passed explicitly; there are no silent defaults.
"""

VERDICTS = ("food", "empty", "unknown")


def verdict(stratum, food_score, tau_high, tau_low, produced_food=False):
    """One image verdict.

    stratum         frozen manifest stratum (empty_visible | opaque_unknown |
                    food_control)
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
    if stratum == "opaque_unknown":
        return "unknown"
    if stratum == "empty_visible" and food_score <= tau_low:
        return "empty"
    return "unknown"
