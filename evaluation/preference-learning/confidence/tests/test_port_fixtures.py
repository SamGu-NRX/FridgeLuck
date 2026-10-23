"""Differential fixtures for the Python port of ConfidenceLearningService.

Each expected value was hand-derived from the Swift source arithmetic
(apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift on
alpha @ 2e77938) step by step, computed once as a calculator exercise, and
transcribed as a literal below. The comment on each test shows the derivation
steps with the Swift lines. The port must reproduce every literal to 1e-12.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from confidence_port import (  # noqa: E402
    TrustState,
    assess,
    assess_signal,
    blended_signal_reward,
    load_trust,
    prior_for,
    trust_influence,
    beta_update_signal,
)

SWIFT = "apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift"


def test_prior_substring_order():
    # Swift lines 312-330: contains() checks in order; ocr_exact before ocr_fuzzy.
    assert prior_for("reverse_scan.OCR_EXACT.score") == (7.0, 2.0)
    assert prior_for("reverse_scan.vision_detection") == (6.0, 2.4)
    assert prior_for("reverse_scan.ocr_fuzzy.score") == (3.4, 3.0)
    assert prior_for("portion_estimator.food_class") == (2.8, 3.6)
    assert prior_for("macro.provenance") == (4.4, 2.8)
    assert prior_for("gemini_recipe_rerank") == (4.8, 2.7)
    assert prior_for("reverse_scan.recipe_match") == (4.5, 2.9)
    assert prior_for("reverse_scan.required_coverage") == (4.0, 3.0)
    assert prior_for("anything.else") == (4.0, 3.0)


def test_trust_state_properties():
    # Swift lines 66-81: mean = alpha/(alpha+beta);
    # uncertainty = sqrt(mean*(1-mean)/(alpha+beta+1)); sampleSize = alpha+beta.
    t = TrustState(alpha=4.0, beta=3.0)
    assert t.mean == pytest.approx(4 / 7, abs=1e-15)
    assert t.uncertainty == pytest.approx(0.17496355305594127, abs=1e-15)
    assert t.sample_size == pytest.approx(7.0, abs=1e-15)


def test_trust_influence_ramp():
    # Swift line 279: max(0.20, min((sampleSize - 2.0) / 18.0, 1.0)).
    assert trust_influence(7.0) == pytest.approx(5 / 18, abs=1e-15)  # 0.2777...
    assert trust_influence(2.0) == pytest.approx(0.20, abs=1e-15)  # floor
    assert trust_influence(1.0) == pytest.approx(0.20, abs=1e-15)  # below floor
    assert trust_influence(20.0) == pytest.approx(1.0, abs=1e-15)  # cap
    assert trust_influence(100.0) == pytest.approx(1.0, abs=1e-15)


def test_assess_signal_default_prior_raw_08():
    # Hand derivation for key "reverse_scan.required_coverage" (prior 4/3),
    # rawScore = 0.8, weight = 1.0. Swift assessSignal lines 276-294:
    #   mean           = 4/7                          (lines 68-70)
    #   uncertainty    = sqrt((4/7)(3/7)/(4+3+1)) = sqrt(3/98)
    #                  = 0.17496355305594127          (lines 74-76)
    #   influence      = (7-2)/18 = 0.27777...        (line 279)
    #   trustWeighted  = 0.8 * 4/7 = 0.4571428571...  (line 280)
    #   blended        = 0.8*(1-5/18) + (0.8*4/7)*(5/18) = 0.70476190476...  (line 281)
    #   penalty        = 0.20 * 0.17496355305594127 = 0.034992710611188254 (line 282)
    #   adjusted       = 0.7047619047619048 - 0.034992710611188254
    #                  = 0.6697691941507166           (line 283)
    trust = load_trust({}, "reverse_scan.required_coverage")
    out = assess_signal(0.8, 1.0, trust)
    assert out["adjusted_score"] == pytest.approx(0.6697691941507166, abs=1e-12)
    assert out["trust_mean"] == pytest.approx(0.5714285714285714, abs=1e-12)
    assert out["trust_uncertainty"] == pytest.approx(0.17496355305594127, abs=1e-12)


def test_assess_signal_vision_prior_raw_09():
    # Hand derivation for key "reverse_scan.vision_detection" (prior 6/2.4),
    # rawScore = 0.9. Swift lines 276-294:
    #   mean        = 6/8.4 = 0.7142857142857143
    #   uncertainty = sqrt((5/7)(2/7)/9.4) = 0.14734589232268477
    #   influence   = (8.4-2)/18 = 0.35555555555555557
    #   blended     = 0.9*(1-0.35555...) + (0.9*5/7)*0.35555... = 0.8085714285714285
    #   adjusted    = 0.8085714285714285 - 0.2*0.14734589232268477 = 0.7791022501068915
    trust = load_trust({}, "reverse_scan.vision_detection")
    out = assess_signal(0.9, 0.32, trust)
    assert out["adjusted_score"] == pytest.approx(0.7791022501068915, abs=1e-12)


def test_blended_reward():
    # Swift lines 184-188 with reward = 0.96, adjusted = 0.7791022501068915:
    #   calibrationReward = 1 - |0.96 - 0.7791022501068915| = 0.8191022501068915
    #   blendedSignalReward = 0.55*0.96 + 0.45*0.8191022501068915
    #                       = 0.8965960125481012
    assert blended_signal_reward(0.96, 0.7791022501068915) == pytest.approx(
        0.8965960125481012, abs=1e-12
    )


def test_beta_update_after_one_episode():
    # Swift lines 207-211 with prior vision (6, 2.4), weight 0.32, blended
    # reward 0.8965960125481012, decay 0.997:
    #   updateWeight = max(0.25, min(0.32, 1.6)) = 0.32     (line 208)
    #   nextAlpha = 1 + (6-1)*0.997   + 0.8965960125481012*0.32
    #             = 1 + 4.985         + 0.2869107240153924  = 6.271910724015392
    #   nextBeta  = 1 + (2.4-1)*0.997 + (1-0.8965960125481012)*0.32
    #             = 1 + 1.3958        + 0.03308927598460761 = 2.4288892759846075
    trust = load_trust({}, "reverse_scan.vision_detection")
    nxt = beta_update_signal(trust, adjusted_score=0.7791022501068915, reward=0.96, signal_weight=0.32)
    assert nxt.alpha == pytest.approx(6.271910724015393, abs=1e-12)
    assert nxt.beta == pytest.approx(2.4288892759846075, abs=1e-12)


def test_assess_overall_penalty_and_mode():
    # Hand derivation, three signals raw 0.9/0.8/0.3 with weights 0.32/0.30/0.23,
    # trust pinned to (1000, 1) for every key. Swift assess lines 122-147:
    #   mean 1000/1001, uncertainty = sqrt((1000/1001)(1/1001)/1002)
    #     = 0.0009980034940103397, influence = min(999/18, 1) = 1.0
    #   adjusted(raw) = raw*0.999000999... - 0.00019960069880206794
    #     raw 0.9 -> 0.8989012984020971
    #     raw 0.8 -> 0.7990011985019971
    #     raw 0.3 -> 0.2995006990014976           (assessSignal lines 276-294)
    #   overall = exp((0.32*ln 0.8989012984020971 + 0.30*ln 0.7990011985019971
    #                  + 0.23*ln 0.2995006990014976)/0.85) = 0.640469309174228
    #   one low signal (< 0.45): penalty 0.08 -> 0.560469309174228  (line 130)
    #   overall < 0.57 -> estimate_only (lines 139-147)
    trust = TrustState(alpha=1000.0, beta=1.0)
    out = assess(
        [
            {"key": "a", "raw_score": 0.9, "weight": 0.32, "reason": "r a"},
            {"key": "b", "raw_score": 0.8, "weight": 0.30, "reason": "r b"},
            {"key": "c", "raw_score": 0.3, "weight": 0.23, "reason": "r c"},
        ],
        lambda key: trust,
    )
    adj = [s["adjusted_score"] for s in out["signals"]]
    assert adj[0] == pytest.approx(0.8989012984020971, abs=1e-12)
    assert adj[1] == pytest.approx(0.7990011985019971, abs=1e-12)
    assert adj[2] == pytest.approx(0.2995006990014976, abs=1e-12)
    assert out["overall_score"] == pytest.approx(0.560469309174228, abs=1e-12)
    assert out["mode"] == "estimate_only"
    assert out["reasons"] == ["Low confidence in r c."]


def test_assess_mode_review_two_signals():
    # Hand derivation, two signals raw 0.9 (w 0.32) and 0.8 (w 0.30), trust
    # pinned to (10, 0.5). Swift assess lines 122-147:
    #   mean = 10/10.5 = 0.9523809523809524
    #   uncertainty = sqrt((10/10.5)(0.5/10.5)/11.5) = 0.06279814032340832
    #   influence = (10.5-2)/18 = 0.4722222222222222
    #   adjusted(0.9) = 0.9*(1-0.4722222) + 0.9*0.95238095*0.4722222
    #                   - 0.2*0.06279814032340832 = 0.867202276697223
    #   adjusted(0.8) = 0.8*(1-0.4722222) + 0.8*0.95238095*0.4722222
    #                   - 0.2*0.06279814032340832 = 0.7694509539459004
    #   overall = exp((0.32*ln 0.867202276697223 + 0.30*ln 0.7694509539459004)/0.62)
    #           = 0.818442944631686
    #   overall >= 0.57 but < 0.84 -> review_required (lines 139-147)
    trust = TrustState(alpha=10.0, beta=0.5)
    out = assess(
        [
            {"key": "k1", "raw_score": 0.9, "weight": 0.32, "reason": "r1"},
            {"key": "k2", "raw_score": 0.8, "weight": 0.30, "reason": "r2"},
        ],
        lambda key: trust,
    )
    assert out["signals"][0]["adjusted_score"] == pytest.approx(0.867202276697223, abs=1e-12)
    assert out["signals"][1]["adjusted_score"] == pytest.approx(0.7694509539459004, abs=1e-12)
    assert out["mode"] == "review_required"
    assert out["overall_score"] == pytest.approx(0.818442944631686, abs=1e-12)


def test_assess_hard_fail_caps_overall():
    # Swift lines 134-138: hard fail -> estimate_only and overall = min(overall, 0.42).
    trust = TrustState(alpha=10.0, beta=0.5)
    out = assess(
        [{"key": "k1", "raw_score": 0.9, "weight": 0.32, "reason": "r1"}],
        lambda key: trust,
        hard_fail_reasons=["No confident recipe candidate."],
    )
    assert out["mode"] == "estimate_only"
    assert out["overall_score"] == pytest.approx(0.42, abs=1e-12)


def test_assess_empty_signals():
    # Swift lines 98-107.
    out = assess([], lambda key: TrustState(alpha=4.0, beta=3.0))
    assert out["mode"] == "estimate_only"
    assert out["overall_score"] == 0.0
    assert out["signals"] == []


def test_load_trust_clamps_at_one():
    # Swift loadTrust lines 296-310: max(1.0, ...) on read.
    states = {"k": TrustState(alpha=0.2, beta=-3.0)}
    t = load_trust(states, "k")
    assert t.alpha == 1.0
    assert t.beta == 1.0
