"""taste-residual-v1 constants — SPEC section 2.2 (normative).

Mirrored from docs/spec/taste/contracts/check.py; a change to the spec's
math that is not reflected here fails the golden-fixture parity test.
"""

HALF_LIFE = {
    "cook_rating": 60.0,
    "cook_no_rating": 30.0,
    "saved": 45.0,
    "skipped": 14.0,
    "substitution": 45.0,
    "lechef": 45.0,
    "open": 7.0,
    "view": 7.0,
}

STRENGTH = {
    "cook_rating": 1.0,
    "cook_no_rating": 0.3,
    "saved": 0.4,
    "skipped": 0.2,
    "substitution": 0.5,
    "lechef": 0.4,
    "open": 0.15,
    "view": 0.08,
}

CAP = {
    "ingredient": 4.0,
    "cuisine": 3.0,
    "technique": 2.0,
    "time": 2.0,
    "nutrient": 2.0,
    "spice": 2.0,
    "tool": 1.0,
    "other": 1.0,
}

K_SHRINK = 3.0
GLOBAL_CLAMP = 8.0

# Fixed rewards for save/skip evidence (SPEC 2.3, contracts REWARD table);
# cooks and ratings derive their reward from the rating itself.
REWARD = {"saved": 0.75, "skipped": 0.15}

# Exposure-share floor: share = max(|slate| / |feasible|, 0.15).
EXPOSURE_FLOOR = 0.15

# A cook with no rating is its own evidence class: reward fixed at 0.6.
COOK_NO_RATING_REWARD = 0.6

# Profile statement display bars (SPEC section 4).
PROFILE_MIN_DENOMINATOR = 3
PROFILE_MIN_RATIO = 0.6
STALE_AFTER_HALF_LIVES = 3.0

# Beta prior.
PRIOR_ALPHA = 1.0
PRIOR_BETA = 1.0

FEATURE_CLASSES = (
    "ingredient",
    "cuisine",
    "technique",
    "time",
    "nutrient",
    "spice",
    "tool",
    "other",
)
