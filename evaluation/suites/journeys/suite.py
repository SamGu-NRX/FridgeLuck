#!/usr/bin/env python3
"""Suite G (journeys) — the nine PLAN journeys must pass with no crash.

Bar (PLAN.md line 52): "All of these pass with no crash: first run, scan and
review, Tonight, recipe, cook, complete, share, challenge, taste-profile
edit" — 100% of the nine journeys, measured on macOS CI in the simulator.

Arms:
  - macOS arm (XCUITest): drives the running app through each journey,
    emitting a per-journey status (passed | failed | crashed | blocked) with
    step-level detail. A journey blocked by a bug or a missing surface is a
    real failure for the bar, never not-run.
  - static arm (any host, SUPPORTING EVIDENCE ONLY): entry-point discovery
    over the committed SwiftUI source — which journeys have a discoverable
    UI affordance at all. Distinct metric id, conservative interval.

On this Linux host the macOS-arm metric reports not-run with the precise
reason; the runner additionally imports committed CI results from
evaluation/out/journeys/results.json when present (SCORECARD.md).

--self-test plants corrupted fixtures, a lying emitter, flipped labels and
channel gaps, and asserts the derived status flips — exit 0 only when every
plant is caught.
"""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUITE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SUITE_DIR))
sys.path.insert(0, str(SUITE_DIR.parent.parent))  # evaluation/

import suite_contract as contract  # noqa: E402
from adapters import journeys_parse  # noqa: E402
from static import entry_points  # noqa: E402

SUITE_ID = "journeys"
LETTER = "G"
TITLE = "Journeys"
MACOS_ARM_TOOLS = ("xcodebuild", "xcrun", "xcodegen")
SAMPLE_DIR = SUITE_DIR / "fixtures" / "sample-journeys"


# --------------------------------------------------------------------------
# metric builders
# --------------------------------------------------------------------------


def primary_metrics_from_run(derived: dict[str, Any], evidence_dir: Path) -> list[dict[str, Any]]:
    detail_bits = [
        f"{derived['passed']}/{derived['total']} journeys passed",
    ]
    if derived["blocked_ids"]:
        detail_bits.append(
            "blocked (missing surface, counts as not passed): "
            + ", ".join(derived["blocked_ids"])
        )
    if derived["failed_ids"]:
        detail_bits.append("failed/crashed: " + ", ".join(derived["failed_ids"]))
    detail_bits.append("per-journey statuses and step trails in the evidence payload")
    return [
        {
            "id": "g_journeys_passed_pct",
            "metric": "Runnable journeys passing with no crash",
            "value": derived["pass_pct"],
            "bar": contract.eq(100.0),
            "detail": "; ".join(detail_bits),
            "evidence": {
                "path": str(evidence_dir),
                "note": json.dumps(derived["journeys"])[:1800],
            },
        }
    ]


def primary_metrics_not_run(reason: str) -> list[dict[str, Any]]:
    return [
        contract.metric_not_run("g_journeys_passed_pct",
                                "Runnable journeys passing with no crash", reason),
    ]


def static_metrics(repo_root: Path) -> list[dict[str, Any]]:
    result = entry_points.run_static_entry_audit(repo_root)
    if not result.get("present"):
        reason = result.get("reason", "journey definitions missing")
        return [
            contract.metric_not_run("g_static_entry_points_discoverable",
                                    "STATIC (supporting evidence): journeys with a discoverable entry affordance",
                                    reason),
        ]
    interval = result["interval"]
    missing = result["missing_ids"]
    found, total = result["found"], result["total"]
    return [
        {
            "id": "g_static_entry_points_discoverable",
            "metric": "STATIC (supporting evidence): journeys with a discoverable entry affordance",
            "value": found,
            "bar": contract.eq(total),
            "detail": (
                f"{found}/{total} journeys have at least one discoverable UI "
                f"affordance in apps/ios (button labels, navigation titles, "
                f"ShareLink, accessibility labels). Missing: "
                f"{', '.join(missing) if missing else 'none'}. The value asserts the "
                f"conservative lower bound of the interval "
                f"[{interval[0]}, {interval[1]}]; presence of an "
                "entry point says nothing about completing the journey — the 100% bar "
                "is judged by the macOS arm."
            ),
            "evidence": {
                "path": "apps/ios",
                "note": json.dumps(
                    [j for j in result["journeys"] if not j["entry_found"]]
                )[:1200],
            },
        }
    ]


# --------------------------------------------------------------------------
# macOS arm driver (runs only on macOS with the toolchain present)
# --------------------------------------------------------------------------


class MacArmError(RuntimeError):
    pass


def _run(cmd: list[str], cwd: Path, what: str) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True,
                              timeout=2400)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise MacArmError(f"{what}: {exc}") from exc
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-800:]
        raise MacArmError(f"{what} failed (exit {proc.returncode}): {tail}")
    return proc


def run_macos_arm(out_dir: Path, repo_root: Path) -> list[dict[str, Any]]:
    project = repo_root / "FridgeLuckEvalJourneys.xcodeproj"
    spec = SUITE_DIR / "xcode" / "project.yml"
    work = Path("/tmp") / f"fl-journeys-{datetime.now().strftime('%H%M%S')}"
    work.mkdir(parents=True, exist_ok=True)
    try:
        _run(["xcodegen", "generate", "--spec", str(spec), "--project", str(project)],
             cwd=repo_root, what="xcodegen generate")
        dest = _run(
            [str(repo_root / "scripts" / "resolve_ios_sim_destination.sh")],
            cwd=repo_root, what="resolve simulator destination",
        ).stdout.strip()
        derived_data = work / "dd"
        _run(["xcodebuild", "build-for-testing",
              "-project", str(project), "-scheme", "FLJourneys",
              "-destination", dest, "-derivedDataPath", str(derived_data)],
             cwd=repo_root, what="xcodebuild build-for-testing")
        xctestruns = list(derived_data.glob("Build/Products/*.xctestrun"))
        if not xctestruns:
            raise MacArmError(f"no .xctestrun produced under {derived_data}")
        result_bundle = work / "journeys.xcresult"
        _run(["xcodebuild", "test-without-building",
              "-xctestrun", str(xctestruns[0]), "-destination", dest,
              "-resultBundlePath", str(result_bundle)],
             cwd=repo_root, what="xcodebuild test-without-building")
        summary_raw = json.loads(_run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary",
             "--path", str(result_bundle)],
            cwd=repo_root, what="xcresulttool summary").stdout)
        observed = journeys_parse.normalize_xcresulttool_summary(summary_raw)
        attachments = work / "attachments"
        _run(["xcrun", "xcresulttool", "export", "attachments",
              "--path", str(result_bundle), "--output-path", str(attachments)],
             cwd=repo_root, what="xcresulttool export attachments")
        payload = _load_payload_attachment(attachments, out_dir)
        derived = journeys_parse.build_journeys_metrics(payload, observed)
        return primary_metrics_from_run(derived, out_dir / "artifacts")
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(project, ignore_errors=True)


def _load_payload_attachment(attachments_dir: Path, out_dir: Path) -> dict[str, Any]:
    manifest_path = attachments_dir / "manifest.json"
    if not manifest_path.is_file():
        raise MacArmError(
            f"xcresulttool exported no manifest.json under {attachments_dir}"
        )
    manifest = json.loads(manifest_path.read_text())
    payloads_dir = out_dir / "artifacts"
    payloads_dir.mkdir(parents=True, exist_ok=True)
    best: tuple[int, dict[str, Any]] | None = None  # (journey_count, payload)
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or attachment.get("exportedFileName") or ""
            if not name.startswith("fl-journeys-"):
                continue
            raw_path = attachments_dir / attachment["exportedFileName"]
            payload = json.loads(raw_path.read_text())
            if not isinstance(payload, dict) or payload.get("emitter") != journeys_parse.TEST_CLASS:
                continue
            count = len(payload.get("journeys") or [])
            if best is None or count > best[0]:
                best = (count, payload)
    if best is None or best[0] < len(journeys_parse.KNOWN_JOURNEYS):
        raise MacArmError(
            "no fl-journeys-* payload attachment with the full journey list "
            "was exported from the xcresult bundle"
        )
    (payloads_dir / "journey-payload.json").write_text(
        json.dumps(best[1], indent=2, sort_keys=True))
    return best[1]


# --------------------------------------------------------------------------
# results assembly
# --------------------------------------------------------------------------


def macos_not_run_reason() -> str:
    if sys.platform.startswith("darwin"):
        missing = [t for t in MACOS_ARM_TOOLS if not shutil.which(t)]
        if missing:
            return (
                f"macOS toolchain incomplete: missing {', '.join(missing)}. "
                "Install Xcode 26.6 and xcodegen (brew install xcodegen)."
            )
        return ""
    return (
        "this host is linux and has no Xcode or iOS simulator; the XCUITest "
        "journeys require macOS. They run only in approved native CI — the "
        "existing iOS CI targets, or a workflow Sam approves from the staged "
        "proposal ci/pending-workflows/eval-macos.yml; no committed native "
        "results were imported either."
    )


def build_results(out_dir: Path, repo_root: Path) -> dict[str, Any]:
    metrics: list[dict[str, Any]] = []
    reason = macos_not_run_reason()
    if reason:
        metrics.extend(primary_metrics_not_run(reason))
    else:
        try:
            metrics.extend(run_macos_arm(out_dir, repo_root))
        except (MacArmError, journeys_parse.JourneysPayloadError) as exc:
            metrics.extend(primary_metrics_not_run(
                f"macOS arm failed and was fail-closed: {exc}"))

    metrics.extend(static_metrics(repo_root))

    return {
        "suite": SUITE_ID,
        "letter": LETTER,
        "title": TITLE,
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": {
            "python": sys.version.split()[0],
            "platform": sys.platform,
        },
        "metrics": metrics,
    }


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------


def _load_samples() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = json.loads((SAMPLE_DIR / "journey-results.json").read_text())
    summary_raw = json.loads((SAMPLE_DIR / "xcresult-summary.json").read_text())
    observed = journeys_parse.normalize_xcresulttool_summary(summary_raw)
    return payload, observed


def self_test() -> int:
    caught = 0
    failures: list[str] = []
    total = 6

    def expect(name: str, condition: bool, detail: str) -> None:
        nonlocal caught
        if condition:
            caught += 1
            print(f"  caught  planted {name}: {detail}")
        else:
            failures.append(f"planted {name}: {detail}")

    def set_outcome(observed: list[dict[str, Any]], name: str, outcome: str) -> list[dict[str, Any]]:
        adjusted = copy.deepcopy(observed)
        for case in adjusted:
            if case["name"] == name:
                case["outcome"] = outcome
        return adjusted

    clean_payload, clean_observed = _load_samples()

    # 1. corrupted fixture: a journey genuinely failing (app crash) with the
    #    main test case honestly failed -> pass_pct < 100 -> metric fail.
    corrupted = copy.deepcopy(clean_payload)
    for j in corrupted["journeys"]:
        if j["id"] == "cook":
            j["status"] = "crashed"
            j["reason"] = "app terminated during cook session (planted)"
    derived = journeys_parse.build_journeys_metrics(
        corrupted, set_outcome(clean_observed, journeys_parse.TEST_MAIN, "failed"))
    metric = primary_metrics_from_run(derived, Path("/tmp"))[0]
    status = contract.derive_status(metric)
    expect("corrupted fixture", status == "fail" and derived["pass_pct"] < 100,
           f"1 of 9 crashed -> pass_pct {derived['pass_pct']} -> {status}")

    # 2. lying emitter: payload claims every journey passed while the
    #    xcresult channel says the main test failed -> contradiction.
    liar = copy.deepcopy(clean_payload)
    for j in liar["journeys"]:
        j["status"] = "passed"
        j.pop("blocked_by", None)
        j.pop("reason", None)
    try:
        journeys_parse.build_journeys_metrics(
            liar, set_outcome(clean_observed, journeys_parse.TEST_MAIN, "failed"))
        expect("lying emitter", False, "contradictory channels were accepted")
    except journeys_parse.JourneysPayloadError:
        expect("lying emitter", True, "all-passed payload / failed main -> rejected")

    # 3. flipped labels: the main test PASSED but the payload marks a journey
    #    failed (a failure smuggled in under a passing run, or the inverse —
    #    a failed run reported clean). Either direction is a contradiction.
    flipped = copy.deepcopy(clean_payload)
    for j in flipped["journeys"]:
        j["status"] = "passed"
        j.pop("blocked_by", None)
        j.pop("reason", None)
    for j in flipped["journeys"]:
        if j["id"] == "tonight":
            j["status"] = "failed"
            j["reason"] = "flipped label: failure attributed to the wrong journey"
    try:
        journeys_parse.build_journeys_metrics(
            flipped, set_outcome(clean_observed, journeys_parse.TEST_MAIN, "passed"))
        expect("flipped labels", False, "passed main with non-passed journey accepted")
    except journeys_parse.JourneysPayloadError:
        expect("flipped labels", True, "passed main / payload failure -> rejected")

    # 4. unknown or missing journey id: the payload must report exactly the
    #    nine committed journeys.
    tampered = copy.deepcopy(clean_payload)
    tampered["journeys"] = [j for j in tampered["journeys"] if j["id"] != "share"]
    try:
        journeys_parse.build_journeys_metrics(tampered, clean_observed)
        expect("missing journey id", False, "a missing journey went unnoticed")
    except journeys_parse.JourneysPayloadError:
        expect("missing journey id", True, "missing journey -> rejected")

    # 5. blocked journey without a blocked_by reason: the reason trail is
    #    mandatory so a block can never be an unexplained skip.
    unexplained = copy.deepcopy(clean_payload)
    for j in unexplained["journeys"]:
        if j["id"] == "share":
            j.pop("blocked_by", None)
    try:
        journeys_parse.build_journeys_metrics(unexplained, clean_observed)
        expect("blocked without reason", False, "unexplained block was accepted")
    except journeys_parse.JourneysPayloadError:
        expect("blocked without reason", True, "blocked requires blocked_by -> rejected")

    # 6. missing xcresult channel: outcomes lacking the main or harness case
    #    must fail-closed, never skip the cross-check.
    try:
        reduced = [t for t in clean_observed if t["name"] != journeys_parse.TEST_MAIN]
        journeys_parse.build_journeys_metrics(copy.deepcopy(clean_payload), reduced)
        expect("missing xcresult channel", False, "missing main case went unnoticed")
    except journeys_parse.JourneysPayloadError:
        expect("missing xcresult channel", True, "missing main case -> fail-closed")

    print("")
    if failures:
        print(f"SELF-TEST FAILED: {caught}/{total} planted failures were caught")
        for f in failures:
            print(f"  UNCAUGHT: {f}")
        return 2
    print(f"caught {caught}/{total} planted failures")
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Suite G (journeys)")
    ap.add_argument("--out", required=False, help="abs output dir")
    ap.add_argument("--repo-root", required=False, help="abs repo root")
    ap.add_argument("--self-test", action="store_true",
                    help="plant corrupted fixtures / a lying emitter / flipped "
                         "labels and assert the derived status flips")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not args.out or not args.repo_root:
        ap.error("--out and --repo-root are required unless --self-test is given")
    out_dir = Path(args.out).resolve()
    repo_root = Path(args.repo_root).resolve()
    results = build_results(out_dir, repo_root)
    path = contract.write_results(out_dir, results)
    for m in results["metrics"]:
        line = f"{m['id']}: {m['status']}"
        if m["status"] == "not-run":
            line += f" — {m['reason']}"
        else:
            line += f" (value {m.get('value')})"
        print(line)
    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
