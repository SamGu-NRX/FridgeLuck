"""Python port of ConfidenceLearningService (apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift on alpha @ 2e77938).

Differentially checked against hand-computed fixtures in tests/test_port_fixtures.py.
Every function cites the Swift lines it mirrors. Pure functions only; state is an
explicit alpha/beta mapping so replays are deterministic and reproducible.

Source line numbers below refer to ConfidenceLearningService.swift (359 lines)
and were re-verified against the file on 2026-10-11.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Priors — Swift `prior(for:)`, lines 312-330. Substring match on the
# lowercased key; first match wins, so ocr_exact must be tested before ocr_fuzzy.
# Values verified against the Swift source:
#   ocr_exact 7.0/2.0, vision 6.0/2.4, ocr_fuzzy 3.4/3.0, portion 2.8/3.6,
#   macro 4.4/2.8, gemini 4.8/2.7, recipe 4.5/2.9, default 4.0/3.0
# ---------------------------------------------------------------------------

PRIOR_TABLE: tuple[tuple[str, tuple[float, float]], ...] = (
    ("ocr_exact", (7.0, 2.0)),
    ("vision", (6.0, 2.4)),
    ("ocr_fuzzy", (3.4, 3.0)),
    ("portion", (2.8, 3.6)),
    ("macro", (4.4, 2.8)),
    ("gemini", (4.8, 2.7)),
    ("recipe", (4.5, 2.9)),
)

DEFAULT_PRIOR = (4.0, 3.0)


def prior_for(key: str, overrides: dict[str, tuple[float, float]] | None = None) -> tuple[float, float]:
    """Swift `prior(for:)` (lines 312-330). `overrides` replaces a matched
    prior by signal-key substring for the sweep arms; None entries fall back
    to the shipped table."""
    normalized = key.lower()
    for needle, shipped in PRIOR_TABLE:
        if needle in normalized:
            if overrides and needle in overrides and overrides[needle] is not None:
                return overrides[needle]
            return shipped
    if overrides and "default" in overrides and overrides["default"] is not None:
        return overrides["default"]
    return DEFAULT_PRIOR


# ---------------------------------------------------------------------------
# TrustState — Swift struct TrustState, lines 66-81.
# ---------------------------------------------------------------------------


@dataclass
class TrustState:
    alpha: float
    beta: float

    @property
    def mean(self) -> float:
        return self.alpha / (self.alpha + self.beta)

    @property
    def uncertainty(self) -> float:
        m = self.mean
        return math.sqrt((m * (1 - m)) / (self.alpha + self.beta + 1))

    @property
    def sample_size(self) -> float:
        return self.alpha + self.beta


# ---------------------------------------------------------------------------
# assessSignal — Swift lines 276-294.
# ---------------------------------------------------------------------------


def trust_influence(sample_size: float) -> float:
    """Swift line 279: max(0.20, min((sampleSize - 2.0) / 18.0, 1.0))."""
    return max(0.20, min((sample_size - 2.0) / 18.0, 1.0))


def assess_signal(raw_score: float, weight: float, trust: TrustState) -> dict:
    """Swift `assessSignal(_:_:)` lines 276-294:
      trustInfluence    = max(0.20, min((trust.sampleSize - 2.0) / 18.0, 1.0))   // line 279
      trustWeightedRaw  = rawScore * trust.mean                                  // line 280
      blended           = rawScore * (1 - influence) + trustWeightedRaw * influence  // line 281
      adjusted          = clamp(blended - 0.20 * trust.uncertainty, 0, 1)        // line 283
    """
    influence = trust_influence(trust.sample_size)
    trust_weighted_raw = raw_score * trust.mean
    blended = (raw_score * (1 - influence)) + (trust_weighted_raw * influence)
    uncertainty_penalty = 0.20 * trust.uncertainty
    adjusted = max(0.0, min(blended - uncertainty_penalty, 1.0))
    return {
        "raw_score": raw_score,
        "weight": weight,
        "adjusted_score": adjusted,
        "trust_mean": trust.mean,
        "trust_uncertainty": trust.uncertainty,
    }


# ---------------------------------------------------------------------------
# assess — Swift `assess(signals:hardFailReasons:)` lines 89-167.
# ---------------------------------------------------------------------------

CONTRADICTION_LOW_CUTOFF = 0.45  # Swift line 124
CONTRADICTION_PENALTY = 0.08  # Swift line 125
EXACT_OVERALL = 0.84  # Swift line 141
EXACT_MIN_ADJUSTED = 0.62  # Swift line 142
REVIEW_OVERALL = 0.57  # Swift line 143
HARD_FAIL_OVERALL_CAP = 0.42  # Swift line 136
LOG_FLOOR = 0.0001  # Swift lines 121-122


def assess(
    signals: list[dict],
    trust_for_key,
    hard_fail_reasons: list[str] | None = None,
) -> dict:
    """Port of `assess(signals:hardFailReasons:)`. `signals` is a list of
    {key, raw_score, weight, reason}; `trust_for_key(key) -> TrustState`."""
    hard_fail_reasons = hard_fail_reasons or []
    if not signals:
        # Swift lines 98-107: empty input -> estimate_only, overall 0.
        return {
            "mode": "estimate_only",
            "overall_score": 0.0,
            "deterministic_ready": False,
            "reasons": ["No confidence signals available."],
            "signals": [],
        }

    assessed = []
    for signal in signals:
        trust = trust_for_key(signal["key"])
        entry = assess_signal(signal["raw_score"], signal["weight"], trust)
        entry["key"] = signal["key"]
        entry["reason"] = signal["reason"]
        assessed.append(entry)

    total_weight = sum(entry["weight"] for entry in assessed)
    weighted_log_sum = sum(
        entry["weight"] * math.log(max(entry["adjusted_score"], LOG_FLOOR))
        for entry in assessed
    )
    overall = math.exp(weighted_log_sum / max(total_weight, LOG_FLOOR))  # Swift line 122

    low_signals = [e for e in assessed if e["adjusted_score"] < CONTRADICTION_LOW_CUTOFF]
    contradiction_penalty = float(len(low_signals)) * CONTRADICTION_PENALTY  # Swift lines 124-127
    overall = max(0.0, min(overall - contradiction_penalty, 1.0))

    reasons = list(hard_fail_reasons)
    for entry in low_signals[:3]:  # Swift lines 129-132: prefix(3)
        reasons.append(f"Low confidence in {entry['reason'].lower()}.")

    if hard_fail_reasons:
        mode = "estimate_only"  # Swift lines 134-138
        overall = min(overall, HARD_FAIL_OVERALL_CAP)
    else:
        minimum_adjusted = min((e["adjusted_score"] for e in assessed), default=0.0)
        if overall >= EXACT_OVERALL and minimum_adjusted >= EXACT_MIN_ADJUSTED:  # Swift 141-142
            mode = "exact"
        elif overall >= REVIEW_OVERALL:  # Swift line 143
            mode = "review_required"
        else:
            mode = "estimate_only"

    return {
        "mode": mode,
        "overall_score": max(0.0, min(overall, 1.0)),
        "deterministic_ready": mode == "exact",
        "reasons": reasons,
        "signals": assessed,
    }


# ---------------------------------------------------------------------------
# recordOutcome — Swift `recordOutcome(assessment:outcomeReward:contextKey:note:)`
# lines 170-232. The stored reward is the 0.55/0.45 blend (lines 184-188, stored
# at lines 194-202); the Beta update uses decay 0.997 on the evidence mass above
# 1 (lines 207-211).
# ---------------------------------------------------------------------------

BLEND_OUTCOME_WEIGHT = 0.55  # Swift line 186
BLEND_CALIBRATION_WEIGHT = 0.45  # Swift line 187
DECAY = 0.997  # Swift line 207
UPDATE_WEIGHT_FLOOR = 0.25  # Swift line 189
UPDATE_WEIGHT_CEIL = 1.6  # Swift line 189


def calibration_reward(reward: float, adjusted_score: float) -> float:
    """Swift line 184: max(0, min(1 - |reward - adjustedScore|, 1))."""
    return max(0.0, min(1.0 - abs(reward - adjusted_score), 1.0))


def blended_signal_reward(reward: float, adjusted_score: float) -> float:
    """Swift lines 185-188: 0.55 * reward + 0.45 * calibrationReward, clamped."""
    reward = max(0.0, min(reward, 1.0))
    calib = calibration_reward(reward, adjusted_score)
    return max(0.0, min(reward * BLEND_OUTCOME_WEIGHT + calib * BLEND_CALIBRATION_WEIGHT, 1.0))


def update_weight(weight: float) -> float:
    """Swift line 189: max(0.25, min(weight, 1.6))."""
    return max(UPDATE_WEIGHT_FLOOR, min(weight, UPDATE_WEIGHT_CEIL))


def beta_update_signal(
    trust: TrustState, adjusted_score: float, reward: float, signal_weight: float, decay: float = DECAY
) -> TrustState:
    blended = blended_signal_reward(reward, adjusted_score)
    w = update_weight(signal_weight)
    next_alpha = 1 + max(0.0, (trust.alpha - 1) * decay) + blended * w
    next_beta = 1 + max(0.0, (trust.beta - 1) * decay) + (1 - blended) * w
    return TrustState(alpha=next_alpha, beta=next_beta)


def load_trust(states: dict[str, TrustState], key: str, prior_overrides=None) -> TrustState:
    """Swift `loadTrust` lines 296-310 clamps at 1.0 on read; missing keys use
    `prior(for:)` exactly as the service does (assess lines 112-115,
    recordOutcome line 205)."""
    if key in states:
        raw = states[key]
        return TrustState(alpha=max(1.0, raw.alpha), beta=max(1.0, raw.beta))
    a, b = prior_for(key, prior_overrides)
    return TrustState(alpha=a, beta=b)


# ---------------------------------------------------------------------------
# calibrationSnapshots — Swift lines 234-274 (SQL at lines 244-259). The stored
# `outcome_reward` column holds the BLENDED reward, so `averageAbsoluteError`
# measures |raw - blended|, not |raw - truth|. Reproduced here so the telemetry
# gap is measurable.
# ---------------------------------------------------------------------------


def calibration_snapshot(events: list[dict], trust_for_key) -> dict:
    """events: [{signal_key, raw_score, stored_outcome_reward}] for one key.
    Returns the snapshot the Swift would print plus the true-error column the
    Swift cannot print (truth is not stored)."""
    n = len(events)
    avg_raw = sum(e["raw_score"] for e in events) / n
    avg_stored = sum(e["stored_outcome_reward"] for e in events) / n
    avg_err_vs_stored = sum(abs(e["raw_score"] - e["stored_outcome_reward"]) for e in events) / n
    trust = trust_for_key(events[0]["signal_key"])
    return {
        "signal_key": events[0]["signal_key"],
        "event_count": n,
        "average_raw_score": avg_raw,
        "average_outcome_reward": avg_stored,
        "average_absolute_error_vs_stored": avg_err_vs_stored,  # what Swift reports
        "trust_mean": trust.mean,
        "trust_uncertainty": trust.uncertainty,
    }
