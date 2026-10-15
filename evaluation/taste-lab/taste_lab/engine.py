"""taste-residual-v1 engine — SPEC sections 2 and 4.

The reference math for rated cooks (lazy decay between updates, exposure-share
weighting, contribution = d * c * CAP, 6-decimal canonical floats) is byte-
compatible with docs/spec/taste/contracts/check.py's recompute(): the parity
test replays the contracts' coriander-v1 golden fixture and compares.

This implementation generalizes the contracts' cook-only reference to all 12
event kinds (SPEC section 2.3). The generalization decisions, each documented
where it is made:

1. Final decay to the evaluation instant uses the half-life of the class of
   the feature's LAST update. For cook-only streams this reduces to the
   checker's behaviour (its fixtures only contain rated cooks, hard-coded to
   the cook_rating half-life).
2. recipe_rated with a known cookEventId MERGES into the cook's transaction
   window: an unrated cook's "it got made" update is replaced by the rated
   update (no double counting); a re-rating of an already-rated cook is a
   correction — the old reward is reversed, the new one applied.
3. recipe_unsaved reverses a save by applying the save's update with negative
   weight. Updates are linear in (alpha, beta) before decay, so this undoes
   the reward to first order.
4. ingredient_substituted trains only for motivations "preferred" and
   "none_available"; "recipe_recommended" is ignored.
5. lechef_feedback "too_bland" rewards the recipe's spice features, "too_spicy"
   penalizes them; other tags do not touch posteriors.
6. recipe_viewed / recipe_opened / recipe_skipped require an exposureId that
   resolves to a logged exposure whose slate contains the recipe; events that
   resolve against nothing are dropped (availability is not preference).
7. profile_edited "never_suggest" creates a pinned statement (pinnedValue -8);
   "reopen" removes it. servings_edited and correction_applied never touch
   posteriors; correction_applied mutes the statement it names and suppresses
   regeneration of inferred statements for that statement's featureKey.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from .constants import (
    CAP,
    COOK_NO_RATING_REWARD,
    EXPOSURE_FLOOR,
    GLOBAL_CLAMP,
    HALF_LIFE,
    K_SHRINK,
    PRIOR_ALPHA,
    PRIOR_BETA,
    PROFILE_MIN_DENOMINATOR,
    PROFILE_MIN_RATIO,
    STALE_AFTER_HALF_LIVES,
    STRENGTH,
)


def parse_utc(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def iso_utc(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def decay(dt_days: float, half_life: float) -> float:
    return 2.0 ** (-dt_days / half_life)


def f6(x: float) -> float:
    """Canonical 6-decimal rounding (round-half-even)."""
    return round(x, 6)


@dataclass
class _Posterior:
    alpha: float = PRIOR_ALPHA
    beta: float = PRIOR_BETA
    last_update: Optional[datetime] = None  # last lazy-decay point
    last_evidence: Optional[datetime] = None  # last evidence timestamp
    last_class: str = "cook_rating"  # class of the last update (for final decay)


@dataclass
class _CookWindow:
    """Transaction bookkeeping for one recipe_cooked event (SPEC 9)."""

    recipe_id: str
    exposure_share: float
    rating: Optional[int]
    at: datetime


@dataclass
class RankEntry:
    recipe_id: str
    rule_score: float
    learned_features: List[dict]  # [{"featureKey", "contribution"}]
    learned_contribution: float
    total_score: float

    def to_json(self, recipe_ref: dict) -> dict:
        return {
            "recipe": recipe_ref,
            "ruleScore": f6(self.rule_score),
            "learnedFeatures": [
                {"featureKey": ft["featureKey"], "contribution": f6(ft["contribution"])}
                for ft in self.learned_features
            ],
            "learnedContribution": f6(self.learned_contribution),
            "totalScore": f6(self.total_score),
        }


def _statement_id(feature_key: str, template_id: str) -> str:
    ns = uuid.UUID("5e6f7081-0000-4e00-8f00-000000000000")
    return str(uuid.uuid5(ns, f"{template_id}:{feature_key}"))


class TasteResidualEngine:
    """The learned residual layer. Deterministic: same catalog + events +
    exposures + statements => identical outputs (no RNG anywhere)."""

    def __init__(self, feature_keys_by_recipe: Dict[str, Sequence[str]], name_of: Optional[Dict[str, str]] = None):
        # feature_keys_by_recipe: recipe id -> feature keys (the extractor).
        self._features_of = {rid: sorted(set(fks)) for rid, fks in feature_keys_by_recipe.items()}
        self._name_of = dict(name_of or {})
        self.state: Dict[str, _Posterior] = {}
        self._seen_event_ids: set = set()
        self._cooks: Dict[str, _CookWindow] = {}
        # statementId -> True once correction_applied named it.
        self._corrected_statements: set = set()
        # featureKey -> True once a corrected statement carried that feature.
        self._rejected_features: set = set()
        # featureKey -> pinned statement dict (from input statements and
        # profile_edited never_suggest events).
        self.pinned: Dict[str, dict] = {}
        self.restriction_statements: List[dict] = []
        self._cook_events: List[dict] = []
        self._input_statements: Dict[str, dict] = {}

    # ------------------------------------------------------------------
    # Ingestion
    # ------------------------------------------------------------------

    def ingest(
        self,
        events: Iterable[dict],
        exposures: Iterable[dict],
        statements: Iterable[dict] = (),
    ) -> None:
        """Full replay. Events sort by (at, id); duplicates are no-ops."""
        exposures_by_id = {e["id"]: e for e in exposures}
        self._input_statements = {st["id"]: st for st in statements}
        for st in self._input_statements.values():
            if st["layer"] == "pinned" and st.get("featureKey"):
                self.pinned[st["featureKey"]] = st
            elif st["layer"] == "restriction":
                self.restriction_statements.append(st)

        ordered = sorted(events, key=lambda e: (e["at"], e["id"]))
        for ev in ordered:
            if ev["id"] in self._seen_event_ids:
                continue  # idempotent replay
            self._seen_event_ids.add(ev["id"])
            self._ingest_event(ev, exposures_by_id)
        self.attach_event_log(list(self._cook_events))

    def _share(self, ev: dict, exposures_by_id: dict) -> Optional[float]:
        exp_id = ev["payload"].get("exposureId")
        if not exp_id:
            return None
        exp = exposures_by_id.get(exp_id)
        if exp is None:
            return None
        # Skips/views/opens only count for slate members (SPEC 9): a recipe
        # nobody was shown is availability, not preference.
        slate_ids = {item["recipe"]["id"] for item in exp["slate"]}
        if ev["recipe"] is None or ev["recipe"]["id"] not in slate_ids:
            return None
        share = len(exp["slate"]) / len(exp["feasible"])
        return max(share, EXPOSURE_FLOOR)

    def _update(
        self,
        fk: str,
        at: datetime,
        evidence_class: str,
        reward: float,
        weight: float,
    ) -> None:
        post = self.state.setdefault(fk, _Posterior())
        if post.last_update is not None:
            dt_days = (at - post.last_update).total_seconds() / 86400.0
            d = decay(dt_days, HALF_LIFE[evidence_class])
            post.alpha *= d
            post.beta *= d
        post.alpha += weight * reward
        post.beta += weight * (1.0 - reward)
        post.last_update = at
        post.last_evidence = at
        post.last_class = evidence_class

    def _ingest_event(self, ev: dict, exposures_by_id: dict) -> None:
        kind = ev["kind"]
        at = parse_utc(ev["at"])
        rid = ev["recipe"]["id"] if ev.get("recipe") else None
        features = self._features_of.get(rid, []) if rid else []
        payload = ev.get("payload", {})

        if kind == "recipe_cooked":
            self._cook_events.append(ev)
            rating = payload.get("rating")
            share = self._share(ev, exposures_by_id)
            if share is None:
                share = EXPOSURE_FLOOR  # cook without a logged exposure
            if rating is None:
                self._apply_reward_to_features(features, at, "cook_no_rating", COOK_NO_RATING_REWARD, share * STRENGTH["cook_no_rating"])
            else:
                self._apply_reward_to_features(features, at, "cook_rating", (rating - 1) / 4.0, share * STRENGTH["cook_rating"])
            self._cooks[ev["id"]] = _CookWindow(rid, share, rating, at)

        elif kind == "recipe_rated":
            cook = self._cooks.get(payload.get("cookEventId"))
            rating = payload.get("rating")
            if rating is None:
                return
            reward = (rating - 1) / 4.0
            if cook is None:
                # Standalone rating: its own evidence at strength 1.0.
                self._apply_reward_to_features(features, at, "cook_rating", reward, STRENGTH["cook_rating"])
            elif cook.rating is None:
                # Merge into the cook's window: replace the no-rating update.
                w = cook.exposure_share * STRENGTH["cook_rating"]
                w0 = cook.exposure_share * STRENGTH["cook_no_rating"]
                delta_alpha = w * reward - w0 * COOK_NO_RATING_REWARD
                delta_beta = w * (1.0 - reward) - w0 * (1.0 - COOK_NO_RATING_REWARD)
                self._apply_delta_to_features(self._features_of.get(cook.recipe_id, []), at, "cook_rating", delta_alpha, delta_beta)
                cook.rating = rating
            else:
                # Stray late rating for an already-rated cook: correction.
                old_reward = (cook.rating - 1) / 4.0
                w = cook.exposure_share * STRENGTH["cook_rating"]
                delta = w * (reward - old_reward)
                self._apply_delta_to_features(self._features_of.get(cook.recipe_id, []), at, "cook_rating", delta, -delta)
                cook.rating = rating

        elif kind == "recipe_saved":
            share = self._share(ev, exposures_by_id)
            if share is None:
                share = 1.0  # saved off-surface (recipe detail): full credit
            self._apply_reward_to_features(features, at, "saved", 1.0, share * STRENGTH["saved"])

        elif kind == "recipe_unsaved":
            share = 1.0
            self._apply_reward_to_features(features, at, "saved", 1.0, -share * STRENGTH["saved"])

        elif kind == "recipe_skipped":
            share = self._share(ev, exposures_by_id)
            if share is None:
                return  # skip against no logged slate is not taste
            self._apply_reward_to_features(features, at, "skipped", 0.0, share * STRENGTH["skipped"])

        elif kind == "ingredient_substituted":
            motivation = payload.get("motivation")
            if motivation not in ("preferred", "none_available"):
                return
            away = ev.get("ingredient")
            substitute = payload.get("substituteIngredientId")
            share = 1.0
            for fk in features:
                if fk == f"ingredient:{away}":
                    self._update(fk, at, "substitution", 0.0, share * STRENGTH["substitution"])
                elif fk == f"ingredient:{substitute}":
                    self._update(fk, at, "substitution", 1.0, share * STRENGTH["substitution"])

        elif kind == "lechef_feedback":
            tag = payload.get("tag")
            if tag not in ("too_bland", "too_spicy"):
                return
            reward = 1.0 if tag == "too_bland" else 0.0
            spice_features = [fk for fk in features if fk.startswith("spice:")]
            self._apply_reward_to_features(spice_features, at, "lechef", reward, STRENGTH["lechef"])

        elif kind in ("recipe_viewed", "recipe_opened"):
            evidence_class = "view" if kind == "recipe_viewed" else "open"
            share = self._share(ev, exposures_by_id)
            if share is None:
                return
            self._apply_reward_to_features(features, at, evidence_class, 1.0, share * STRENGTH[evidence_class])

        elif kind == "profile_edited":
            op = payload.get("op")
            fk = payload.get("featureKey")
            if not fk:
                return
            if op == "never_suggest":
                self.pinned[fk] = {
                    "id": _statement_id(fk, "pinned.dont_ask_again"),
                    "layer": "pinned",
                    "featureKind": fk.split(":", 1)[0],
                    "featureKey": fk,
                    "templateId": "pinned.dont_ask_again",
                    "numerator": None,
                    "denominator": None,
                    "state": "active",
                    "mutedUntil": None,
                    "pinnedValue": -8.0,
                    "lastEvidenceAt": ev["at"],
                    "createdAt": ev["at"],
                    "updatedAt": ev["at"],
                    "text": f"You asked not to hear about {self._name(fk)} again.",
                }
            elif op in ("reopen", "remove"):
                self.pinned.pop(fk, None)

        elif kind == "correction_applied":
            statement_id = payload.get("statementId")
            self._corrected_statements.add(statement_id)
            statement = self._input_statements.get(statement_id)
            if statement is not None and statement.get("featureKey"):
                # Inferred statements regenerate only from the corrected rule
                # set (SPEC 4): the feature stops rendering this replay.
                self._rejected_features.add(statement["featureKey"])

        # servings_edited: configures, never trains.

    def _apply_reward_to_features(self, features, at, evidence_class, reward, weight) -> None:
        for fk in features:
            self._update(fk, at, evidence_class, reward, weight)

    def _apply_delta_to_features(self, features, at, evidence_class, delta_alpha, delta_beta) -> None:
        for fk in features:
            post = self.state.setdefault(fk, _Posterior())
            if post.last_update is not None:
                dt_days = (at - post.last_update).total_seconds() / 86400.0
                d = decay(dt_days, HALF_LIFE[evidence_class])
                post.alpha *= d
                post.beta *= d
            post.alpha += delta_alpha
            post.beta += delta_beta
            post.last_update = at
            post.last_class = evidence_class
            # last_evidence unchanged: the evidence instant is the cook's.

    # ------------------------------------------------------------------
    # Contributions and ranking
    # ------------------------------------------------------------------

    def final_state(self, eval_at: str) -> Dict[str, tuple]:
        """Posterior decayed to the evaluation instant: fk -> (alpha, beta,
        last_evidence_dt)."""
        t_eval = parse_utc(eval_at)
        final = {}
        for fk, post in self.state.items():
            a, b = post.alpha, post.beta
            if post.last_update is not None:
                dt_days = (t_eval - post.last_update).total_seconds() / 86400.0
                d = decay(dt_days, HALF_LIFE[post.last_class])
                a, b = a * d, b * d
            final[fk] = (a, b, post.last_evidence)
        return final

    def contributions(self, eval_at: str) -> Dict[str, float]:
        out = {}
        for fk, (a, b, _t) in self.final_state(eval_at).items():
            out[fk] = self._contribution_of(fk, a, b)
        return out

    def _contribution_of(self, fk: str, alpha: float, beta: float) -> float:
        n = alpha + beta
        if n <= 0:
            return 0.0
        d = 2.0 * (alpha / n) - 1.0
        c = n / (n + K_SHRINK)
        cls = fk.split(":", 1)[0]
        return max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, d * c * CAP[cls]))

    def rank(self, rule_scores: Dict[str, float], eval_at: str, pinned_extra: float = 0.0) -> List[RankEntry]:
        """rule_scores: the rule ranker's output for this context (the anchor).
        Ties break by recipe id ascending, as the checker does."""
        contribs = self.contributions(eval_at)
        pinned_by_recipe: Dict[str, float] = {}
        for fk, st in self.pinned.items():
            if st.get("mutedUntil") and parse_utc(st["mutedUntil"]) > parse_utc(eval_at):
                continue
            value = st.get("pinnedValue") or 0.0
            if value:
                for rid, fks in self._features_of.items():
                    if fk in fks:
                        pinned_by_recipe[rid] = pinned_by_recipe.get(rid, 0.0) + value

        entries: List[RankEntry] = []
        for rid, rule in rule_scores.items():
            fks = sorted(self._features_of.get(rid, []))
            learned = [{"featureKey": fk, "contribution": contribs.get(fk, 0.0)} for fk in fks]
            learned_sum = sum(ft["contribution"] for ft in learned)
            # GLOBAL_CLAMP bounds the whole learned sum; pinned values count
            # toward it (SPEC 9: "pinnedValue ... counts toward GLOBAL_CLAMP").
            total_learned = max(-GLOBAL_CLAMP, min(GLOBAL_CLAMP, learned_sum + pinned_by_recipe.get(rid, 0.0)))
            entries.append(
                RankEntry(
                    recipe_id=rid,
                    rule_score=rule,
                    learned_features=learned,
                    learned_contribution=learned_sum,
                    total_score=rule + total_learned,
                )
            )
        entries.sort(key=lambda e: (-e.total_score, e.recipe_id))
        return entries

    # ------------------------------------------------------------------
    # Profile statements (SPEC section 4)
    # ------------------------------------------------------------------

    def profile(self, eval_at: str, catalog: Optional[dict] = None) -> Tuple[List[dict], List[dict]]:
        """Returns (rendered, hidden). `catalog` maps recipe id -> feature
        keys (defaults to the engine's own map)."""
        t_eval = parse_utc(eval_at)
        events_features = catalog or self._features_of

        rendered: List[dict] = []
        hidden: List[dict] = []

        for st in self.restriction_statements:
            rendered.append(dict(st))

        # Inferred statements from cooked-recipe evidence.
        cook_evidence: Dict[str, dict] = {}
        for ev in sorted(self._seen_cook_events(), key=lambda e: (e["at"], e["id"])):
            rid = ev["recipe"]["id"]
            rating = ev["payload"].get("rating")
            for fk in events_features.get(rid, []):
                bucket = cook_evidence.setdefault(
                    fk, {"denominator": 0, "dislikes": 0, "likes": 0, "last": None}
                )
                bucket["denominator"] += 1
                if rating is not None and rating <= 2:
                    bucket["dislikes"] += 1
                if rating is not None and rating >= 4:
                    bucket["likes"] += 1
                bucket["last"] = ev["at"]

        corrected_features = self._corrected_features_from_input()

        for fk in sorted(cook_evidence):
            bucket = cook_evidence[fk]
            cls = fk.split(":", 1)[0]
            stale = bucket["last"] is None or (
                (t_eval - parse_utc(bucket["last"])).total_seconds() / 86400.0
                > STALE_AFTER_HALF_LIVES * HALF_LIFE["cook_rating"]
            )
            if bucket["denominator"] < PROFILE_MIN_DENOMINATOR:
                hidden.append({"featureKey": fk, "reason": "thin-evidence"})
                continue
            if stale:
                hidden.append({"featureKey": fk, "reason": "stale-evidence"})
                continue
            if fk in corrected_features:
                hidden.append({"featureKey": fk, "reason": "rejected"})
                continue
            if fk in self.pinned:
                hidden.append({"featureKey": fk, "reason": "pinned-opposite"})
                continue

            dislike_ratio = bucket["dislikes"] / bucket["denominator"]
            like_ratio = bucket["likes"] / bucket["denominator"]
            if dislike_ratio >= PROFILE_MIN_RATIO:
                hedged = bucket["denominator"] < 10
                numer, denom = bucket["dislikes"], bucket["denominator"]
                name = self._name(fk)
                if hedged:
                    template = "taste.lowrating.hedged"
                    text = (
                        f"You seem to go off {name}: the last {numer} recipes you cooked with it "
                        f"were rated 2 stars or below."
                    )
                else:
                    template = "taste.lowrating.confident"
                    text = (
                        f"You go off {name}: {numer} of the {denom} recipes you cooked with it "
                        f"were rated 2 stars or below."
                    )
                state = dict(
                    id=_statement_id(fk, template),
                    layer="inferred",
                    featureKind=cls,
                    featureKey=fk,
                    templateId=template,
                    numerator=numer,
                    denominator=denom,
                    state="active",
                    mutedUntil=None,
                    pinnedValue=None,
                    lastEvidenceAt=bucket["last"],
                    createdAt=eval_at,
                    updatedAt=eval_at,
                    text=text,
                )
                if state["id"] in self._corrected_statements:
                    state["state"] = "muted"
                    hidden.append({"featureKey": fk, "reason": "muted"})
                    continue
                rendered.append(state)
            elif like_ratio >= PROFILE_MIN_RATIO:
                hedged = bucket["denominator"] < 10
                numer, denom = bucket["likes"], bucket["denominator"]
                name = self._name(fk)
                if hedged:
                    template = "taste.liking.hedged"
                    text = f"You seem to enjoy {name}: it showed up in your higher-rated cooks."
                else:
                    template = "taste.liking.confident"
                    text = f"You enjoy {name}: {numer} of the {denom} recipes you cooked with it were rated 4 stars or more."
                state = dict(
                    id=_statement_id(fk, template),
                    layer="inferred",
                    featureKind=cls,
                    featureKey=fk,
                    templateId=template,
                    numerator=numer,
                    denominator=denom,
                    state="active",
                    mutedUntil=None,
                    pinnedValue=None,
                    lastEvidenceAt=bucket["last"],
                    createdAt=eval_at,
                    updatedAt=eval_at,
                    text=text,
                )
                if state["id"] in self._corrected_statements:
                    state["state"] = "muted"
                    hidden.append({"featureKey": fk, "reason": "muted"})
                    continue
                rendered.append(state)
            else:
                hidden.append({"featureKey": fk, "reason": "thin-evidence"})

        # Pinned statements: render when active, hide with "muted" while
        # mutedUntil is in the future.
        for fk in sorted(self.pinned):
            st = dict(self.pinned[fk])
            muted = st.get("mutedUntil") and parse_utc(st["mutedUntil"]) > t_eval
            if muted:
                st["state"] = "muted"
                hidden.append({"featureKey": fk, "reason": "muted"})
            else:
                st["state"] = "active"
                rendered.append(st)

        return rendered, hidden

    def _seen_cook_events(self) -> List[dict]:
        return self._cook_events_log

    def _corrected_features_from_input(self) -> set:
        return self._rejected_features

    def _name(self, fk: str) -> str:
        return self._name_of.get(fk, fk.split(":", 1)[1])

    # ------------------------------------------------------------------
    # Fixture support
    # ------------------------------------------------------------------

    def attach_event_log(self, events: Sequence[dict]) -> None:
        """The statement layer recomputes numerators/denominators from the
        cooked events; ingest fills this automatically, fixtures may set it
        directly."""
        self._cook_events_log = sorted(events, key=lambda e: (e["at"], e["id"]))
