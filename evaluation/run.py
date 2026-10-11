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
- Exit code: 0 when the scorecard was produced (pass/fail is data, reported
  honestly); 1 on infrastructure errors; 2 when --self-test catches an
  uncaught planted failure.

macOS-only suites (ui-polish, journeys) run via .github/workflows/eval-macos.yml.
On other hosts the runner imports their committed `evaluation/out/<id>/results.json`
(produced from that workflow's artifacts and committed with its run URL) after
re-validating it under the same contract; absent that, they are not-run.
"""

from __future__ import annotations

import argparse
import json
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


def load_registry() -> list[dict[str, Any]]:
    reg_path = EVAL_DIR / "registry.json"
    reg = json.loads(reg_path.read_text())
    return reg["suites"]


def discover_suites() -> list[dict[str, Any]]:
    """Merge the expected registry with whatever suite directories exist.

    Registry entries without directories still appear (not-run, owner named).
    Directories with a manifest but no registry entry are included too, so a
    delivering task is never silently dropped.
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
            "requires macOS (Xcode/simulator). Runs via .github/workflows/eval-macos.yml; "
            "no committed results imported from a CI run yet.",
            started,
        )
    try:
        payload = json.loads(path.read_text())
        contract.validate_results(payload, expected_suite_id=entry["id"])
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return not_run_suite(
            entry, f"committed results failed contract validation: {exc}", started
        )
    payload["source"] = "imported"
    payload["imported_from"] = str(path.relative_to(REPO_ROOT))
    return payload


def run_suite(entry: dict[str, Any], out_root: Path, timeout_s: int) -> dict[str, Any]:
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
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout_s, cwd=str(suite_dir)
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
        contract.validate_results(payload, expected_suite_id=entry["id"])
    except (json.JSONDecodeError, contract.ContractError) as exc:
        return not_run_suite(entry, f"suite results failed contract validation: {exc}", started)

    payload["source"] = "run"
    payload["duration_ms"] = int((time.monotonic() - started) * 1000)
    payload["timeout_s"] = timeout_s
    return payload


# --------------------------------------------------------------------------
# scorecard assembly and rendering
# --------------------------------------------------------------------------


def collect(selected: list[str] | None, out_root: Path) -> dict[str, Any]:
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
        suites_out.append(run_suite(entry, out_root, timeout_s))
    return suites_out


def build_scorecard(suites_out: list[dict[str, Any]]) -> dict[str, Any]:
    counts = {"pass": 0, "fail": 0, "not-run": 0}
    for s in suites_out:
        for m in s.get("metrics", []):
            counts[m["status"]] += 1
    return {
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
    return f"""import json, sys
from pathlib import Path
out = Path(sys.argv[sys.argv.index('--out') + 1])
payload = {source}
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
}

# What the runner must report for each planted suite's single metric.
EXPECTED = {
    "crash": NOT_RUN,
    "honest-fail": "fail",
    "honest-pass": "pass",
    "liar": "fail",         # declared pass stripped -> derived fail
    "missing-inputs": NOT_RUN,
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
            (d / "suite.py").write_text(
                planted_suite(json.dumps({"suite": sid, "metrics": metrics}))
                + ("import os; os._exit(3)" if name == "crash" else "")
            )
        # run the collector core against the planted tree: import this file as a
        # module named `run` and point its module-level EVAL_DIR at the temp tree
        # (reloading would not work: the module body recomputes EVAL_DIR from __file__).
        # This module's own EVAL_DIR is untouched — `run` is a separate module object.
        (tmp_root / "registry.json").write_text(json.dumps({"suites": []}))
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
        if proc.returncode == 0:
            caught += 1
            print(f"  caught  {label}: {(proc.stdout or '').strip().splitlines()[-1] if (proc.stdout or '').strip() else 'ok'}")
        else:
            failures.append(
                f"{label} failed (exit {proc.returncode}): "
                f"{(proc.stderr or proc.stdout or '').strip()[-300:]}"
            )
            total += 1

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

    started = time.monotonic()
    suites_out = collect(selected, out_root)
    card = build_scorecard(suites_out)
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
