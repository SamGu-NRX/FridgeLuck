"""Structural diagnostics on an open read-only connection. Owned by: DIAGNOSTICS stream.

Contract (do not change signatures; do not edit model.py / codes.py):
- DEFAULT_EXPECTED_TABLES: core structural tables the current app creates
  ("recipes", "cooking_history", "streaks", "grdb_migrations").
- KNOWN_LATEST_MIGRATION: "v15_notification_rules_and_opportunities".
- fingerprint(con) -> CheckResult(CHECK_SCHEMA_FINGERPRINT): sha256 over
  sorted "type\\x1fname\\x1fcoalesce(sql,'')" lines of sqlite_master where name
  does not start with 'sqlite_'. Output ONLY the 16-hex prefix + object count.
  Never put SQL text into detail.
- integrity(con, budget) -> CheckResult(CHECK_INTEGRITY): run PRAGMA
  integrity_check with the connection's progress handler active; detail has
  {"error_count": n} (0 when "ok"). A cancelled/limited run reports status
  "limited" — never "pass".
- foreign_keys(con, budget) -> CheckResult(CHECK_FOREIGN_KEY_CHECK): bounded
  fetch over SELECT * FROM pragma_foreign_key_check (via reader.bounded_fetch);
  detail {"violation_count": n, "truncated": bool}.
- tables_and_migrations(con, budget, expected_tables) -> list[CheckResult]:
  CHECK_TABLE_PRESENCE (table names via bounded fetch of
  SELECT name FROM sqlite_master WHERE type='table'; detail has counts,
  expected_present, expected_missing — table NAMES are structural metadata and
  allowed) and CHECK_MIGRATION_STATE (PRAGMA user_version value; applied
  migration count and latest identifier read from grdb_migrations when that
  table exists — identifiers are fixed code strings, not user data).
- run_diagnostics(con, budget, expected_tables=..., known_latest_migration=...)
  -> DiagnosticsResult: run all checks, map failures/limits to issue codes,
  compute the verdict ladder:
      limited/cancelled anywhere -> cap at READABLE_WITH_ISSUES + limited exit
      integrity fail or fk>0 or missing markers or migration state fail
          -> READABLE_WITH_ISSUES
      markers present + latest migration match -> APP_COMPATIBLE
      app-compatible + integrity ok + fk 0 + nothing limited -> RESTORABLE_CANDIDATE
      otherwise (readable, no compatible claim) -> STRUCTURALLY_READABLE
  Every check must complete or be explicitly marked limited/skipped; a
  cancelled or truncated check is never reported as a pass.

Implementation notes (diagnostics stream):
- Every check turns a budget abort (model.BudgetExceeded, or the sqlite
  "interrupted" OperationalError raised when the progress handler aborts a
  statement) into a STATUS_LIMITED CheckResult; run_diagnostics additionally
  guards each check call and attributes limit issues from reader handle state:
  handle.cancelled -> CHECK_CANCELLED, else handle.deadline_hit ->
  CHECK_DEADLINE_EXCEEDED, else CHECK_LIMITED_ROWS (bounded-fetch truncation
  or a row-capped scan). Issues are aggregated: one entry per code, count
  accumulated. Zero-count conditions emit no issue entry.
- details carry counts, codes and structural table/migration names only —
  never SQL text, never row values, never exception message text.
"""
from __future__ import annotations

import hashlib
import sqlite3

try:  # package context: doctor.diagnostics (tests, SDK consumers)
    from . import codes, model, reader
except ImportError:  # top-level context: script-style CLI run, sys.path=doctor/
    import codes  # type: ignore[no-redef]
    import model  # type: ignore[no-redef]
    import reader  # type: ignore[no-redef]

DEFAULT_EXPECTED_TABLES = ("recipes", "cooking_history", "streaks", "grdb_migrations")
KNOWN_LATEST_MIGRATION = "v15_notification_rules_and_opportunities"
KNOWN_MIGRATION_COUNT = 15

_SEP = "\x1f"

_SCHEMA_FINGERPRINT_SQL = (
    "SELECT type, name, sql FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
)
_TABLES_SQL = "SELECT name FROM sqlite_master WHERE type='table'"
_MIGRATIONS_SQL = "SELECT identifier FROM grdb_migrations"
_LATEST_MIGRATION_SQL = (
    "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
)
_USER_VERSION_SQL = "PRAGMA user_version"
_INTEGRITY_SQL = "PRAGMA integrity_check"
_FOREIGN_KEY_CHECK_SQL = "SELECT * FROM pragma_foreign_key_check"


def _interrupted(exc: Exception) -> bool:
    """True when sqlite aborted the executing statement (progress handler)."""
    return "interrupted" in str(exc).lower()


def _limited_result(code: str) -> "model.CheckResult":
    """A limited check reports nothing it did not verify — empty detail."""
    return model.CheckResult(code, codes.STATUS_LIMITED, {})


def fingerprint(con: sqlite3.Connection) -> "model.CheckResult":
    """Stable schema fingerprint: sha256 over sorted sqlite_master lines."""
    try:
        cur = con.execute(_SCHEMA_FINGERPRINT_SQL)
        lines = [
            f"{obj_type}{_SEP}{name}{_SEP}{sql or ''}"
            for obj_type, name, sql in cur
        ]
    except model.BudgetExceeded:
        return _limited_result(codes.CHECK_SCHEMA_FINGERPRINT)
    except sqlite3.OperationalError as exc:
        if _interrupted(exc):
            return _limited_result(codes.CHECK_SCHEMA_FINGERPRINT)
        return model.CheckResult(
            codes.CHECK_SCHEMA_FINGERPRINT,
            codes.STATUS_FAIL,
            {"schema_objects": 0, "error_class": type(exc).__name__},
        )
    except sqlite3.Error as exc:
        # Malformed/truncated images can raise DatabaseError directly.
        return model.CheckResult(
            codes.CHECK_SCHEMA_FINGERPRINT,
            codes.STATUS_FAIL,
            {"schema_objects": 0, "error_class": type(exc).__name__},
        )
    digest = hashlib.sha256("\n".join(sorted(lines)).encode("utf-8")).hexdigest()
    return model.CheckResult(
        codes.CHECK_SCHEMA_FINGERPRINT,
        codes.STATUS_PASS,
        {"fingerprint": digest[:16], "schema_objects": len(lines)},
    )


def integrity(con: sqlite3.Connection, budget: "model.Budget") -> "model.CheckResult":
    """PRAGMA integrity_check with a row-count cap; counts only, no message text."""
    try:
        cur = con.execute(_INTEGRITY_SQL)
        seen = 0
        errors = 0
        for row in cur:
            seen += 1
            if seen > budget.max_rows:
                return _limited_result(codes.CHECK_INTEGRITY)
            if str(row[0]) != "ok":
                errors += 1
    except model.BudgetExceeded:
        return _limited_result(codes.CHECK_INTEGRITY)
    except sqlite3.OperationalError as exc:
        if _interrupted(exc):
            return _limited_result(codes.CHECK_INTEGRITY)
        return model.CheckResult(
            codes.CHECK_INTEGRITY,
            codes.STATUS_FAIL,
            {"error_count": 0, "error_class": type(exc).__name__},
        )
    except sqlite3.Error as exc:
        return model.CheckResult(
            codes.CHECK_INTEGRITY,
            codes.STATUS_FAIL,
            {"error_count": 0, "error_class": type(exc).__name__},
        )
    if errors:
        return model.CheckResult(
            codes.CHECK_INTEGRITY, codes.STATUS_FAIL, {"error_count": errors}
        )
    return model.CheckResult(
        codes.CHECK_INTEGRITY, codes.STATUS_PASS, {"error_count": 0}
    )


def foreign_keys(con: sqlite3.Connection, budget: "model.Budget") -> "model.CheckResult":
    """Bounded scan of pragma_foreign_key_check; violation counts only."""
    try:
        cur = con.execute(_FOREIGN_KEY_CHECK_SQL)
        rows, truncated = reader.bounded_fetch(cur, budget)
    except model.BudgetExceeded:
        return _limited_result(codes.CHECK_FOREIGN_KEYS)
    except sqlite3.OperationalError as exc:
        if _interrupted(exc):
            return _limited_result(codes.CHECK_FOREIGN_KEYS)
        return model.CheckResult(
            codes.CHECK_FOREIGN_KEYS,
            codes.STATUS_FAIL,
            {
                "violation_count": 0,
                "truncated": False,
                "error_class": type(exc).__name__,
            },
        )
    except sqlite3.Error as exc:
        return model.CheckResult(
            codes.CHECK_FOREIGN_KEYS,
            codes.STATUS_FAIL,
            {
                "violation_count": 0,
                "truncated": False,
                "error_class": type(exc).__name__,
            },
        )
    detail = {"violation_count": len(rows), "truncated": truncated}
    if truncated:
        status = codes.STATUS_LIMITED  # truncated scan is never a pass
    elif rows:
        status = codes.STATUS_FAIL
    else:
        status = codes.STATUS_PASS
    return model.CheckResult(codes.CHECK_FOREIGN_KEYS, status, detail)


def tables_and_migrations(
    con: sqlite3.Connection,
    budget: "model.Budget",
    expected_tables=DEFAULT_EXPECTED_TABLES,
) -> list:
    """Marker-table presence (a) and migration-ledger state (b), in order."""
    expected = frozenset(expected_tables)
    results = []

    observed: set = set()
    rows: list = []
    truncated = False
    aborted = False
    try:
        cur = con.execute(_TABLES_SQL)
        rows, truncated = reader.bounded_fetch(cur, budget)
        observed = {str(row[0]) for row in rows}
    except model.BudgetExceeded:
        aborted = True
    except sqlite3.OperationalError as exc:
        if not _interrupted(exc):
            raise
        aborted = True

    if aborted:
        results.append(
            model.CheckResult(codes.CHECK_TABLE_PRESENCE, codes.STATUS_LIMITED, {})
        )
    else:
        detail = {
            "table_count": len(rows),
            "expected_present": sorted(expected & observed),
            "expected_missing": sorted(expected - observed),
        }
        if truncated:
            status = codes.STATUS_LIMITED  # incomplete enumeration is never a pass
        elif detail["expected_missing"]:
            status = codes.STATUS_FAIL
        else:
            status = codes.STATUS_PASS
        results.append(model.CheckResult(codes.CHECK_TABLE_PRESENCE, status, detail))

    try:
        row = con.execute(_USER_VERSION_SQL).fetchone()
        user_version = row[0] if row is not None else 0
        if "grdb_migrations" not in observed:
            results.append(
                model.CheckResult(
                    codes.CHECK_MIGRATION_STATE,
                    codes.STATUS_FAIL,
                    {"ledger_present": False, "user_version": user_version},
                )
            )
            return results
        cur = con.execute(_MIGRATIONS_SQL)
        applied_rows, applied_truncated = reader.bounded_fetch(cur, budget)
        latest_row = con.execute(_LATEST_MIGRATION_SQL).fetchone()
    except model.BudgetExceeded:
        results.append(
            model.CheckResult(codes.CHECK_MIGRATION_STATE, codes.STATUS_LIMITED, {})
        )
        return results
    except sqlite3.OperationalError as exc:
        if not _interrupted(exc):
            raise
        results.append(
            model.CheckResult(codes.CHECK_MIGRATION_STATE, codes.STATUS_LIMITED, {})
        )
        return results

    latest = latest_row[0] if latest_row is not None else None
    detail = {
        "user_version": user_version,
        "applied_count": len(applied_rows),
        "latest_identifier": latest,
        "ledger_present": True,
    }
    if applied_truncated:
        status = codes.STATUS_LIMITED
    elif latest == KNOWN_LATEST_MIGRATION:
        status = codes.STATUS_PASS
    else:
        status = codes.STATUS_FAIL  # ledger present but lagging the known release
    results.append(model.CheckResult(codes.CHECK_MIGRATION_STATE, status, detail))
    return results


def run_diagnostics(
    con: sqlite3.Connection,
    budget: "model.Budget",
    expected_tables=DEFAULT_EXPECTED_TABLES,
    known_latest_migration=KNOWN_LATEST_MIGRATION,
) -> "model.DiagnosticsResult":
    """Run every bounded check on the open connection and apply the verdict ladder."""
    handle = reader.BudgetHandle(budget)
    con.set_progress_handler(handle.handler, 100)

    checks = [
        model.CheckResult(
            codes.CHECK_HEADER_MAGIC, codes.STATUS_PASS, {"verified_by": "reader"}
        )
    ]
    issues: dict = {}
    state = {"truncated": False}

    def _abort_issue_code() -> str:
        if handle.cancelled:
            return codes.ISSUE_CANCELLED
        if handle.deadline_hit:
            return codes.ISSUE_DEADLINE
        return codes.ISSUE_LIMITED_ROWS

    def _take(result) -> None:
        checks.append(result)
        if result.status == codes.STATUS_LIMITED:
            code = _abort_issue_code()
            issues[code] = issues.get(code, 0) + 1
        if result.detail.get("truncated") is True:
            state["truncated"] = True

    def _guarded(code, fn):
        try:
            return fn()
        except model.BudgetExceeded:
            return model.CheckResult(code, codes.STATUS_LIMITED, {})
        except sqlite3.OperationalError as exc:
            if _interrupted(exc):
                return model.CheckResult(code, codes.STATUS_LIMITED, {})
            return model.CheckResult(
                code, codes.STATUS_FAIL, {"error_class": type(exc).__name__}
            )
        except sqlite3.Error as exc:
            return model.CheckResult(
                code, codes.STATUS_FAIL, {"error_class": type(exc).__name__}
            )

    fingerprint_result = _guarded(
        codes.CHECK_SCHEMA_FINGERPRINT, lambda: fingerprint(con)
    )
    _take(fingerprint_result)

    integrity_result = _guarded(codes.CHECK_INTEGRITY, lambda: integrity(con, budget))
    _take(integrity_result)

    foreign_key_result = _guarded(
        codes.CHECK_FOREIGN_KEYS, lambda: foreign_keys(con, budget)
    )
    _take(foreign_key_result)

    try:
        marker_results = list(tables_and_migrations(con, budget, expected_tables))
    except model.BudgetExceeded:
        marker_results = [
            model.CheckResult(codes.CHECK_TABLE_PRESENCE, codes.STATUS_LIMITED, {}),
            model.CheckResult(codes.CHECK_MIGRATION_STATE, codes.STATUS_LIMITED, {}),
        ]
    except sqlite3.OperationalError as exc:
        if _interrupted(exc):
            marker_results = [
                model.CheckResult(codes.CHECK_TABLE_PRESENCE, codes.STATUS_LIMITED, {}),
                model.CheckResult(codes.CHECK_MIGRATION_STATE, codes.STATUS_LIMITED, {}),
            ]
        else:
            marker_results = [
                model.CheckResult(
                    codes.CHECK_TABLE_PRESENCE,
                    codes.STATUS_FAIL,
                    {"error_class": type(exc).__name__},
                ),
                model.CheckResult(
                    codes.CHECK_MIGRATION_STATE,
                    codes.STATUS_FAIL,
                    {"error_class": type(exc).__name__},
                ),
            ]
    except sqlite3.Error as exc:
        marker_results = [
            model.CheckResult(
                codes.CHECK_TABLE_PRESENCE,
                codes.STATUS_FAIL,
                {"error_class": type(exc).__name__},
            ),
            model.CheckResult(
                codes.CHECK_MIGRATION_STATE,
                codes.STATUS_FAIL,
                {"error_class": type(exc).__name__},
            ),
        ]
    for marker_result in marker_results:
        _take(marker_result)

    presence_result = marker_results[0]
    migration_result = marker_results[1]

    # Issue codes aggregated from check outcomes (zero counts emit no entry).
    error_count = integrity_result.detail.get("error_count") or 0
    if integrity_result.status == codes.STATUS_FAIL and error_count > 0:
        issues[codes.ISSUE_INTEGRITY_ERRORS] = error_count
    violation_count = foreign_key_result.detail.get("violation_count") or 0
    if violation_count > 0:
        issues[codes.ISSUE_FK_VIOLATIONS] = violation_count
    missing = presence_result.detail.get("expected_missing") or []
    if len(missing) > 0:
        issues[codes.ISSUE_EXPECTED_TABLE_MISSING] = len(missing)
    if migration_result.status == codes.STATUS_FAIL:
        if migration_result.detail.get("ledger_present") is False:
            issues[codes.ISSUE_MIGRATION_STATE_UNKNOWN] = 1
        else:
            issues[codes.ISSUE_MIGRATION_LAGGING] = 1

    limits = {
        "cancelled": bool(handle.cancelled),
        "truncated": state["truncated"] or codes.ISSUE_LIMITED_ROWS in issues,
        "deadline_hit": bool(handle.deadline_hit),
        "steps_used": handle.steps_used,
        "steps_max": budget.max_steps,
    }
    any_limited = any(c.status == codes.STATUS_LIMITED for c in checks)

    if (
        limits["cancelled"]
        or limits["truncated"]
        or limits["deadline_hit"]
        or any_limited
    ):
        verdict = codes.VERDICT_READABLE_WITH_ISSUES  # limited runs are never a pass
    elif (
        integrity_result.status == codes.STATUS_FAIL
        or violation_count > 0
        or len(missing) > 0
        or migration_result.status == codes.STATUS_FAIL
    ):
        verdict = codes.VERDICT_READABLE_WITH_ISSUES
    elif (
        presence_result.status == codes.STATUS_PASS
        and not missing
        and migration_result.detail.get("ledger_present") is True
        and migration_result.detail.get("latest_identifier") == known_latest_migration
    ):
        if integrity_result.status == codes.STATUS_PASS and violation_count == 0:
            verdict = codes.VERDICT_RESTORABLE
        else:
            verdict = codes.VERDICT_APP_COMPATIBLE
    else:
        verdict = codes.VERDICT_READABLE

    return model.DiagnosticsResult(
        verdict=verdict,
        checks=checks,
        issues=[{"code": code, "count": count} for code, count in issues.items()],
        limits=limits,
        fingerprint=fingerprint_result.detail.get("fingerprint"),
    )
