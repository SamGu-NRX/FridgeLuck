#!/usr/bin/env python3
"""Planted-failure self-tests for the scorecard runner (part D, r3).

The BLOCK review of PR #88 at 9e04af4 names ways forged evidence could reach
a scorecard. Each plant below builds a throwaway tree (registry, planted
suite, cached or imported results), runs the runner under test's collect(),
and reports whether the runner ADMITTED the forgery (red) or failed closed
(caught):

  (i)    stale-result-copy — a cached passing results.json from an OLD
         out/ directory is copied into the fresh run directory; two
         variants: carrying the old run's binding (i-old-binding) and
         carrying no binding at all (i-no-binding).
  (ii)   the suite emits a bar that differs from the registry bar.
  (iii)  import with synthetic ci.example.test provenance.
  (iv)   learning +10% point estimate without the required 95% interval.
  (v)    zero-issues results whose run_status reports an infrastructure
         failure.
  (vi)   import whose GitHub run exists but was produced at another head
         (forged git.sha).
  (vii)  import that cannot be verified because GitHub is unreachable.

Usage — one runner per process (runners share the `suite_contract` module
name, so two runners must never be imported into one process):

    python3 evaluation/tests/planted_failures.py --run-py <path/to/run.py>
    python3 evaluation/tests/planted_failures.py --expect-green \
        --run-py <path/to/run.py>   # exit 2 unless every plant is caught

At base 9e04af4 plants i, iii, iv, v, vi and vii are admitted (red); ii is
caught there already (the registry bar check landed earlier). On the
scorecard-d-runner branch every plant is caught.
"""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import sys
import tempfile
import urllib.error
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_RUN_PY = Path(__file__).resolve().parent.parent / "run.py"

# Deterministic stand-ins for run identity. The plants never touch the real
# head: the runner under test only ever sees this synthetic binding.
HEAD = "1" * 40
OLD_SHA = "0" * 40
OLD_RUN_ID = "r-20260101T000000Z-oldrun01"
# A real FridgeLuck CI run id (the build-and-test run cited in the PR #88
# review), used as the recorded fixture for provenance plants.
REAL_RUN_ID = "38184946729"
REPO = "SamGu-NRX/FridgeLuck"
BINDING = {
    "run_id": "r-plant-00000000",
    "git_sha": HEAD,
    "started_at": "2026-10-12T00:00:00Z",
}


@dataclass
class Plant:
    name: str
    suite_id: str
    registry_entry: dict[str, Any] | None  # None → use the runner's real registry
    suite_py: str | None                   # planted suite.py source (None for import plants)
    import_payload: dict[str, Any] | None  # written to out/<sid>/results.json
    expect_row_id: str
    expect_status: str
    expect_reason_contains: list[str]
    ci_api: dict[str, Any] = field(default_factory=dict)   # run_id -> fake GitHub API body
    ci_unreachable: bool = False


def _emitter(payload: dict[str, Any]) -> str:
    """A conforming planted suite: stamps the binding the runner passed in
    (FL_RUN_BINDING) as its producer binding, then writes results.json."""
    lit = json.dumps(json.dumps(payload))
    return (
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "out = Path(sys.argv[sys.argv.index('--out') + 1])\n"
        "out.mkdir(parents=True, exist_ok=True)\n"
        f"payload = json.loads({lit})\n"
        "if os.environ.get('FL_RUN_BINDING'):\n"
        "    payload['run'] = json.loads(os.environ['FL_RUN_BINDING'])\n"
        "(out / 'results.json').write_text(json.dumps(payload))\n"
    )


def _copier(cached: dict[str, Any]) -> str:
    """A lying planted suite: copies a cached passing results.json from an
    old out/ directory into the fresh run directory it was handed."""
    lit = json.dumps(json.dumps(cached))
    return (
        "import json, shutil, sys\n"
        "from pathlib import Path\n"
        "out = Path(sys.argv[sys.argv.index('--out') + 1])\n"
        "out.mkdir(parents=True, exist_ok=True)\n"
        "old = Path(__file__).resolve().parent / 'old-out'\n"
        "old.mkdir(exist_ok=True)\n"
        f"(old / 'results.json').write_text(json.dumps(json.loads({lit})))\n"
        "shutil.copyfile(old / 'results.json', out / 'results.json')\n"
    )


def _entry(sid: str, metrics: dict[str, Any], *, platform: str = "any") -> dict[str, Any]:
    return {
        "id": sid, "letter": "T", "title": sid, "owner_task": "selftest",
        "platform": platform, "timeout_s": 60, "metrics": metrics,
    }


_M1 = {"m1": {"label": "kept metric", "bar": {"op": "<=", "value": 0}}}
_M1_ROW = {"id": "m1", "metric": "kept metric", "value": 0, "bar": {"op": "<=", "value": 0}}
_LEARNING_LABELS = {
    "ndcg10_vs_rule_ranker_pct": (
        "NDCG@10 vs the rule ranker: relative gain among feasible picks "
        "(95% interval low, %)"
    ),
    "ndcg10_vs_profile_only_pct": (
        "NDCG@10 vs explicit-profile-only: relative gain (95% interval low, %)"
    ),
    "restriction_violations": "Restriction violations",
    "taste_shift_recovery_cooks_median": "Cooks to recover from a taste shift (median)",
}


def plant_i_old_binding() -> Plant:
    sid = "selftest-stalecopy"
    cached = {
        "suite": sid, "letter": "T", "title": sid,
        "run": {"run_id": OLD_RUN_ID, "git_sha": OLD_SHA,
                "started_at": "2026-01-01T00:00:00Z"},
        "metrics": [dict(_M1_ROW)],
    }
    return Plant(
        name="i-old-binding-stale-copy", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1)), suite_py=_copier(cached),
        import_payload=None, expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["contradicting this run"],
    )


def plant_i_no_binding() -> Plant:
    sid = "selftest-stalecopy2"
    cached = {"suite": sid, "letter": "T", "title": sid, "metrics": [dict(_M1_ROW)]}
    return Plant(
        name="i-no-binding-stale-copy", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1)), suite_py=_copier(cached),
        import_payload=None, expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["no run binding"],
    )


def plant_ii_bar_mismatch() -> Plant:
    sid = "selftest-rebar"
    payload = {
        "suite": sid, "letter": "T", "title": sid,
        "metrics": [{"id": "m1", "metric": "kept metric", "value": 5,
                     "bar": {"op": "<=", "value": 10}}],  # registry says <= 0
    }
    return Plant(
        name="ii-bar-mismatch", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1)), suite_py=_emitter(payload),
        import_payload=None, expect_row_id="m1", expect_status="fail",
        expect_reason_contains=["differs from the registry bar"],
    )


def plant_iii_synthetic_url() -> Plant:
    sid = "selftest-import-synth"
    payload = {
        "suite": sid, "letter": "T", "title": sid, "git": {"sha": HEAD},
        "run_url": "https://ci.example.test/FridgeLuck/actions/runs/424242",
        "run": {"run_id": "424242", "started_at": "2026-10-11T00:00:00Z"},
        "metrics": [dict(_M1_ROW)],
    }
    return Plant(
        name="iii-synthetic-url-import", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1), platform="macos"), suite_py=None,
        import_payload=payload, expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["not provenance"],
    )


def plant_iv_point_estimate() -> Plant:
    payload = {
        "suite": "learning", "letter": "B", "title": "Learning",
        "metrics": [
            {"id": "ndcg10_vs_rule_ranker_pct", "metric": _LEARNING_LABELS["ndcg10_vs_rule_ranker_pct"],
             "value": 10.5},  # point estimate: no interval
            {"id": "ndcg10_vs_profile_only_pct", "metric": _LEARNING_LABELS["ndcg10_vs_profile_only_pct"],
             "value": 12, "interval": [11, 13]},
            {"id": "restriction_violations", "metric": _LEARNING_LABELS["restriction_violations"],
             "value": 0},
            {"id": "taste_shift_recovery_cooks_median",
             "metric": _LEARNING_LABELS["taste_shift_recovery_cooks_median"], "value": 3},
        ],
    }
    return Plant(
        name="iv-point-estimate-no-interval", suite_id="learning",
        registry_entry=None,  # the runner's real registry
        suite_py=_emitter(payload), import_payload=None,
        expect_row_id="ndcg10_vs_rule_ranker_pct", expect_status="fail",
        expect_reason_contains=["interval"],
    )


def plant_v_infra_failure() -> Plant:
    sid = "selftest-infra"
    payload = {
        "suite": sid, "letter": "T", "title": sid,
        "run_status": "infrastructure-failure",
        "run_status_reason": "planted: xcrun could not boot the simulator; "
                             "the audit app never launched",
        "metrics": [dict(_M1_ROW, bar={"op": "==", "value": 0})],
    }
    return Plant(
        name="v-infra-failure-zero-issues", suite_id=sid,
        registry_entry=_entry(sid, {"m1": {"label": "kept metric",
                                           "bar": {"op": "==", "value": 0}}}),
        suite_py=_emitter(payload), import_payload=None,
        expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["infrastructure-failure"],
    )


def plant_vi_forged_sha() -> Plant:
    sid = "selftest-import-forged"
    payload = {
        "suite": sid, "letter": "T", "title": sid, "git": {"sha": HEAD},
        "run_url": f"https://github.com/{REPO}/actions/runs/{REAL_RUN_ID}",
        "run": {"run_id": REAL_RUN_ID, "started_at": "2026-10-11T00:00:00Z"},
        "metrics": [dict(_M1_ROW)],
    }
    return Plant(
        name="vi-forged-sha-import", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1), platform="macos"), suite_py=None,
        import_payload=payload, expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["was produced at"],
        # the real run exists but was produced at another head: the planted
        # git.sha is a forgery the REST check must catch
        ci_api={REAL_RUN_ID: {"head_sha": OLD_SHA,
                              "html_url": f"https://github.com/{REPO}/actions/runs/{REAL_RUN_ID}"}},
    )


def plant_vii_unreachable() -> Plant:
    sid = "selftest-import-unreach"
    payload = {
        "suite": sid, "letter": "T", "title": sid, "git": {"sha": HEAD},
        "run_url": f"https://github.com/{REPO}/actions/runs/{REAL_RUN_ID}",
        "run": {"run_id": REAL_RUN_ID, "started_at": "2026-10-11T00:00:00Z"},
        "metrics": [dict(_M1_ROW)],
    }
    return Plant(
        name="vii-unreachable-import", suite_id=sid,
        registry_entry=_entry(sid, dict(_M1), platform="macos"), suite_py=None,
        import_payload=payload, expect_row_id=f"{sid}_suite", expect_status="not-run",
        expect_reason_contains=["UNVERIFIED-NATIVE"], ci_unreachable=True,
    )


PLANTS = [
    plant_i_old_binding, plant_i_no_binding, plant_ii_bar_mismatch,
    plant_iii_synthetic_url, plant_iv_point_estimate, plant_v_infra_failure,
    plant_vi_forged_sha, plant_vii_unreachable,
]


def load_runner(run_py: Path) -> Any:
    spec = importlib.util.spec_from_file_location("run_under_test", run_py)
    if spec is None or spec.loader is None:
        raise SystemExit(f"could not load runner from {run_py}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def install_fixture_transport(contract_mod: Any, plant: Plant) -> Any:
    """Swap the runner's GitHub transport for a deterministic fixture (the
    branch's HTTP_GET seam). Pre-provenance runners have no seam: return None
    and the plant runs against whatever that runner does."""
    if not hasattr(contract_mod, "HTTP_GET"):
        return None
    def fake_get(url: str, token: str | None) -> tuple[int, str]:
        if plant.ci_unreachable:
            raise urllib.error.URLError("planted: network unreachable")
        run_id = url.rstrip("/").rsplit("/", 1)[-1]
        body = plant.ci_api.get(run_id)
        if body is None:
            raise urllib.error.HTTPError(url, 404, "planted: no such run", None,
                                         io.BytesIO(b""))
        return 200, json.dumps(body)
    original = contract_mod.HTTP_GET
    contract_mod.HTTP_GET = fake_get
    return original


def run_plant(run_mod: Any, plant: Plant, tmp_root: Path) -> tuple[str, str]:
    """Returns (verdict, detail): verdict is 'ADMITTED' or 'caught'."""
    case_root = tmp_root / plant.name.replace("/", "-")
    case_root.mkdir()
    if plant.registry_entry is None:
        registry = {"suites": run_mod.load_registry()}
    else:
        registry = {"suites": [plant.registry_entry]}
    (case_root / "registry.json").write_text(json.dumps(registry))
    suite_dir = case_root / "suites" / plant.suite_id
    suite_dir.mkdir(parents=True)
    platform = next(s.get("platform", "any") for s in registry["suites"]
                    if s["id"] == plant.suite_id)
    (suite_dir / "suite.json").write_text(json.dumps(
        {"id": plant.suite_id, "platform": platform, "timeout_s": 60}))
    if plant.suite_py is not None:
        (suite_dir / "suite.py").write_text(plant.suite_py)
    if plant.import_payload is not None:
        out_dir = case_root / "out" / plant.suite_id
        out_dir.mkdir(parents=True)
        (out_dir / "results.json").write_text(json.dumps(plant.import_payload))

    originals = (run_mod.EVAL_DIR, run_mod.REPO_ROOT)
    contract_mod = getattr(run_mod, "contract", None)
    restore = install_fixture_transport(contract_mod, plant) if contract_mod else None
    try:
        run_mod.EVAL_DIR = case_root
        run_mod.REPO_ROOT = case_root
        results_list = run_mod.collect([plant.suite_id], case_root / "out", dict(BINDING))
    finally:
        run_mod.EVAL_DIR, run_mod.REPO_ROOT = originals
        if restore is not None and contract_mod is not None:
            contract_mod.HTTP_GET = restore

    result = next((s for s in results_list if s.get("suite") == plant.suite_id), None)
    if result is None:
        return "ADMITTED", f"suite {plant.suite_id!r} vanished from collection"
    row = next((m for m in result.get("metrics", []) if m.get("id") == plant.expect_row_id), None)
    if row is None:
        observed = [(m.get("id"), m.get("status")) for m in result.get("metrics", [])]
        return "ADMITTED", f"row {plant.expect_row_id!r} absent — observed rows {observed}"
    detail = f"{plant.expect_row_id}: {row.get('status')} — {(row.get('reason') or '')[:200]}"
    if row.get("status") != plant.expect_status:
        return "ADMITTED", detail
    if not all(sub in (row.get("reason") or "") for sub in plant.expect_reason_contains):
        return "ADMITTED", detail
    return "caught", detail


def main() -> int:
    ap = argparse.ArgumentParser(description="planted-failure self-tests (one runner per process)")
    ap.add_argument("--run-py", default=str(DEFAULT_RUN_PY),
                    help="path to the evaluation/run.py under test")
    ap.add_argument("--expect-green", action="store_true",
                    help="exit 2 unless every plant is caught")
    args = ap.parse_args()

    run_py = Path(args.run_py).resolve()
    run_mod = load_runner(run_py)
    print(f"runner under test: {run_py}")

    misses: list[str] = []
    with tempfile.TemporaryDirectory(prefix="fl-plant-") as tmp:
        tmp_root = Path(tmp)
        for factory in PLANTS:
            plant = factory()
            verdict, detail = run_plant(run_mod, plant, tmp_root)
            print(f"  {verdict:<9} {plant.name}: {detail}")
            if args.expect_green and verdict != "caught":
                misses.append(f"{plant.name}: {detail}")

    print("")
    if misses:
        print(f"PLANTS FAILED ({len(misses)}/{len(PLANTS)} admitted forgeries):")
        for m in misses:
            print(f"  {m}")
        return 2
    if args.expect_green:
        print(f"all {len(PLANTS)} plants caught: the runner refused every forgery")
    else:
        print(f"report only: {sum(1 for _ in PLANTS)} plants run "
              "(re-run with --expect-green to enforce)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
