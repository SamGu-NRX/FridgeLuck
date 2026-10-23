#!/usr/bin/env python3
"""Deterministic experiment driver for Part 0 (confidence evaluation).

Writes results/metrics.json (sorted keys, no timestamps).
Run: python3 experiments/run_all.py

Arms on the PR #7 reverse-meal replay (12 episodes, file order):
  beta-proxy      as built: shipped priors, decay 0.997, recordOutcome fed proxy_reward
  beta-truth      control:  shipped priors, decay 0.997, recordOutcome fed truth_reward
  prior-jeffreys  Beta(1,1) on every key, truth reward
  prior-flat-10-5 Beta(10,5) on every key, truth reward
  prior-doubled   shipped priors doubled (alpha,beta)*2, truth reward
  decay-1.00      shipped priors, no decay, truth reward
  decay-0.990     shipped priors, decay 0.99, truth reward
  decay-0.999     shipped priors, decay 0.999, truth reward
Alternatives (same episodes, same decision thresholds):
  isotonic-pava   isotonic (PAVA) on the raw overall score (in-sample + LOO)
  logistic        per-signal logistic (raw, key one-hots, trust uncertainty), in-sample + LOO
Drift:
  capability drop injected on reverse-meal (documented transform, from episode 7)
  changed family of PR #53 histories (authored truth flip, 50 seeds)
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from calibrators import (  # noqa: E402
    geo_mean_signal_scores,
    isotonic_fit,
    isotonic_predict,
    logistic_fit,
    logistic_predict,
)
from confidence_port import TrustState, assess, beta_update_signal, load_trust  # noqa: E402
from metrics import (  # noqa: E402
    BOOTSTRAP_B,
    BOOTSTRAP_SEED,
    MODE_ERROR_BAR,
    bootstrap_metric,
    brier,
    cumulative_mode_error_rate,
    decision_counts,
    ece,
    first_exact_episode,
    reliability_curve,
    stabilization_episode,
    trailing_stabilization_episode,
)
from replay_runner import (  # noqa: E402
    REVERSE_MEAL_WEIGHTS,
    history_scan_series,
    load_expected_current,
    load_histories,
    load_reverse_meal,
    project_reverse_meal,
    run_history_online,
    run_reverse_meal_online,
)

RESULTS = ROOT / "results"

SHIPPED = {
    "ocr_exact": (7.0, 2.0), "vision": (6.0, 2.4), "ocr_fuzzy": (3.4, 3.0),
    "portion": (2.8, 3.6), "macro": (4.4, 2.8), "gemini": (4.8, 2.7),
    "recipe": (4.5, 2.9), "default": (4.0, 3.0),
}

# Spec-derived outcome labels for the held-out rows (reverse-meal-spec-v1.md,
# "Family coverage and reference meaning" table: RM-03/04/13 are correct
# proposal / wrong recipe / wrong servings; RM-05 and RM-14 are correct
# despite weak evidence; RM-06 correct vs RM-16 wrong on quantity; RM-07's
# top dish happens to be correct but the request hard-fails on ambiguity).
SPEC_LABELED = {
    "RM-03": 1.0, "RM-04": 0.0, "RM-13": 0.0,
    "RM-05": 1.0, "RM-14": 1.0,
    "RM-06": 1.0, "RM-16": 0.0,
    "RM-07": 1.0,
}
SPEC_UNLABELED = ["RM-01", "RM-02", "RM-08", "RM-09", "RM-10", "RM-11", "RM-12", "RM-15"]

ARMS = [
    ("beta-proxy", "proxy", None, 0.997),
    ("beta-truth", "truth", None, 0.997),
    ("prior-jeffreys", "truth", {k: (1.0, 1.0) for k in SHIPPED}, 0.997),
    ("prior-flat-10-5", "truth", {k: (10.0, 5.0) for k in SHIPPED}, 0.997),
    ("prior-doubled", "truth", {k: (2 * a, 2 * b) for k, (a, b) in SHIPPED.items()}, 0.997),
    ("decay-1.00", "truth", None, 1.0),
    ("decay-0.990", "truth", None, 0.99),
    ("decay-0.999", "truth", None, 0.999),
]

DROP_AFTER_EPISODE = 6  # 0-based index of the first degraded episode (episodes 7-12)
DROP_FACTORS = [0.9, 0.75, 0.6]  # primary first; the rest are sensitivity
TRAILING_WINDOW = 4


def capability_drop(factor: float):
    """Documented drift transform: episodes after the change point get every
    raw score multiplied by `factor`, clamped to [0,1]. Truth labels are
    unchanged — the transform degrades the producer's ability to discern the
    same underlying outcomes (the confidence layer must stop overclaiming
    when its signals go bad while trust is still warm)."""

    def transform(state: dict) -> dict:
        return {
            "detection_confidences": [min(max(c * factor, 0.0), 1.0) for c in state.get("detection_confidences", [])],
            "ranked_candidates": [
                {**c, "confidence_score": min(max(float(c["confidence_score"]) * factor, 0.0), 1.0)}
                for c in state.get("ranked_candidates", [])
            ],
        }

    return transform


def records_fn_for(reward_source, prior_overrides, decay):
    """records_fn for the episode bootstrap: rerun the online replay over the
    resampled episode order/composition."""

    def fn(indices):
        _, replay = load_reverse_meal()
        episodes = replay["episodes"]
        sub = {**replay, "episodes": [episodes[i] for i in indices]}
        records, _ = run_reverse_meal_online(sub, reward_source, prior_overrides, decay)
        return records

    return fn


def arm_metrics(records):
    usable = [r for r in records if not r["hard_fail"]]
    pooled_adj = [s for r in usable for s in r["adjusted_scores"]]
    pooled_truth = [r["truth"] for r in usable for _ in r["adjusted_scores"]]
    return {
        "overall_ece_vs_truth": ece([r["overall_score"] for r in usable], [r["truth"] for r in usable]),
        "pooled_signal_ece_vs_truth": ece(pooled_adj, pooled_truth),
        "overall_brier_vs_truth": brier([r["overall_score"] for r in usable], [r["truth"] for r in usable]),
        "decision": decision_counts(records),
        "stabilization_episode_cumulative": stabilization_episode(records),
        "stabilization_episode_trailing4": trailing_stabilization_episode(records),
        "cumulative_mode_error": cumulative_mode_error_rate(records),
    }


def bootstrap_arm_metrics(records_fn, n_items):
    """Intervals for overall ECE and mode error rate; stabilization summary
    from the same resampling scheme (fixed seed per statistic, documented)."""

    def ece_stat(records):
        usable = [r for r in records if not r["hard_fail"]]
        return ece([r["overall_score"] for r in usable], [r["truth"] for r in usable])

    def err_stat(records):
        rate = decision_counts(records)["mode_error_rate"]
        return rate if rate is not None else 0.0

    ece_ci = bootstrap_metric(records_fn, n_items, ece_stat)
    err_ci = bootstrap_metric(records_fn, n_items, err_stat)
    rng = random.Random(BOOTSTRAP_SEED)
    stabs = []
    for _ in range(BOOTSTRAP_B):
        idx = [rng.randrange(n_items) for _ in range(n_items)]
        s = stabilization_episode(records_fn(idx))
        if s is not None:
            stabs.append(s)
    stab_summary = {
        "reached_fraction": len(stabs) / BOOTSTRAP_B,
        "median_when_reached": sorted(stabs)[len(stabs) // 2] if stabs else None,
        "bar": MODE_ERROR_BAR,
        "b": BOOTSTRAP_B,
        "seed": BOOTSTRAP_SEED,
    }
    return {"overall_ece_vs_truth": ece_ci, "mode_error_rate": err_ci, "stabilization": stab_summary}


def raw_scores_by_episode_id():
    _, replay = load_reverse_meal()
    states = replay["states"]
    out = {}
    for ep in replay["episodes"]:
        signals, _ = project_reverse_meal(states[ep["state_id"]])
        out[ep["episode_id"]] = [s["raw_score"] for s in signals]
    return out


def calibration_snapshot_gap(records, raw_by_ep):
    """What the Swift's calibrationSnapshots reports vs the true error on
    identical episodes. Stored reward = 0.55/0.45 blend (Swift lines 184-188);
    the snapshot's averageAbsoluteError is |raw - stored| — truth never enters."""
    rows = []
    for r in records:
        if r["hard_fail"]:
            continue
        for key, raw, adj in zip(r["keys"], raw_by_ep[r["episode_id"]], r["adjusted_scores"]):
            calib = max(0.0, min(1 - abs(r["arm_reward"] - adj), 1.0))
            stored = max(0.0, min(r["arm_reward"] * 0.55 + calib * 0.45, 1.0))
            rows.append({"key": key, "raw": raw, "stored": stored, "truth": r["truth"]})
    per_key = {}
    for key in sorted(set(row["key"] for row in rows)):
        sub = [row for row in rows if row["key"] == key]
        per_key[key] = {
            "n": len(sub),
            "avg_abs_error_vs_stored": sum(abs(row["raw"] - row["stored"]) for row in sub) / len(sub),
            "avg_abs_error_vs_truth": sum(abs(row["raw"] - row["truth"]) for row in sub) / len(sub),
        }
    n = len(rows)
    return {
        "pooled": {
            "n": n,
            "avg_abs_error_vs_stored": sum(abs(row["raw"] - row["stored"]) for row in rows) / n,
            "avg_abs_error_vs_truth": sum(abs(row["raw"] - row["truth"]) for row in rows) / n,
        },
        "per_key": per_key,
    }


# ---------------------------------------------------------------------------
# Alternatives on the same episodes
# ---------------------------------------------------------------------------


def signal_rows_for_alternatives(replay):
    """Per-episode (overall raw, truth) pairs and per-episode per-signal rows
    (raw, key_index, uncertainty, truth). The uncertainty feature comes from
    the as-built trust evolution under the truth arm (documented entanglement:
    the logistic re-maps the service's own uncertainty signal)."""
    states = replay["states"]
    ep_overall_raw = []
    ep_truth = []
    sig_rows_by_episode = []
    trust: dict[str, TrustState] = {}
    for ep in replay["episodes"]:
        signals, fails = project_reverse_meal(states[ep["state_id"]])
        truth = float(ep["truth_reward"])
        raw_scores = [s["raw_score"] for s in signals]
        overall_raw = geo_mean_signal_scores(raw_scores, REVERSE_MEAL_WEIGHTS)
        if not fails:
            ep_overall_raw.append(overall_raw)
            ep_truth.append(truth)
        assessment = assess(signals, lambda key: load_trust(trust, key, None), hard_fail_reasons=fails)
        rows = []
        for j, s in enumerate(assessment["signals"]):
            if not fails:
                rows.append({
                    "raw": s["raw_score"],
                    "key_index": j,
                    "uncertainty": s["trust_uncertainty"],
                    "truth": truth,
                })
        if rows:
            sig_rows_by_episode.append(rows)
        for s in assessment["signals"]:
            key = s["key"]
            current = load_trust(trust, key, None)
            trust[key] = beta_update_signal(
                current,
                adjusted_score=s["adjusted_score"],
                reward=truth,
                signal_weight=s["weight"],
            )
    return ep_overall_raw, ep_truth, sig_rows_by_episode


def run_isotonic(ep_raw, ep_truth):
    """Isotonic (PAVA) on the per-episode (raw overall, truth) pairs.
    Returns in-sample and leave-one-out predicted probabilities."""
    knots = isotonic_fit(ep_raw, ep_truth)
    preds = [isotonic_predict(knots, x) for x in ep_raw]
    loo_preds = []
    for i in range(len(ep_raw)):
        sub_x = [x for j, x in enumerate(ep_raw) if j != i]
        sub_y = [y for j, y in enumerate(ep_truth) if j != i]
        sub_knots = isotonic_fit(sub_x, sub_y)
        loo_preds.append(isotonic_predict(sub_knots, ep_raw[i]))
    return preds, loo_preds


def run_logistic(episodes_rows):
    """Per-signal logistic: features [raw, recipe dummy, coverage dummy,
    margin dummy, uncertainty]. `episodes_rows` is a list (episodes) of row
    lists (4 signals). Fits on ALL rows, then leave-one-EPISODE-out: fit on
    the other episodes' rows, predict this episode's 4 rows."""
    def feats(rows):
        return [
            [r["raw"], 1.0 if r["key_index"] == 1 else 0.0,
             1.0 if r["key_index"] == 2 else 0.0,
             1.0 if r["key_index"] == 3 else 0.0,
             r["uncertainty"]]
            for r in rows
        ]

    def labels(rows):
        return [r["truth"] for r in rows]

    flat = [row for rows in episodes_rows for row in rows]
    X, y = feats(flat), labels(flat)
    model = logistic_fit(X, y, lam=1.0, iters=400, lr=0.5)
    preds = logistic_predict(X, model)
    loo_rows = []
    for i, rows in enumerate(episodes_rows):
        sub = [row for j, other in enumerate(episodes_rows) if j != i for row in other]
        sub_model = logistic_fit(feats(sub), labels(sub), lam=1.0, iters=400, lr=0.5)
        loo_rows.extend(logistic_predict(feats(rows), sub_model))
    return preds, loo_rows


def modes_from_calibrated_signal_scores(signal_scores_by_episode, weights):
    """Service thresholds on the geometric mean of calibrated per-signal
    scores (documented apples-to-apples choice)."""
    out = []
    for scores in signal_scores_by_episode:
        overall = geo_mean_signal_scores(scores, weights)
        min_adj = min(scores)
        if overall >= 0.84 and min_adj >= 0.62:
            mode = "exact"
        elif overall >= 0.57:
            mode = "review_required"
        else:
            mode = "estimate_only"
        out.append({"mode": mode, "overall_score": overall})
    return out


# ---------------------------------------------------------------------------
# Drift
# ---------------------------------------------------------------------------


def trailing_error_rate(usable, k, window=TRAILING_WINDOW):
    """Mode error rate over usable[k-window+1 .. k]. None if under 2 samples."""
    lo = max(0, k - window + 1)
    sub = usable[lo:k + 1]
    if len(sub) < 2:
        return None
    errors = sum(1 for r in sub if (r["mode"] == "exact" and r["truth"] == 0.0) or (r["mode"] == "estimate_only" and r["truth"] == 1.0))
    return errors / len(sub)


def recovery_episode(records, change_index, bar=MODE_ERROR_BAR, window=TRAILING_WINDOW):
    """Usable episodes after the change until the trailing-window error rate
    is <= bar and stays <= bar through the end. None if not reached.
    `change_index` is the 0-based index in the original record list of the
    first post-change record."""
    usable_positions = [i for i, r in enumerate(records) if not r["hard_fail"]]
    usable = [records[i] for i in usable_positions]
    start = next((u for u, p in zip(range(len(usable_positions)), usable_positions) if p >= change_index), None)
    if start is None:
        return None
    for k in range(start, len(usable)):
        rate = trailing_error_rate(usable, k, window)
        if rate is not None and rate <= bar:
            stable = True
            for k2 in range(k, len(usable)):
                later = trailing_error_rate(usable, k2, window)
                if later is None or later > bar:
                    stable = False
                    break
            if stable:
                return k - start + 1
    return None


def run_synthetic_drop(factor: float, reward_source: str):
    """Replay with the capability drop applied ONLY to episodes at/after
    DROP_AFTER_EPISODE (the docstring in capability_drop promises a change
    point; scale the state each such episode references — state list
    positions do not match episode positions because 4 spec rows have no
    episode)."""
    _, replay = load_reverse_meal()
    drop = capability_drop(factor)
    states = dict(replay["states"])
    for position, episode in enumerate(replay["episodes"]):
        if position >= DROP_AFTER_EPISODE:
            states[episode["state_id"]] = drop(states[episode["state_id"]])
    records, _ = run_reverse_meal_online({**replay, "states": states}, reward_source)
    return records


def base_rate_strawman(ep_truth):
    """Expanding-mean base-rate predictor: for each episode, the mean truth
    of all PRIOR episodes (0.5 before any). A calibration floor no adaptive
    method should lose to. Scores only; its decisions under the fixed
    thresholds (p ~= 0.42-0.5 -> estimate_only) are reported for context."""
    preds = []
    running = [0.5]
    for t in ep_truth[:-1]:
        preds.append(running[-1])
        running.append(running[-1] + (t - running[-1]) / (len(running)))
    return preds


def extended_first_exact(replay, reward_source, passes):
    """Repeat the 12-episode sequence `passes` times (documented synthetic
    extension: tests whether the exact gate is reachable at all as trust
    accumulates). Returns first-exact episode, exact counts, and the max
    overall score seen."""
    sub = {**replay, "episodes": replay["episodes"] * passes}
    records, _ = run_reverse_meal_online(sub, reward_source)
    usable = [r for r in records if not r["hard_fail"]]
    counts = decision_counts(records)
    return {
        "passes": passes,
        "episodes": len(sub["episodes"]),
        "first_exact_episode": first_exact_episode(records),
        "exact_n": counts["exact_n"],
        "exact_right": counts["exact_right"],
        "exact_wrong": counts["exact_wrong"],
        "max_overall": max(r["overall_score"] for r in usable) if usable else None,
        "mode_error_rate": counts["mode_error_rate"],
    }


def changed_family_recovery():
    """Recovery on PR #53's changed family (50 seeds, authored truth flip).
    Change point per history = first scan where the committed reference
    correctness drops from correct to wrong (in this family that IS the truth
    flip by construction: the pipeline lags the flip). Metric: usable scans
    after the change until the trailing-4 mode error rate is <= 0.25 and
    stays there."""
    histories = load_histories()["histories"]
    expected = load_expected_current()["seeds"]
    recoveries = []
    not_reached = 0
    for history in histories:
        if history["family"] != "changed":
            continue
        series = history_scan_series(history, expected[f"{history['family']}/{history['seed']}"])
        if len(series) < 6:
            continue
        records = run_history_online(series)
        change = None
        for i in range(1, len(series)):
            if series[i - 1]["correct"] == 1.0 and series[i]["correct"] == 0.0:
                change = i
                break
        if change is None:
            continue
        rec = recovery_episode(records, change)
        if rec is None:
            not_reached += 1
        else:
            recoveries.append(rec)
    return {
        "n_seeds": len(recoveries) + not_reached,
        "reached": len(recoveries),
        "not_reached": not_reached,
        "median_scans_to_recovery": sorted(recoveries)[len(recoveries) // 2] if recoveries else None,
        "min": min(recoveries) if recoveries else None,
        "max": max(recoveries) if recoveries else None,
        "bar": MODE_ERROR_BAR,
        "window": TRAILING_WINDOW,
    }


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    _, replay = load_reverse_meal()
    n_eps = len(replay["episodes"])

    # --- service arms ---
    arm_results = {}
    for name, source, overrides, decay in ARMS:
        records, final_trust = run_reverse_meal_online(replay, source, overrides, decay)
        fn = records_fn_for(source, overrides, decay)
        arm_results[name] = {
            "config": {
                "reward_source": source,
                "decay": decay,
                "priors": {k: list(v) for k, v in (overrides or {}).items()} or "shipped",
            },
            "metrics": arm_metrics(records),
            "bootstrap": bootstrap_arm_metrics(fn, n_eps),
            "final_trust": {k: [v.alpha, v.beta] for k, v in sorted(final_trust.items())},
            "reliability_overall": reliability_curve(
                [r["overall_score"] for r in records if not r["hard_fail"]],
                [r["truth"] for r in records if not r["hard_fail"]],
            ),
        }

    # --- headline telemetry gap on identical episodes ---
    raw_by_ep = raw_scores_by_episode_id()
    records_proxy, _ = run_reverse_meal_online(replay, "proxy")
    records_truth, _ = run_reverse_meal_online(replay, "truth")
    gap = {
        "beta-proxy": calibration_snapshot_gap(records_proxy, raw_by_ep),
        "beta-truth": calibration_snapshot_gap(records_truth, raw_by_ep),
    }

    # --- alternatives ---
    ep_raw, ep_truth, sig_rows_by_episode = signal_rows_for_alternatives(replay)
    iso_preds, iso_loo = run_isotonic(ep_raw, ep_truth)
    log_preds, log_loo = run_logistic(sig_rows_by_episode)
    iso_modes = modes_from_calibrated_signal_scores([[p] for p in iso_preds], [1.0])
    iso_loo_modes = modes_from_calibrated_signal_scores([[p] for p in iso_loo], [1.0])
    log_modes = modes_from_calibrated_signal_scores(
        [log_preds[i:i + 4] for i in range(0, len(log_preds), 4)], REVERSE_MEAL_WEIGHTS)
    log_loo_modes = modes_from_calibrated_signal_scores(
        [log_loo[i:i + 4] for i in range(0, len(log_loo), 4)], REVERSE_MEAL_WEIGHTS)

    def alt_record(modes):
        usable = [{"mode": m["mode"], "truth": t, "hard_fail": False} for m, t in zip(modes, ep_truth)]
        return {
            "ece_vs_truth": ece([m["overall_score"] for m in modes], ep_truth),
            "brier_vs_truth": brier([m["overall_score"] for m in modes], ep_truth),
            "decision": decision_counts(usable),
        }

    alternatives = {
        "isotonic-pava": {
            "fit": "isotonic (PAVA) on the per-episode raw overall score, unit weights",
            "in_sample": alt_record(iso_modes),
            "leave_one_out": alt_record(iso_loo_modes),
        },
        "logistic": {
            "fit": "per-signal logistic [raw, recipe/coverage/margin one-hots, trust uncertainty], L2 lam=1.0, 400 iters, lr 0.5",
            "in_sample": alt_record(log_modes),
            "leave_one_out": alt_record(log_loo_modes),
        },
        "note": "Alternatives are fit and scored on the SAME 12 episodes "
                "(in-sample, flattering) and leave-one-out (honest at n=12). "
                "Decision rule = the service's own thresholds on the "
                "calibrated overall score, so arms differ only in score source.",
    }

    # --- drift: synthetic capability drop on reverse-meal ---
    drift = {"drop_after_episode_index": DROP_AFTER_EPISODE, "window": TRAILING_WINDOW, "bar": MODE_ERROR_BAR, "arms": {}}
    for factor in DROP_FACTORS:
        for source in ["proxy", "truth"]:
            records = run_synthetic_drop(factor, source)
            rec = recovery_episode(records, DROP_AFTER_EPISODE)
            pre_counts = decision_counts([r for r in records[:DROP_AFTER_EPISODE] if not r["hard_fail"]])
            drift["arms"].setdefault(f"factor-{factor}", {})[f"beta-{source}"] = {
                "recovery_episodes": rec,
                "pre_drop_mode_error_rate": pre_counts["mode_error_rate"],
                "post_drop_modes": [r["mode"] for r in records[DROP_AFTER_EPISODE:]],
                "post_drop_truth": [r["truth"] for r in records[DROP_AFTER_EPISODE:]],
            }

    # --- drift: changed family (authored, 50 seeds) ---
    drift["changed-family"] = changed_family_recovery()

    # --- held-out rows ---
    rows, _ = load_reverse_meal()
    heldout = []
    for row in rows:
        signals, fails = project_reverse_meal(row["producer_state"])
        entry = {"case_id": row["case_id"], "hard_fail": bool(fails), "spec_truth": SPEC_LABELED.get(row["case_id"])}
        for arm_name in ["beta-proxy", "beta-truth"]:
            trust_map = {k: TrustState(alpha=v[0], beta=v[1]) for k, v in arm_results[arm_name]["final_trust"].items()}
            a = assess(signals, lambda key: load_trust(trust_map, key, None), hard_fail_reasons=fails)
            entry[arm_name] = {"mode": a["mode"], "overall_score": a["overall_score"]}
        heldout.append(entry)
    heldout_summary = {}
    for arm_name in ["beta-proxy", "beta-truth"]:
        labeled = [e for e in heldout if e["spec_truth"] is not None]
        counted = [e for e in labeled if not e["hard_fail"]]
        heldout_summary[arm_name] = {
            "n_labeled": len(labeled),
            "n_counted_non_hardfail": len(counted),
            "exact_on_wrong": sum(1 for e in counted if e[arm_name]["mode"] == "exact" and e["spec_truth"] == 0.0),
            "estimate_on_correct": sum(1 for e in counted if e[arm_name]["mode"] == "estimate_only" and e["spec_truth"] == 1.0),
            "modes_on_labeled": {e["case_id"]: e[arm_name]["mode"] for e in labeled},
        }

    # --- base-rate strawman (calibration floor, scores only) ---
    strawman_preds = base_rate_strawman(ep_truth)
    strawman = {
        "fit": "expanding mean of prior episode truths (0.5 before any)",
        "ece_vs_truth": ece(strawman_preds, ep_truth),
        "brier_vs_truth": brier(strawman_preds, ep_truth),
        "note": "Decisions under the service's fixed thresholds would be "
                "estimate_only-always (p stays below 0.57), which the mode "
                "metric counts as a false negative on every correct episode "
                "- the thresholds, not the predictor, fail there.",
    }

    # --- extended replay: is the exact gate reachable at all? ---
    extended = {
        f"passes-{p}": {
            "beta-truth": extended_first_exact(replay, "truth", p),
            "beta-proxy": extended_first_exact(replay, "proxy", p),
        }
        for p in [1, 2, 4, 8]
    }

    # --- determinism self-check ---
    det_a = run_reverse_meal_online(replay, "truth")[0]
    det_b = run_reverse_meal_online(replay, "truth")[0]
    det_ok = json.dumps(det_a, sort_keys=True) == json.dumps(det_b, sort_keys=True)

    out = {
        "schema": "confidence-part0-metrics-v1",
        "bar": MODE_ERROR_BAR,
        "bootstrap": {"b": BOOTSTRAP_B, "seed": BOOTSTRAP_SEED},
        "episodes": n_eps,
        "arms": arm_results,
        "telemetry_gap": gap,
        "base_rate_strawman": strawman,
        "extended_first_exact": extended,
        "alternatives": alternatives,
        "drift": drift,
        "heldout": {"rows": heldout, "summary": heldout_summary, "unlabeled_case_ids": SPEC_UNLABELED},
        "determinism_selfcheck": det_ok,
    }
    (RESULTS / "metrics.json").write_text(json.dumps(out, sort_keys=True, indent=1) + "\n")
    print("wrote", RESULTS / "metrics.json", "determinism:", det_ok)


if __name__ == "__main__":
    main()
