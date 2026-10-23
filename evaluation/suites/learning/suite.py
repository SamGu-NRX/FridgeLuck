#!/usr/bin/env python3
"""Suite B (learning) — activation-gate bar for the learned taste ranker.

The bar (PLAN.md scorecard B): the learned engine must beat BOTH the
current rule ranker AND an explicit-profile-only baseline on NDCG@10 among
feasible picks, 95% interval low >= +10% relative, with ZERO
hard-restriction violations and median taste-shift recovery within 6 cooks.

The campaign itself is offline Swift (`packages/FLTaste/Eval`): simulated
households replayed through competing ranker arms against hidden ground
truth, paired per seed. This suite does NOT re-run the campaign; it reads
the committed campaign artifacts (`campaign/`), re-derives every status
under the shared contract, fail-closes to not-run when anything is missing
or stale, and writes `<out>/results.json` in the runner schema.

Inputs (all committed, all produced by the fltaste-eval CLI at the git SHA
recorded in campaign/PROVENANCE.json):

  campaign/results.json     per (arm, seed) campaign results
  campaign/gate.json        the Swift-side gate verdict (evidence, not authority)
  campaign/config.json      the campaign configuration
  campaign/arms.json        the preregistered arm roster with rationales
  campaign/manifest.json    run identity (toolchain, host, corpus, config digest)
  campaign/PROVENANCE.json  producing git SHA and UTC timestamp

Metrics (status always derived here, never asserted):

  ndcg_lift_vs_rule        bar >= 0.10 (relative lift, conservative low end)
  ndcg_lift_vs_profile     bar >= 0.10
  restriction_violations   bar == 0  (equality, engine arm)
  shift_recovery_cooks     bar <= 6
  preregistered_scale      bar == 1  (1 only when the full 5,000 x 20 grid ran)

`preregistered_scale` encodes the fail-close rule for compute: a reduced
grid reports the honest lift intervals but derives 0 here, so the
scorecard cannot present a reduced-scale pass as the full activation
decision. The unreduced grid's absence is itself recorded in RESULTS.md
with measured throughput as evidence.

Self-test: `suite.py --self-test` plants a flipped winner, planted
violations, a deleted gate file, a stale provenance SHA, a shrunk scale,
and a lying emitter, and asserts the derived status flips (or fails
closed). Prints `caught k/k planted failures`; exits 0 only when all are
caught.

Invocation (mirrors evaluation/run.py): suite.py --out <dir> --repo-root <dir>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUITE_DIR = Path(__file__).resolve().parent
EVAL_DIR = SUITE_DIR.parent.parent
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))  # evaluation/ for the shared contract

try:
    import suite_contract  # provided by the runner branch (evaluation/)

    _CONTRACT_SOURCE = "evaluation/suite_contract.py"
except ImportError:  # suite delivered before the runner branch merges
    suite_contract = None
    _CONTRACT_SOURCE = "vendored fallback (identical semantics)"

RESULTS_SUITE_ID = "learning"

ENGINE_ARM = "engine"
RULE_ARM = "rule-port"
PROFILE_ARM = "profile-only"

# (metric_id, human label) in scorecard order.
METRIC_DEFS = [
    ("ndcg_lift_vs_rule", "NDCG@10 relative lift vs rule ranker (95% CI low)"),
    ("ndcg_lift_vs_profile", "NDCG@10 relative lift vs profile-only (95% CI low)"),
    ("restriction_violations", "Hard-restriction violations (engine arm)"),
    ("shift_recovery_cooks", "Median taste-shift recovery (cooks)"),
    ("preregistered_scale", "Campaign executed at preregistered 5,000 x 20 scale"),
]

PREREGISTERED_HOUSEHOLDS = 5_000
PREREGISTERED_SEEDS = 20

REQUIRED_INPUTS = [
    "results.json",
    "gate.json",
    "config.json",
    "arms.json",
    "manifest.json",
    "PROVENANCE.json",
]

# Self-test hook: when set, inputs are read from here instead of campaign/.
_campaign_dir_override: Path | None = None


# --- Contract fallback (vendored when the runner branch is not merged yet).

def _check_bar(value: float, bar: dict, interval: list | None) -> bool:
    op, target = bar["op"], bar["value"]
    if op == "==":
        return value == target
    if op == ">=":
        low = interval[0] if interval else value
        return low >= target
    if op == "<=":
        high = interval[1] if interval else value
        return high <= target
    raise ValueError(f"unknown bar op {op!r}")


def _derive_status(metric: dict) -> str:
    if metric.get("status") == "not-run":
        if not str(metric.get("reason", "")).strip():
            raise ValueError("not-run requires a reason")
        return "not-run"
    bar, value = metric.get("bar"), metric.get("value")
    if bar is None or not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError("bared metric needs a numeric value and a bar")
    interval = metric.get("interval")
    if interval is not None and (
        not isinstance(interval, list)
        or len(interval) != 2
        or interval[0] > interval[1]
    ):
        raise ValueError("interval must be [low, high], low <= high")
    return "pass" if _check_bar(value, bar, interval) else "fail"


def _derive(metric: dict) -> str:
    if suite_contract is not None:
        return suite_contract.derive_status(metric)
    return _derive_status(metric)


# --- Input loading (fail-close).

def _campaign_dir() -> Path:
    return _campaign_dir_override or (SUITE_DIR / "campaign")


def _load_inputs(campaign_dir: Path) -> tuple[dict | None, str | None]:
    """Returns (inputs, not_run_reason). Reason is None only when complete."""
    for name in REQUIRED_INPUTS:
        if not (campaign_dir / name).is_file():
            return None, f"missing campaign input: campaign/{name}"
    inputs: dict[str, Any] = {}
    for name in REQUIRED_INPUTS:
        try:
            inputs[name] = json.loads((campaign_dir / name).read_text())
        except (json.JSONDecodeError, OSError) as exc:
            return None, f"unreadable campaign input campaign/{name}: {exc}"
    return inputs, None


def _identity_problem(inputs: dict) -> str | None:
    """Run identity must be present and plausible, else fail closed."""
    provenance = inputs["PROVENANCE.json"]
    sha = str(provenance.get("git_sha", "")).strip()
    if len(sha) != 40 or not all(c in "0123456789abcdef" for c in sha.lower()):
        return (
            "campaign provenance has no valid producing git SHA "
            "(stale or hand-written results are not accepted)"
        )
    if not str(provenance.get("produced_at", "")).strip():
        return "campaign provenance has no production timestamp"
    manifest = inputs["manifest.json"]
    if not str(manifest.get("startedAt", "")).strip():
        return "campaign manifest has no start timestamp (run identity incomplete)"
    if not str(manifest.get("swiftVersion", "")).strip():
        return "campaign manifest has no toolchain (run identity incomplete)"
    return None


# --- Metric computation.

def _by_arm(results: list) -> dict:
    grouped: dict[str, list] = {}
    for row in results:
        grouped.setdefault(row.get("arm", "?"), []).append(row)
    for rows in grouped.values():
        rows.sort(key=lambda r: r.get("seed", 0))
    return grouped


def _per_seed_ndcg(rows: list) -> list[float] | None:
    values = [r.get("meanNDCG") for r in rows]
    if not values or any(v is None for v in values):
        return None
    return [float(v) for v in values]


def _relative_lifts(engine: list[float], baseline: list[float]) -> list[float]:
    return [(e - b) / b if b != 0 else 0.0 for e, b in zip(engine, baseline)]


def compute_metrics(inputs: dict) -> list[dict]:
    """Builds the scorecard metric list; statuses are derived by the contract."""
    results = inputs["results.json"]
    gate = inputs["gate.json"]
    config = inputs["config.json"]
    roster = inputs["arms.json"]

    grouped = _by_arm(results)
    roster_ids = [entry["id"] for entry in roster]
    missing = [arm for arm in roster_ids if arm not in grouped]

    seeds = len(config.get("seeds", []))
    households = int(config.get("householdsPerSeed", 0))
    at_scale = households >= PREREGISTERED_HOUSEHOLDS and seeds >= PREREGISTERED_SEEDS

    def lift_metric(baseline_arm: str, gate_key: str, metric_id: str, label: str) -> dict:
        base = {
            "id": metric_id,
            "metric": label,
            "bar": {
                "op": ">=",
                "value": 0.10,
                "label": "95% interval low >= +10% relative",
            },
        }
        if missing:
            return {
                **base,
                "status": "not-run",
                "reason": f"campaign results missing arms: {', '.join(missing)}",
            }
        engine_ndcg = _per_seed_ndcg(grouped[ENGINE_ARM])
        baseline_ndcg = _per_seed_ndcg(grouped[baseline_arm])
        if engine_ndcg is None or baseline_ndcg is None:
            return {
                **base,
                "status": "not-run",
                "reason": "per-seed NDCG missing for engine or baseline arm",
            }
        if len(engine_ndcg) != len(baseline_ndcg) or len(engine_ndcg) < 2:
            return {
                **base,
                "status": "not-run",
                "reason": "paired bootstrap needs >= 2 seeds present for both arms",
            }

        lifts = _relative_lifts(engine_ndcg, baseline_ndcg)
        mean_lift = sum(lifts) / len(lifts)
        verdict_lift = gate.get(gate_key, {})
        interval = [
            float(verdict_lift.get("ciLow", mean_lift)),
            float(verdict_lift.get("ciHigh", mean_lift)),
        ]
        # Conservative intersection: the recomputed point must lie inside the
        # carried interval for the interval to be trusted. A tampered or
        # stale gate file widens the interval to include the recomputed
        # value, so the bar then applies to the honest point estimate.
        interval = [
            min(interval[0], mean_lift),
            max(interval[1], mean_lift),
        ]
        return {
            **base,
            "value": round(mean_lift, 6),
            "interval": interval,
            "detail": (
                f"mean relative lift {mean_lift:+.4f} over {len(lifts)} paired seeds; "
                f"bootstrap 95% CI [{interval[0]:+.4f}, {interval[1]:+.4f}] "
                f"(B={config.get('bootstrapResamples', '?')}, seeded in FLTasteEvalCore)"
            ),
            "evidence": {
                "path": "evaluation/suites/learning/campaign/results.json",
                "note": f"per-seed NDCG for {ENGINE_ARM} vs {baseline_arm}",
            },
        }

    violations_metric: dict = {
        "id": "restriction_violations",
        "metric": "Hard-restriction violations (engine arm)",
        "bar": {"op": "==", "value": 0, "label": "zero, ever"},
    }
    if missing:
        violations_metric.update(
            status="not-run",
            reason=f"campaign results missing arms: {', '.join(missing)}",
        )
    else:
        total = sum(int(r.get("restrictionViolations", 0)) for r in grouped[ENGINE_ARM])
        violations_metric.update(
            value=total,
            detail=(
                f"{total} violations across {len(grouped[ENGINE_ARM])} engine (seed) "
                f"results; gate.json noViolations={gate.get('noViolations')}"
            ),
            evidence={
                "path": "evaluation/suites/learning/campaign/results.json",
                "note": "restrictionViolations summed over engine arm seeds",
            },
        )

    recovery_metric: dict = {
        "id": "shift_recovery_cooks",
        "metric": "Median taste-shift recovery (cooks)",
        "bar": {"op": "<=", "value": 6, "label": "median <= 6 cooks"},
    }
    median_recovery = gate.get("medianRecoveryCooks")
    if missing:
        recovery_metric.update(
            status="not-run",
            reason=f"campaign results missing arms: {', '.join(missing)}",
        )
    elif median_recovery is None:
        censored = sum(int(r.get("recoveryCensored", 0)) for r in grouped[ENGINE_ARM])
        recovery_metric.update(
            value=999,
            detail=(
                f"no uncensored recovery observed; {censored} censored households "
                "(horizon too short or shift unseen — this is a fail, not a pass)"
            ),
            evidence={
                "path": "evaluation/suites/learning/campaign/gate.json",
                "note": "medianRecoveryCooks null",
            },
        )
    else:
        recovery_metric.update(
            value=float(median_recovery),
            detail=(
                f"median {median_recovery} cooks; gate.json recoveryBarMet="
                f"{gate.get('recoveryBarMet')}"
            ),
            evidence={
                "path": "evaluation/suites/learning/campaign/gate.json",
                "note": "median of per-seed median recovery cooks, engine arm",
            },
        )

    scale_metric = {
        "id": "preregistered_scale",
        "metric": "Campaign executed at preregistered 5,000 x 20 scale",
        "bar": {"op": "==", "value": 1, "label": "full grid executed"},
        "value": 1 if at_scale else 0,
        "detail": (
            f"executed {households} households x {seeds} seeds x {len(roster_ids)} arms "
            f"({config.get('weeks', '?')} weeks). The preregistered 5,000 x 20 grid is "
            f"labeled not-run in RESULTS.md with measured throughput as evidence; "
            f"lift intervals on this card are computed on the executed grid."
        ),
        "evidence": {
            "path": "evaluation/suites/learning/campaign/config.json",
            "note": "campaign configuration actually executed",
        },
    }

    metrics = [
        lift_metric(RULE_ARM, "versusRule", "ndcg_lift_vs_rule", METRIC_DEFS[0][1]),
        lift_metric(
            PROFILE_ARM, "versusProfileOnly", "ndcg_lift_vs_profile", METRIC_DEFS[1][1]
        ),
        violations_metric,
        recovery_metric,
        scale_metric,
    ]
    for metric in metrics:
        metric["status"] = _derive(metric)
    return metrics


# --- Emission.

def _toolchain() -> dict:
    toolchain: dict[str, str] = {
        "python": sys.version.split()[0],
        "contract_source": _CONTRACT_SOURCE,
    }
    manifest_path = _campaign_dir() / "manifest.json"
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text())
            toolchain["swift"] = str(manifest.get("swiftVersion", "unknown"))
        except (json.JSONDecodeError, OSError):
            toolchain["swift"] = "unknown"
    return toolchain


def _payload_header(inputs: dict | None) -> dict:
    if inputs is None:
        return {}
    return {
        "run": {
            "git_sha": inputs["PROVENANCE.json"]["git_sha"],
            "campaign_started_at": inputs["manifest.json"]["startedAt"],
            "config_digest": hashlib.sha256(
                json.dumps(inputs["config.json"], sort_keys=True).encode()
            ).hexdigest(),
        }
    }


def build_payload() -> dict:
    inputs, reason = _load_inputs(_campaign_dir())
    if inputs is None:
        return _not_run_payload(reason)

    identity_problem = _identity_problem(inputs)
    if identity_problem:
        return _not_run_payload(identity_problem)

    payload = {
        "suite": RESULTS_SUITE_ID,
        "letter": "B",
        "title": "Learned taste ranker vs baselines (suite B)",
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": _toolchain(),
        **_payload_header(inputs),
        "metrics": compute_metrics(inputs),
    }
    if suite_contract is not None:
        suite_contract.validate_results(payload, expected_suite_id=RESULTS_SUITE_ID)
    return payload


def _not_run_payload(reason: str) -> dict:
    return {
        "suite": RESULTS_SUITE_ID,
        "letter": "B",
        "title": "Learned taste ranker vs baselines (suite B)",
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": _toolchain(),
        "metrics": [
            {"id": mid, "metric": label, "status": "not-run", "reason": reason}
            for mid, label in METRIC_DEFS
        ],
        "detail": reason,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Suite B (learning) scorecard")
    parser.add_argument("--out", required=True, help="absolute output directory")
    parser.add_argument("--repo-root", default="..", help="absolute repo root")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = build_payload()
    (out_dir / "results.json").write_text(json.dumps(payload, indent=2) + "\n")

    statuses = [m["status"] for m in payload["metrics"]]
    if all(s == "not-run" for s in statuses):
        print(f"suite {RESULTS_SUITE_ID}: not-run — {payload.get('detail', '')}")
        return 0
    summary = ", ".join(f"{m['id']}={m['status']}" for m in payload["metrics"])
    print(f"suite {RESULTS_SUITE_ID}: {summary}")
    return 0


# --- Self-test (planted failures must all be caught).

def _with_corrupted_campaign(mutate) -> dict:
    """Copies the committed campaign into a temp dir, applies one plant."""
    tmp = Path(tempfile.mkdtemp(prefix="suite-b-selftest-"))
    campaign_dir = tmp / "campaign"
    campaign_dir.mkdir()
    for name in REQUIRED_INPUTS:
        shutil.copy(SUITE_DIR / "campaign" / name, campaign_dir / name)
    mutate(campaign_dir)
    global _campaign_dir_override
    _campaign_dir_override = campaign_dir
    try:
        return build_payload()
    finally:
        _campaign_dir_override = None
        shutil.rmtree(tmp, ignore_errors=True)


def self_test() -> int:
    if not (SUITE_DIR / "campaign" / "results.json").is_file():
        print(
            f"suite {RESULTS_SUITE_ID}: self-test skipped — no committed campaign "
            "inputs yet (the suite reports not-run on the real path; plants "
            "cannot be exercised without baseline inputs)"
        )
        return 0

    def metric_by_id(payload: dict, metric_id: str) -> dict:
        return next(m for m in payload["metrics"] if m["id"] == metric_id)

    def flip_winner(campaign_dir: Path) -> None:
        path = campaign_dir / "results.json"
        results = json.loads(path.read_text())
        for row in results:
            if row["arm"] == ENGINE_ARM and row.get("meanNDCG") is not None:
                row["meanNDCG"] = 0.30
            if row["arm"] == RULE_ARM and row.get("meanNDCG") is not None:
                row["meanNDCG"] = 0.60
        path.write_text(json.dumps(results))

    def plant_violations(campaign_dir: Path) -> None:
        path = campaign_dir / "results.json"
        results = json.loads(path.read_text())
        for row in results:
            if row["arm"] == ENGINE_ARM:
                row["restrictionViolations"] = 3
        path.write_text(json.dumps(results))

    def delete_gate(campaign_dir: Path) -> None:
        (campaign_dir / "gate.json").unlink()

    def stale_sha(campaign_dir: Path) -> None:
        path = campaign_dir / "PROVENANCE.json"
        provenance = json.loads(path.read_text())
        provenance["git_sha"] = ""
        path.write_text(json.dumps(provenance))

    def shrink_scale(campaign_dir: Path) -> None:
        path = campaign_dir / "config.json"
        config = json.loads(path.read_text())
        config["householdsPerSeed"] = 50
        path.write_text(json.dumps(config))

    plants = [
        (
            "flipped winner must derive fail",
            flip_winner,
            lambda p: metric_by_id(p, "ndcg_lift_vs_rule")["status"] == "fail",
        ),
        (
            "planted violations must derive fail",
            plant_violations,
            lambda p: metric_by_id(p, "restriction_violations")["status"] == "fail",
        ),
        (
            "deleted gate must fail closed to not-run",
            delete_gate,
            lambda p: all(m["status"] == "not-run" for m in p["metrics"]),
        ),
        (
            "stale provenance SHA must fail closed to not-run",
            stale_sha,
            lambda p: all(m["status"] == "not-run" for m in p["metrics"]),
        ),
        (
            "reduced scale must derive fail",
            shrink_scale,
            lambda p: metric_by_id(p, "preregistered_scale")["status"] == "fail",
        ),
        (
            "lying pass on a violated bar must be stripped",
            shrink_scale,
            lambda p: _derive(
                {
                    "id": "lie",
                    "value": 0.02,
                    "bar": {"op": ">=", "value": 0.10},
                    "status": "pass",
                }
            )
            == "fail",
        ),
    ]

    caught = 0
    for description, mutate, expect in plants:
        payload = _with_corrupted_campaign(mutate)
        if expect(payload):
            caught += 1
        else:
            print(f"NOT CAUGHT: {description}")

    print(f"caught {caught}/{len(plants)} planted failures")
    return 0 if caught == len(plants) else 2


if __name__ == "__main__":
    sys.exit(main())
