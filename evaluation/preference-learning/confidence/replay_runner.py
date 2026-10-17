"""Replay protocol for Part 0 confidence evaluation.

Data sources (verbatim copies in data/, SHAs in data/PROVENANCE.md):
- PR #7 (merged into alpha): backend/gemini-agent/evaluation-fixtures/
  reverse-meal-replay-v1.json (12 episodes, proxy_reward + truth_reward) and
  reverse-meal-states-v1.jsonl (16 case rows). Projection matches
  apps/ios/Tools/reverse-meal-eval/main.swift `project(_:)` and
  reverse-meal-spec-v1.md "Source boundary and state projection".
- PR #53 (branch obv/fl-l2-correction-drift, read-only):
  apps/ios/Tools/scan-correction-eval/data/histories.json (300 histories,
  6 families) + data/expected_current.json (committed current-policy
  reference decisions). Scan-level outcome = (reference decision == truth),
  abstentions excluded; the chain is documented in FINDINGS.md.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

from confidence_port import TrustState, assess, beta_update_signal, load_trust

DATA = Path(__file__).resolve().parent / "data"

# Signal keys, weights, and reasons exactly as PR #7's main.swift lines 41-43.
REVERSE_MEAL_KEYS = [
    "reverse_scan.vision_detection",
    "reverse_scan.recipe_match",
    "reverse_scan.required_coverage",
    "reverse_scan.candidate_margin",
]
REVERSE_MEAL_WEIGHTS = [0.32, 0.30, 0.23, 0.15]
REVERSE_MEAL_REASONS = [
    "ingredient detection",
    "recipe match",
    "required ingredient coverage",
    "candidate ambiguity",
]

# The vision key is the one prior-matched key among the four (prior 6/2.4);
# the histories corpus models vision-label scans, so it uses the same key.
HISTORY_SCAN_KEY = "reverse_scan.vision_detection"


def float32(x: float) -> float:
    """Swift `Float(x)` conversion: IEEE binary32 round, then widen to binary64."""
    return struct.unpack("f", struct.pack("f", x))[0]


def project_reverse_meal(producer_state: dict) -> tuple[list[dict], list[str]]:
    """PR #7 main.swift `project(_:)` / reverse-meal-spec-v1.md steps 1-6.

    1. detection confidences -> binary32, clamp [0,1], widen, mean in order
       (empty -> 0)
    2. top candidate confidence_score (first in supplied order), or 0
    3. coverage = matched_required / max(total_required, 1), or 0
    4. margin: none -> 0; one candidate -> 0.82; two+ -> clamp(0.5 + max(gap, 0))
    5. fixed key/weight/reason order
    6. first-match hard-failure rule, no epsilon
    """
    confs = producer_state.get("detection_confidences", [])
    if confs:
        vals = [max(0.0, min(float32(c), 1.0)) for c in confs]
        mean = sum(vals) / len(vals)
    else:
        mean = 0.0
    candidates = producer_state.get("ranked_candidates", [])
    top = candidates[0] if candidates else None
    top_score = float(top["confidence_score"]) if top else 0.0
    coverage = (float(top["matched_required"]) / max(float(top["total_required"]), 1.0)) if top else 0.0
    if not candidates:
        margin = 0.0
    elif len(candidates) < 2:
        margin = 0.82
    else:
        gap = float(top["confidence_score"]) - float(candidates[1]["confidence_score"])
        margin = max(0.0, min(0.5 + max(gap, 0.0), 1.0))

    if top is None:
        fails = ["No confident recipe candidate."]
    elif int(top["missing_required_count"]) > 2:
        fails = ["Too many required ingredients are missing."]
    elif len(candidates) >= 2 and (float(top["confidence_score"]) - float(candidates[1]["confidence_score"])) < 0.06:
        fails = ["Top recipe candidates are highly ambiguous."]
    else:
        fails = []

    values = [mean, top_score, coverage, margin]
    signals = [
        {"key": REVERSE_MEAL_KEYS[i], "raw_score": values[i], "weight": REVERSE_MEAL_WEIGHTS[i], "reason": REVERSE_MEAL_REASONS[i]}
        for i in range(4)
    ]
    return signals, fails


def load_reverse_meal():
    """Returns (states_rows, replay_doc). states_rows: [{case_id, producer_state}]."""
    rows = []
    with (DATA / "reverse-meal-states-v1.jsonl").open() as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    with (DATA / "reverse-meal-replay-v1.json").open() as fh:
        replay = json.load(fh)
    return rows, replay


def run_reverse_meal_online(
    replay: dict,
    reward_source: str,  # "truth" | "proxy"
    prior_overrides: dict | None = None,
    decay: float = 0.997,
    transform=None,  # optional fn(producer_state) -> producer_state for drift injection
):
    """One online pass over the 12 episodes in file order.

    Per episode: project the state, assess with current trust, evaluate the
    mode against the episode's truth_reward, then recordOutcome with the arm's
    reward column — the production loop (assess -> recordOutcome) and PR #7's
    per-case replay.

    Returns per-episode records plus final trust. Hard-fail episodes are
    recorded but flagged; decision metrics exclude them (the spec's
    learner contract forces estimate_only there regardless of trust).
    """
    states = replay["states"]
    trust: dict[str, TrustState] = {}
    records = []
    for episode in replay["episodes"]:
        state = states[episode["state_id"]]
        if transform is not None:
            state = transform(state)
        signals, fails = project_reverse_meal(state)
        assessment = assess(
            signals,
            lambda key: load_trust(trust, key, prior_overrides),
            hard_fail_reasons=fails,
        )
        truth = float(episode["truth_reward"])
        arm_reward = float(episode["proxy_reward"] if reward_source == "proxy" else episode["truth_reward"])
        # recordOutcome (Swift lines 170-232) applies per signal.
        for signal in assessment["signals"]:
            key = signal["key"]
            current = load_trust(trust, key, prior_overrides)
            trust[key] = beta_update_signal(
                current,
                adjusted_score=signal["adjusted_score"],
                reward=arm_reward,
                signal_weight=signal["weight"],
                decay=decay,
            )
        records.append(
            {
                "episode_id": episode["episode_id"],
                "state_id": episode["state_id"],
                "mode": assessment["mode"],
                "overall_score": assessment["overall_score"],
                "adjusted_scores": [s["adjusted_score"] for s in assessment["signals"]],
                "keys": [s["key"] for s in assessment["signals"]],
                "hard_fail": bool(fails),
                "truth": truth,
                "proxy_reward": float(episode["proxy_reward"]),
                "arm_reward": arm_reward,
            }
        )
    return records, trust


# ---------------------------------------------------------------------------
# PR #53 correction histories (read-only reuse).
# ---------------------------------------------------------------------------


def load_histories():
    with (DATA / "scan-correction-histories.json").open() as fh:
        return json.load(fh)


def load_expected_current():
    with (DATA / "scan-correction-expected-current.json").open() as fh:
        return json.load(fh)


def history_scan_series(history: dict, expected_row: list[dict]):
    """Scan series for one history: [(conf, pipeline_correct)] for scans where
    the committed current-policy reference decided (abstentions excluded —
    the pipeline took no action, so the confidence layer's claim had no
    measured outcome). pipeline_correct = (reference decision == truth);
    `truth` is the history's ground-truth product id, authored by PR #53."""
    decisions = {d["i"]: d["decision"] for d in expected_row}
    series = []
    for event in history["events"]:
        if event["type"] != "scan":
            continue
        decision = decisions.get(event["i"])
        if decision is None:
            continue
        series.append({"conf": float(event["conf"]), "correct": 1.0 if decision == event["truth"] else 0.0})
    return series


def run_history_online(series, prior_overrides=None, decay=0.997):
    """Online confidence-service replay over one history's scan series.
    Single vision signal per scan (HISTORY_SCAN_KEY, weight 1.0)."""
    trust: dict[str, TrustState] = {}
    records = []
    for step, point in enumerate(series):
        signals = [{"key": HISTORY_SCAN_KEY, "raw_score": point["conf"], "weight": 1.0, "reason": "ingredient detection"}]
        assessment = assess(signals, lambda key: load_trust(trust, key, prior_overrides))
        outcome = point["correct"]
        # Feed truth as the reward for this arm (the proxy arm is studied on
        # the reverse-meal replay; histories carry no proxy column).
        key = signals[0]["key"]
        current = load_trust(trust, key, prior_overrides)
        trust[key] = beta_update_signal(
            current,
            adjusted_score=assessment["signals"][0]["adjusted_score"],
            reward=outcome,
            signal_weight=1.0,
            decay=decay,
        )
        records.append(
            {
                "step": step,
                "mode": assessment["mode"],
                "overall_score": assessment["overall_score"],
                "adjusted_score": assessment["signals"][0]["adjusted_score"],
                "truth": outcome,
                "hard_fail": False,
            }
        )
    return records
