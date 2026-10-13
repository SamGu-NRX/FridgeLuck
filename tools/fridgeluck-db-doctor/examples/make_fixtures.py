#!/usr/bin/env python3
"""Build the committed synthetic example fixtures and run the CLI against them.

Synthetic data only — the fixtures contain no real user data. Every fixture is
built in a scratch directory; nothing in the repo is ever written except the
committed report JSONs.

Usage: python3 examples/make_fixtures.py [--regen-reports]
"""
from __future__ import annotations

import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile

TOOL_DIR = pathlib.Path(__file__).resolve().parents[1]
CLI = TOOL_DIR / "doctor" / "cli.py"
HERE = pathlib.Path(__file__).resolve().parent

SENTINEL = "TOPSECRET-SENTINEL-7f3a"
LATEST = "v15_notification_rules_and_opportunities"


def healthy(path: pathlib.Path) -> None:
    con = sqlite3.connect(str(path))
    con.executescript(
        """
        CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE cooking_history (id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL REFERENCES recipes(id));
        CREATE TABLE streaks (id INTEGER PRIMARY KEY, days INTEGER NOT NULL);
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL);
        """
    )
    con.execute("INSERT INTO grdb_migrations VALUES (?)", (LATEST,))
    con.execute("INSERT INTO recipes VALUES (1, ?)", (SENTINEL,))
    con.execute("INSERT INTO cooking_history VALUES (1, 1)")
    con.execute("INSERT INTO streaks VALUES (1, 3)")
    con.commit()
    con.close()


def broken_fk(path: pathlib.Path) -> None:
    con = sqlite3.connect(str(path))
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


def plain(path: pathlib.Path) -> None:
    con = sqlite3.connect(str(path))
    con.execute("CREATE TABLE notes (x TEXT)")
    con.commit()
    con.close()


def corrupted(path: pathlib.Path, source: pathlib.Path, pos: int) -> None:
    raw = bytearray(source.read_bytes())
    raw[pos : pos + len(SENTINEL)] = SENTINEL.encode()
    path.write_bytes(bytes(raw))


def main() -> int:
    regen = "--regen-reports" in sys.argv
    reports: list[dict] = []
    with tempfile.TemporaryDirectory() as td:
        td_path = pathlib.Path(td)
        cases: list[tuple[str, pathlib.Path, list[str], int]] = []
        h = td_path / "healthy-fixture.sqlite"
        healthy(h)
        cases.append(("healthy_full_shape", h, [], 0))
        fk = td_path / "broken-fk-fixture.sqlite"
        broken_fk(fk)
        cases.append(("broken_foreign_keys", fk, [], 1))
        pl = td_path / "plain-fixture.sqlite"
        plain(pl)
        cases.append(("plain_sqlite_no_markers", pl, [], 1))
        # OBSERVATION-ONLY: direct probe of corrupted-page-header raises
        # sqlite3.DatabaseError from PRAGMA integrity_check, yet the CLI
        # reported exit 0 at integration time — unresolved discrepancy (see
        # README "Known open questions"). expected_exit=None records observed
        # behavior without claiming a pass.
        cor = td_path / "corrupted-page-header.sqlite"
        corrupted(cor, h, 4096)
        cases.append(("corrupt_page2_header_observed", cor, [], None))
        # Overwrite free space mid-page: integrity_check does not traverse
        # unused page regions, so corruption there is UNDETECTED (exit 0).
        # This documents the tool's honest limitation: it is a structural
        # canary, not a guarantee of byte-level integrity.
        cor2 = td_path / "corrupted-freespace.sqlite"
        corrupted(cor2, h, len(h.read_bytes()) // 2)
        cases.append(("corrupt_freespace_undetected_observed", cor2, [], None))
        cases.append(("missing_path", td_path / "does-not-exist.sqlite", [], 2))
        sidecar = td_path / "wal-pending-fixture.sqlite"
        healthy(sidecar)
        (td_path / "wal-pending-fixture.sqlite-wal").write_bytes(b"pending" * 8)
        cases.append(("wal_sidecar_present", sidecar, [], 2))
        big = td_path / "budget-fixture.sqlite"
        con = sqlite3.connect(str(big))
        con.execute("CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        con.executemany("INSERT INTO recipes VALUES (?, 'r')", [(i,) for i in range(3000)])
        con.commit()
        con.close()
        cases.append(("budget_limited_max_steps_1", big, ["--max-steps", "1"], 3))

        for name, path, extra, expected_exit in cases:
            proc = subprocess.run(
                [sys.executable, str(CLI), "--input", str(path), *extra],
                capture_output=True, text=True, timeout=60,
            )
            entry = {
                "case": name,
                "invocation": f"python3 doctor/cli.py --input <{name}.sqlite>"
                + (" " + " ".join(extra) if extra else ""),
                "expected_exit": expected_exit,
                "actual_exit": proc.returncode,
                "stderr_empty": proc.stderr == "",
                "report": json.loads(proc.stdout) if proc.stdout.strip() else None,
            }
            reports.append(entry)
            status = (
                "OK" if proc.returncode == expected_exit
                else "MISMATCH" if expected_exit is not None
                else "OBSERVED"
            )
            print(f"{status}: {name} exit={proc.returncode} (expected {expected_exit})")

    out = HERE / "example-reports.json"
    if regen or not out.exists():
        out.write_text(json.dumps(reports, indent=2, sort_keys=True) + "\n")
        print(f"wrote {out}")
    else:
        prev = json.loads(out.read_text())
        if prev != reports:
            print("example-reports.json differs from current run — rerun with --regen-reports after review")
            return 1
        print("example-reports.json matches current run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
