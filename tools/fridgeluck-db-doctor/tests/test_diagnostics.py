"""Diagnostics stream tests: verdicts, fingerprints, FK counts, migration state. Owner: integrator."""
from __future__ import annotations

import sqlite3

import codes
import diagnostics
import model
import reader

from conftest import make_ledger_db


def open_ro(path):
    con, _info, _handle = reader.open_read_only(str(path), model.Budget())
    return con


def issue_codes(result):
    return {i["code"] for i in result.issues}


def test_healthy_full_shape_is_restorable_candidate(healthy_db):
    con = open_ro(healthy_db)
    try:
        res = diagnostics.run_diagnostics(con, model.Budget())
        assert res.verdict == codes.VERDICT_RESTORABLE
        assert res.issues == []
        assert res.limits["truncated"] is False
        assert res.limits["cancelled"] is False
        assert res.fingerprint is not None and len(res.fingerprint) == 16
        check_codes = {c.code for c in res.checks}
        assert {
            codes.CHECK_HEADER_MAGIC, codes.CHECK_INTEGRITY, codes.CHECK_FOREIGN_KEYS,
            codes.CHECK_TABLE_PRESENCE, codes.CHECK_MIGRATION_STATE,
            codes.CHECK_SCHEMA_FINGERPRINT,
        } <= check_codes
    finally:
        con.close()


def test_broken_fk_is_readable_with_issues(tmp_path):
    p = tmp_path / "bad-fk.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY)")
    con.execute(
        "CREATE TABLE cooking_history (id INTEGER PRIMARY KEY,"
        " recipe_id INTEGER NOT NULL REFERENCES recipes(id))"
    )
    con.execute("INSERT INTO recipes VALUES (1)")
    con.execute("PRAGMA foreign_keys=OFF")
    con.execute("INSERT INTO cooking_history VALUES (1, 999)")
    con.commit()
    con.close()
    con2 = open_ro(p)
    try:
        res = diagnostics.run_diagnostics(con2, model.Budget())
        assert res.verdict == codes.VERDICT_READABLE_WITH_ISSUES
        assert codes.ISSUE_FK_VIOLATIONS in issue_codes(res)
        fk = [c for c in res.checks if c.code == codes.CHECK_FOREIGN_KEYS][0]
        assert fk.detail["violation_count"] >= 1
        assert fk.status == codes.STATUS_FAIL
    finally:
        con2.close()


def test_plain_sqlite_readable_but_not_compatible(tmp_path):
    p = tmp_path / "plain.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE t (x INTEGER)")
    con.commit()
    con.close()
    con2 = open_ro(p)
    try:
        res = diagnostics.run_diagnostics(con2, model.Budget())
        assert res.verdict in (codes.VERDICT_READABLE, codes.VERDICT_READABLE_WITH_ISSUES)
        assert codes.ISSUE_EXPECTED_TABLE_MISSING in issue_codes(res)
        # must NOT claim compatibility or restorability
        assert res.verdict not in (codes.VERDICT_APP_COMPATIBLE, codes.VERDICT_RESTORABLE)
    finally:
        con2.close()


def test_migration_lagging_blocks_compatibility(tmp_path):
    p = tmp_path / "v14.sqlite"
    make_ledger_db(p, "v14_pantry_assumptions_saved_winners")
    con = open_ro(p)
    try:
        res = diagnostics.run_diagnostics(con, model.Budget())
        assert codes.ISSUE_MIGRATION_LAGGING in issue_codes(res)
        assert res.verdict not in (codes.VERDICT_APP_COMPATIBLE, codes.VERDICT_RESTORABLE)
    finally:
        con.close()


def test_migration_ledger_missing(tmp_path):
    p = tmp_path / "no-ledger.sqlite"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    con.execute("CREATE TABLE cooking_history (id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL REFERENCES recipes(id))")
    con.execute("CREATE TABLE streaks (id INTEGER PRIMARY KEY, days INTEGER NOT NULL)")
    con.commit()
    con.close()
    con2 = open_ro(p)
    try:
        res = diagnostics.run_diagnostics(con2, model.Budget())
        assert codes.ISSUE_MIGRATION_STATE_UNKNOWN in issue_codes(res)
    finally:
        con2.close()


def test_fingerprint_stable_and_sensitive(healthy_db, tmp_path):
    con = open_ro(healthy_db)
    try:
        fp1 = diagnostics.fingerprint(con)
        fp2 = diagnostics.fingerprint(con)
        assert fp1.detail["fingerprint"] == fp2.detail["fingerprint"]
    finally:
        con.close()
    other = tmp_path / "other.sqlite"
    con = sqlite3.connect(str(other))
    con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    con.commit()
    con.close()
    con2 = open_ro(other)
    try:
        fp3 = diagnostics.fingerprint(con2)
    finally:
        con2.close()
    assert fp1.detail["fingerprint"] != fp3.detail["fingerprint"]


def test_limited_run_is_never_a_pass(healthy_db):
    con = open_ro(healthy_db)
    try:
        res = diagnostics.run_diagnostics(
            con, model.Budget(max_steps=1, max_rows=1, max_seconds=5)
        )
        assert res.verdict == codes.VERDICT_READABLE_WITH_ISSUES
        limited_flags = res.limits
        assert (
            limited_flags["cancelled"] or limited_flags["truncated"] or limited_flags["deadline_hit"]
        )
        statuses = [c.status for c in res.checks]
        assert codes.STATUS_LIMITED in statuses or codes.STATUS_SKIPPED in statuses
        assert res.verdict not in (codes.VERDICT_RESTORABLE, codes.VERDICT_APP_COMPATIBLE)
    finally:
        con.close()


def test_no_row_values_or_sql_in_details(healthy_db):
    from conftest import SENTINEL

    con = open_ro(healthy_db)
    try:
        res = diagnostics.run_diagnostics(con, model.Budget())
    finally:
        con.close()
    blob = repr(res.checks) + repr(res.issues)
    assert SENTINEL not in blob
    assert "CREATE TABLE" not in blob
