"""Declared coverage bands for suite C (cuisines and time bands).

PLAN.md's scorecard bar reads "every cuisine and time band in SPEC 3.5
represented", but SPEC 3.5 enumerates no lists — it binds the corpus to
quantity evidence, rights and safety instead. The declared bands are
therefore *this suite's* declared instrument, recorded here once so the bar
has a fixed denominator:

- meal slots: breakfast / lunch / dinner (the app's meal contexts);
- time bands: derived from the bundled catalog's `minutes` field
  (quick=15, standard 30/45 patterns in apps/ios/Resources/data.json);
- cuisines: the regional tags the bundled catalog actually carries
  (asian, mediterranean, mexican) plus the broad families the corpus task
  is expected to fill (american, indian, italian).

Moving any list here requires a recorded reason in PLAN.md (SCORECARD.md,
"Bars").
"""

MEAL_SLOTS = ("breakfast", "lunch", "dinner")

TIME_BANDS = (
    ("0-15", 0, 15),
    ("16-30", 16, 30),
    ("31-45", 31, 45),
    ("46-60", 46, 60),
    ("61+", 61, 10_000),
)

CUISINES = (
    "american", "asian", "indian", "italian", "mediterranean", "mexican",
)

CUISINE_SET = set(CUISINES)
SLOT_SET = set(MEAL_SLOTS)


def time_band(minutes: float) -> str:
    for name, low, high in TIME_BANDS:
        if low <= minutes <= high:
            return name
    return "61+"


DECLARED_BANDS = [f"slot:{s}" for s in MEAL_SLOTS] \
    + [f"time:{name}" for name, _, _ in TIME_BANDS] \
    + [f"cuisine:{c}" for c in CUISINES]


def coverage(recipes: list[dict]) -> dict:
    """Per-band counts across the corpus (marginal coverage per axis)."""
    counts = {b: 0 for b in DECLARED_BANDS}
    for r in recipes:
        for s in r.get("meal_slots", []):
            counts[f"slot:{s}"] += 1
        counts[f"time:{time_band(r.get('minutes', 0))}"] += 1
        counts[f"cuisine:{r.get('cuisine')}"] += 1
    missing = [b for b, n in counts.items() if n == 0]
    cells = len(CUISINES) * len(MEAL_SLOTS) * len(TIME_BANDS)
    filled = len({
        (r["cuisine"], s, time_band(r["minutes"]))
        for r in recipes for s in r.get("meal_slots", [])
    })
    return {
        "declared": DECLARED_BANDS,
        "counts": counts,
        "missing": missing,
        "represented": len(DECLARED_BANDS) - len(missing),
        "total_declared": len(DECLARED_BANDS),
        "cross_product_cells": cells,
        "cross_product_filled": filled,
    }
