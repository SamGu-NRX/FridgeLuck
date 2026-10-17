"""Adapter for suite F: macOS XCUITest emissions -> results.json metrics.

The macOS arm produces two inputs:

1. `audit-results.json` — attached by the FLUiPolishAuditUITests run and
   exported from the .xcresult bundle. It carries RAW issue lists per screen
   and per Dynamic Type pass. It deliberately carries no count fields: counts
   are derived here from the raw lists, so an emitter cannot claim a clean
   zero it did not observe.
2. `observed-tests.json` — a normalized test-outcome list the driver derives
   from `xcrun xcresulttool get test-results summary` (see
   normalize_xcresulttool_summary below). It is the independent channel the
   payload is cross-checked against.

Consistency rules (any violation -> AuditPayloadError -> not-run, never pass):

- payload structure, screens and audit types must be from the known sets;
- exactly one "standard" and one "XXL" pass must be present;
- a test that PASSED in xcresult must derive zero violations in its channel;
- a test that FAILED in xcresult must derive at least one violation.

Because both channels would have to be forged in agreement to hide a real
violation, a lying emitter cannot produce a pass here; the best it can do is
turn the suite honestly not-run.

This module is pure Python with no macOS dependency: the self-test runs it
against committed sample outputs under evaluation/suites/ui-polish/fixtures/.
"""

from __future__ import annotations

import json
from typing import Any

# Screens the audit visits. The XCUITest driver navigates by these names; the
# payload must reference exactly these (unknown names -> invalid payload).
KNOWN_SCREENS = (
    "home", "kitchen", "progress", "settings", "recipe-detail", "cook-mode",
)

# Audit types requested by the XCUITest driver, and which pass uses them.
KNOWN_AUDIT_TYPES = ("contrast", "hitRegion", "dynamicType", "textClipped")
STANDARD_PASS_AUDIT_TYPES = ("contrast", "hitRegion")
XXL_PASS_AUDIT_TYPES = ("dynamicType", "textClipped")

# Observed test outcomes -> which payload channel they cross-check.
TEST_STANDARD = "test_audit_screens_standard_type"
TEST_XXL = "test_audit_screens_xxl_type"
TEST_COOK_64 = "test_cook_mode_targets_64pt"


class AuditPayloadError(ValueError):
    """Raised when a macOS emission violates the adapter's contract."""


def normalize_xcresulttool_summary(raw: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten `xcrun xcresulttool get test-results summary` JSON to test cases.

    The tool returns a tree of testNodes (suites containing cases). Returns
    [{"name": <test method>, "outcome": "passed"|"failed"|"skipped"}].
    Unknown shapes raise AuditPayloadError so the driver fail-closes instead
    of guessing.
    """
    if not isinstance(raw, dict) or not isinstance(raw.get("testNodes"), list):
        raise AuditPayloadError(
            "xcresult summary JSON has no testNodes list; cannot derive outcomes"
        )
    cases: list[dict[str, Any]] = []

    def walk(node: dict[str, Any]) -> None:
        node_type = node.get("nodeType", "")
        children = node.get("childNodes") or []
        if node_type == "Test Case" or (not children and node.get("result")):
            result = str(node.get("result", "")).lower()
            if result not in ("passed", "failed", "skipped"):
                raise AuditPayloadError(
                    f"test case {node.get('name', '?')!r}: unknown result {result!r}"
                )
            # xcresulttool names async test methods with a trailing "()"
            # (e.g. "test_audit_screens_standard_type()"); strip it so the
            # cross-check can look the case up by its Swift method name.
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
        raise AuditPayloadError(f"{what} must be a list")
    return value


def _validate_issue(issue: Any, pass_config: str) -> dict[str, Any]:
    if not isinstance(issue, dict):
        raise AuditPayloadError("each issue must be an object")
    audit_type = issue.get("audit_type")
    if audit_type not in KNOWN_AUDIT_TYPES:
        raise AuditPayloadError(f"issue with unknown audit_type {audit_type!r}")
    allowed = (
        STANDARD_PASS_AUDIT_TYPES if pass_config == "standard" else XXL_PASS_AUDIT_TYPES
    )
    if audit_type not in allowed:
        raise AuditPayloadError(
            f"audit_type {audit_type!r} is not part of the {pass_config} pass"
        )
    for field in ("element", "description"):
        if not isinstance(issue.get(field), str):
            raise AuditPayloadError(f"issue field {field!r} must be a string")
    return issue


def _validate_screen(screen: Any, pass_config: str) -> dict[str, Any]:
    if not isinstance(screen, dict):
        raise AuditPayloadError("each screen entry must be an object")
    name = screen.get("screen")
    if name not in KNOWN_SCREENS:
        raise AuditPayloadError(f"screen {name!r} is not in the audited set {KNOWN_SCREENS}")
    if not isinstance(screen.get("reachable"), bool):
        raise AuditPayloadError(f"screen {name!r}: reachable must be a boolean")
    if not screen["reachable"]:
        reason = screen.get("unreachable_reason")
        if not (isinstance(reason, str) and reason.strip()):
            raise AuditPayloadError(
                f"screen {name!r}: unreachable requires unreachable_reason"
            )
        if screen.get("issues"):
            raise AuditPayloadError(
                f"screen {name!r}: unreachable screens cannot report issues"
            )
    for issue in _require_list(screen.get("issues", []), f"screen {name!r} issues"):
        _validate_issue(issue, pass_config)
    return screen


def _validate_cook_block(block: Any) -> dict[str, Any]:
    if not isinstance(block, dict):
        raise AuditPayloadError("cook_mode must be an object")
    if not isinstance(block.get("reachable"), bool):
        raise AuditPayloadError("cook_mode.reachable must be a boolean")
    if not block["reachable"]:
        reason = block.get("unreachable_reason")
        if not (isinstance(reason, str) and reason.strip()):
            raise AuditPayloadError("cook_mode: unreachable requires unreachable_reason")
        if block.get("undersized_64"):
            raise AuditPayloadError("cook_mode: unreachable cannot report undersized targets")
    measured = block.get("interactive_elements_measured")
    if not isinstance(measured, int) or isinstance(measured, bool) or measured < 0:
        raise AuditPayloadError("cook_mode.interactive_elements_measured must be a non-negative int")
    for entry in _require_list(block.get("undersized_64", []), "cook_mode.undersized_64"):
        if not isinstance(entry, dict):
            raise AuditPayloadError("undersized_64 entries must be objects")
        for field in ("element", "width_pt", "height_pt"):
            if field not in entry:
                raise AuditPayloadError(f"undersized_64 entry missing {field!r}")
    return block


def parse_audit_payload(payload: Any) -> list[dict[str, Any]]:
    """Validate ONE emitter payload and return its validated pass blocks.

    A run attaches one payload per test (standard, XXL, cook); the driver
    passes all of them and merge_passes unions them before counting. A payload
    may carry an empty pass list (e.g. the cook-unreachable note attachment).
    """
    if not isinstance(payload, dict):
        raise AuditPayloadError("audit payload must be a JSON object")
    emitter = payload.get("emitter")
    if not (isinstance(emitter, str) and emitter.startswith("FLUiPolishAuditUITests")):
        raise AuditPayloadError(f"unexpected emitter {emitter!r}")
    passes_raw = _require_list(payload.get("passes", []), "passes")
    validated = []
    for pass_block in passes_raw:
        if not isinstance(pass_block, dict):
            raise AuditPayloadError("each pass must be an object")
        config = pass_block.get("dynamic_type_config")
        if config not in ("standard", "XXL"):
            raise AuditPayloadError(
                f"pass config must be 'standard' or 'XXL', got {config!r}"
            )
        screens = [
            _validate_screen(s, config)
            for s in _require_list(pass_block.get("screens", []), f"{config} pass screens")
        ]
        screen_names = [s["screen"] for s in screens]
        if len(set(screen_names)) != len(screen_names):
            raise AuditPayloadError(f"{config} pass lists a screen twice")
        block: dict[str, Any] = {"dynamic_type_config": config, "screens": screens}
        if config == "standard" and "cook_mode" in pass_block:
            block["cook_mode"] = _validate_cook_block(pass_block["cook_mode"])
        validated.append(block)
    return validated


def merge_passes(payloads: list[Any]) -> dict[str, Any]:
    """Union pass blocks across payloads: each screen once, one cook block."""
    screens_by_config: dict[str, list[dict[str, Any]]] = {"standard": [], "XXL": []}
    cook_block: dict[str, Any] | None = None
    for payload in payloads:
        for pass_block in parse_audit_payload(payload):
            config = pass_block["dynamic_type_config"]
            names = {s["screen"] for s in screens_by_config[config]}
            for screen in pass_block["screens"]:
                if screen["screen"] in names:
                    raise AuditPayloadError(
                        f"screen {screen['screen']!r} reported twice across payloads"
                    )
                screens_by_config[config].append(screen)
            if "cook_mode" in pass_block:
                if cook_block is not None:
                    raise AuditPayloadError("cook_mode reported twice across payloads")
                cook_block = pass_block["cook_mode"]
    if len(screens_by_config["standard"]) == 0 or len(screens_by_config["XXL"]) == 0:
        raise AuditPayloadError(
            "payload set must cover every screen in both the standard and XXL passes"
        )
    if cook_block is None:
        raise AuditPayloadError("no cook_mode block found in any payload attachment")
    return {
        "standard": {"screens": screens_by_config["standard"], "cook_mode": cook_block},
        "XXL": {"screens": screens_by_config["XXL"]},
    }

def derive_counts(passes: dict[str, Any]) -> dict[str, Any]:
    """Derive violation counts from validated pass blocks (the only counts)."""
    counts = {"contrast": 0, "hitRegion": 0, "dynamicType": 0, "textClipped": 0}
    per_screen: dict[str, dict[str, int]] = {
        s: {"contrast": 0, "hitRegion": 0, "dynamicType": 0, "textClipped": 0}
        for s in KNOWN_SCREENS
    }
    for config in ("standard", "XXL"):
        for screen in passes[config]["screens"]:
            for issue in screen.get("issues", []):
                counts[issue["audit_type"]] += 1
                per_screen[screen["screen"]][issue["audit_type"]] += 1

    cook = passes["standard"]["cook_mode"]
    undersized_64 = cook.get("undersized_64", []) if cook.get("reachable") else []
    coverage = sum(1 for s in passes["standard"]["screens"] if s["reachable"])
    return {
        "counts": counts,
        "per_screen": per_screen,
        "undersized_64": undersized_64,
        "cook_measured": cook.get("interactive_elements_measured", 0),
        "cook_reachable": bool(cook.get("reachable")),
        "screens_reachable": coverage,
        "screens_total": len(KNOWN_SCREENS),
        "unreachable": [
            s["screen"] for s in passes["standard"]["screens"] if not s["reachable"]
        ],
        "derived_violations_standard": (
            counts["contrast"] + counts["hitRegion"] + len(undersized_64)
        ),
        "derived_violations_xxl": counts["dynamicType"] + counts["textClipped"],
    }


def check_consistency(derived: dict[str, Any], observed: list[dict[str, Any]]) -> None:
    """Cross-check payload-derived violations against xcresult test outcomes."""
    by_name = {t.get("name"): t.get("outcome") for t in observed}
    for test_name, expected_zero in (
        (TEST_STANDARD, derived["derived_violations_standard"]),
        (TEST_XXL, derived["derived_violations_xxl"]),
    ):
        outcome = by_name.get(test_name)
        if outcome is None:
            raise AuditPayloadError(
                f"xcresult outcomes do not contain {test_name!r}; cannot cross-check"
            )
        if outcome == "passed" and expected_zero > 0:
            raise AuditPayloadError(
                f"{test_name} passed in xcresult but the payload derives "
                f"{expected_zero} violation(s); emitter and runner disagree"
            )
        if outcome == "failed" and expected_zero == 0:
            raise AuditPayloadError(
                f"{test_name} failed in xcresult but the payload derives zero "
                "violations; emitter and runner disagree"
            )
    cook_outcome = by_name.get(TEST_COOK_64)
    if cook_outcome is None:
        raise AuditPayloadError(
            f"xcresult outcomes do not contain {TEST_COOK_64!r}; cannot cross-check"
        )
    if derived["cook_reachable"]:
        if cook_outcome == "passed" and derived["undersized_64"]:
            raise AuditPayloadError(
                f"{TEST_COOK_64} passed but the payload lists undersized cook targets"
            )
        if cook_outcome == "failed" and not derived["undersized_64"]:
            raise AuditPayloadError(
                f"{TEST_COOK_64} failed but the payload lists no undersized cook targets"
            )


def build_audit_metrics(payloads: list[Any], observed: list[dict[str, Any]]) -> dict[str, Any]:
    """Validate all payload attachments + the xcresult channel; derive counts.

    `payloads` is the list of exported emitter attachments (standard, XXL and
    optionally cook). Raises AuditPayloadError on any validation or
    consistency failure; the suite turns that into not-run metrics with the
    precise reason (never pass).
    """
    passes = merge_passes(payloads)
    derived = derive_counts(passes)
    check_consistency(derived, observed)
    return derived
