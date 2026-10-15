"""Faithful Python port of today's rule ranking.

Two production sources, transcribed statement-for-statement:

- apps/ios/Platform/Persistence/Services/PersonalizationService.swift
  (`personalScore(for:)`)
- apps/ios/Platform/Persistence/Repository/RecipeScoring.swift
  (`sharedRankingScore`), fed by HealthScoringService's rating and
  NutritionService's per-serving macros (both ported in features.py).

Deviation from production, documented: PersonalizationService reads
`cooking_history` with `datetime('now')`; here the history is the replayed
event stream and "now" is the caller-supplied evaluation instant, so the port
is deterministic. Event semantics map 1:1: cooking_history rows are
recipe_cooked events; rating is the payload rating.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence

from .features import Catalog, Recipe, health_score_rating


def _parse_utc(s: str) -> datetime:
    # Local copy of the engine's parse_utc — importing the engine here would
    # be circular (the engine imports the rule port for the ranker arm).
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _days(a: datetime, b: datetime) -> float:
    return (a - b).total_seconds() / 86400.0


@dataclass
class CookRecord:
    """One cooking_history row (from a recipe_cooked event)."""

    recipe_id: str
    rating: Optional[int]
    cooked_at: datetime


class PersonalizationHistory:
    """The cooking_history projection of an event stream."""

    def __init__(self) -> None:
        self.cooks: List[CookRecord] = []

    def add(self, record: CookRecord) -> None:
        self.cooks.append(record)

    @classmethod
    def from_events(cls, events: Iterable[dict]) -> "PersonalizationHistory":
        history = cls()
        for ev in events:
            if ev["kind"] != "recipe_cooked":
                continue
            history.add(
                CookRecord(
                    recipe_id=ev["recipe"]["id"],
                    rating=ev["payload"].get("rating"),
                    cooked_at=ev["at"],
                )
            )
        return history

    def personal_score(self, recipe: Recipe, now: datetime) -> float:
        """PersonalizationService.personalScore(for:) — same arithmetic,
        same clipping. Range roughly [-1.0, +1.0]."""
        score = 0.0

        # AVG(rating) over rated cooks of this recipe: 5-star → +0.4,
        # 3-star → 0, 1-star → -0.4.
        ratings = [c.rating for c in self.cooks if c.recipe_id == recipe.id and c.rating is not None]
        if ratings:
            avg_rating = sum(ratings) / len(ratings)
            score += (avg_rating - 3.0) * 0.2

        # Tag affinity: cooks in the past 30 days on recipes sharing >= 1 tag
        # bit with the target, +0.03 each, capped at +0.3.
        tag_affinity = 0
        for cook in self.cooks:
            if _days(now, cook.cooked_at) > 30.0:
                continue
            other = self._recipe_tags.get(cook.recipe_id)
            if other is not None and (other & recipe.tag_bitmask) > 0:
                tag_affinity += 1
        score += min(0.3, tag_affinity * 0.03)

        # Variety: recently cooked recipes are penalized.
        cooked_at = [c.cooked_at for c in self.cooks if c.recipe_id == recipe.id]
        if cooked_at:
            days_since_last = min(_days(now, t) for t in cooked_at)
            if days_since_last < 3.0:
                score -= 0.3 * (1.0 - days_since_last / 3.0)

        return score

    # The Swift SQL joins against the recipes table; the lab carries the tag
    # bitmasks alongside the history instead of a DB.
    _recipe_tags: Dict[str, int] = {}

    def attach_catalog(self, catalog: Catalog) -> None:
        self._recipe_tags = {rid: r.tag_bitmask for rid, r in catalog.recipes.items()}


@dataclass
class RuleScore:
    """sharedRankingScore's inputs and output for one recipe in one context."""

    recipe: Recipe
    matched_required: int
    total_required: int
    matched_optional: int
    missing_required_count: int
    health_rating: int
    personal_score: float
    macros_protein: float
    goal: str  # general | weight_loss | muscle_gain | maintenance
    score: float


def shared_ranking_score(
    recipe: Recipe,
    pantry: set,
    macros: Dict[str, float],
    personal_score: float,
    goal: str = "general",
    daily_calories: int = 2000,
    protein_pct: float = 0.25,
    carbs_pct: float = 0.45,
    fat_pct: float = 0.30,
) -> RuleScore:
    """RecipeScoring.sharedRankingScore — same terms, same weights."""
    required_ids = {ing_id for ing_id, _ in recipe.required}
    optional_ids = {ing_id for ing_id, _ in recipe.optional}

    matched_required = len(required_ids & pantry)
    total_required = len(required_ids)
    matched_optional = len(optional_ids & pantry)
    missing_required_count = total_required - matched_required

    required_coverage = matched_required / max(total_required, 1)
    optional_contribution = float(matched_optional) * 2.5
    health_rating = health_score_rating(
        macros,
        daily_calories=daily_calories,
        protein_pct=protein_pct,
        carbs_pct=carbs_pct,
        fat_pct=fat_pct,
    )
    health_contribution = float(health_rating) * 6.5
    personalization_contribution = personal_score * 8.0

    score = (
        required_coverage * 72.0
        + optional_contribution
        + health_contribution
        + personalization_contribution
    )

    if recipe.time_minutes <= 15:
        score += 6.0
    elif recipe.time_minutes <= 30:
        score += 3.0

    if goal == "muscle_gain":
        score += min(macros["protein"] / 8.0, 8.0)
    elif goal == "weight_loss":
        score += 5.0 if macros["calories"] <= 550 else -3.0
    elif goal == "maintenance":
        if 450 <= macros["calories"] <= 750:
            score += 3.0
    # goal == "general": no adjustment.

    high_protein_tag = bool(recipe.tag_bitmask & (1 << 9))
    if high_protein_tag or macros["protein"] >= 24:
        score += 4.0

    score -= float(max(0, missing_required_count)) * 24.0

    return RuleScore(
        recipe=recipe,
        matched_required=matched_required,
        total_required=total_required,
        matched_optional=matched_optional,
        missing_required_count=missing_required_count,
        health_rating=health_rating,
        personal_score=personal_score,
        macros_protein=macros["protein"],
        goal=goal,
        score=score,
    )


class RuleRanker:
    """The production ranker as a lab arm: pantry feasibility + personalScore
    + sharedRankingScore, ties broken by recipe id ascending."""

    def __init__(self, catalog: Catalog, goal: str = "general") -> None:
        self.catalog = catalog
        self.goal = goal
        self.history = PersonalizationHistory()
        self.history.attach_catalog(catalog)

    def observe(self, events: Sequence[dict], exposures: Sequence[dict] = ()) -> None:
        """Replay recipe_cooked events into the history (in order). The
        exposures argument exists so every evaluation arm shares one
        observe(events, exposures) interface; the rule arm ignores it."""
        for ev in sorted(events, key=lambda e: (e["at"], e["id"])):
            if ev["kind"] == "recipe_cooked":
                self.history.add(
                    CookRecord(
                        recipe_id=ev["recipe"]["id"],
                        rating=ev["payload"].get("rating"),
                        cooked_at=_parse_utc(ev["at"]),
                    )
                )

    def rule_scores(self, feasible: Sequence[str], pantry: set, now: datetime) -> Dict[str, float]:
        out: Dict[str, float] = {}
        for rid in feasible:
            recipe = self.catalog.recipes[rid]
            macros = self._macros(rid)
            ps = self.history.personal_score(recipe, now)
            out[rid] = shared_ranking_score(recipe, pantry, macros, ps, goal=self.goal).score
        return out

    def rank(self, feasible: Sequence[str], pantry: set, now: datetime) -> List[str]:
        scores = self.rule_scores(feasible, pantry, now)
        return sorted(feasible, key=lambda rid: (-scores[rid], rid))

    _macro_cache: Dict[str, Dict[str, float]] = {}

    def _macros(self, rid: str) -> Dict[str, float]:
        return self.catalog.macros(rid)
