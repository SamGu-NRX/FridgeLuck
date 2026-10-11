#!/usr/bin/env python3
"""Suite E (community composition) — scenario bar on the CURRENT community code.

Runs the suite-E bun scenarios (src/__tests__/community/
suiteE.scenarios.test.ts) against the real wiring — every community part
mounted, the real Firestore block directory and moderation queue, real HTTP
over the Firestore emulator — and reports three bared metrics:

  1. private-field-leaks            bar == 0
     Every response captured across the scenarios is scanned for identity
     fields, session material and token keys (auth endpoints exempt for the
     caller's own tokens).
  2. authorization-failures         bar == 0
     Scenario steps whose HTTP status diverged from the contract (an
     authorized path failing, a boundary letting someone through).
  3. moderation-transition-coverage bar == 8 (of 8)
     The queue-item lifecycle (submitted:user-report, resolved:rejected,
     submitted:author-appeal, resolved:approved) and the publication
     transitions (live->queued report, queued->live appeal, queued->
     withdrawn author-withdraw-while-queued, live->withdrawn deletion).

The verdict is derived ONLY from the bun run's metrics.json (the scenario
file's afterAll emits it); this wrapper never substitutes its own. If bun,
java or the firebase CLI is unavailable, or the emulator cannot start, every
metric reports not-run with the precise reason — never skipped silently,
never faked.

Invocation (mirrors evaluation/run.py):
    suite.py --out <dir> --repo-root <dir>

Exit status: 0 whenever honest results were written (statuses may be fail);
non-zero only when the wrapper itself cannot run (bad arguments).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

EVAL_DIR = Path(__file__).resolve().parents[2]
SUITE_DIR = Path(__file__).resolve().parent
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))  # evaluation/ for suite_contract
if str(SUITE_DIR) not in sys.path:
    sys.path.insert(0, str(SUITE_DIR))
try:
    import suite_contract  # noqa: E402
except ImportError:  # the shared contract lands with evaluation/ (PR #88/#93 lineage)
    print(
        "suite community-suite-e: cannot run — evaluation/suite_contract.py is not in this "
        "checkout (it lands with the evaluation scorecard runner). Merge order required; "
        "the wrapper matched that contract as of commit 26c7004.",
        file=sys.stderr,
    )
    sys.exit(2)

RESULTS_SUITE_ID = "community-suite-e"

REQUIRED_QUEUE_TRANSITIONS = (
    "submitted:user-report",
    "resolved:rejected",
    "submitted:author-appeal",
    "resolved:approved",
)
REQUIRED_PUBLICATION_TRANSITIONS = (
    "live->queued: user report",
    "queued->live: appeal approved",
    "queued->withdrawn: author withdrew while queued",
    "live->withdrawn: account deletion",
)

SCENARIO_TEST_PATH = "src/__tests__/community/suiteE.scenarios.test.ts"
AGENT_DIR = "backend/gemini-agent"  # run-tests.sh's cwd; the emulator config is relative to it
EMULATOR_CONFIG = "community-emulator/firebase.json"


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _git_sha(repo_root: Path) -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo_root, capture_output=True, text=True, check=True
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return "unknown"


def _tool(name: str, bin_dir: Path | None = None) -> str | None:
    """Returns the resolved path, or None when absent (callers record why)."""
    if bin_dir is not None:
        candidate = bin_dir / name
        return str(candidate) if candidate.exists() else None
    return shutil.which(name)


def _java_tool() -> str | None:
    """java discovery: PATH first, then JAVA_HOME/bin (the documented setup)."""
    resolved = shutil.which("java")
    if resolved is not None:
        return resolved
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        candidate = Path(java_home) / "bin" / "java"
        if candidate.exists():
            return str(candidate)
    return None


def _not_run_all(reason: str, out_dir: Path, toolchain: dict[str, Any], git_sha: str) -> None:
    metrics = [
        suite_contract.metric_not_run("private-field-leaks", "Private-field leaks across scenario responses", reason),
        suite_contract.metric_not_run("authorization-failures", "Authorization failures across scenario steps", reason),
        suite_contract.metric_not_run(
            "moderation-transition-coverage", "Moderation transition coverage (of 8 required)", reason
        ),
    ]
    payload = {
        "suite": RESULTS_SUITE_ID,
        "run_at": _iso_now(),
        "toolchain": toolchain,
        "revision": {"git_sha": git_sha},
        "grounding": {
            "scenario_test": SCENARIO_TEST_PATH,
            "note": "not-run: the bun scenario run produced no metrics",
        },
        "metrics": metrics,
    }
    suite_contract.write_results(out_dir, payload)


def _run_scenarios(repo_root: Path, firebase: str, bun: str) -> tuple[dict[str, Any] | None, str | None]:
    """Runs the bun scenarios under the emulator; returns (metrics, reason)."""
    with tempfile.TemporaryDirectory(prefix="suite-e-out-") as tmp:
        # SUITE_E_OUT_DIR is an out DIRECTORY on the bun side (it appends the
        # metrics.json filename itself).
        env = dict(os.environ)
        env.update(
            {
                "FIRESTORE_EMULATOR_HOST": "127.0.0.1:8080",
                "COMMUNITY_SESSION_SECRET": "emulator-run-secret",
                "CI": "1",
                "SUITE_E_OUT_DIR": tmp,
                "PATH": f"{bun.rsplit('/', 1)[0]}:{env.get('PATH', '')}",
            }
        )
        metrics_path = Path(tmp) / "metrics.json"
        proc = subprocess.run(
            [
                firebase,
                "emulators:exec",
                "--only",
                "firestore",
                "--project",
                "community-test",
                "--config",
                EMULATOR_CONFIG,
                "--",
                f"{bun} test {SCENARIO_TEST_PATH}",
            ],
            cwd=repo_root / AGENT_DIR,
            env=env,
            capture_output=True,
            text=True,
            timeout=1700,
        )
        if not metrics_path.exists():
            tail = (proc.stdout + proc.stderr)[-1500:]
            return None, (
                f"bun scenario run produced no metrics.json (exit {proc.returncode}). "
                f"Output tail: {tail}"
            )
        try:
            metrics = json.loads(metrics_path.read_text())
        except json.JSONDecodeError as err:
            return None, f"metrics.json is not valid JSON: {err}"
        return metrics, None


def main() -> int:
    parser = argparse.ArgumentParser(description="suite E runner: community composition scenarios")
    parser.add_argument("--out", default=None, help="output directory for results.json")
    parser.add_argument("--repo-root", default=None, help="the fl-ro repository checkout")
    args = parser.parse_args()
    if args.repo_root is None:
        parser.error("--repo-root is required")

    repo_root = Path(args.repo_root).resolve()
    out_dir = Path(args.out).resolve() if args.out else repo_root / "evaluation" / "out" / RESULTS_SUITE_ID

    bun = _tool("bun")
    java = _java_tool()
    firebase = _tool("firebase", repo_root / "backend" / "gemini-agent" / "node_modules" / ".bin")
    toolchain = {
        "bun": bun or "missing",
        "java": java or "missing",
        "firebase": firebase or "missing",
        "python": sys.version.split()[0],
    }
    git_sha = _git_sha(repo_root)

    missing = [n for n, v in (("bun", bun), ("java (JRE 11+)", java), ("firebase CLI", firebase)) if v is None]
    if missing:
        _not_run_all(
            f"required tools unavailable: {', '.join(missing)}. "
            "The Firestore emulator needs a JRE (set JAVA_HOME or install java); "
            "the firebase CLI must be installed in backend/gemini-agent/node_modules.",
            out_dir,
            toolchain,
            git_sha,
        )
        print(f"suite {RESULTS_SUITE_ID}: not-run ({', '.join(missing)} missing)")
        return 0

    metrics, reason = _run_scenarios(repo_root, firebase, bun)
    if metrics is None:
        _not_run_all(reason or "unknown failure", out_dir, toolchain, git_sha)
        print(f"suite {RESULTS_SUITE_ID}: not-run ({reason})")
        return 0

    leaks = metrics.get("leaks", [])
    scenarios = metrics.get("scenarios", [])
    step_failures = sum(int(s.get("failures", 0)) for s in scenarios)
    queue_covered = list(dict.fromkeys(metrics.get("queueTransitionsCovered", [])))
    pub_covered = list(dict.fromkeys(metrics.get("publicationTransitionsCovered", [])))
    covered_count = len(queue_covered) + len(pub_covered)
    required_count = len(REQUIRED_QUEUE_TRANSITIONS) + len(REQUIRED_PUBLICATION_TRANSITIONS)

    m1 = suite_contract.metric(
        "private-field-leaks",
        "Private-field leaks across scenario responses",
        value=len(leaks),
        bar=suite_contract.eq(0),
        detail=(
            f"{len(scenarios)} composition scenarios (two-account table cooks; "
            "three-account report/appeal/withdraw/deletion) captured every HTTP response "
            "and scanned it for identity fields, session material and token keys "
            "(auth endpoints exempt for the caller's own tokens)."
        ),
        evidence={"leaks": leaks[:20]},
    )
    m2 = suite_contract.metric(
        "authorization-failures",
        "Authorization failures across scenario steps",
        value=step_failures,
        bar=suite_contract.eq(0),
        detail=(
            "Every scenario step's HTTP status against its contract: authorized "
            "paths must succeed, boundaries (401/403/404/409/422) must hold."
        ),
        evidence={"scenarios": scenarios},
    )
    m3 = suite_contract.metric(
        "moderation-transition-coverage",
        "Moderation transition coverage (of 8 required)",
        value=covered_count,
        bar=suite_contract.ge(required_count),
        detail=(
            "Required queue transitions: " + ", ".join(REQUIRED_QUEUE_TRANSITIONS)
            + ". Required publication transitions: " + ", ".join(REQUIRED_PUBLICATION_TRANSITIONS) + "."
        ),
        evidence={"queue": queue_covered, "publication": pub_covered},
    )

    payload = {
        "suite": RESULTS_SUITE_ID,
        "run_at": _iso_now(),
        "toolchain": toolchain,
        "revision": {"git_sha": git_sha},
        "grounding": {
            "scenario_test": SCENARIO_TEST_PATH,
            "emulator_config": EMULATOR_CONFIG,
            "note": (
                "Verdict derived solely from the bun scenario run's metrics.json "
                "(real wiring: all parts mounted, real Firestore block directory and "
                "moderation queue, real HTTP over the Firestore emulator)."
            ),
        },
        "metrics": [m1, m2, m3],
    }
    suite_contract.write_results(out_dir, payload)
    statuses = ", ".join(f"{m['id']}={m['status']}" for m in payload["metrics"])
    print(f"suite {RESULTS_SUITE_ID}: {statuses}; results in {out_dir / 'results.json'}")
    return 0  # exit 0 whenever honest results were written (statuses may be fail)


if __name__ == "__main__":
    sys.exit(main())
