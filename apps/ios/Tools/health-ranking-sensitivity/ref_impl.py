"""Python reference implementation of the FridgeLuck production scoring formulas.

PURPOSE AND STATUS: this is a VERIFICATION cross-check only. It mirrors the production
Swift formulas (HealthScoringService.computeScore / buildReasoning and
RecipeScoring.sharedRankingScore / rankingReasons at base commit 8c9c88f) operation by
operation so the unchanged control arm can be asserted bit-exact against the vendored
Swift replay. The production path in this study is the byte-identical vendored Swift
copy (see SwiftReplay/ + tests/test_parity.py); this file is deliberately NOT that path.

All arithmetic uses IEEE-754 doubles with the same operation order as the Swift source.
"""

import math
from dataclasses import dataclass

LABELS = ["", "Not aligned", "Indulgent", "Moderate", "Good", "Great match"]

HIGH_PROTEIN_TAG = "high_protein"


@dataclass(frozen=True)
class Macros:
    calories: float
    protein: float
    carbs: float
    fat: float
    fiber: float
    sugar: float
    sodium: float


@dataclass(frozen=True)
class Profile:
    goal: str  # "general" | "weight_loss" | "muscle_gain" | "maintenance"
    daily_calories: int | None
    protein_pct: float
    carbs_pct: float
    fat_pct: float


@dataclass(frozen=True)
class RankingInputs:
    time_minutes: int
    tags: tuple  # of str
    matched_required: int
    total_required: int
    matched_optional: int
    missing_required_count: int
    personal_score: float


@dataclass(frozen=True)
class HealthScore:
    rating: int
    label: str
    reasoning: str


def macro_split(protein: float, carbs: float, fat: float):
    """Swift: RecipeMacros.macroSplit (4/4/9 kcal per gram; thirds on zero total)."""
    protein_cal = protein * 4
    carbs_cal = carbs * 4
    fat_cal = fat * 9
    total = protein_cal + carbs_cal + fat_cal
    if not total > 0:
        return (0.33, 0.33, 0.33)
    return (protein_cal / total, carbs_cal / total, fat_cal / total)


def compute_score(macros: Macros, profile: Profile) -> HealthScore:
    """Swift: HealthScoringService.computeScore, operation order preserved."""
    points = 0.0

    if profile.daily_calories is not None:
        meal_target = float(profile.daily_calories) / 3.0
        ratio = macros.calories / meal_target
        if 0.7 <= ratio <= 1.1:
            points += 30
        elif 0.5 <= ratio < 0.7:
            points += 20
        elif 1.1 <= ratio < 1.4:
            points += 15
        else:
            points += 5
    else:
        points += 20

    split = macro_split(macros.protein, macros.carbs, macros.fat)
    protein_diff = abs(split[0] - profile.protein_pct)
    carbs_diff = abs(split[1] - profile.carbs_pct)
    fat_diff = abs(split[2] - profile.fat_pct)
    avg_diff = (protein_diff + carbs_diff + fat_diff) / 3.0

    points += max(5.0, 40 * (1.0 - avg_diff * 3.0))

    if macros.fiber >= 5:
        points += 10
    if macros.sugar <= 10:
        points += 10
    if macros.sodium <= 600:
        points += 10

    rating = min(5, max(1, math.ceil(points / 20.0)))
    reasoning = _build_reasoning(macros, split)
    return HealthScore(rating=rating, label=LABELS[rating], reasoning=reasoning)


def _build_reasoning(macros: Macros, split) -> str:
    notes = []
    if split[0] > 0.30:
        notes.append("High protein")
    elif split[0] > 0.25:
        notes.append("Good protein")

    if macros.calories < 350:
        notes.append("Light meal")
    elif macros.calories > 700:
        notes.append("Hearty portion")

    if macros.fiber >= 5:
        notes.append("Good fiber")
    if macros.sugar > 15:
        notes.append("Higher sugar")
    if macros.sodium > 800:
        notes.append("High sodium")

    return "Balanced" if not notes else " · ".join(notes)


def shared_ranking_score(macros: Macros, profile: Profile, ri: RankingInputs,
                         rating: int) -> float:
    """Swift: RecipeRepository.sharedRankingScore, operation order preserved."""
    required_coverage = ri.matched_required / max(ri.total_required, 1)
    optional_contribution = ri.matched_optional * 2.5
    health_contribution = rating * 6.5
    personalization_contribution = ri.personal_score * 8.0

    score = (
        required_coverage * 72.0
        + optional_contribution
        + health_contribution
        + personalization_contribution
    )

    if ri.time_minutes <= 15:
        score += 6.0
    elif ri.time_minutes <= 30:
        score += 3.0

    if profile.goal == "muscle_gain":
        score += min(macros.protein / 8.0, 8.0)
    elif profile.goal == "weight_loss":
        score += 5.0 if macros.calories <= 550 else -3.0
    elif profile.goal == "maintenance":
        score += 3.0 if 450 <= macros.calories <= 750 else 0.0

    if HIGH_PROTEIN_TAG in ri.tags or macros.protein >= 24:
        score += 4.0

    score -= max(0, ri.missing_required_count) * 24.0
    return score


def ranking_reasons(macros: Macros, profile: Profile, ri: RankingInputs,
                    rating: int) -> list:
    """Swift: RecipeRepository.rankingReasons, string-for-string."""
    reasons = []
    if ri.missing_required_count == 0:
        reasons.append("Complete match")
    else:
        reasons.append(f"Almost there (missing {ri.missing_required_count})")

    if ri.time_minutes <= 20:
        reasons.append("Quick cook")

    if profile.goal == "muscle_gain":
        if macros.protein >= 25:
            reasons.append("Fits your goal")
    elif profile.goal == "weight_loss":
        if macros.calories <= 550:
            reasons.append("Fits your goal")
    elif profile.goal == "maintenance":
        if 450 <= macros.calories <= 750:
            reasons.append("Fits your goal")

    if HIGH_PROTEIN_TAG in ri.tags or macros.protein >= 24:
        reasons.append("High protein")

    if len(reasons) < 2 and rating >= 4:
        reasons.append("High health score")

    return reasons[:4]


def rank_order(results: list) -> list:
    """Production sort: rankingScore desc, ties by missingRequiredCount asc then
    timeMinutes asc (RecipeRepository). The replay adds a final stable input-order
    tiebreak, documented as a replay-side determinism guard: production leaves the
    order of full (score, missing, time) ties to Swift's unstable sort."""
    keyed = sorted(
        enumerate(results),
        key=lambda item: (-item[1]["ranking_score"], item[1]["missing"],
                          item[1]["time"], item[0]),
    )
    return [item[1] for item in keyed]


def evaluate(macros: Macros, profile: Profile, ri: RankingInputs) -> dict:
    score = compute_score(macros, profile)
    ranking = shared_ranking_score(macros, profile, ri, score.rating)
    reasons = ranking_reasons(macros, profile, ri, score.rating)
    return {
        "rating": score.rating,
        "label": score.label,
        "reasoning": score.reasoning,
        "ranking_score": ranking,
        "ranking_reasons": reasons,
        "missing": ri.missing_required_count,
        "time": ri.time_minutes,
    }
