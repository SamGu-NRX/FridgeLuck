"""Shared contract for FridgeLuck evaluation suites.

Every suite in `evaluation/suites/<id>/` emits a `results.json` that conforms
to this contract. The runner (`run.py`) re-validates everything a suite emits
and derives pass/fail itself from value + bar + interval, so a broken or lying
check cannot report pass.

Design rules (see SCORECARD.md for the full document):

1. A suite whose inputs are missing reports `not-run` with a reason, never pass.
2. `status` is DERIVED by this contract from `value`, `bar` and `interval`.
   A suite never asserts `pass` or `fail` on a bared numeric metric; it only
   declares `not-run` (with a reason) for metrics it could not measure.
3. When an `interval` is present, the bar is applied to the conservative
   bound (`>=` bars use the interval low, `<=` bars the high). Equality bars
   do not accept intervals.
4. The runner fail-closes: a crashed, timed-out or malformed suite run is
   `not-run` with the reason, never pass.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

VALID_STATUS = ("pass", "fail", "not-run")
VALID_OPS = ("<=", ">=", "==")


class ContractError(ValueError):
    """Raised when a results payload violates the suite contract."""


def check_bar(value: float, bar: dict[str, Any], interval: list[float] | None) -> bool:
    """Return True when `value` (conservatively interval-adjusted) satisfies `bar`."""
    op = bar["op"]
    target = bar["value"]
    if op == "==":
        # Equality bars do not accept intervals (validated elsewhere).
        return value == target
    if op == ">=":
        # Conservative: the interval's low end must clear the bar.
        low = interval[0] if interval else value
        return low >= target
    if op == "<=":
        high = interval[1] if interval else value
        return high <= target
    raise ContractError(f"unknown bar op {op!r}")


def derive_status(metric: dict[str, Any]) -> str:
    """Derive the status of one metric from its value/bar/interval.

    `not-run` is the only status a suite may declare. Everything else is
    computed here so a broken scorer cannot report pass.
    """
    status = metric.get("status", "pass")
    if status == "not-run":
        reason = metric.get("reason")
        if not reason or not str(reason).strip():
            raise ContractError(
                f"metric {metric.get('id', '?')!r}: not-run requires a reason"
            )
        return "not-run"
    bar = metric.get("bar")
    value = metric.get("value")
    if bar is None:
        raise ContractError(
            f"metric {metric.get('id', '?')!r}: a measurable metric requires a bar"
        )
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ContractError(
            f"metric {metric.get('id', '?')!r}: bared metric value must be numeric, "
            f"got {value!r}"
        )
    interval = metric.get("interval")
    if interval is not None:
        if bar.get("op") == "==":
            raise ContractError(
                f"metric {metric.get('id', '?')!r}: equality bars do not accept intervals"
            )
        if (
            not isinstance(interval, list)
            or len(interval) != 2
            or not all(isinstance(b, (int, float)) and not isinstance(b, bool) for b in interval)
            or interval[0] > interval[1]
        ):
            raise ContractError(
                f"metric {metric.get('id', '?')!r}: interval must be [low, high] with low <= high"
            )
    return "pass" if check_bar(value, bar, interval) else "fail"


def validate_results(payload: Any, expected_suite_id: str | None = None) -> dict[str, Any]:
    """Validate a suite `results.json` payload in place; returns it.

    Raises ContractError with a precise message on any violation. Validated
    metrics get their derived `status` written back.
    """
    if not isinstance(payload, dict):
        raise ContractError("results must be a JSON object")
    suite_id = payload.get("suite")
    if not suite_id or not isinstance(suite_id, str):
        raise ContractError("results.suite (string) is required")
    if expected_suite_id and suite_id != expected_suite_id:
        raise ContractError(
            f"results.suite is {suite_id!r} but this is the {expected_suite_id!r} slot"
        )
    metrics = payload.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        raise ContractError("results.metrics must be a non-empty list")
    seen: set[str] = set()
    for m in metrics:
        if not isinstance(m, dict):
            raise ContractError("each metric must be an object")
        mid = m.get("id")
        if not mid or not isinstance(mid, str):
            raise ContractError("each metric needs a string id")
        if mid in seen:
            raise ContractError(f"duplicate metric id {mid!r}")
        seen.add(mid)
        if not m.get("metric") or not isinstance(m["metric"], str):
            raise ContractError(f"metric {mid!r}: 'metric' (human label) is required")
        derived = derive_status(m)
        m["status"] = derived
        bar = m.get("bar")
        if bar is not None:
            if not isinstance(bar, dict) or bar.get("op") not in VALID_OPS:
                raise ContractError(f"metric {mid!r}: bar.op must be one of {VALID_OPS}")
            if not isinstance(bar.get("value"), (int, float)) or isinstance(bar["value"], bool):
                raise ContractError(f"metric {mid!r}: bar.value must be numeric")
    return payload


def write_results(out_dir: Path, payload: dict[str, Any]) -> Path:
    """Write a validated results payload to <out_dir>/results.json."""
    validate_results(payload)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "results.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")
    return path


def metric(
    id: str,
    metric_label: str,
    value: Any,
    bar: dict[str, Any] | None,
    *,
    interval: list[float] | None = None,
    reason: str | None = None,
    detail: str | None = None,
    evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build one metric entry. Suites declare not-run via metric_not_run()."""
    m: dict[str, Any] = {"id": id, "metric": metric_label}
    if value is not None:
        m["value"] = value
    if bar is not None:
        m["bar"] = bar
    if interval is not None:
        m["interval"] = interval
    if detail is not None:
        m["detail"] = detail
    if evidence is not None:
        m["evidence"] = evidence
    m["status"] = "not-run" if reason is not None else "pass"
    if reason is not None:
        m["reason"] = reason
    return m


def metric_not_run(id: str, metric_label: str, reason: str) -> dict[str, Any]:
    """Declare a metric that could not be measured, with the reason. Never pass."""
    return {
        "id": id,
        "metric": metric_label,
        "status": "not-run",
        "reason": reason,
    }


def ge(value: float) -> dict[str, Any]:
    return {"op": ">=", "value": value}


def le(value: float) -> dict[str, Any]:
    return {"op": "<=", "value": value}


def eq(value: float) -> dict[str, Any]:
    return {"op": "==", "value": value}
