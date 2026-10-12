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
- The runner derives pass/fail itself from value + bar + interval via
  suite_contract.py, so a broken or lying check cannot report pass.
- The runner fail-closes: a suite that crashes, times out, or emits malformed
  results is not-run with the reason.
- Bars come from the plan (evaluation/registry.json "bars"), not from the
  suites: a suite-declared bar that differs from the registered bar, or that
  is registered nowhere, fails the metric with the reason.
- Executed suites must echo the runner's run id (env EVAL_RUN_ID) in their
  results; the runner rejects stale output as not-run, never scores it.
- Exit code: 0 when the scorecard was produced (pass/fail is data, reported
  honestly); 1 on infrastructure errors; 2 when --self-test catches an
  uncaught planted failure.

macOS-only suites (ui-polish, journeys) run on macOS only: via the existing
iOS CI targets, or via a workflow proposed under ci/pending-workflows/ and
approved and installed by Sam (the fleet never edits or installs CI).
On other hosts the runner imports their committed `evaluation/out/<id>/results.json`
(produced from that workflow's artifacts and committed with its run URL) after
re-validating it under the same contract; absent that, they are not-run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
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
# host and git identity
# --------------------------------------------------------------------------


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


def load_registry() -> dict[str, Any]:
    reg_path = EVAL_DIR / "registry.json"
    return json.loads(reg_path.read_text())


def load_bars() -> dict[str, Any]:
    """Plan bars live here, keyed by suite, not in the suites' own results."""
    return load_registry().get("bars", {})

def discover_suites() -> list[dict[str, Any]]:
    """Merge the expected registry with whatever suite directories exist.

    Registry entries without directories still appear (not-run, owner named).
    Directories with a manifest but no registry entry are included too, so a
    delivering task is never silently dropped.
    """
    suites_dir = EVAL_DIR / "suites"
    entries: dict[str, dict[str, Any]] = {}
    for expected in load_registry()["suites"]:
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
                # merge manifest detail over the registry spine
                merged = {**entries[sid], **{k: v for k, v in manifest.items() if k != "id"}}
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
                entry["dir"] = manifest_path.parent
                entry["present"] = True
                entries[sid] = entry
    def letter_key(e: dict[str, Any]) -> tuple[Any, ...]:
        letter = e.get("letter", "?")
        return (letter if isinstance(letter, str) else "z", e["id"])
    return [entries[k] for k in sorted(entries, key=lambda k: letter_key(entries[k]))]


# --------------------------------------------------------------------------
# bar governance: the plan's bars, not the suite's
# --------------------------------------------------------------------------


def _bar_core(bar: Any) -> tuple[Any, Any] | None:
    if not isinstance(bar, dict):
        return None
    return (bar.get("op"), bar.get("value"))


def _bars_for(suite_id: str) -> dict[str, Any]:
    return load_bars().get(suite_id, {})


def _bar_source(suite_id: str) -> str:
    return _bars_for(suite_id).get("authority", "plan")


def _registry_bar(suite_id: str, metric_id: str) -> tuple[dict[str, Any] | None, str | None]:
    """The registered bar for a metric, and which section registered it.

    Returns (bar, "plan" | "supporting") for a fixed bar, (None,
    "supporting-free") when the metric is listed as supporting with no fixed
    bar, and (None, None) when the metric is not registered at all.
    """
    section = _bars_for(suite_id)
    sup = section.get("supporting", {})
    if metric_id in sup:
        bar = sup.get(metric_id)
        return (dict(bar), "supporting") if isinstance(bar, dict) else (None, "supporting-free")
    plan_bar = section.get("plan", {}).get(metric_id)
    if isinstance(plan_bar, dict):
        return dict(plan_bar), "plan"
    return None, None


def apply_plan_bars_pre(suite_id: str, payload: dict[str, Any]) -> None:
    """Before derivation: a value with no declared bar takes the plan's bar."""
    if _bar_source(suite_id) != "plan":
        return
    for m in payload.get("metrics", []):
        if not isinstance(m, dict):
            continue
        rb, _group = _registry_bar(suite_id, str(m.get("id", "")))
        if rb is not None and m.get("bar") is None and m.get("value") is not None:
            m["bar"] = rb


def apply_plan_bars_post(suite_id: str, payload: dict[str, Any]) -> None:
    """After derivation: the registry's bar governs. A suite-declared bar that
    differs from the registered bar, or that is registered nowhere, fails the
    metric with the reason — a suite cannot lower its own bar and pass."""
    if _bar_source(suite_id) != "plan":
        return
    for m in payload.get("metrics", []):
        if not isinstance(m, dict):
            continue
        sb = m.get("bar")
        if sb is None:
            continue
        rb, group = _registry_bar(suite_id, str(m.get("id", "")))
        if group == "supporting-free":
            continue
        if rb is None:
            m["status"] = "fail"
            m["reason"] = (
                f"metric {m.get('id')!r} declares a bar that is not in "
                "evaluation/registry.json (no plan or supporting bar); "
                "suites may not set their own bars"
            )
            continue
        if _bar_core(sb) != _bar_core(rb):
            m["declared_bar"] = sb
            m["bar"] = rb
            m["status"] = "fail"
            m["reason"] = (
                "suite-declared bar differs from the registered "
                f"{group} bar (evaluation/registry.json is authoritative): "
                f"declared {json.dumps(_bar_core(sb))}, registered {json.dumps(_bar_core(rb))}"
            )


def stamp_identity(payload: dict[str, Any], entry: dict[str, Any]) -> None:
    """The runner stamps suite identity from the registry; suites do not."""
    payload.setdefault("letter", entry.get("letter", "?"))
    payload.setdefault("title", entry.get("title", entry["id"]))


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


def import_committed_results(entry: dict[str, Any], started: float) -> dict[str, Any]:
    """Pick up a macOS suite's committed results (produced on macOS CI)."""
    path = EVAL_DIR / "out" / entry["id"] / "results.json"
    if not path.is_file():
        return not_run_suite(
            entry,
            "requires macOS (Xcode/simulator). Native runs need the existing iOS CI "
            "targets or a workflow approved from ci/pending-workflows/eval-macos.yml "
            "(staged proposal, not installed); "
            "no committed results imported from a CI run yet.",
            started,
        )
    try:
        payload = json.loads(path.read_text())
        apply_plan_bars_pre(entry["id"], payload)
        contract.validate_results(payload, expected_suite_id=entry["id"])
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return not_run_suite(
            entry, f"committed results failed contract validation: {exc}", started
        )
    apply_plan_bars_post(entry["id"], payload)
    stamp_identity(payload, entry)
    payload["source"] = "imported"
    payload["imported_from"] = str(path.relative_to(REPO_ROOT))
    return payload


def run_suite(
    entry: dict[str, Any], out_root: Path, timeout_s: int, run_id: str | None = None
) -> dict[str, Any]:
    started = time.monotonic()
    platform = entry.get("platform", "any")
    host = "macos" if sys.platform.startswith("darwin") else "linux"
    if platform not in ("any", host):
        return import_committed_results(entry, started)

    suite_dir: Path = entry["dir"]
    suite_py = suite_dir / "suite.py"
    if not suite_py.is_file():
        return not_run_suite(entry, "suite directory has no suite.py", started)

    out_dir = out_root / entry["id"]
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, str(suite_py),
        "--out", str(out_dir),
        "--repo-root", str(REPO_ROOT),
    ]
    if run_id:
        cmd += ["--run-id", run_id]
    env = dict(os.environ)
    if run_id:
        env["EVAL_RUN_ID"] = run_id
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout_s, cwd=str(suite_dir),
            env=env,
        )
    except subprocess.TimeoutExpired:
        return not_run_suite(entry, f"suite exceeded its {timeout_s}s timeout", started)
    except OSError as exc:
        return not_run_suite(entry, f"could not launch suite: {exc}", started)

    results_path = out_dir / "results.json"
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-400:]
        return not_run_suite(
            entry, f"suite exited with code {proc.returncode}: {tail or '(no output)'}", started
        )
    if not results_path.is_file():
        tail = (proc.stderr or proc.stdout or "").strip()[-400:]
        return not_run_suite(entry, f"suite wrote no results.json: {tail or '(no output)'}", started)
    try:
        payload = json.loads(results_path.read_text())
        if run_id is not None and payload.get("run_id") != run_id:
            return not_run_suite(
                entry,
                f"stale results rejected: results.json carries run_id "
                f"{payload.get('run_id')!r} but this run is {run_id!r}; a suite "
                "exiting 0 must write fresh output carrying the runner's run id "
                "(env EVAL_RUN_ID) every time",
                started,
            )
        apply_plan_bars_pre(entry["id"], payload)
        contract.validate_results(payload, expected_suite_id=entry["id"])
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return not_run_suite(entry, f"suite results failed contract validation: {exc}", started)

    apply_plan_bars_post(entry["id"], payload)
    stamp_identity(payload, entry)
    payload["source"] = "run"
    payload["duration_ms"] = int((time.monotonic() - started) * 1000)
    payload["timeout_s"] = timeout_s
    return payload


# --------------------------------------------------------------------------
# scorecard assembly and rendering
# --------------------------------------------------------------------------


def collect(selected: list[str] | None, out_root: Path, run_id: str) -> dict[str, Any]:
    suites_out = []
    for entry in discover_suites():
        sid = entry["id"]
        if selected and sid not in selected:
            continue
        present = entry["present"]
        platform = entry.get("platform", "any")
        host = "macos" if sys.platform.startswith("darwin") else "linux"
        if not present:
            reason = (
                f"suite not yet delivered by {entry.get('owner_task', 'its owner')} "
                f"(no evaluation/suites/{sid}/)"
            )
            suites_out.append(not_run_suite(entry, reason, time.monotonic()))
            continue
        timeout_s = int(entry.get("timeout_s", DEFAULT_TIMEOUT_S))
        suites_out.append(run_suite(entry, out_root, timeout_s, run_id))
    return suites_out


def build_scorecard(suites_out: list[dict[str, Any]], run_id: str) -> dict[str, Any]:
    counts = {"pass": 0, "fail": 0, "not-run": 0}
    for s in suites_out:
        for m in s.get("metrics", []):
            counts[m["status"]] += 1
    return {
        "run_id": run_id,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git": git_info(),
        "toolchain": host_toolchain(),
        "summary": counts,
        "suites": suites_out,
    }


def render_markdown(card: dict[str, Any]) -> str:
    lines: list[str] = []
    s = card["summary"]
    git = card["git"]
    lines.append("# FridgeLuck overhaul scorecard")
    lines.append("")
    lines.append(
        f"Generated {card['generated_at']} · git `{git['sha'][:12]}` ({git['branch']}"
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
    lines.append(
        "*Bars are the lead's choices from PLAN.md (\"The scorecard\"), not measured "
        "optima. Suites B, D and E are delivered by the learning, LeChef and community "
        "tasks (see SCORECARD.md for their file contract).*"
    )
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# self-test: planted failures must be caught
# --------------------------------------------------------------------------


def planted_suite(source: str) -> str:
    return f"""import json, sys, os
from pathlib import Path
out = Path(sys.argv[sys.argv.index('--out') + 1])
payload = {source}
if isinstance(payload, dict) and 'run_id' not in payload:
    env_run = os.environ.get('EVAL_RUN_ID')
    if env_run is not None:
        payload['run_id'] = env_run
(out / 'results.json').write_text(json.dumps(payload))
"""


PLANTED = {
    # A suite that crashes without writing results -> all not-run, never pass.
    "crash": ("evaluation-crash", []),
    # An honest fail must stay fail.
    "honest-fail": ("evaluation-honest-fail", [
        {"id": "m1", "metric": "planted honest fail", "value": 5, "bar": {"op": "<=", "value": 0}}
    ]),
    # An honest pass must stay pass.
    "honest-pass": ("evaluation-honest-pass", [
        {"id": "m1", "metric": "planted honest pass", "value": 0, "bar": {"op": "<=", "value": 0}}
    ]),
    # A lying suite: bar violated but status declared pass. The contract strips
    # the declared status and reports the derived one, so the lie becomes an
    # honest fail, never a pass.
    "liar": ("evaluation-liar", [
        {"id": "m1", "metric": "planted liar", "value": 5, "bar": {"op": "<=", "value": 0}, "status": "pass"}
    ]),
    # Missing inputs: the suite itself reports not-run with a reason.
    "missing-inputs": ("evaluation-missing-inputs", [
        {"id": "m1", "metric": "planted missing inputs", "status": "not-run",
         "reason": "planted: input corpus absent"}
    ]),
    # An interval recorded on an equality bar is kept as evidence and must not
    # affect derivation: 55 != 200 derives fail, never pass.
    "interval-equality": ("evaluation-interval-equality", [
        {"id": "m1", "metric": "planted interval on equality bar", "value": 55,
         "bar": {"op": "==", "value": 200}, "interval": [0.2226, 0.3501]}
    ]),
    # A suite exits 0 but writes stale results (wrong run id): the runner
    # refuses to score old output as this run's evidence.
    "stale-results": ("evaluation-stale", [
        {"id": "m1", "metric": "planted stale results", "value": 0, "bar": {"op": "<=", "value": 0}}
    ]),
    # A suite weakening its own bar (0 -> 999) must not turn a violation into
    # a pass: the plan bar in the registry governs.
    "weakened-bar": ("evaluation-weakened", [
        {"id": "m1", "metric": "planted weakened bar", "value": 5, "bar": {"op": "<=", "value": 999}}
    ]),
    # A suite inventing a bar that is not in the registry fails outright.
    "unregistered-bar": ("evaluation-unregistered", [
        {"id": "m1", "metric": "planted unregistered bar", "value": 5, "bar": {"op": ">=", "value": 1}}
    ]),
}

# What the runner must report for each planted suite's single metric.
EXPECTED = {
    "crash": NOT_RUN,
    "honest-fail": "fail",
    "honest-pass": "pass",
    "liar": "fail",         # declared pass stripped -> derived fail
    "missing-inputs": NOT_RUN,
    "interval-equality": "fail",
    "stale-results": NOT_RUN,   # wrong run id -> stale, rejected
    "weakened-bar": "fail",     # registry bar governs; the weakened bar is a violation
    "unregistered-bar": "fail", # suites may not set their own bars
}


def self_test() -> int:
    failures: list[str] = []
    caught = 0
    total = len(PLANTED)

    with tempfile.TemporaryDirectory(prefix="fl-scorecard-selftest-") as tmp:
        tmp_root = Path(tmp)
        suites_dir = tmp_root / "suites"
        for name, (sid, metrics) in PLANTED.items():
            d = suites_dir / sid
            d.mkdir(parents=True)
            (d / "suite.json").write_text(
                json.dumps({"id": sid, "letter": "T", "title": sid, "owner_task": "selftest",
                            "platform": "any", "timeout_s": 60})
            )
            payload_src: dict[str, Any] = {"suite": sid, "metrics": metrics}
            if name == "stale-results":
                # writes a deliberately stale run id; the emitter template
                # must keep it so the runner rejects the results
                payload_src["run_id"] = "stale-run"
            (d / "suite.py").write_text(
                planted_suite(json.dumps(payload_src))
                + ("import os; os._exit(3)" if name == "crash" else "")
            )
        # run the collector core against the planted tree: import this file as a
        # module named `run` and point its module-level EVAL_DIR at the temp tree
        # (reloading would not work: the module body recomputes EVAL_DIR from __file__).
        # This module's own EVAL_DIR is untouched — `run` is a separate module object.
        (tmp_root / "registry.json").write_text(json.dumps({
            "suites": [],
            "bars": {
                "evaluation-honest-fail": {"plan": {"m1": {"op": "<=", "value": 0}}},
                "evaluation-honest-pass": {"plan": {"m1": {"op": "<=", "value": 0}}},
                "evaluation-liar": {"plan": {"m1": {"op": "<=", "value": 0}}},
                "evaluation-interval-equality": {"plan": {"m1": {"op": "==", "value": 200}}},
                "evaluation-weakened": {"plan": {"m1": {"op": "<=", "value": 0}}},
            },
        }))
        import run as run_mod  # type: ignore  (this same file, under module name `run`)

        run_mod.EVAL_DIR = tmp_root
        out_root = tmp_root / "out"
        results = {s["suite"]: s for s in run_mod.collect(None, out_root)}

        for name, (sid, _) in PLANTED.items():
            suite_res = results.get(sid)
            if suite_res is None:
                failures.append(f"planted {name}: suite vanished from collection")
                continue
            for m in suite_res.get("metrics", []):
                want = EXPECTED[name]
                got = m["status"]
                label = f"planted {name}: {m.get('id')}"
                if got == want:
                    caught += 1
                    print(f"  caught  {label} -> {got}")
                else:
                    failures.append(f"{label} reported {got}, expected {want}")

    # every present real suite must also catch its own planted failures
    for entry in discover_suites():
        if not entry["present"]:
            continue
        suite_py = entry["dir"] / "suite.py"
        if not suite_py.is_file():
            continue
        proc = subprocess.run(
            [sys.executable, str(suite_py), "--self-test"],
            capture_output=True, text=True, timeout=DEFAULT_TIMEOUT_S, cwd=str(entry["dir"]),
        )
        label = f"suite {entry['id']} --self-test"
        total += 1
        if proc.returncode == 0:
            caught += 1
            print(f"  caught  {label}: {(proc.stdout or '').strip().splitlines()[-1] if (proc.stdout or '').strip() else 'ok'}")
        else:
            failures.append(
                f"{label} failed (exit {proc.returncode}): "
                f"{(proc.stderr or proc.stdout or '').strip()[-300:]}"
            )

    print("")
    if failures:
        print(f"SELF-TEST FAILED: {caught}/{total} planted checks behaved as required")
        for f in failures:
            print(f"  UNCAUGHT: {f}")
        return 2
    print(f"self-test ok: {caught}/{total} planted checks behaved as required")
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
        print(f"{'id':<16} {'letter':<6} {'platform':<8} {'present':<8} owner")
        for e in discover_suites():
            print(f"{e['id']:<16} {e.get('letter', '?'):<6} {e.get('platform', 'any'):<8} "
                  f"{'yes' if e['present'] else 'no':<8} {e.get('owner_task', '')}")
        return 0

    if args.self_test:
        return self_test()

    selected = args.suites  # None means: everything (same as --all)
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    run_id = f"r{time.time_ns():x}"
    started = time.monotonic()
    suites_out = collect(selected, out_root, run_id)
    card = build_scorecard(suites_out, run_id)
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
