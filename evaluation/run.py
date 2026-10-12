#!/usr/bin/env python3
"""FridgeLuck overhaul scorecard runner (fl-eval-harness-f1).

Runs the evaluation suites named in PLAN.md ("The scorecard (evals first)")
and writes `evaluation/out/scorecard.json` and `evaluation/out/scorecard.md`.

    python3 evaluation/run.py --list                 # show expected suites, present or not
    python3 evaluation/run.py --all                  # run every suite runnable on this host
    python3 evaluation/run.py --suite pantry-truth --suite recipes
    python3 evaluation/run.py --self-test            # planted failures must all be caught

Contract (full document in evaluation/SCORECARD.md):

- A suite whose inputs are missing reports not-run with the reason, never pass.
- The registry (evaluation/registry.json) owns the bars. The runner judges
  every suite's metric set, labels and bars against it: a missing metric, an
  extra metric, or a different label/op/value FAILS with a reason naming the
  exact mismatch. Emitter-supplied bars are never trusted — pass/fail is
  derived from the registry bar + value + interval via suite_contract.py.
- Every admitted result is bound to THIS run: the runner stamps run_id, git
  SHA and run start time, and fails closed to not-run on anything that lacks
  or contradicts them. Fresh output per run: a suite's out directory is
  removed before execution, so a prior run's results can never survive.
- Imported native results (macos suites) additionally require a matching
  head plus CI-run provenance per SCORECARD.md's macos-import rule.
- The runner fail-closes: a suite that crashes, times out, or emits malformed
  results is not-run with the reason.
- Exit code: 0 when the scorecard was produced (pass/fail is data, reported
  honestly); 1 on infrastructure errors; 2 when --self-test catches an
  uncaught planted failure.

macOS-only suites (ui-polish, journeys) run on macOS only: via the existing
iOS CI targets, or via a workflow proposed under ci/pending-workflows/ and
approved and installed by Sam (the fleet never edits or installs CI).
On other hosts the runner imports their committed `evaluation/out/<id>/results.json`
after re-validating it under the same contract AND the macos-import rule;
absent or unproven, they are not-run.
"""

from __future__ import annotations

import argparse
import inspect
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

EVAL_DIR = Path(__file__).resolve().parent
REPO_ROOT = EVAL_DIR.parent
sys.path.insert(0, str(EVAL_DIR))

import suite_contract as contract  # noqa: E402

DEFAULT_TIMEOUT_S = 1800
NOT_RUN = "not-run"


# --------------------------------------------------------------------------
# run identity: every admitted result is bound to this run
# --------------------------------------------------------------------------


def make_run_binding(git: dict[str, Any] | None = None) -> dict[str, str]:
    """The identity of THIS run, stamped onto every result it admits.

    `git` is the pre-run tree snapshot: the binding (and the scorecard
    header) must describe the tree the run STARTED from, not the tree
    after the run wrote its own out/ artifacts.
    """
    started = datetime.now(timezone.utc)
    return {
        "run_id": f"r-{started.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}",
        "git_sha": (git or git_info())["sha"],
        "started_at": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def bind_result(result: dict[str, Any], run_binding: dict[str, str]) -> dict[str, Any]:
    """Stamp a RUNNER-AUTHORED row (a not-run refusal, a mismatch report, an
    admitted-import record) with this run's binding and re-validate it.
    Raises ContractError (a runner bug) if the stamp could not be applied —
    never silently admit. A suite-produced result is never re-stamped here:
    its producer binding is verified instead (see run_suite)."""
    result["run"] = dict(run_binding)
    contract.validate_run_binding(result, run_binding)
    return result


def reject_failed_run(payload: dict[str, Any]) -> None:
    """Explicit failed-run admission (SCORECARD.md section 4).

    A suite whose run itself failed at the infrastructure level cannot
    report results: whatever zero-issues emission it carries is refused, so
    a dead simulator or a crashed audit can never be scored as a pass. A
    payload without `run_status`, or with `run_status: "ok"`, proceeds to
    normal admission; any other declared value fails closed."""
    run_status = payload.get("run_status")
    if run_status is None or run_status == "ok":
        return
    detail = payload.get("run_status_reason") or payload.get("reason")
    raise contract.ContractError(
        f"explicit failed-run admission: the suite declared run_status "
        f"{run_status!r}"
        + (f" ({detail})" if detail else "")
        + " — a failed run cannot report results; recorded not-run, never pass"
    )


def git_info() -> dict[str, Any]:
    """Best-effort identity of the tree the scorecard was produced from."""
    info: dict[str, Any] = {"sha": "unknown", "branch": "unknown", "dirty": None}
    try:
        info["sha"] = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True,
            timeout=15, check=True,
        ).stdout.strip()
        info["branch"] = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO_ROOT,
            capture_output=True, text=True, timeout=15, check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "status", "--porcelain"], cwd=REPO_ROOT, capture_output=True,
            text=True, timeout=15, check=True,
        ).stdout.strip()
        info["dirty"] = bool(dirty)
    except (subprocess.SubprocessError, OSError):
        pass
    return info


def host_toolchain() -> dict[str, str]:
    tc = {
        "python": sys.version.split()[0],
        "platform": sys.platform,
        "runner": "linux" if not sys.platform.startswith("darwin") else "macos",
    }
    for tool, args in (("swift", ["swift", "--version"]), ("bun", ["bun", "--version"])):
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=30)
            first = (out.stdout or out.stderr).strip().splitlines()
            tc[tool] = first[0][:120] if out.returncode == 0 and first else "unavailable"
        except (subprocess.SubprocessError, OSError):
            tc[tool] = "unavailable"
    return tc


# --------------------------------------------------------------------------
# suite discovery
# --------------------------------------------------------------------------


def load_registry() -> list[dict[str, Any]]:
    """Load and shape-check the runner-owned registry (suites + bars)."""
    reg_path = EVAL_DIR / "registry.json"
    reg = json.loads(reg_path.read_text())
    if not isinstance(reg.get("suites"), list):
        raise ValueError(f"{reg_path}: expected a 'suites' list")
    for entry in reg["suites"]:
        sid = entry.get("id")
        if not sid or not isinstance(sid, str):
            raise ValueError(f"{reg_path}: every suite needs a string id")
        metrics = entry.get("metrics")
        if not isinstance(metrics, dict):
            raise ValueError(
                f"{reg_path}: suite {sid!r} needs a 'metrics' object "
                "(the runner owns the bars; an empty object registers no metrics)"
            )
        for mid, spec in metrics.items():
            if not isinstance(spec, dict) or not spec.get("label"):
                raise ValueError(
                    f"{reg_path}: suite {sid!r} metric {mid!r} needs a 'label'"
                )
            if "interval_required" in spec and not isinstance(
                spec["interval_required"], bool
            ):
                raise ValueError(
                    f"{reg_path}: suite {sid!r} metric {mid!r} "
                    "'interval_required' must be a bool"
                )
            bar = spec.get("bar")
            if bar is None:
                continue
            if not isinstance(bar, dict) or bar.get("op") not in contract.VALID_OPS:
                raise ValueError(
                    f"{reg_path}: suite {sid!r} metric {mid!r}: bar.op must be "
                    f"one of {contract.VALID_OPS}"
                )
            if not isinstance(bar.get("value"), (int, float)) or isinstance(bar["value"], bool):
                raise ValueError(
                    f"{reg_path}: suite {sid!r} metric {mid!r}: bar.value must be numeric"
                )
    return reg["suites"]


def discover_suites() -> list[dict[str, Any]]:
    """Merge the expected registry with whatever suite directories exist.

    Registry entries without directories still appear (not-run, owner named).
    Directories with a manifest but no registry entry are included too, so a
    delivering task is never silently dropped — but they carry no registry
    metrics, so their results cannot be judged (not-run until registered).
    """
    suites_dir = EVAL_DIR / "suites"
    entries: dict[str, dict[str, Any]] = {}
    for expected in load_registry():
        entry = dict(expected)
        entry["dir"] = suites_dir / entry["id"]
        entry["present"] = (entry["dir"] / "suite.json").is_file()
        entries[entry["id"]] = entry
    if suites_dir.is_dir():
        for manifest_path in sorted(suites_dir.glob("*/suite.json")):
            try:
                manifest = json.loads(manifest_path.read_text())
            except (json.JSONDecodeError, OSError) as exc:
                print(f"warning: unreadable manifest {manifest_path}: {exc}", file=sys.stderr)
                continue
            sid = manifest.get("id") or manifest_path.parent.name
            if sid in entries:
                # merge manifest detail over the registry spine; the runner
                # owns 'metrics' (the bars) — a manifest cannot set them
                merged = {
                    **entries[sid],
                    **{k: v for k, v in manifest.items() if k not in ("id", "metrics")},
                }
                merged["dir"] = manifest_path.parent
                merged["present"] = True
                entries[sid] = merged
            else:
                entry = dict(manifest)
                entry["id"] = sid
                entry.setdefault("letter", "?")
                entry.setdefault("title", sid)
                entry.setdefault("owner_task", "unregistered")
                entry.setdefault("platform", "any")
                entry.setdefault("metrics", {})
                entry["dir"] = manifest_path.parent
                entry["present"] = True
                entries[sid] = entry
    def letter_key(e: dict[str, Any]) -> tuple[Any, ...]:
        letter = e.get("letter", "?")
        return (letter if isinstance(letter, str) else "z", e["id"])
    return [entries[k] for k in sorted(entries, key=lambda k: letter_key(entries[k]))]


# --------------------------------------------------------------------------
# running one suite
# --------------------------------------------------------------------------


def not_run_suite(entry: dict[str, Any], reason: str, started: float) -> dict[str, Any]:
    return {
        "suite": entry["id"],
        "letter": entry.get("letter", "?"),
        "title": entry.get("title", entry["id"]),
        "owner_task": entry.get("owner_task", "unregistered"),
        "source": "runner",
        "metrics": [
            {
                "id": f"{entry['id']}_suite",
                "metric": f"{entry.get('letter', '?')}. {entry.get('title', entry['id'])}",
                "status": NOT_RUN,
                "reason": reason,
            }
        ],
        "duration_ms": int((time.monotonic() - started) * 1000),
    }


def mismatch_suite(
    entry: dict[str, Any], exc: contract.RegistryMismatch, started: float, source: str
) -> dict[str, Any]:
    """A suite whose metric set/labels/bars — or declared identity — differ
    from the registry: FAIL, with every mismatch named. Never not-run, never
    pass. A suite-level mismatch (e.g. missing letter/title, no metric rows
    affected) still surfaces as one fail-marked contract row."""
    metrics = exc.metrics or [
        {
            "id": f"{entry['id']}_contract",
            "metric": f"{entry.get('letter', '?')}. {entry.get('title', entry['id'])}",
            "status": "fail",
            "reason": "; ".join(exc.reasons),
        }
    ]
    return {
        "suite": entry["id"],
        "letter": entry.get("letter", "?"),
        "title": entry.get("title", entry["id"]),
        "owner_task": entry.get("owner_task", "unregistered"),
        "source": source,
        "registry_mismatches": exc.reasons,
        "metrics": metrics,
        "duration_ms": int((time.monotonic() - started) * 1000),
    }


def import_committed_results(
    entry: dict[str, Any], run_binding: dict[str, str], started: float
) -> dict[str, Any]:
    """Pick up a macOS suite's committed results (produced by an approved
    native CI run) — only after the macos-import rule proves them: matching
    head plus CI-run provenance re-verified against GitHub's REST API.
    Anything less is not-run, never pass."""
    path = EVAL_DIR / "out" / entry["id"] / "results.json"
    if not path.is_file():
        return bind_result(
            not_run_suite(
                entry,
                "requires macOS (Xcode/simulator). Native runs need the existing iOS CI "
                "targets or a workflow approved from ci/pending-workflows/eval-macos.yml "
                "(staged proposal, not installed); no committed results from a proven "
                "CI run at this head are available to import.",
                started,
            ),
            run_binding,
        )
    try:
        payload = json.loads(path.read_text())
        reject_failed_run(payload)
        provenance = contract.validate_import_provenance(
            payload, expected_sha=run_binding["git_sha"]
        )
        contract.validate_results(
            payload,
            expected_suite_id=entry["id"],
            registry_metrics=entry.get("metrics") or {},
            expected_identity={
                "letter": entry.get("letter"),
                "title": entry.get("title"),
            },
        )
    except contract.RegistryMismatch as exc:
        res = mismatch_suite(entry, exc, started, source="imported")
        res["imported_from"] = str(path.relative_to(REPO_ROOT))
        return bind_result(res, run_binding)
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return bind_result(
            not_run_suite(
                entry, f"committed results refused (macos-import rule): {exc}", started
            ),
            run_binding,
        )
    # proven: keep the producing run's identity under native_run, record the
    # verification evidence, and bind the admission record to THIS run
    payload["native_run"] = {
        **payload.pop("run", {}),
        "run_url": payload.pop("run_url", None),
    }
    payload["source"] = "imported"
    payload["imported_from"] = str(path.relative_to(REPO_ROOT))
    payload["import_provenance"] = provenance
    return bind_result(payload, run_binding)


def run_suite(
    entry: dict[str, Any],
    out_root: Path,
    timeout_s: int,
    run_binding: dict[str, str],
) -> dict[str, Any]:
    started = time.monotonic()
    platform = entry.get("platform", "any")
    host = "macos" if sys.platform.startswith("darwin") else "linux"
    if platform not in ("any", host):
        return import_committed_results(entry, run_binding, started)

    suite_dir: Path = entry["dir"]
    suite_py = suite_dir / "suite.py"
    if not suite_py.is_file():
        return bind_result(
            not_run_suite(entry, "suite directory has no suite.py", started), run_binding
        )

    out_dir = out_root / entry["id"]
    # Fresh output per run: remove whatever a previous run left behind before
    # executing, so an exit-zero suite that emits nothing can never reuse a
    # previous pass.
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, str(suite_py),
        "--out", str(out_dir),
        "--repo-root", str(REPO_ROOT),
    ]
    # Hand this run's identity to the suite: the suite stamps it as the
    # producer binding on its own results (conforming suites write
    # results["run"] = json.loads(os.environ["FL_RUN_BINDING"])), and the
    # runner verifies the emitted binding instead of overwriting it.
    env = {**os.environ, "FL_RUN_BINDING": json.dumps(run_binding)}
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout_s, cwd=str(suite_dir),
            env=env,
        )
    except subprocess.TimeoutExpired:
        return bind_result(
            not_run_suite(entry, f"suite exceeded its {timeout_s}s timeout", started),
            run_binding,
        )
    except OSError as exc:
        return bind_result(
            not_run_suite(entry, f"could not launch suite: {exc}", started), run_binding
        )

    results_path = out_dir / "results.json"
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-400:]
        return bind_result(
            not_run_suite(
                entry, f"suite exited with code {proc.returncode}: {tail or '(no output)'}", started
            ),
            run_binding,
        )
    if not results_path.is_file():
        tail = (proc.stderr or proc.stdout or "").strip()[-400:]
        return bind_result(
            not_run_suite(entry, f"suite wrote no results.json: {tail or '(no output)'}", started),
            run_binding,
        )
    try:
        payload = json.loads(results_path.read_text())
        # §4: an explicit infrastructure-failure status refuses the emission;
        # §1: the SUITE-emitted producer binding is verified, not overwritten.
        reject_failed_run(payload)
        contract.validate_run_binding(payload, run_binding)
        contract.validate_results(
            payload,
            expected_suite_id=entry["id"],
            registry_metrics=entry.get("metrics") or {},
            expected_identity={
                "letter": entry.get("letter"),
                "title": entry.get("title"),
            },
        )
    except contract.RegistryMismatch as exc:
        return bind_result(mismatch_suite(entry, exc, started, source="run"), run_binding)
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return bind_result(
            not_run_suite(entry, f"suite results failed contract validation: {exc}", started),
            run_binding,
        )

    payload["source"] = "run"
    payload["duration_ms"] = int((time.monotonic() - started) * 1000)
    payload["timeout_s"] = timeout_s
    # write the verified payload back: the per-suite evidence file itself
    # then carries the (unchanged) producer binding this run verified
    results_path.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


# --------------------------------------------------------------------------
# scorecard assembly and rendering
# --------------------------------------------------------------------------


def collect(
    selected: list[str] | None, out_root: Path, run_binding: dict[str, str]
) -> list[dict[str, Any]]:
    suites_out = []
    for entry in discover_suites():
        sid = entry["id"]
        if selected and sid not in selected:
            continue
        present = entry["present"]
        if not present:
            reason = (
                f"suite not yet delivered by {entry.get('owner_task', 'its owner')} "
                f"(no evaluation/suites/{sid}/)"
            )
            suites_out.append(bind_result(not_run_suite(entry, reason, time.monotonic()), run_binding))
            continue
        if entry.get("metrics") is None:
            # a discovered directory with no registry entry: the runner owns
            # no bars for it, so its results cannot be judged
            reason = (
                "suite directory present but not in evaluation/registry.json — the "
                "runner owns no bars for it; register the suite (with the lead's "
                "recorded bars) before its results can be judged"
            )
            suites_out.append(bind_result(not_run_suite(entry, reason, time.monotonic()), run_binding))
            continue
        timeout_s = int(entry.get("timeout_s", DEFAULT_TIMEOUT_S))
        # run_suite verifies the suite's producer binding and binds every
        # row it authors itself; do not re-stamp its result here.
        suites_out.append(run_suite(entry, out_root, timeout_s, run_binding))
    return suites_out


def build_scorecard(
    suites_out: list[dict[str, Any]],
    run_binding: dict[str, str],
    pre_run_git: dict[str, Any],
) -> dict[str, Any]:
    counts = {"pass": 0, "fail": 0, "not-run": 0}
    for s in suites_out:
        for m in s.get("metrics", []):
            counts[m["status"]] += 1
    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run": dict(run_binding),
        "git": pre_run_git,  # sampled before the run wrote anything
        "toolchain": host_toolchain(),
        "summary": counts,
        "suites": suites_out,
    }


def render_markdown(card: dict[str, Any]) -> str:
    lines: list[str] = []
    s = card["summary"]
    git = card["git"]
    run = card.get("run", {})
    lines.append("# FridgeLuck overhaul scorecard")
    lines.append("")
    lines.append(
        f"Generated {card['generated_at']} · run `{run.get('run_id', '?')}` "
        f"(started {run.get('started_at', '?')}) · git `{git['sha'][:12]}` ({git['branch']}"
        f"{', dirty' if git['dirty'] else ''}) · "
        f"python {card['toolchain']['python']} · {card['toolchain']['runner']}"
    )
    lines.append("")
    lines.append(
        f"**{s['pass']} pass · {s['fail']} fail · {s['not-run']} not-run** — "
        "a suite whose inputs are missing reports not-run, never pass."
    )
    lines.append("")
    for suite in card["suites"]:
        letter = suite.get("letter", "?")
        title = suite.get("title", suite["suite"])
        source = suite.get("source", "run")
        dur = suite.get("duration_ms")
        lines.append(
            f"## {letter}. {title} `{suite['suite']}` "
            f"({source}{f', {dur/1000:.1f}s' if isinstance(dur, int) else ''})"
        )
        lines.append("")
        for reason in suite.get("registry_mismatches", []):
            lines.append(f"**registry mismatch:** {reason}")
            lines.append("")
        lines.append("| metric | value | interval | bar | status | reason |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for m in suite.get("metrics", []):
            value = m.get("value", "—")
            interval = m.get("interval")
            interval_s = f"[{interval[0]}, {interval[1]}]" if interval else "—"
            bar = m.get("bar")
            bar_s = f"{bar['op']} {bar['value']}" if bar else "—"
            reason = (m.get("reason") or "").replace("|", "\\|")
            lines.append(
                f"| {m.get('metric', m.get('id', '?'))} | {value} | {interval_s} "
                f"| {bar_s} | {m['status']} | {reason} |"
            )
        lines.append("")
    native = card.get("run", {}).get("git_sha", "?")
    lines.append(
        "*Bars are the lead's choices, owned by `evaluation/registry.json` from "
        "PLAN.md (\"The scorecard\"); a suite cannot add, drop or re-bar a metric, "
        "and bars that require intervals apply to the interval's low end. "
        "Suite results must carry this run's identity as their producer binding "
        "(passed to the suite, verified by the runner, never overwritten); "
        "imported native results keep their producing CI run's identity, "
        "re-verified against GitHub's REST API; anything without a verifiable "
        f"binding reports not-run, never pass (head {native[:12]}). Suites B, D "
        "and E are delivered by the learning, LeChef and community tasks "
        "(see SCORECARD.md for their file contract).*"
    )
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# self-test: planted failures must be caught (data-driven)
# --------------------------------------------------------------------------


def _planted_suite_py(emit: Any) -> str:
    """Source for a planted suite.py: write `emit` as results.json — stamped
    with the producer binding this run passed in (FL_RUN_BINDING), exactly
    the way a conforming suite binds its output — exit 0 silently (emit
    None), or crash (emit 'crash')."""
    if emit == "crash":
        return "import os; os._exit(3)\n"
    if emit is None:
        return "import sys; sys.exit(0)\n"
    payload_literal = json.dumps(json.dumps(emit))  # double-encoded: quote-proof
    return (
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "out = Path(sys.argv[sys.argv.index('--out') + 1])\n"
        "out.mkdir(parents=True, exist_ok=True)\n"
        f"payload = json.loads({payload_literal})\n"
        "if os.environ.get('FL_RUN_BINDING'):\n"
        "    payload['run'] = json.loads(os.environ['FL_RUN_BINDING'])\n"
        "(out / 'results.json').write_text(json.dumps(payload))\n"
    )


def _copying_suite_py(cached: dict[str, Any]) -> str:
    """A lying planted suite: copies a cached passing results.json from an
    old out/ directory into the fresh run directory it was handed — the
    cached-pass-reuse forgery the review planted."""
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


def _synthetic_entry(
    sid: str,
    metrics: dict[str, Any],
    *,
    letter: str = "T",
    owner: str = "selftest",
    platform: str = "any",
) -> dict[str, Any]:
    return {
        "id": sid,
        "letter": letter,
        "title": sid,
        "owner_task": owner,
        "platform": platform,
        "timeout_s": 60,
        "metrics": metrics,
    }


_M_LE0 = {"label": "kept metric", "bar": {"op": "<=", "value": 0}}
_HEAD = "@HEAD@"                      # substituted with the real head at plant time
_HEAD_MISMATCH = "@HEAD-MISMATCH@"    # substituted with a non-head SHA

# A real Actions run of this repository (run 38192616346, recorded in project
# memory from the iOS CI history): the positive control binds to a run id that
# actually exists, while the CI REST response itself comes from the test
# fixture (ci_api) so the check stays deterministic offline.
REAL_RUN_ID = "38192616346"
REPO = "SamGu-NRX/FridgeLuck"


def _import_payload(
    metrics: list[dict[str, Any]],
    sha: str,
    *,
    run_id: str = REAL_RUN_ID,
    url: str | None = None,
    with_run: bool = True,
) -> dict[str, Any]:
    """A committed native-results payload: `git.sha` plus the producing CI
    run's identity. The run_url defaults to this repository's Actions URL for
    the run id — the shape real provenance has (the review's synthetic
    ci.example.test URL is planted explicitly by the synthetic-url case)."""
    payload: dict[str, Any] = {"suite": "@SUITE@", "metrics": metrics, "git": {"sha": sha}}
    payload["run_url"] = url or f"https://github.com/{REPO}/actions/runs/{run_id}"
    if with_run:
        payload["run"] = {"run_id": run_id, "started_at": "2026-10-11T00:00:00Z"}
    return payload


def _m1(value: Any, **extra: Any) -> dict[str, Any]:
    m = {"id": "m1", "metric": "kept metric", "value": value,
         "bar": {"op": "<=", "value": 0}}
    m.update(extra)
    return m


# Runner-owned planted cases. Each runs in its own temp tree against its own
# synthetic registry (or the real registry when use_real_registry is set), so
# the minimum set is deterministic regardless of which suites are delivered.
RUNNER_CASES: list[dict[str, Any]] = [
    # --- legacy runner behaviour: still must hold ---
    {"case": "crash", "suite_id": "selftest-crash",
     "registry_entry": _synthetic_entry("selftest-crash", {"m1": _M_LE0}),
     "emit": "crash",
     "expect_rows": [{"id": "selftest-crash_suite", "status": "not-run",
                      "reason_contains": ["exited with code"]}]},
    {"case": "honest-fail", "suite_id": "selftest-honest",
     "registry_entry": _synthetic_entry("selftest-honest", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-honest", "letter": "T", "title": "selftest-honest",
              "metrics": [_m1(5)]},
     "expect_rows": [{"id": "m1", "status": "fail"}]},
    {"case": "honest-pass", "suite_id": "selftest-honest",
     "registry_entry": _synthetic_entry("selftest-honest", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-honest", "letter": "T", "title": "selftest-honest",
              "metrics": [_m1(0)]},
     "expect_rows": [{"id": "m1", "status": "pass"}]},
    {"case": "liar", "suite_id": "selftest-liar",
     "registry_entry": _synthetic_entry("selftest-liar", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-liar", "letter": "T", "title": "selftest-liar",
              "metrics": [_m1(5, status="pass")]},
     "expect_rows": [{"id": "m1", "status": "fail"}]},
    {"case": "missing-inputs", "suite_id": "selftest-missing",
     "registry_entry": _synthetic_entry("selftest-missing", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-missing", "letter": "T", "title": "selftest-missing",
              "metrics": [{"id": "m1", "metric": "kept metric", "status": "not-run",
                           "reason": "planted: input corpus absent"}]},
     "expect_rows": [{"id": "m1", "status": "not-run"}]},
    {"case": "interval-equality", "suite_id": "selftest-interval",
     "registry_entry": _synthetic_entry(
         "selftest-interval",
         {"m1": {"label": "equality metric", "bar": {"op": "==", "value": 200}}}),
     "emit": {"suite": "selftest-interval", "letter": "T", "title": "selftest-interval",
              "metrics": [{"id": "m1", "metric": "equality metric", "value": 55,
                           "bar": {"op": "==", "value": 200},
                           "interval": [0.22, 0.35]}]},
     "expect_rows": [{"id": "m1", "status": "fail"}]},

    # --- defect 3: the registry owns the metric set and the bars ---
    {"case": "dropped-metric", "suite_id": "selftest-drop",
     "registry_entry": _synthetic_entry("selftest-drop", {
         "m1": _M_LE0, "m2": {"label": "second metric", "bar": {"op": "==", "value": 0}}}),
     "emit": {"suite": "selftest-drop", "letter": "T", "title": "selftest-drop",
              "metrics": [_m1(0)]},   # m2 quietly dropped
     "expect_rows": [
         {"id": "m1", "status": "pass"},
         {"id": "m2", "status": "fail",
          "reason_contains": ["missing from the suite results"]}]},
    {"case": "weakened-bar", "suite_id": "selftest-weaken",
     "registry_entry": _synthetic_entry("selftest-weaken", {"m1": _M_LE0}),
     # the suite re-bars its own metric: value 5 violates <=0, so it declares <=10
     "emit": {"suite": "selftest-weaken", "letter": "T", "title": "selftest-weaken",
              "metrics": [{"id": "m1", "metric": "kept metric", "value": 5,
                           "bar": {"op": "<=", "value": 10}}]},
     "expect_rows": [{"id": "m1", "status": "fail",
                      "reason_contains": ["differs from the registry bar"]}]},
    {"case": "extra-metric", "suite_id": "selftest-extra",
     "registry_entry": _synthetic_entry("selftest-extra", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-extra", "letter": "T", "title": "selftest-extra",
              "metrics": [_m1(0),
                          {"id": "m_extra", "metric": "sneaky extra", "value": 0,
                           "bar": {"op": "<=", "value": 0}}]},
     "expect_rows": [
         {"id": "m1", "status": "pass"},
         {"id": "m_extra", "status": "fail",
          "reason_contains": ["not in the registry"]}]},
    # --- suite identity: letter/title are schema-required on every emission
    # (the "?. suite" rendering defect seen on suite A before its fix) ---
    {"case": "missing-identity", "suite_id": "selftest-ident",
     "registry_entry": _synthetic_entry("selftest-ident", {"m1": _M_LE0}),
     "emit": {"suite": "selftest-ident", "metrics": [_m1(0)]},  # no letter/title
     "expect_rows": [{"id": "m1", "status": "pass"},
                     {"id": "selftest-ident_contract", "status": "fail",
                      "reason_contains": ["missing 'letter'"]}]},
    {"case": "wrong-identity", "suite_id": "selftest-ident2",
     "registry_entry": _synthetic_entry("selftest-ident2", {"m1": _M_LE0},
                                        letter="T"),
     "emit": {"suite": "selftest-ident2", "letter": "Z", "title": "selftest-ident2",
              "metrics": [_m1(0)]},  # declares a letter it is not registered under
     "expect_rows": [{"id": "m1", "status": "pass"},
                     {"id": "selftest-ident2_contract", "status": "fail",
                      "reason_contains": ["declare letter 'Z'",
                                          "registered as 'T'"]}]},
    # --- defect 4: fresh output per run — a stale pass cannot survive ---
    {"case": "stale-result-reuse", "suite_id": "selftest-stale",
     "registry_entry": _synthetic_entry("selftest-stale", {"m1": _M_LE0}),
     "plant_out": {"suite": "selftest-stale", "metrics": [_m1(0)]},  # last run's pass
     "emit": None,   # exits 0 and emits nothing
     "expect_rows": [{"id": "selftest-stale_suite", "status": "not-run",
                      "reason_contains": ["wrote no results.json"]}],
     "forbid_ids": ["m1"], "expect_file_absent": True},
    # --- defect 4: imported native results must prove themselves ---
    {"case": "missing-binding-import", "suite_id": "selftest-import-missing",
     "registry_entry": _synthetic_entry("selftest-import-missing", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": _import_payload([_m1(0)], _HEAD, with_run=False),
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-missing_suite", "status": "not-run",
                      "reason_contains": ["carry no run binding"]}]},
    {"case": "unbound-import", "suite_id": "selftest-import-unbound",
     "registry_entry": _synthetic_entry("selftest-import-unbound", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": {"suite": "selftest-import-unbound", "metrics": [_m1(0)]},
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-unbound_suite", "status": "not-run",
                      "reason_contains": ["no git.sha"]}]},
    {"case": "head-mismatch-import", "suite_id": "selftest-import-head",
     "registry_entry": _synthetic_entry("selftest-import-head", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": _import_payload([_m1(0)], _HEAD_MISMATCH),
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-head_suite", "status": "not-run",
                      "reason_contains": ["not the current head"]}]},
    # positive control: an import whose provenance the runner can verify is
    # admitted (source: imported) — a real run id, this repository's Actions
    # URL, and a CI REST response (fixture) confirming the run was produced
    # at exactly this head
    {"case": "bound-import", "suite_id": "selftest-import-bound",
     "registry_entry": _synthetic_entry("selftest-import-bound", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": _import_payload([_m1(0)], _HEAD),
     "ci_api": {REAL_RUN_ID: {"head_sha": _HEAD,
                              "html_url": f"https://github.com/{REPO}/actions/runs/{REAL_RUN_ID}",
                              "conclusion": "success"}},
     "emit": None, "skip_on_macos": True,
     "expect_source": "imported", "expect_all_pass": True,
     "expect_producer_run_id": REAL_RUN_ID,
     "expect_rows": [{"id": "m1", "status": "pass"}]},
    # --- r3 review: run-identity binding — a stale pass cannot be smuggled in ---
    {"case": "stale-copy-old-binding", "suite_id": "selftest-stalecopy",
     "registry_entry": _synthetic_entry("selftest-stalecopy", {"m1": _M_LE0}),
     # the suite copies a cached passing results.json from an old out/ dir;
     # it carries last run's binding (a different run id and head)
     "copy_cached": {"suite": "selftest-stalecopy", "letter": "T",
                     "title": "selftest-stalecopy",
                     "run": {"run_id": "r-20260101T000000Z-oldrun01",
                             "git_sha": "0" * 40,
                             "started_at": "2026-01-01T00:00:00Z"},
                     "metrics": [_m1(0)]},
     "emit": None,
     "expect_rows": [{"id": "selftest-stalecopy_suite", "status": "not-run",
                      "reason_contains": ["contradicting this run"]}]},
    {"case": "stale-copy-no-binding", "suite_id": "selftest-stalecopy2",
     "registry_entry": _synthetic_entry("selftest-stalecopy2", {"m1": _M_LE0}),
     "copy_cached": {"suite": "selftest-stalecopy2", "letter": "T",
                     "title": "selftest-stalecopy2", "metrics": [_m1(0)]},
     "emit": None,
     "expect_rows": [{"id": "selftest-stalecopy2_suite", "status": "not-run",
                      "reason_contains": ["no run binding"]}]},
    # --- r3 review: imports need verifiable provenance, not any HTTPS URL ---
    {"case": "synthetic-url-import", "suite_id": "selftest-import-synth",
     "registry_entry": _synthetic_entry("selftest-import-synth", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": _import_payload(
         [_m1(0)], _HEAD, run_id="424242",
         url="https://ci.example.test/FridgeLuck/actions/runs/424242"),
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-synth_suite", "status": "not-run",
                      "reason_contains": ["not provenance"]}]},
    {"case": "forged-sha-import", "suite_id": "selftest-import-forged",
     "registry_entry": _synthetic_entry("selftest-import-forged", {"m1": _M_LE0},
                                        platform="macos"),
     # right run id and URL, but the CI run was produced at another head:
     # the payload's git.sha is a forgery the REST check must expose
     "import_source": _import_payload([_m1(0)], _HEAD),
     "ci_api": {REAL_RUN_ID: {"head_sha": _HEAD_MISMATCH,
                              "html_url": f"https://github.com/{REPO}/actions/runs/{REAL_RUN_ID}"}},
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-forged_suite", "status": "not-run",
                      "reason_contains": ["was produced at"]}]},
    {"case": "unreachable-import", "suite_id": "selftest-import-unreach",
     "registry_entry": _synthetic_entry("selftest-import-unreach", {"m1": _M_LE0},
                                        platform="macos"),
     "import_source": _import_payload([_m1(0)], _HEAD),
     "ci_api_unreachable": True,
     "emit": None, "skip_on_macos": True,
     "expect_rows": [{"id": "selftest-import-unreach_suite", "status": "not-run",
                      "reason_contains": ["UNVERIFIED-NATIVE"]}]},
    # --- r3 review: explicit failed-run admission (the lead's native-audit item) ---
    {"case": "infra-failure-zero-issues", "suite_id": "selftest-infra",
     "registry_entry": _synthetic_entry(
         "selftest-infra",
         {"m1": {"label": "equality metric", "bar": {"op": "==", "value": 0}}}),
     # a suite whose run failed at the infrastructure level yet reports
     # zero issues: the emission must be refused, never scored as a pass
     "emit": {"suite": "selftest-infra", "letter": "T", "title": "selftest-infra",
              "run_status": "infrastructure-failure",
              "run_status_reason": "planted: the simulator never finished booting",
              "metrics": [{"id": "m1", "metric": "equality metric", "value": 0,
                           "bar": {"op": "==", "value": 0}}]},
     "expect_rows": [{"id": "selftest-infra_suite", "status": "not-run",
                      "reason_contains": ["infrastructure-failure"]}]},
    # --- defect 6: an absent suite dir reports not-run with the owner named ---
    {"case": "absent-suite-dir", "suite_id": "selftest-absent",
     "registry_entry": _synthetic_entry("selftest-absent", {"m1": _M_LE0},
                                        owner="fl-selftest-owner"),
     "absent_dir": True,
     "expect_rows": [{"id": "selftest-absent_suite", "status": "not-run",
                      "reason_contains": ["fl-selftest-owner",
                                          "no evaluation/suites/selftest-absent/"]}]},

    # --- defect 6: the real registry's B/D/E wiring, tested end to end ---
    {"case": "real-registry-learning-dropped", "suite_id": "learning",
     "use_real_registry": True,
     "emit": {"suite": "learning", "letter": "B", "title": "Learning",
              "metrics": [{"id": "restriction_violations",
                           "metric": "Restriction violations", "value": 0}]},
     "expect_rows": [
         {"id": "restriction_violations", "status": "pass"},
         {"id": "ndcg10_vs_rule_ranker_pct", "status": "fail",
          "reason_contains": ["missing from the suite results"]},
         {"id": "ndcg10_vs_profile_only_pct", "status": "fail",
          "reason_contains": ["missing from the suite results"]},
         {"id": "taste_shift_recovery_cooks_median", "status": "fail",
          "reason_contains": ["missing from the suite results"]}]},
    # --- r3 review: registry bars that need intervals judge the low end ---
    {"case": "real-registry-learning-point-estimate", "suite_id": "learning",
     "use_real_registry": True,
     # a +10.5% point estimate WITHOUT the required 95% interval: the
     # learning bar must not be passable on uncertainty-free estimates
     "emit": {"suite": "learning", "letter": "B", "title": "Learning", "metrics": [
         {"id": "ndcg10_vs_rule_ranker_pct",
          "metric": "NDCG@10 vs the rule ranker: relative gain among feasible picks (95% interval low, %)",
          "value": 10.5},
         {"id": "ndcg10_vs_profile_only_pct",
          "metric": "NDCG@10 vs explicit-profile-only: relative gain (95% interval low, %)",
          "value": 12, "interval": [11, 13]},
         {"id": "restriction_violations", "metric": "Restriction violations", "value": 0},
         {"id": "taste_shift_recovery_cooks_median",
          "metric": "Cooks to recover from a taste shift (median)", "value": 3}]},
     "expect_rows": [
         {"id": "ndcg10_vs_rule_ranker_pct", "status": "fail",
          "reason_contains": ["interval"]},
         {"id": "ndcg10_vs_profile_only_pct", "status": "pass"},
         {"id": "restriction_violations", "status": "pass"},
         {"id": "taste_shift_recovery_cooks_median", "status": "pass"}]},
    {"case": "real-registry-lechef-harness-conformance", "suite_id": "lechef",
     "use_real_registry": True,
     # bars omitted entirely: the runner injects them; 50% fails the >=90 bar
     "emit": {"suite": "lechef", "letter": "D", "title": "LeChef", "metrics": [
         {"id": "food_safety_violations", "metric": "Food-safety violations", "value": 0},
         {"id": "actions_without_approval",
          "metric": "Actions executed without approval", "value": 0},
         {"id": "harness_conformance_pct",
          "metric": "Harness conformance (% of scripted cook jobs)", "value": 50},
         {"id": "timer_correctness_pct",
          "metric": "Timer correctness across kill and resume (%)", "value": 100}]},
     "expect_rows": [
         {"id": "food_safety_violations", "status": "pass"},
         {"id": "actions_without_approval", "status": "pass"},
         {"id": "harness_conformance_pct", "status": "fail"},
         {"id": "timer_correctness_pct", "status": "pass"}]},
    {"case": "real-registry-community-pass", "suite_id": "community",
     "use_real_registry": True,
     "emit": {"suite": "community", "letter": "E", "title": "Community", "metrics": [
         {"id": "private_field_leaks", "metric": "Private-field leaks", "value": 0},
         {"id": "authorization_failures", "metric": "Authorization failures", "value": 0},
         {"id": "moderation_transitions_covered_pct",
          "metric": "Moderation transitions covered (%)", "value": 100}]},
     "expect_rows": [
         {"id": "private_field_leaks", "status": "pass"},
         {"id": "authorization_failures", "status": "pass"},
         {"id": "moderation_transitions_covered_pct", "status": "pass"}]},
]


def _collect_under(run_mod: Any, selected: list[str], out_root: Path,
                   binding: dict[str, str]) -> list[dict[str, Any]]:
    """collect() through the module under test, old or new signature."""
    if "run_binding" in inspect.signature(run_mod.collect).parameters:
        return run_mod.collect(selected, out_root, binding)
    return run_mod.collect(selected, out_root)  # pre-binding runner: plant away


def _check_case(case: dict[str, Any], result: dict[str, Any], sid: str) -> list[str]:
    """Assert one planted case against the result — the ENTIRE expected row
    set, not selected rows: a positive control must not be 'caught' while an
    extra identity-contract failure (or any other unexpected row) hides
    alongside it. Also checks per-row status/reason substrings, positive-
    control success, and the preserved producing identity of admitted
    imports."""
    errors: list[str] = []
    rows = {m.get("id"): m for m in result.get("metrics", [])}
    want_source = case.get("expect_source")
    if want_source and result.get("source") != want_source:
        errors.append(
            f"source is {result.get('source')!r}, expected {want_source!r}"
        )
    wants = case.get("expect_rows", [])
    for want in wants:
        row = rows.get(want["id"])
        if row is None:
            errors.append(
                f"expected row {want['id']!r} absent (rows: {sorted(rows)})"
            )
            continue
        if row.get("status") != want["status"]:
            errors.append(
                f"row {want['id']!r} reported {row.get('status')!r}, "
                f"expected {want['status']!r} (reason: {row.get('reason')!r})"
            )
        for sub in want.get("reason_contains", []):
            if sub not in (row.get("reason") or ""):
                errors.append(
                    f"row {want['id']!r} reason {row.get('reason')!r} "
                    f"does not name {sub!r}"
                )
    if not case.get("allow_extra_rows"):
        expected_ids = {w["id"] for w in wants}
        extra = sorted(set(rows) - expected_ids)
        if extra:
            errors.append(
                f"unexpected rows {extra} beyond the expected set "
                f"{sorted(expected_ids)} — the whole emitted metric set is "
                "judged, not selected rows"
            )
    if case.get("expect_all_pass"):
        failing = sorted(i for i, m in rows.items() if m.get("status") != "pass")
        if failing:
            errors.append(f"positive control: rows {failing} did not pass")
    producer_run_id = case.get("expect_producer_run_id")
    if producer_run_id is not None:
        native = result.get("native_run") or {}
        if native.get("run_id") != producer_run_id:
            errors.append(
                f"producing identity not preserved: native_run.run_id is "
                f"{native.get('run_id')!r}, expected {producer_run_id!r}"
            )
    for fid in case.get("forbid_ids", []):
        if fid in rows:
            errors.append(
                f"forbidden row {fid!r} present — a stale result survived"
            )
    if case.get("expect_file_absent"):
        if (case["_case_root"] / "out" / sid / "results.json").is_file():
            errors.append("out/<suite>/results.json still exists after a silent suite")
    return errors


def _run_case(case: dict[str, Any], tmp_root: Path, run_mod: Any,
              real_registry: dict[str, Any], binding: dict[str, str]) -> list[str]:
    case_root = tmp_root / case["case"]
    case_root.mkdir()
    case["_case_root"] = case_root
    sid = case["suite_id"]
    registry = real_registry if case.get("use_real_registry") else {
        "suites": [case["registry_entry"]]
    }
    (case_root / "registry.json").write_text(json.dumps(registry))
    platform = next(
        (s.get("platform", "any") for s in registry["suites"] if s["id"] == sid), "any"
    )
    if not case.get("absent_dir"):
        d = case_root / "suites" / sid
        d.mkdir(parents=True)
        (d / "suite.json").write_text(json.dumps(
            {"id": sid, "platform": platform, "timeout_s": 60}))
        emit = case.get("emit")
        if isinstance(emit, dict) and "suite" in emit and emit["suite"] != sid:
            raise ValueError(f"case {case['case']}: emit targets {emit['suite']!r}, not {sid!r}")
        if "copy_cached" in case:
            (d / "suite.py").write_text(_copying_suite_py(case["copy_cached"]))
        else:
            (d / "suite.py").write_text(_planted_suite_py(emit))
    # CI REST fixture: deterministic responses for the run ids a case's import
    # claims; ci_api_unreachable simulates a network that blocks verification.
    ci_api: dict[str, str] = {}
    for run_id, body in (case.get("ci_api") or {}).items():
        dumped = json.dumps(body)
        ci_api[run_id] = dumped.replace(_HEAD, binding["git_sha"]).replace(
            _HEAD_MISMATCH, "0" * 40
        )
    if case.get("import_source") is not None:
        src = json.loads(json.dumps(case["import_source"]))  # deep copy
        src["suite"] = sid
        # conforming imports carry the suite identity too (validate_results
        # checks it on every result); take it from the case's registry entry
        entry_spec = next((s for s in registry["suites"] if s["id"] == sid), {})
        src.setdefault("letter", entry_spec.get("letter"))
        src.setdefault("title", entry_spec.get("title"))
        for node in (src, src.get("git")):
            if isinstance(node, dict) and node.get("sha") == _HEAD:
                node["sha"] = binding["git_sha"]
            if isinstance(node, dict) and node.get("sha") == _HEAD_MISMATCH:
                node["sha"] = "0" * 40
        out_dir = case_root / "out" / sid
        out_dir.mkdir(parents=True)
        (out_dir / "results.json").write_text(json.dumps(src))
    if case.get("plant_out") is not None:
        out_dir = case_root / "out" / sid
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "results.json").write_text(json.dumps(case["plant_out"]))

    # The module under test derives paths from its module globals: point both
    # at the temp tree (eval dir and the repo root its imported-from paths are
    # made relative to), then restore. Use its own originals, not ours - the
    # module under test may be an extracted base-content copy.
    originals = (run_mod.EVAL_DIR, run_mod.REPO_ROOT)
    saved_http_get = getattr(run_mod.contract, "HTTP_GET", None)
    if (ci_api or case.get("ci_api_unreachable")) and saved_http_get is not None:
        def _fixture_get(url: str, token: str | None) -> tuple[int, str]:
            if case.get("ci_api_unreachable"):
                raise urllib.error.URLError("planted: the network is unreachable")
            rid = url.rstrip("/").rsplit("/", 1)[-1]
            if rid not in ci_api:
                raise urllib.error.HTTPError(
                    url, 404, "planted: no such Actions run", None, io.BytesIO(b"")
                )
            return 200, ci_api[rid]

        run_mod.contract.HTTP_GET = _fixture_get
    try:
        run_mod.EVAL_DIR = case_root
        run_mod.REPO_ROOT = case_root
        results_list = _collect_under(run_mod, [sid], case_root / "out", binding)
    except Exception as exc:  # the module under test crashed: record, don't abort
        import traceback

        return [
            f"module under test crashed instead of failing closed: "
            f"{type(exc).__name__}: {exc} (tail: {traceback.format_exc()[-200:]})"
        ]
    finally:
        run_mod.EVAL_DIR, run_mod.REPO_ROOT = originals
        if saved_http_get is not None:
            run_mod.contract.HTTP_GET = saved_http_get
    results = {s["suite"]: s for s in results_list}
    result = results.get(sid)
    if result is None:
        return [f"suite {sid!r} vanished from collection"]
    return _check_case(case, result, sid)


def _per_suite_case_files() -> list[tuple[str, Path]]:
    """The per-suite planted-case convention: every suite may ship
    `evaluation/suites/<id>/selftest/*.json` case files (schema in
    SCORECARD.md). The runner owns none of them — suites add their own."""
    found: list[tuple[str, Path]] = []
    for suite_dir in sorted((EVAL_DIR / "suites").glob("*")):
        cases_dir = suite_dir / "selftest"
        if not cases_dir.is_dir():
            continue
        for case_path in sorted(cases_dir.glob("*.json")):
            found.append((suite_dir.name, case_path))
    return found


def self_test(run_mod: Any | None = None) -> int:
    """Plant failures; every one must be caught. Exits 0 only when every
    planted failure is caught (2 otherwise).

    Runs the runner-owned RUNNER_CASES plus each suite's own planted cases
    from `evaluation/suites/<id>/selftest/*.json`, then every present suite's
    internal `suite.py --self-test`. `run_mod` defaults to this same file
    imported as module `run` (a separate module object so the temp-tree
    EVAL_DIR swap does not touch this module).
    """
    failures: list[str] = []
    caught = 0
    total = 0  # runner cases + per-suite cases + present-suite self-tests
    if run_mod is None:
        import run as run_mod  # type: ignore  (this same file, module name `run`)

    real_registry = {"suites": load_registry()}
    binding = {
        "run_id": "r-selftest-000000",
        "git_sha": git_info()["sha"],
        "started_at": "1970-01-01T00:00:00Z",
    }
    on_macos = sys.platform.startswith("darwin")

    with tempfile.TemporaryDirectory(prefix="fl-scorecard-selftest-") as tmp:
        tmp_root = Path(tmp)
        all_cases: list[dict[str, Any]] = [dict(c) for c in RUNNER_CASES]
        for sid, case_path in _per_suite_case_files():
            try:
                case = json.loads(case_path.read_text())
            except (json.JSONDecodeError, OSError) as exc:
                failures.append(f"per-suite case {case_path}: unreadable: {exc}")
                continue
            case.setdefault("case", f"{sid}:{case_path.stem}")
            case["suite_id"] = sid
            case["use_real_registry"] = True
            # per-suite cases are their author's scope: expect_rows names the
            # rows under test and honest rows may sit alongside them. The
            # runner's OWN cases assert the exact row set instead — a
            # positive control must not be 'caught' while an extra
            # identity-contract failure hides beside it.
            case.setdefault("allow_extra_rows", True)
            all_cases.append(case)
        skipped = []
        for case in all_cases:
            if case.get("skip_on_macos") and on_macos:
                skipped.append(case["case"])
                continue
            case_errors = _run_case(case, tmp_root, run_mod, real_registry, binding)
            label = f"planted {case['case']}"
            total += 1
            if case_errors:
                failures.extend(f"{label}: {e}" for e in case_errors)
                print(f"  UNCAUGHT {label}: {case_errors[0]}")
            else:
                caught += 1
                print(f"  caught  {label}")

        # every present real suite must also catch its own planted failures
        # (this module's discover: the real tree, whatever run_mod points at)
        for entry in discover_suites():
            if not entry["present"]:
                continue
            suite_py = entry["dir"] / "suite.py"
            if not suite_py.is_file():
                continue
            proc = subprocess.run(
                [sys.executable, str(suite_py), "--self-test"],
                capture_output=True, text=True, timeout=DEFAULT_TIMEOUT_S,
                cwd=str(entry["dir"]),
            )
            label = f"suite {entry['id']} --self-test"
            total += 1
            caught += 1
            if proc.returncode == 0:
                print(f"  caught  {label}: "
                      f"{(proc.stdout or '').strip().splitlines()[-1] if (proc.stdout or '').strip() else 'ok'}")
            else:
                caught -= 1
                failures.append(
                    f"{label} failed (exit {proc.returncode}): "
                    f"{(proc.stderr or proc.stdout or '').strip()[-300:]}"
                )

    # present suites shipping no planted cases of their own: warn, don't fail
    shipped = {sid for sid, _ in _per_suite_case_files()}
    for entry in discover_suites():
        if entry["present"] and entry["id"] not in shipped:
            print(f"  note    suite {entry['id']}: no selftest/ cases yet — "
                  "add evaluation/suites/" + entry["id"] + "/selftest/*.json "
                  "(convention in SCORECARD.md)")

    print("")
    if skipped:
        print(f"(skipped on this host: {', '.join(skipped)})")
    if failures:
        print(f"SELF-TEST FAILED: {caught}/{total} runner cases + suites behaved as required")
        for f in failures:
            print(f"  UNCAUGHT: {f}")
        return 2
    print(f"self-test ok: {caught}/{total} runner cases + suites behaved as required")
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="FridgeLuck overhaul scorecard runner")
    ap.add_argument("--suite", action="append", dest="suites",
                    help="suite id to run (repeatable); default: all")
    ap.add_argument("--all", action="store_true", help="run every suite runnable on this host")
    ap.add_argument("--list", action="store_true", help="list expected suites and exit")
    ap.add_argument("--self-test", action="store_true",
                    help="planted failures must be caught by the runner and every suite")
    ap.add_argument("--out", default=str(EVAL_DIR / "out"), help="output directory")
    args = ap.parse_args()

    if args.list:
        print(f"{'id':<16} {'letter':<6} {'platform':<8} {'present':<8} {'bars':<5} owner")
        for e in discover_suites():
            bars = e.get("metrics")
            bars_s = str(len(bars)) if isinstance(bars, dict) else "—"
            print(f"{e['id']:<16} {e.get('letter', '?'):<6} {e.get('platform', 'any'):<8} "
                  f"{'yes' if e['present'] else 'no':<8} {bars_s:<5} {e.get('owner_task', '')}")
        return 0

    if args.self_test:
        return self_test()

    selected = args.suites  # None means: everything (same as --all)
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    pre_run_git = git_info()  # sampled before any out/ write can dirty the tree
    run_binding = make_run_binding(pre_run_git)
    started = time.monotonic()
    suites_out = collect(selected, out_root, run_binding)
    card = build_scorecard(suites_out, run_binding, pre_run_git)
    card["runner_duration_ms"] = int((time.monotonic() - started) * 1000)

    json_path = out_root / "scorecard.json"
    md_path = out_root / "scorecard.md"
    json_path.write_text(json.dumps(card, indent=2) + "\n")
    md_path.write_text(render_markdown(card))

    s = card["summary"]
    print(f"scorecard: {s['pass']} pass, {s['fail']} fail, {s['not-run']} not-run")
    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
