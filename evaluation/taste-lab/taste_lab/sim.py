"""Seeded household simulator and golden-fixture generation.

Households have LATENT preferences over feature keys (hidden from every
ranking arm). They cook recipes they were shown; their events (ratings,
skips, saves, substitutions, LeChef feedback) are the only things the arms
observe. Ground truth for metrics is the latent utility, never the events.

Determinism: `random.Random(seed)` only. Time advances in whole days. All
timestamps end in Z.
"""

from __future__ import annotations

import json
import random
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Sequence

from .engine import iso_utc
from .features import Catalog


def parse_utc(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def start_day() -> datetime:
    """The fixed simulation start (a Monday, 18:00 UTC). Kept constant so the
    whole pipeline — fixtures included — is reproducible."""
    return datetime(2026, 1, 5, 18, 0, 0)


class Household:
    """One simulated household with latent feature preferences."""

    def __init__(self, household_id: str, rng: random.Random, catalog: Catalog, pool_mode: str = "app"):
        self.id = household_id
        self.catalog = catalog
        self.pool_mode = pool_mode
        # Latent taste: a weight in [-1, 1] per feature key, sparse (each
        # feature is "active" with probability P_ACTIVE).
        self.latent: Dict[str, float] = {}
        self.rng = rng
        for fk in catalog.all_features():
            if rng.random() < 0.35:
                self.latent[fk] = round(rng.uniform(-1.0, 1.0), 3)
        self.goal = rng.choice(["general", "general", "weight_loss", "muscle_gain", "maintenance"])
        self.pantry: set = set()
        self.cook_counts: Dict[str, int] = {}
        self.events: List[dict] = []
        self.exposures: List[dict] = []
        self._seq = 0

    # ------------------------------------------------------------------
    # Latent utilities and behaviour
    # ------------------------------------------------------------------

    def utility(self, rid: str) -> float:
        """Latent utility of a recipe — the ground truth, in [0, 100]."""
        r = self.catalog.recipes[rid]
        base = 50.0
        for fk in r.features:
            base += 12.0 * self.latent.get(fk, 0.0)
        if r.time_minutes <= 20:
            base += 3.0  # everyone mildly prefers quick dinners
        return base

    def _event(self, at: datetime, kind: str, recipe: Optional[str], payload: dict, ingredient: Optional[str] = None) -> dict:
        self._seq += 1
        ev = {
            "id": f"{self.id}-e{self._seq:04d}",
            "at": iso_utc(at),
            "kind": kind,
            "recipe": {"id": recipe, "title": self.catalog.recipes[recipe].title} if recipe else None,
            "payload": payload,
        }
        if ingredient is not None:
            ev["ingredient"] = ingredient
        return ev

    def _log_exposure(self, at: datetime, feasible: Sequence[str], slate: Sequence[str], surface: str) -> str:
        self._seq += 1
        exp_id = f"{self.id}-x{self._seq:04d}"
        self.exposures.append(
            {
                "id": exp_id,
                "at": iso_utc(at),
                "surface": surface,
                "feasible": list(feasible),
                "slate": [{"recipe": {"id": rid, "title": self.catalog.recipes[rid].title}} for rid in slate],
            }
        )
        return exp_id

    def pantry_for_day(self, day_index: int, rng: random.Random) -> set:
        """A plausible pantry: a stable staple set plus rotating produce.
        Deterministic per (household, day).

        Pool modes (the flag the committed gate report documents):
        - `app` (default): the setup the app actually ranks — pantries hold
          the catalog's assumed staples plus a draw of 15-40 other keys, and
          the candidate pool is the exact plus at-most-2-missing tiers of
          RecipeRepositoryCatalogRecommend.
        - `legacy`: the catalog-v2 gate's committed setup, kept reproducible
          behind the flag — pantries draw 160-260 non-staple keys and the pool
          is exact-feasible only (a normal 6-14 key draw leaves 0-2 feasible
          recipes on this catalog, which is why the old setup inflated the
          draw)."""
        catalog = self.catalog
        staples = catalog.staple_ids()
        # App mode guarantees the catalog's assumed staples BEFORE the draw
        # (the product's intake paths always have them): they never compete
        # for draw slots, so the +2.5 sharedRankingScore staple bonus no
        # longer depends on the draw (Greptile P1 on #184 — the v2 loader
        # leaves assumed staples out of staple_ids(), so they used to land in
        # the random 15-40 draw pool). Legacy mode keeps the committed setup
        # unchanged.
        guaranteed = catalog.assumed_staple_keys() if self.pool_mode == "app" else set()
        produce = sorted(
            i.id
            for i in catalog.ingredients.values()
            if i.id not in staples and i.id not in guaranteed
        )
        pantry = set(staples) | guaranteed
        if catalog.is_v2:
            lo, hi = (15, 40) if self.pool_mode == "app" else (160, 260)
        else:
            lo, hi = (6, 14)
        n_extra = rng.randint(lo, hi)
        if produce:
            pantry |= set(rng.sample(produce, min(n_extra, len(produce))))
        return pantry

    def feasible_recipes(self, pantry: set) -> List[str]:
        return sorted(rid for rid, r in self.catalog.recipes.items() if r.feasible(pantry))

    def candidate_pool(self, pantry: set) -> List[str]:
        """The pool the app ranks. `app` mode: the exact tier (0 missing
        required) plus the near-match tier (1-2 missing), with
        RecipeRepositoryCatalogRecommend's feasibility rules — assumed staples
        never block, and a recipe needs at least one blocking required line.
        `legacy` mode: the exact-feasible set only."""
        if self.pool_mode != "app":
            return self.feasible_recipes(pantry)
        return sorted(
            rid
            for rid, r in self.catalog.recipes.items()
            if len(r.required) > 0 and r.missing_required_count(pantry) <= 2
        )

    # ------------------------------------------------------------------
    # One day of life
    # ------------------------------------------------------------------

    def live_day(
        self,
        day: datetime,
        day_index: int,
        slate_size: int,
        chosen_slate_size: int,
        rng: random.Random,
        feedback_rate: float = 0.35,
    ) -> None:
        pantry = self.pantry_for_day(day_index, rng)
        self.pantry = pantry
        pool = self.candidate_pool(pantry)
        if not pool:
            return

        # Ranking surface: the household sees a slate — simulated as a noisy
        # latent-utility browser (a stand-in for "some ranker produced the
        # slate"; the arms under test are re-ranked from the SAME logs).
        utilities = {rid: self.utility(rid) + rng.gauss(0, 6.0) for rid in pool}
        browsed = sorted(pool, key=lambda rid: (-utilities[rid], rid))
        surface = "plan" if day_index % 3 == 0 else "browse"
        chosen = browsed[: min(chosen_slate_size, len(browsed))]
        exposure_id = self._log_exposure(day, pool, chosen, surface)

        cook_p = 0.5 if len(chosen) < 5 else 0.75
        if rng.random() > cook_p:
            # A skip day: skip one shown recipe.
            skip = rng.choice(chosen)
            self.events.append(
                self._event(day, "recipe_skipped", skip, {"exposureId": exposure_id, "position": chosen.index(skip)})
            )
            return

        cooked = rng.choice(chosen)
        self.events.append(
            self._event(day, "recipe_cooked", cooked, {"exposureId": exposure_id, "servings": 2})
        )
        self.cook_counts[cooked] = self.cook_counts.get(cooked, 0) + 1

        # Consume pantry items (required ingredients present).
        for ing_id, _qty in self.catalog.recipes[cooked].required:
            if ing_id in pantry and rng.random() < 0.85:
                pantry.discard(ing_id)

        # Rating: latent utility -> 1..5 stars with salt.
        u = self.utility(cooked) + rng.gauss(0, 5.0)
        stars = max(1, min(5, int(round(u / 25.0))))
        if rng.random() < 0.6:  # not every cook gets rated immediately
            at = day + timedelta(hours=rng.randint(1, 20))
            cook_event_id = self.events[-1]["id"]
            self.events.append(
                self._event(at, "recipe_rated", cooked, {"cookEventId": cook_event_id, "rating": stars})
            )
            if rng.random() < feedback_rate:
                at2 = at + timedelta(hours=rng.randint(1, 10))
                if stars <= 2 and rng.random() < 0.5:
                    tag = "too_bland" if self.latent.get("spice:none", 0) >= 0 else "too_spicy"
                    self.events.append(self._event(at2, "lechef_feedback", cooked, {"tag": tag}))

        # Occasionally save or unsave.
        if rng.random() < 0.15:
            self.events.append(self._event(day + timedelta(hours=22), "recipe_saved", cooked, {"source": "post_cook"}))
        if self.events and rng.random() < 0.03:
            saved = rng.choice(list(self.cook_counts))
            self.events.append(self._event(day + timedelta(hours=23), "recipe_unsaved", saved, {}))

        # Occasional substitution away from a disliked ingredient.
        if rng.random() < 0.08:
            recipe = self.catalog.recipes[cooked]
            away_candidates = [i for i, _q in recipe.required if self.latent.get(f"ingredient:{i}", 0) < -0.2]
            if away_candidates:
                away = rng.choice(sorted(away_candidates))
                subs = self.catalog.substitute_of().get(away, [])
                sub = rng.choice(subs) if subs else None
                motivation = "preferred" if sub else "none_available"
                self.events.append(
                    self._event(
                        day + timedelta(hours=21),
                        "ingredient_substituted",
                        cooked,
                        {"motivation": motivation, "substituteIngredientId": sub},
                        ingredient=away,
                    )
                )


def simulate(
    catalog: Catalog,
    n_households: int,
    days: int,
    start: datetime,
    seed: int,
    slate_size: int = 8,
    chosen_slate_size: int = 6,
    pool_mode: str = "app",
) -> List[Household]:
    """Run the simulation. One RNG per household, derived from the master
    seed — adding households never perturbs earlier households' streams."""
    households: List[Household] = []
    for h_index in range(n_households):
        rng = random.Random(seed * 1_000_003 + h_index)
        h = Household(f"hh{h_index:02d}", rng, catalog, pool_mode=pool_mode)
        for day_index in range(days):
            day = start + timedelta(days=day_index, hours=rng.randint(16, 20))
            h.live_day(day, day_index, slate_size, chosen_slate_size, rng)
        households.append(h)
    return households


def utility_table(h: Household) -> Dict[str, float]:
    return {rid: h.utility(rid) for rid in h.catalog.recipes}


# ----------------------------------------------------------------------
# Golden fixtures
# ----------------------------------------------------------------------

def event_json(ev: dict) -> dict:
    return dict(ev)


def exposure_json(exp: dict) -> dict:
    return dict(exp)


def write_golden_fixture(
    path: str,
    h: Household,
    eval_at: str,
    rendered: List[dict],
    hidden: List[dict],
    ranking: List[dict],
    rule_scores: dict,
    variant: Optional[dict] = None,
) -> None:
    """A committed fixture: inputs (events, exposures, statements) + expected
    outputs (ranking, profile), in the lab's tasteFixture envelope. The rule
    scores that anchored the ranking are stored so validation replays the
    residual layer without re-deriving the pantry. `variant` pins the ranking
    variant the fixture expects (absent = the shipped residual math)."""
    doc = {
        "version": "tasteFixture/v1",
        "name": path.rsplit("/", 1)[-1].replace(".json", ""),
        "evalAt": eval_at,
        "events": [event_json(e) for e in h.events],
        "exposures": [exposure_json(e) for e in h.exposures],
        "statements": [],
        "ruleScores": {rid: round(float(v), 6) for rid, v in rule_scores.items()},
        "expected": {"profile": rendered, "hidden": hidden, "ranking": ranking},
    }
    if variant is not None:
        doc["variant"] = variant
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=False, default=str)
        f.write("\n")
