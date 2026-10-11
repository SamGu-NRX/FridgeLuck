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
      integrity fail or fk>0 or missing markers -> READABLE_WITH_ISSUES
      markers present + latest migration match -> APP_COMPATIBLE
      app-compatible + integrity ok + fk 0 + nothing limited -> RESTORABLE_CANDIDATE
      otherwise (readable, no compatible claim) -> STRUCTURALLY_READABLE
  Every check must complete or be explicitly marked limited/skipped; a
  cancelled or truncated check is never reported as a pass.
"""
from __future__ import annotations

DEFAULT_EXPECTED_TABLES = ("recipes", "cooking_history", "streaks", "grdb_migrations")
KNOWN_LATEST_MIGRATION = "v15_notification_rules_and_opportunities"
KNOWN_MIGRATION_COUNT = 15


def fingerprint(con):  # noqa: ANN201 - contract stub
    raise NotImplementedError("diagnostics stream: fingerprint")


def integrity(con, budget):  # noqa: ANN201 - contract stub
    raise NotImplementedError("diagnostics stream: integrity")


def foreign_keys(con, budget):  # noqa: ANN201 - contract stub
    raise NotImplementedError("diagnostics stream: foreign_keys")


def tables_and_migrations(con, budget, expected_tables=DEFAULT_EXPECTED_TABLES):  # noqa: ANN001,ANN201
    raise NotImplementedError("diagnostics stream: tables_and_migrations")


def run_diagnostics(con, budget, expected_tables=DEFAULT_EXPECTED_TABLES,
                    known_latest_migration=KNOWN_LATEST_MIGRATION):  # noqa: ANN201
    raise NotImplementedError("diagnostics stream: run_diagnostics")
