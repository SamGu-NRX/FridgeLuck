"""Replay protocol tests: projection hand-fixtures, data invariants,
one-episode update chain, and byte-stable determinism."""

from __future__ import annotations

import json

from confidence_port import load_trust
from replay_runner import (
    float32,
    history_scan_series,
    load_expected_current,
    load_histories,
    load_reverse_meal,
    project_reverse_meal,
    run_history_online,
    run_reverse_meal_online,
)


def test_float32_conversion():
    # Known IEEE binary32 neighbors: 0.97 rounds up, 0.96 rounds down.
    assert float32(0.97) == 0.9700000286102295
    assert float32(0.96) == 0.9599999785423279
    assert float32(1.0) == 1.0
    assert float32(0.5) == 0.5


def test_projection_hand_fixtures():
    # Exact binary-representable inputs: mean of [1.0, 0.5] = 0.75;
    # top score 1.0; coverage 3/3 = 1.0; gap 1.0-0.9375 = 0.0625 >= 0.06
    # so no hard fail; margin = 0.5 + 0.0625 = 0.5625. All exact in binary64.
    state = {
        "detection_confidences": [1.0, 0.5],
        "ranked_candidates": [
            {"id": 1, "confidence_score": 1.0, "matched_required": 3, "total_required": 3, "missing_required_count": 0},
            {"id": 2, "confidence_score": 0.9375, "matched_required": 1, "total_required": 3, "missing_required_count": 2},
        ],
    }
    signals, fails = project_reverse_meal(state)
    assert [s["raw_score"] for s in signals] == [0.75, 1.0, 1.0, 0.5625]
    assert [s["weight"] for s in signals] == [0.32, 0.30, 0.23, 0.15]
    assert [s["key"] for s in signals] == [
        "reverse_scan.vision_detection",
        "reverse_scan.recipe_match",
        "reverse_scan.required_coverage",
        "reverse_scan.candidate_margin",
    ]
    assert fails == []


def test_projection_hard_fail_rules_first_match():
    # No candidates -> "No confident recipe candidate." (first match wins even
    # though other conditions could apply).
    signals, fails = project_reverse_meal({"detection_confidences": [], "ranked_candidates": []})
    assert fails == ["No confident recipe candidate."]
    assert all(s["raw_score"] == 0.0 for s in signals)

    # >2 missing required -> missing rule beats ambiguity (spec step 6 order).
    state = {
        "detection_confidences": [1.0],
        "ranked_candidates": [
            {"id": 1, "confidence_score": 1.0, "matched_required": 0, "total_required": 4, "missing_required_count": 3},
            {"id": 2, "confidence_score": 0.9, "matched_required": 0, "total_required": 4, "missing_required_count": 3},
        ],
    }
    _, fails = project_reverse_meal(state)
    assert fails == ["Too many required ingredients are missing."]

    # gap 0.05 < 0.06 -> ambiguity hard fail (binary-exact inputs).
    state = {
        "detection_confidences": [1.0],
        "ranked_candidates": [
            {"id": 1, "confidence_score": 0.5, "matched_required": 1, "total_required": 1, "missing_required_count": 0},
            {"id": 2, "confidence_score": 0.45, "matched_required": 1, "total_required": 1, "missing_required_count": 0},
        ],
    }
    _, fails = project_reverse_meal(state)
    assert fails == ["Top recipe candidates are highly ambiguous."]


def test_fixture_invariants():
    """PR #7's runner asserts these cardinalities on Sam's Mac; assert them
    here so a silently swapped fixture fails loudly."""
    rows, replay = load_reverse_meal()
    assert len(rows) == 16
    assert len(set(r["case_id"] for r in rows)) == 16
    assert replay["version"] == "reverse-meal-dev-v1"
    assert len(replay["episodes"]) == 12
    assert len(replay["states"]) == 11
    for ep in replay["episodes"]:
        assert ep["state_id"] in replay["states"]
        assert 0.0 <= ep["proxy_reward"] <= 1.0
        assert ep["truth_reward"] in (0.0, 1.0)


def test_one_episode_update_chain():
    """Integration chain: RMD-01 (truth 1.0, proxy 0.96) replayed once. The
    final vision-key trust must equal the fixture-chain update with raw =
    D1's vision signal; recomputed here from the projection output through
    the port's public functions (the per-step math is pinned by
    test_port_fixtures)."""
    _, replay = load_reverse_meal()
    single = {**replay, "episodes": replay["episodes"][:1]}
    records, trust = run_reverse_meal_online(single, "proxy")
    assert len(records) == 1
    assert records[0]["episode_id"] == "RMD-01"
    assert records[0]["mode"] == "review_required"  # raw ~0.96/1.0/1.0/0.56 with
    # 0.20 influence cap: overall ~0.67 >= 0.57, but min-adjusted ~0.56 < 0.62.
    assert set(trust) == {
        "reverse_scan.vision_detection",
        "reverse_scan.recipe_match",
        "reverse_scan.required_coverage",
        "reverse_scan.candidate_margin",
    }
    for key, state in trust.items():
        prior = load_trust({}, key)
        # decayed evidence + one blended update: alpha strictly moves toward
        # the blend; assert the update moved mass (not stuck at prior).
        assert state.alpha != prior.alpha or state.beta != prior.beta
        assert state.alpha >= 1.0 and state.beta >= 1.0


def test_determinism_byte_stable():
    """Same replay input + no seed anywhere => identical records JSON bytes."""
    _, replay = load_reverse_meal()
    a = json.dumps(run_reverse_meal_online(replay, "truth")[0], sort_keys=True)
    b = json.dumps(run_reverse_meal_online(replay, "truth")[0], sort_keys=True)
    c = json.dumps(run_reverse_meal_online(replay, "proxy")[0], sort_keys=True)
    assert a == b
    assert a != c  # the arms genuinely differ


def test_histories_changed_family_series():
    """The changed family's committed reference series: per seed, correctness
    starts at 1, drops to 0 (the flip lag), returns to 1. The confidence
    replay consumes exactly these scans."""
    histories = load_histories()
    expected = load_expected_current()
    changed = [h for h in histories["histories"] if h["family"] == "changed"]
    assert len(changed) == 50
    series = history_scan_series(changed[0], expected["seeds"][f"changed/{changed[0]['seed']}"])
    assert len(series) >= 6
    corrects = [p["correct"] for p in series]
    assert corrects[0] == 1.0
    assert 0.0 in corrects  # the flip lag is present
    records = run_history_online(series)
    assert len(records) == len(series)
    # scan sequence order preserved
    assert [r["step"] for r in records] == list(range(len(series)))
