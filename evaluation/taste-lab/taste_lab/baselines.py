"""Evaluation arms.

Arms are objects with `rank(feasible, pantry, now) -> [recipe ids]`. The rule
arm IS the production port (rules.RuleRanker). The residual arm anchors on the
rule arm's scores — the spec's structure (totalScore = ruleScore + residual).
"""

from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional, Sequence

from .engine import TasteResidualEngine, normalize_variant
from .features import Catalog
from .rules import RuleRanker


class ResidualArm:
    """taste-residual-v1: rule anchor + engine contributions. The engine is
    fed the arm's own observed events so far (on-line learning).

    variant: an optional ranking-variant spec (see
    TasteResidualEngine.normalize_variant) — "churn_bounded" bounds the
    learned layer's reordering to near-tie runs of the rule order; "shrunk"
    additionally shrinks contributions by evidence count. The arm name carries
    the variant so reports can tell arms apart."""

    def __init__(self, catalog: Catalog, rule: RuleRanker, variant: Optional[dict] = None, name: str = "residual"):
        self.catalog = catalog
        self.rule = rule
        self.variant = normalize_variant(variant)
        self.name = name if self.variant is None else f"{name}_{self.variant['name']}"
        self.engine = TasteResidualEngine(
            {rid: r.features for rid, r in catalog.recipes.items()},
            name_of=catalog.feature_names,
        )

    def observe(self, events: Sequence[dict], exposures: Sequence[dict]) -> None:
        self.engine.ingest(events, exposures)

    def rank(self, feasible: Sequence[str], pantry: set, now: datetime) -> List[str]:
        rule_scores = self.rule.rule_scores(feasible, pantry, now)
        entries = self.engine.rank(
            rule_scores, now.strftime("%Y-%m-%dT%H:%M:%SZ"), variant=self.variant
        )
        return [e.recipe_id for e in entries]


class ProfileOnlyArm:
    """Explicit-profile-only baseline (the #115 family): ranks by the
    explicit personalization history and the declared health profile — no
    pantry-fit, no learned layer. Documented seam: it still respects the same
    feasible set."""

    name = "profile_only"

    def __init__(self, catalog: Catalog, rule: RuleRanker):
        self.catalog = catalog
        self.rule = rule

    def observe(self, events: Sequence[dict], exposures: Sequence[dict]) -> None:
        self.rule.observe(events)

    def rank(self, feasible: Sequence[str], pantry: set, now: datetime) -> List[str]:
        scores: Dict[str, float] = {}
        for rid in feasible:
            recipe = self.catalog.recipes[rid]
            ps = self.rule.history.personal_score(recipe, now)
            macros = self.catalog.macros(rid)
            from .features import health_score_rating

            scores[rid] = ps * 8.0 + health_score_rating(macros) * 6.5
        return sorted(feasible, key=lambda rid: (-scores[rid], rid))


class PopularityArm:
    """Popularity baseline. On-device honesty constraint: the app cannot see
    other households' history, so 'popularity' here is the household's own
    repeat-cook frequency (a habit proxy), ties by rule order then id."""

    name = "popularity"

    def __init__(self, catalog: Catalog, rule: RuleRanker):
        self.catalog = catalog
        self.rule = rule
        self.cook_counts: Dict[str, int] = {}

    def observe(self, events: Sequence[dict], exposures: Sequence[dict]) -> None:
        self.rule.observe(events)
        for ev in events:
            if ev["kind"] == "recipe_cooked":
                rid = ev["recipe"]["id"]
                self.cook_counts[rid] = self.cook_counts.get(rid, 0) + 1

    def rank(self, feasible: Sequence[str], pantry: set, now: datetime) -> List[str]:
        rule_scores = self.rule.rule_scores(feasible, pantry, now)
        return sorted(
            feasible,
            key=lambda rid: (-self.cook_counts.get(rid, 0), -rule_scores[rid], rid),
        )
