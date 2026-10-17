"""Shared contract for FridgeLuck evaluation suites.

Every suite in `evaluation/suites/<id>/` emits a `results.json` that conforms
to this contract. The runner (`run.py`) re-validates everything a suite emits
and derives pass/fail itself from the **registry bar** + value + interval, so
a broken or lying check cannot report pass.

Design rules (see SCORECARD.md for the full document):

1. A suite whose inputs are missing reports `not-run` with a reason, never pass.
2. `status` is DERIVED by this contract from `value`, the registry bar and
   `interval`. A suite never asserts `pass` or `fail` on a bared metric; it
   only declares `not-run` (with a reason) for metrics it could not measure.
3. The registry (`evaluation/registry.json`) owns the bars. When the runner
   passes a suite's registry metrics, the metric set, labels and bars are
   judged against it: a missing metric, an extra metric, a different label
   or a different bar is a mismatch that FAILS with a reason naming the
   exact difference. Emitter-supplied bars are never trusted — derivation
   always uses the registry bar.
4. Every admitted result is bound to its run: the runner stamps `run`
   (run_id, git_sha, started_at) and re-validates it; imported results must
   first prove CI provenance and a matching head. Anything lacking or
   contradicting the binding fails closed to `not-run`.
5. The runner fail-closes: a crashed, timed-out or malformed suite run is
   `not-run` with the reason, never pass.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VALID_STATUS = ("pass", "fail", "not-run")
VALID_OPS = ("<=", ">=", "==")

RUN_BINDING_FIELDS = ("run_id", "git_sha", "started_at")

# The repository whose CI runs can produce imported results.
GITHUB_REPO = "SamGu-NRX/FridgeLuck"


class ContractError(ValueError):
    """Raised when a results payload violates the suite contract."""


class RegistryMismatch(ContractError):
    """A payload whose metric set, labels or bars differ from the registry.

    Carries the fully-built metric rows (valid metrics derived from registry
    bars, every mismatch forced to `fail` with its reason) so the runner can
    show the mismatch instead of hiding it.
    """

    def __init__(self, metrics: list[dict[str, Any]], reasons: list[str]):
        self.metrics = metrics
        self.reasons = reasons
        super().__init__("; ".join(reasons))


def check_bar(value: float, bar: dict[str, Any], interval: list[float] | None) -> bool:
    """Return True when `value` (conservatively interval-adjusted) satisfies `bar`."""
    op = bar["op"]
    target = bar["value"]
    if op == "==":
        # Equality bars ignore any recorded interval: the bar applies to the
        # measured value exactly.
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


def _bars_differ(a: dict[str, Any], b: dict[str, Any]) -> bool:
    """Compare two bars by op and value (a bar's free-text label is not identity)."""
    return a.get("op") != b.get("op") or a.get("value") != b.get("value")


def _has_interval(m: dict[str, Any]) -> bool:
    """True when the metric carries a well-formed [low, high] interval."""
    interval = m.get("interval")
    return (
        isinstance(interval, list)
        and len(interval) == 2
        and all(isinstance(b, (int, float)) and not isinstance(b, bool) for b in interval)
    )


def _enforce_registry(
    metrics: list[dict[str, Any]], suite_id: str, registry_metrics: dict[str, dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str]]:
    """Judge emitted metrics against the runner-owned registry metrics.

    Returns (rows, reasons). Every mismatch — a metric the registry requires
    but the suite dropped, an extra metric, a different label, a different
    bar — becomes a `fail` row whose reason names the exact difference.
    Derivation always uses the registry bar; a suite-set bar that differs is
    recorded as the mismatch it is, never trusted.
    """
    rows: list[dict[str, Any]] = []
    reasons: list[str] = []
    emitted: set[str] = set()
    for m in metrics:
        mid = m["id"]
        emitted.add(mid)
        spec = registry_metrics.get(mid)
        row = dict(m)
        mismatches: list[str] = []
        reg_bar: dict[str, Any] | None = None
        if spec is None:
            mismatches.append(
                f"metric {mid!r} is not in the registry for suite {suite_id!r} "
                "(extra metric) — suites cannot add, drop or re-bar metrics; "
                "register it with a recorded reason first"
            )
        else:
            reg_label = spec.get("label")
            reg_bar = spec.get("bar")
            if reg_label is not None and m.get("metric") != reg_label:
                mismatches.append(
                    f"metric {mid!r}: label {m.get('metric')!r} differs from the "
                    f"registry label {reg_label!r}"
                )
            emitted_bar = m.get("bar")
            if reg_bar is None:
                if emitted_bar is not None or (
                    "value" in m and m.get("value") is not None
                ):
                    mismatches.append(
                        f"metric {mid!r}: the registry records no bar for it — a "
                        "suite-set bar or bare value cannot be judged; declare it "
                        "not-run (with a reason) or set the bar in the registry "
                        "with a recorded reason"
                    )
            else:
                # The registry bar is the only trusted bar; inject it for
                # derivation and rendering.
                row["bar"] = dict(reg_bar)
                if emitted_bar is not None and _bars_differ(emitted_bar, reg_bar):
                    mismatches.append(
                        f"metric {mid!r}: suite bar {{op {emitted_bar.get('op')!r}, "
                        f"value {emitted_bar.get('value')!r}}} differs from the "
                        f"registry bar {{op {reg_bar['op']!r}, value "
                        f"{reg_bar['value']!r}}} — emitter bars are never trusted"
                    )
                if (
                    spec.get("interval_required")
                    and m.get("status") != "not-run"
                    and not _has_interval(m)
                ):
                    mismatches.append(
                        f"metric {mid!r}: the registry requires this bar on the "
                        "95% interval's low end — a point estimate without an "
                        "interval cannot pass; emit the measured interval"
                    )

        if m.get("status") == "not-run":
            if not m.get("reason") or not str(m["reason"]).strip():
                mismatches.append(f"metric {mid!r}: not-run requires a reason")
            else:
                row["status"] = "not-run"
        elif reg_bar is not None:
            row["status"] = derive_status({**row, "bar": dict(reg_bar)})
        elif spec is not None:
            # No registry bar and the metric claims to be measurable: it can
            # never pass (covered by the no-bar mismatch above); force fail.
            row["status"] = "fail"
        else:
            # Extra metric: unjudgable by definition.
            row["status"] = "fail"
        if mismatches:
            row["status"] = "fail"
            row["reason"] = "; ".join(mismatches)
            reasons.extend(mismatches)
        elif row.get("status") != "not-run":
            row.pop("reason", None)
        rows.append(row)
    for mid, spec in registry_metrics.items():
        if mid in emitted:
            continue
        reason = (
            f"metric {mid!r} ({spec.get('label', mid)}) is missing from the suite "
            "results — the registry requires it; dropping a metric cannot hide "
            "a failing bar"
        )
        row: dict[str, Any] = {"id": mid, "metric": spec.get("label", mid),
                               "status": "fail", "reason": reason}
        if spec.get("bar") is not None:
            row["bar"] = dict(spec["bar"])
        rows.append(row)
        reasons.append(reason)
    return rows, reasons


def validate_results(
    payload: Any,
    expected_suite_id: str | None = None,
    registry_metrics: dict[str, dict[str, Any]] | None = None,
    expected_identity: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Validate a suite `results.json` payload in place; returns it.

    Raises ContractError with a precise message on any violation. Validated
    metrics get their derived `status` written back. When `registry_metrics`
    is given (the runner always gives it), any deviation from the registry —
    missing or extra metric, different label, different bar — raises
    RegistryMismatch carrying the fail-marked rows and exact reasons.

    `expected_identity` (the runner supplies it with `registry_metrics`)
    carries the suite's registered `letter` and `title`. The results.json
    schema requires both on every emission, and they must match the
    registered identity — a payload without them is how a scorecard renders
    "?. suite" (defect seen on suite A before its fix): missing or differing
    identity is a RegistryMismatch, never silently re-labelled. Identity is
    judged only when the registry is in play; bare checks stay structural.
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
    # Suite identity (results.json schema): letter + title are required on
    # every emission and must match the registered suite identity. Without
    # this check a suite omitting them renders as "?. suite". Enforced when
    # the registry is in play (runner-side judging); a bare contract check
    # (suite-internal self-tests) stays structural, so the identity rule has
    # exactly one owner: the runner, against the registry.
    identity_reasons: list[str] = []
    if registry_metrics is not None:
        for key in ("letter", "title"):
            value = payload.get(key)
            if not value or not isinstance(value, str) or not value.strip():
                identity_reasons.append(
                    f"results are missing {key!r} — required by the results.json "
                    "schema (the suite's identity from its suite.json/registry entry)"
                )
            elif (
                expected_identity
                and isinstance(expected_identity.get(key), str)
                and expected_identity[key]
                and value != expected_identity[key]
            ):
                identity_reasons.append(
                    f"results declare {key} {value!r} but the suite is registered "
                    f"as {expected_identity[key]!r}"
                )
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
        if registry_metrics is None:
            derived = derive_status(m)
            m["status"] = derived
        bar = m.get("bar")
        if bar is not None:
            if not isinstance(bar, dict) or bar.get("op") not in VALID_OPS:
                raise ContractError(f"metric {mid!r}: bar.op must be one of {VALID_OPS}")
            if not isinstance(bar.get("value"), (int, float)) or isinstance(bar["value"], bool):
                raise ContractError(f"metric {mid!r}: bar.value must be numeric")
    if registry_metrics is not None:
        rows, reasons = _enforce_registry(metrics, suite_id, registry_metrics)
        if identity_reasons:
            # suite-level failure: surface it as its own fail-marked row so
            # the summary counts it even when every metric row looks fine
            rows.append({
                "id": f"{suite_id}_contract",
                "metric": "suite identity (letter/title per registry)",
                "status": "fail",
                "reason": "; ".join(identity_reasons),
            })
        reasons = identity_reasons + reasons
        if reasons:
            raise RegistryMismatch(rows, reasons)
        payload["metrics"] = rows
    return payload


def validate_run_binding(result: dict[str, Any], expected_run: dict[str, str]) -> None:
    """Fail closed unless the result is bound to this run by its producer.

    Every result the runner admits carries `run` = {run_id, git_sha,
    started_at}. For suite runs the SUITE stamps it — the runner passes this
    run's identity to the suite (`FL_RUN_BINDING`) and verifies the emitted
    producer binding instead of overwriting it — so a result whose binding
    names another run (a stale copy from an old out/ directory) or that was
    written without a binding is not evidence of this run. Imported results
    keep their producing identity and are verified separately (see
    validate_import_provenance).
    """
    run = result.get("run")
    if not isinstance(run, dict):
        raise ContractError(
            "result carries no run binding — the runner passed this run's "
            "identity to the suite (FL_RUN_BINDING: run_id, git_sha, "
            "started_at) and the suite must stamp it as its producer binding; "
            "an output written without one is not evidence of this run"
        )
    for field in RUN_BINDING_FIELDS:
        value = run.get(field)
        if not value or not isinstance(value, str):
            raise ContractError(f"run binding is missing {field!r}")
        if value != expected_run.get(field):
            raise ContractError(
                f"run binding {field} is {value!r}, contradicting this run's "
                f"{expected_run.get(field)!r}"
            )


def _http_get_default(url: str, token: str | None) -> tuple[int, str]:
    """The production transport: one authenticated GET to the GitHub REST API."""
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "fridgeluck-scorecard-runner",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return int(resp.status), resp.read().decode("utf-8")


# Transport seam at the network boundary: production uses the real GET; the
# runner's self-tests install a deterministic fixture transport here.
HTTP_GET = _http_get_default


def _github_token() -> str | None:
    return (
        os.environ.get("GITHUB_TOKEN")
        or os.environ.get("SECRET_GITHUB_TOKEN")
        or os.environ.get("GH_TOKEN")
    )


def verify_github_ci_run(
    run_id: str,
    expected_sha: str,
    run_url: str,
    *,
    repo: str = GITHUB_REPO,
    http_get=None,
) -> dict[str, str]:
    """Re-verify a producing CI run against GitHub's REST API.

    The run must exist in this repository and its recorded head_sha must be
    the current head. Returns evidence the runner keeps on the admitted
    import. Raises ContractError — the caller fails closed to not-run — when
    the id is not a GitHub Actions run id, the URL is not this repository's
    Actions URL, the run does not exist, another head produced it, or the
    network blocks verification (labeled UNVERIFIED-NATIVE).
    """
    if not run_id.isdigit():
        raise ContractError(
            f"run_id {run_id!r} is not the numeric id of a GitHub Actions run — "
            "synthetic run identities are not provenance"
        )
    expected_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    if run_url != expected_url:
        raise ContractError(
            f"run_url {run_url!r} is not this repository's CI run URL "
            f"({expected_url}) — synthetic or foreign URLs are not provenance"
        )
    get = http_get or HTTP_GET
    api = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}"
    try:
        status, body = get(api, _github_token())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ContractError(
                f"GitHub has no Actions run {run_id} — the claimed producing "
                "run does not exist; live-reachability check: run id "
                "unverifiable"
            ) from exc
        raise ContractError(
            f"GitHub refused verification of run {run_id} (HTTP {exc.code}) — "
            "import fails closed; live-reachability check UNVERIFIED-NATIVE"
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ContractError(
            f"GitHub API unreachable while verifying run {run_id} ({exc}) — "
            "import fails closed; live-reachability check UNVERIFIED-NATIVE"
        ) from exc
    if status != 200:
        raise ContractError(
            f"GitHub returned HTTP {status} for run {run_id} — import fails "
            "closed; live-reachability check UNVERIFIED-NATIVE"
        )
    try:
        head = json.loads(body).get("head_sha")
    except json.JSONDecodeError as exc:
        raise ContractError(
            f"GitHub's response for run {run_id} is not JSON — import fails "
            "closed; live-reachability check UNVERIFIED-NATIVE"
        ) from exc
    if not head or not isinstance(head, str):
        raise ContractError(
            f"GitHub's response for run {run_id} carries no head_sha — import "
            "fails closed; live-reachability check UNVERIFIED-NATIVE"
        )
    if head != expected_sha:
        raise ContractError(
            f"GitHub run {run_id} was produced at {head[:12]}, not the current "
            f"head {expected_sha[:12]} — the payload's git.sha is a forgery; "
            "refusing"
        )
    return {
        "verified_via": "github-rest",
        "run_id": run_id,
        "head_sha": head,
        "run_url": expected_url,
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def validate_import_provenance(
    payload: dict[str, Any],
    expected_sha: str | None,
    *,
    repo: str = GITHUB_REPO,
    http_get=None,
) -> dict[str, str]:
    """The macos-import rule: committed native results must prove themselves.

    An import is only evidence when it was produced by a CI run at the
    current head that GitHub's REST API confirms. The payload must carry:
      - `git.sha`: the full SHA of the producing run, equal to the runner's head;
      - `run_url`: this repository's GitHub Actions URL for that run;
      - `run.run_id` (numeric) and `run.started_at`: the producing run's identity.
    The runner then re-verifies run id + head SHA against the GitHub REST API
    (token from GITHUB_TOKEN / SECRET_GITHUB_TOKEN). A synthetic URL
    (ci.example.test and friends), a fabricated run id, a foreign head, or a
    network that blocks verification each fail closed — not-run, never pass.
    Returns the verification evidence recorded on the admitted import.
    """
    git = payload.get("git")
    sha = git.get("sha") if isinstance(git, dict) else None
    if not sha or not isinstance(sha, str) or not sha.strip():
        raise ContractError(
            "imported results carry no git.sha — the macos-import rule "
            "(SCORECARD.md) requires the producing run's full SHA"
        )
    if expected_sha and sha != expected_sha:
        raise ContractError(
            f"imported results were produced at git {sha[:12]}, not the current "
            f"head {expected_sha[:12]} — refusing (matching head required)"
        )
    run_url = payload.get("run_url")
    if not run_url or not isinstance(run_url, str) or not run_url.startswith("https://"):
        raise ContractError(
            "imported results carry no run_url — the macos-import rule "
            "(SCORECARD.md) requires the URL of the CI run that produced them"
        )
    run = payload.get("run")
    if not isinstance(run, dict):
        raise ContractError(
            "imported results carry no run binding — expected run.run_id and "
            "run.started_at of the producing run"
        )
    run_id = run.get("run_id")
    started_at = run.get("started_at")
    if not run_id or not isinstance(run_id, str):
        raise ContractError("imported results' run binding is missing 'run_id'")
    if not started_at or not isinstance(started_at, str):
        raise ContractError("imported results' run binding is missing 'started_at'")
    return verify_github_ci_run(
        run_id, expected_sha or sha, run_url, repo=repo, http_get=http_get
    )


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
