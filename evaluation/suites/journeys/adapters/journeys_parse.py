"""Adapter for suite G (journeys): XCUITest output -> results.json metrics.

The Swift runner attaches one payload per run (FLJourneysUITests) listing the
nine PLAN journeys with RAW per-step results and a status per journey:
  passed | failed | crashed | blocked
Counts are derived on the host from the raw journey list (never accepted from
the emitter) and cross-checked against the xcresult test-case outcomes, so a
lying payload cannot report a clean run:

  - every journey test case must be present in the xcresult summary;
  - payload 'passed' for a journey whose test case outcome is failed/crashed
    is a contradiction -> AuditPayloadError -> not-run (never pass);
  - a journey test case that failed means at least one journey in it failed
    -> any payload claiming all-passed with a failed case is rejected.

KNOWN_JOURNEYS mirrors journeys.json (the committed definition). Payloads
carrying unknown journey ids are rejected; missing ids are rejected.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

KNOWN_JOURNEYS = (
    "first-run", "scan-and-review", "tonight", "recipe", "cook",
    "complete", "share", "challenge", "taste-profile-edit",
)
VALID_STATUSES = ("passed", "failed", "crashed", "blocked")
TEST_CLASS = "FLJourneysUITests"
TEST_MAIN = "test_journeys_run"
TEST_HARNESS = "test_journey_runner_harness"


class JourneysPayloadError(ValueError):
    """Payload/xcresult inconsistency; the suite fail-closes on this."""


def load_journey_definitions(repo_root: Path) -> list[dict[str, Any]]:
    path = Path(__file__).resolve().parent.parent / "journeys.json"
    data = json.loads(path.read_text())
    journeys = data["journeys"]
    ids = [j["id"] for j in journeys]
    if sorted(ids) != sorted(KNOWN_JOURNEYS):
        raise JourneysPayloadError(
            f"journeys.json ids {ids!r} do not match KNOWN_JOURNEYS"
        )
    return journeys


def normalize_xcresulttool_summary(raw: Any) -> list[dict[str, Any]]:
    """Flatten `xcrun xcresulttool get test-results summary` JSON to cases."""
    if not isinstance(raw, dict) or not isinstance(raw.get("testNodes"), list):
        raise JourneysPayloadError(
            "xcresult summary JSON has no testNodes list; cannot derive outcomes"
        )
    cases: list[dict[str, Any]] = []

    def walk(node: dict[str, Any]) -> None:
        node_type = node.get("nodeType", "")
        children = node.get("childNodes") or []
        if node_type == "Test Case" or (not children and node.get("result")):
            result = str(node.get("result", "")).lower()
            if result not in ("passed", "failed", "skipped"):
                raise JourneysPayloadError(
                    f"test case {node.get('name', '?')!r}: unknown result {result!r}"
                )
            name = str(node.get("name", "")).removesuffix("()")
            cases.append({"name": name, "outcome": result})
            return
        for child in children:
            if isinstance(child, dict):
                walk(child)

    for node in raw["testNodes"]:
        if isinstance(node, dict):
            walk(node)
    return cases


def _require_list(value: Any, what: str) -> list[Any]:
    if not isinstance(value, list):
        raise JourneysPayloadError(f"payload {what} must be a list")
    return value


def _validate_journey(entry: Any) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise JourneysPayloadError("each journey entry must be an object")
    jid = entry.get("id")
    if jid not in KNOWN_JOURNEYS:
        raise JourneysPayloadError(f"unknown journey id {jid!r}")
    status = entry.get("status")
    if status not in VALID_STATUSES:
        raise JourneysPayloadError(f"journey {jid!r}: invalid status {status!r}")
    steps = _require_list(entry.get("steps", []), f"journey {jid!r} steps")
    for step in steps:
        if not isinstance(step, dict) or not step.get("step"):
            raise JourneysPayloadError(
                f"journey {jid!r}: each step needs a 'step' name"
            )
    if status != "passed" and not entry.get("reason"):
        raise JourneysPayloadError(
            f"journey {jid!r}: non-passed status requires a 'reason'"
        )
    if status == "blocked" and not entry.get("blocked_by"):
        raise JourneysPayloadError(
            f"journey {jid!r}: blocked requires 'blocked_by'"
        )
    return {
        "id": jid,
        "status": status,
        "reason": entry.get("reason", ""),
        "blocked_by": entry.get("blocked_by", ""),
        "steps": steps,
    }


def derive_journey_metrics(payload: Any, observed: list[dict[str, Any]]) -> dict[str, Any]:
    """Validate payload + xcresult channel; derive the metric inputs."""
    if not isinstance(payload, dict):
        raise JourneysPayloadError("journey payload must be a JSON object")
    emitter = payload.get("emitter")
    if emitter != TEST_CLASS:
        raise JourneysPayloadError(f"unexpected emitter {emitter!r}")

    journeys_raw = _require_list(payload.get("journeys"), "journeys")
    journeys = [_validate_journey(j) for j in journeys_raw]
    ids = [j["id"] for j in journeys]
    if sorted(ids) != sorted(KNOWN_JOURNEYS):
        raise JourneysPayloadError(
            f"payload must report every journey exactly once; got {ids!r}"
        )

    by_name = {t["name"]: t["outcome"] for t in observed}
    missing = [n for n in (TEST_MAIN, TEST_HARNESS) if n not in by_name]
    if missing:
        raise JourneysPayloadError(
            f"xcresult channel missing test case(s): {missing}; fail-closed"
        )
    if by_name[TEST_HARNESS] == "failed":
        raise JourneysPayloadError(
            "journey runner harness failed; per-journey results untrustworthy"
        )
    if by_name[TEST_MAIN] == "failed":
        non_passed = [j for j in journeys if j["status"] != "passed"]
        if not non_passed:
            raise JourneysPayloadError(
                f"{TEST_MAIN} failed but the payload claims every journey passed"
            )
    elif by_name[TEST_MAIN] == "passed":
        non_passed = [j for j in journeys if j["status"] != "passed"]
        if non_passed:
            raise JourneysPayloadError(
                f"{TEST_MAIN} passed but payload marks {len(non_passed)} "
                f"journey(s) non-passed: {[j['id'] for j in non_passed]}"
            )

    passed = sum(1 for j in journeys if j["status"] == "passed")
    blocked = [j for j in journeys if j["status"] == "blocked"]
    failed = [j for j in journeys if j["status"] in ("failed", "crashed")]
    return {
        "journeys": journeys,
        "passed": passed,
        "total": len(KNOWN_JOURNEYS),
        "blocked_ids": [j["id"] for j in blocked],
        "failed_ids": [j["id"] for j in failed],
        "pass_pct": round(100.0 * passed / len(KNOWN_JOURNEYS), 1),
    }


def build_journeys_metrics(payload: Any, observed: list[dict[str, Any]]) -> dict[str, Any]:
    """Public entry: validate both channels, return derived metric values."""
    return derive_journey_metrics(payload, observed)
