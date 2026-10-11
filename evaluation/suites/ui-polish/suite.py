#!/usr/bin/env python3
"""Suite F (ui-polish) — UI polish audit.

Bars (PLAN.md, "The scorecard (evals first)"):
  - body-text contrast violations == 0        (>= 4.5:1, SPEC 5)
  - touch-target violations == 0              (44 pt; 64 pt in cook mode)
  - clipped primary labels at XXL Dynamic Type == 0

Arms:
  - macOS arm (XCUITest): accessibility audits (.contrast/.hitRegion in a
    standard pass; .dynamicType/.textClipped at XXL) plus a 64 pt cook-mode
    frame walk. Needs Xcode + the iOS simulator; runs only inside
    .github/workflows/eval-macos.yml (macos-26, Xcode 26.6).
  - static arm (any host, SUPPORTING EVIDENCE ONLY): WCAG math over the
    committed design tokens, declared-minimum inventory, XXL clipping-risk
    scan. Distinct metric ids with conservative intervals. It does not
    replace the macOS arm and must not be used to move the bar.

On this Linux host the macOS-arm metrics report not-run with the precise
reason; the runner additionally imports committed CI results from
evaluation/out/ui-polish/results.json when present (SCORECARD.md).

Interface: python3 suite.py --out <abs out dir> --repo-root <abs repo root>
(cwd is the suite directory). --self-test plants corrupted fixtures, a lying
emitter and flipped labels, and asserts the derived statuses flip — exit 0
only when every plant is caught.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUITE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SUITE_DIR))
sys.path.insert(0, str(SUITE_DIR.parent.parent))  # evaluation/

import suite_contract as contract  # noqa: E402
from adapters import audit_parse  # noqa: E402
from static import audit as static_audit  # noqa: E402

SUITE_ID = "ui-polish"
LETTER = "F"
TITLE = "UI polish"
OWNER = "fl-eval-harness-f1 (suite F/G sub-thread)"

MACOS_ARM_TOOLS = ("xcodebuild", "xcrun", "xcodegen")
SAMPLE_DIR = SUITE_DIR / "fixtures" / "sample-audit"


# --------------------------------------------------------------------------
# metric builders
# --------------------------------------------------------------------------


def macos_not_run_reason() -> str:
    if sys.platform.startswith("darwin"):
        missing = [t for t in MACOS_ARM_TOOLS if not shutil.which(t)]
        if missing:
            return (
                f"macOS toolchain incomplete: missing {', '.join(missing)}. "
                "Install Xcode 26.6 and xcodegen (brew install xcodegen)."
            )
        return ""  # reachable on macOS with the toolchain present
    return (
        "this host is linux and has no Xcode or iOS simulator; the XCUITest "
        "arm requires macOS. It runs via .github/workflows/eval-macos.yml "
        "(macos-26, Xcode 26.6); no committed macOS CI results were imported "
        "either."
    )


def primary_metrics_from_audit(derived: dict[str, Any], evidence_dir: Path) -> list[dict[str, Any]]:
    """Build the three bared F metrics + the coverage metric from derived counts."""
    counts = derived["counts"]
    touch = counts["hitRegion"] + len(derived["undersized_64"])
    clipped = counts["dynamicType"] + counts["textClipped"]
    unreachable = derived["unreachable"]
    detail_parts = [
        f"contrast issues: {counts['contrast']}",
        f"hitRegion (<44pt): {counts['hitRegion']}",
        f"cook-mode targets <64pt: {len(derived['undersized_64'])} of "
        f"{derived['cook_measured']} measured",
        f"XXL dynamicType/textClipped: {clipped}",
    ]
    if unreachable:
        detail_parts.append(f"unreachable screens: {', '.join(unreachable)}")
    evidence = {"path": str(evidence_dir), "note": "exported XCUITest attachments"}
    return [
        {
            "id": "f_body_text_contrast_violations",
            "metric": "Body-text contrast violations (< 4.5:1)",
            "value": counts["contrast"],
            "bar": contract.eq(0),
            "detail": detail_parts[0],
            "evidence": evidence,
        },
        {
            "id": "f_touch_target_violations",
            "metric": "Touch-target violations (44 pt; 64 pt cook)",
            "value": touch,
            "bar": contract.eq(0),
            "detail": "; ".join(detail_parts[1:3]),
            "evidence": evidence,
        },
        {
            "id": "f_clipped_primary_labels_xxl",
            "metric": "Clipped primary labels at XXL Dynamic Type",
            "value": clipped,
            "bar": contract.eq(0),
            "detail": detail_parts[3],
            "evidence": evidence,
        },
        {
            "id": "f_audit_screen_coverage",
            "metric": "Audited screens reachable",
            "value": derived["screens_reachable"],
            "bar": contract.eq(derived["screens_total"]),
            "detail": (
                f"{derived['screens_reachable']}/{derived['screens_total']} screens "
                "audited; unreachable screens are listed in the touch/contrast details"
            ),
            "evidence": evidence,
        },
    ]


def primary_metrics_not_run(reason: str) -> list[dict[str, Any]]:
    return [
        contract.metric_not_run("f_body_text_contrast_violations",
                                "Body-text contrast violations (< 4.5:1)", reason),
        contract.metric_not_run("f_touch_target_violations",
                                "Touch-target violations (44 pt; 64 pt cook)", reason),
        contract.metric_not_run("f_clipped_primary_labels_xxl",
                                "Clipped primary labels at XXL Dynamic Type", reason),
        contract.metric_not_run("f_audit_screen_coverage",
                                "Audited screens reachable", reason),
    ]


def static_metrics(repo_root: Path) -> list[dict[str, Any]]:
    """The static supporting-evidence arm (its own ids, conservative intervals)."""
    result = static_audit.run_static_audit(repo_root)
    if not result.get("present"):
        reason = result.get("reason", "static inputs missing")
        return [
            contract.metric_not_run("f_static_body_text_contrast_violations",
                                    "STATIC (supporting evidence): declared-token contrast violations", reason),
            contract.metric_not_run("f_static_declared_minimums_below_44pt",
                                    "STATIC (supporting evidence): declared frame minimums below 44 pt", reason),
            contract.metric_not_run("f_static_xxl_clipping_risks",
                                    "STATIC (supporting evidence): XXL clipping-risk markers", reason),
        ]
    contrast = result["contrast"]
    minimums = result["touch_minimums"]
    xxl = result["xxl_risks"]
    return [
        {
            "id": "f_static_body_text_contrast_violations",
            "metric": "STATIC (supporting evidence): declared-token contrast violations",
            "value": len(contrast["violations"]),
            "bar": contract.le(0),
            "interval": contrast["interval"],
            "detail": (
                f"{contrast['pairs_audited']} declared token pairs audited in light "
                f"and dark (WCAG 2.x math over AppTheme.swift); "
                f"{len(contrast['unresolved'])} unresolvable color entries widen the "
                f"interval high bound. Context not counted in the value: "
                f"{len(contrast['dark_panel_pairs'])} dark-panel pairings (deepOlive "
                f"takes light text tokens by design) and "
                f"{len(contrast['accent_below_3'])} accent-text pairs below the 3:1 "
                "large-text rule — both listed in evidence. Static evidence only — "
                "the bar is judged by the macOS XCUITest arm."
            ),
            "evidence": {"path": "apps/ios/DesignSystem/AppTheme.swift",
                         "note": "violations: " + json.dumps(contrast["violations"][:12])},
        },
        {
            "id": "f_static_declared_minimums_below_44pt",
            "metric": "STATIC (supporting evidence): declared frame minimums below 44 pt",
            "value": len(minimums["below_44"]),
            "bar": contract.le(0),
            "interval": minimums["interval"],
            "detail": (
                "literal frame(minWidth:)/frame(minHeight:) declarations below "
                "44 pt in apps/ios. An inventory of declared minimums, not "
                "rendered targets; runtime measurement belongs to the macOS arm."
            ),
            "evidence": {"path": "apps/ios",
                         "note": json.dumps(minimums["below_44"][:12])},
        },
        {
            "id": "f_static_xxl_clipping_risks",
            "metric": "STATIC (supporting evidence): XXL clipping-risk markers",
            "value": len(xxl["risks"]),
            "bar": contract.le(0),
            "interval": xxl["interval"],
            "detail": (
                "fixed-height frames and lineLimit(1) near Text declarations — "
                "the patterns that clip at XXL Dynamic Type. Heuristic risk "
                "markers to review, not proven violations; the bar is judged by "
                "the macOS XXL pass."
            ),
            "evidence": {"path": "apps/ios",
                         "note": json.dumps(xxl["risks"][:12])},
        },
    ]


# --------------------------------------------------------------------------
# macOS arm driver (runs only on macOS with the toolchain present)
# --------------------------------------------------------------------------


def run_macos_arm(out_dir: Path, repo_root: Path) -> tuple[list[dict[str, Any]], dict[str, str]]:
    """Generate, build, run the XCUITest audit; returns (metrics, toolchain).

    Fail-closed: every failure path raises MacArmError with the exact command
    output tail so results.json can carry the precise not-run reason.
    """
    project = repo_root / "FridgeLuckEvalUiPolish.xcodeproj"
    spec = SUITE_DIR / "xcode" / "project.yml"
    work = Path(tempfile.mkdtemp(prefix="fl-ui-polish-"))
    try:
        _run(["xcodegen", "generate", "--spec", str(spec), "--project", str(project)],
             cwd=repo_root, what="xcodegen generate")
        dest = _run(
            [str(repo_root / "scripts" / "resolve_ios_sim_destination.sh")],
            cwd=repo_root, what="resolve simulator destination",
            env={**os.environ, "PROJECT_PATH": str(project), "SCHEME_NAME": "FLUiPolishAudit"},
        ).stdout.strip()
        derived_data = work / "dd"
        _run(["xcodebuild", "build-for-testing",
              "-project", str(project), "-scheme", "FLUiPolishAudit",
              "-destination", dest, "-derivedDataPath", str(derived_data)],
             cwd=repo_root, what="xcodebuild build-for-testing")
        xctestruns = list(derived_data.glob("Build/Products/*.xctestrun"))
        if not xctestruns:
            raise MacArmError(f"no .xctestrun produced under {derived_data}")
        result_bundle = work / "audit.xcresult"
        _run(["xcodebuild", "test-without-building",
              "-xctestrun", str(xctestruns[0]), "-destination", dest,
              "-resultBundlePath", str(result_bundle)],
             cwd=repo_root, what="xcodebuild test-without-building")
        summary_raw = json.loads(_run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary",
             "--path", str(result_bundle)],
            cwd=repo_root, what="xcresulttool summary").stdout)
        observed = audit_parse.normalize_xcresulttool_summary(summary_raw)
        attachments = work / "attachments"
        _run(["xcrun", "xcresulttool", "export", "attachments",
              "--path", str(result_bundle), "--output-path", str(attachments)],
             cwd=repo_root, what="xcresulttool export attachments")
        payloads = _load_payload_attachments(attachments, out_dir)
        derived = audit_parse.build_audit_metrics(payloads, observed)
        return primary_metrics_from_audit(derived, out_dir / "artifacts"), toolchain_info()
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(project, ignore_errors=True)


class MacArmError(RuntimeError):
    pass


def _run(cmd: list[str], cwd: Path, what: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True,
                              timeout=1800, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise MacArmError(f"{what}: {exc}") from exc
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-800:]
        raise MacArmError(f"{what} failed (exit {proc.returncode}): {tail}")
    return proc


def _load_payload_attachments(attachments_dir: Path, out_dir: Path) -> list[dict[str, Any]]:
    """Exported attachments -> parsed emitter payloads; copies them to out_dir."""
    manifest_path = attachments_dir / "manifest.json"
    if not manifest_path.is_file():
        raise MacArmError(
            f"xcresulttool exported no manifest.json under {attachments_dir}; "
            "cannot locate the audit payload attachments"
        )
    manifest = json.loads(manifest_path.read_text())
    payloads: list[dict[str, Any]] = []
    payloads_dir = out_dir / "artifacts"
    payloads_dir.mkdir(parents=True, exist_ok=True)
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or attachment.get("exportedFileName") or ""
            if not name.startswith("fl-audit-"):
                continue
            raw_path = attachments_dir / attachment["exportedFileName"]
            if not raw_path.is_file():
                raise MacArmError(f"attachment {name} listed in manifest but missing on disk")
            payload = json.loads(raw_path.read_text())
            (payloads_dir / raw_path.name).write_bytes(raw_path.read_bytes())
            payloads.append(payload)
    if not payloads:
        raise MacArmError(
            "no fl-audit-* payload attachments exported from the xcresult bundle"
        )
    return payloads


def toolchain_info() -> dict[str, str]:
    info = {"python": sys.version.split()[0], "platform": sys.platform}
    for tool, args in (("xcodebuild", ["xcodebuild", "-version"]),
                       ("xcodegen", ["xcodegen", "version"])):
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=30)
            first = (out.stdout or out.stderr).strip().splitlines()
            info[tool] = first[0][:120] if first else "unavailable"
        except (subprocess.SubprocessError, OSError):
            info[tool] = "unavailable"
    return info


# --------------------------------------------------------------------------
# results assembly
# --------------------------------------------------------------------------


def build_results(out_dir: Path, repo_root: Path) -> dict[str, Any]:
    metrics: list[dict[str, Any]] = []
    reason = macos_not_run_reason()
    toolchain = toolchain_info()
    if reason:
        metrics.extend(primary_metrics_not_run(reason))
    else:
        try:
            metrics.extend(run_macos_arm(out_dir, repo_root))
        except (MacArmError, audit_parse.AuditPayloadError) as exc:
            fail_reason = f"macOS arm failed and was fail-closed: {exc}"
            metrics.extend(primary_metrics_not_run(fail_reason))

    metrics.extend(static_metrics(repo_root))

    return {
        "suite": SUITE_ID,
        "letter": LETTER,
        "title": TITLE,
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": toolchain,
        "metrics": metrics,
    }


# --------------------------------------------------------------------------
# self-test: planted failures must flip the derived statuses
# --------------------------------------------------------------------------


def _load_samples() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = json.loads((SAMPLE_DIR / "audit-results.json").read_text())
    summary_raw = json.loads((SAMPLE_DIR / "xcresult-summary.json").read_text())
    observed = audit_parse.normalize_xcresulttool_summary(summary_raw)
    return payload, observed


def _outcome_map(observed: list[dict[str, Any]]) -> dict[str, str]:
    return {t["name"]: t["outcome"] for t in observed}


def _set_outcomes(observed: list[dict[str, Any]], outcomes: dict[str, str]) -> list[dict[str, Any]]:
    adjusted = copy.deepcopy(observed)
    for case in adjusted:
        if case["name"] in outcomes:
            case["outcome"] = outcomes[case["name"]]
    return adjusted


def self_test() -> int:
    """Plant k=5 corrupted scenarios; the suite must catch every one."""
    caught = 0
    failures: list[str] = []
    total = 5

    def expect(name: str, condition: bool, detail: str) -> None:
        nonlocal caught
        if condition:
            caught += 1
            print(f"  caught  planted {name}: {detail}")
        else:
            failures.append(f"planted {name}: {detail}")

    clean_payload, clean_observed = _load_samples()

    # 1. corrupted fixture: real violations in the payload, outcomes honestly
    #    failed -> every touched metric must derive fail, none may pass.
    corrupted = copy.deepcopy(clean_payload)
    corrupted["passes"][0]["screens"][0]["issues"] = [
        {"audit_type": "contrast", "element": "Text: Tonight's pick",
         "description": "contrast 3.1:1"},
        {"audit_type": "contrast", "element": "Text: subtitle",
         "description": "contrast 3.4:1"},
    ]
    corrupted["passes"][0]["screens"][1]["issues"] = [
        {"audit_type": "hitRegion", "element": "Button: +1", "description": "36x36"},
    ]
    corrupted["passes"][0]["cook_mode"]["undersized_64"] = [
        {"element": "Button: Stir", "width_pt": 51.0, "height_pt": 44.0},
    ]
    corrupted["passes"][1]["screens"][0]["issues"] = [
        {"audit_type": "textClipped", "element": "Text: title", "description": "clipped at XXL"},
    ]
    derived = audit_parse.build_audit_metrics(
        [corrupted], _set_outcomes(clean_observed, {
            audit_parse.TEST_STANDARD: "failed",
            audit_parse.TEST_XXL: "failed",
            audit_parse.TEST_COOK_64: "failed",
        }))
    statuses = {m["id"]: contract.derive_status(m) for m in primary_metrics_from_audit(
        derived, Path("/tmp"))}
    expect(
        "corrupted fixture",
        statuses["f_body_text_contrast_violations"] == "fail"
        and statuses["f_touch_target_violations"] == "fail"
        and statuses["f_clipped_primary_labels_xxl"] == "fail"
        and statuses["f_audit_screen_coverage"] == "pass",
        f"2 contrast + 1 hitRegion + 1 undersized + 1 clip -> {statuses}",
    )

    # 2. lying emitter: claims a clean zero-violation payload while the
    #    xcresult channel says the audit tests FAILED. The disagreement must
    #    be caught (not-run with reason), never a pass.
    liar_payload = copy.deepcopy(clean_payload)  # zero issues anywhere
    try:
        audit_parse.build_audit_metrics(
            [liar_payload], _set_outcomes(clean_observed, {
                audit_parse.TEST_STANDARD: "failed",
            }))
        expect("lying emitter", False, "mismatched channels were accepted")
    except audit_parse.AuditPayloadError:
        expect("lying emitter", True,
               "payload clean / xcresult failed -> rejected, never pass")

    # 3. flipped labels: the emitter swaps metric values (contrast reported
    #    as touch targets and vice versa). The suite rebuilds values from the
    #    raw issue lists, so a claimed swap must be detected as a mismatch
    #    with the observed outcomes channel.
    flipped = copy.deepcopy(corrupted)
    flipped["passes"][0]["screens"][0]["issues"] = [
        {"audit_type": "hitRegion", "element": "Text: Tonight's pick",
         "description": "contrast 3.1:1 relabeled as hitRegion"},
        {"audit_type": "hitRegion", "element": "Text: subtitle",
         "description": "contrast 3.4:1 relabeled as hitRegion"},
    ]
    flipped["passes"][0]["screens"][1]["issues"] = [
        {"audit_type": "contrast", "element": "Button: +1", "description": "36x36 relabeled"},
    ]
    try:
        flipped_derived = audit_parse.build_audit_metrics(
            [flipped], _set_outcomes(clean_observed, {
                audit_parse.TEST_STANDARD: "failed",
                audit_parse.TEST_XXL: "failed",
                audit_parse.TEST_COOK_64: "failed",
            }))
        # The relabel moves the Button's undersize report out of hitRegion and
        # the cook walk keeps its undersized entry; the touch metric must NOT
        # come out clean while the cook test failed.
        touch_value = (flipped_derived["counts"]["hitRegion"]
                       + len(flipped_derived["undersized_64"]))
        expect("flipped labels", touch_value > 0,
               f"relabeled issues still count somewhere real (touch bucket "
               f"value {touch_value} from the cook walk)")
    except audit_parse.AuditPayloadError:
        expect("flipped labels", True, "inconsistent relabel rejected outright")

    # 4. unreachable screen with issues: a screen marked unreachable must
    #    never carry issues (that would fake coverage of a screen nobody saw).
    haunted = copy.deepcopy(clean_payload)
    haunted["passes"][0]["screens"][2]["reachable"] = False
    haunted["passes"][0]["screens"][2]["unreachable_reason"] = "nav missing"
    haunted["passes"][0]["screens"][2]["issues"] = [
        {"audit_type": "contrast", "element": "ghost", "description": "issue on an unreachable screen"},
    ]
    try:
        audit_parse.build_audit_metrics([haunted], clean_observed)
        expect("unreachable-with-issues", False,
               "issues on an unreachable screen were accepted")
    except audit_parse.AuditPayloadError:
        expect("unreachable-with-issues", True, "rejected: unreachable screens cannot report issues")

    # 5. missing xcresult channel: outcomes that lack one of the tests must
    #    fail-closed, not silently skip the cross-check.
    try:
        reduced = [t for t in clean_observed if t["name"] != audit_parse.TEST_COOK_64]
        audit_parse.build_audit_metrics([copy.deepcopy(clean_payload)], reduced)
        expect("missing xcresult channel", False,
               "a missing test outcome went unnoticed")
    except audit_parse.AuditPayloadError:
        expect("missing xcresult channel", True, "missing outcome -> fail-closed")

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
    ap = argparse.ArgumentParser(description="Suite F (ui-polish)")
    ap.add_argument("--out", required=False,
                    help="abs output dir (results.json goes here)")
    ap.add_argument("--repo-root", required=False, help="abs repo root")
    ap.add_argument("--self-test", action="store_true",
                    help="plant corrupted fixtures / a lying emitter / flipped "
                         "labels and assert the derived statuses flip")
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
