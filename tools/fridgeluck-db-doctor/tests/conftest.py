"""Test path bootstrap + shared synthetic-fixture helpers. Owned by: TESTS stream (integrator)."""
from __future__ import annotations

import hashlib
import pathlib
import sqlite3
import sys

TOOL_DIR = pathlib.Path(__file__).resolve().parents[1]
DOCTOR_DIR = TOOL_DIR / "doctor"
for p in (str(TOOL_DIR), str(DOCTOR_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

SENTINEL = "TOPSECRET-SENTINEL-7f3a"

import pytest  # noqa: E402


def sha256_and_listing(path: pathlib.Path):
    """File digest + directory snapshot used to assert zero byte/dir changes."""
    h = hashlib.sha256()
    if path.exists():
        h.update(path.read_bytes())
    listing = sorted(
        (p.name, p.stat().st_size if p.is_file() else -1) for p in path.parent.iterdir()
    ) if path.parent.exists() else []
    return h.hexdigest(), listing


def make_healthy_db(path: pathlib.Path) -> pathlib.Path:
    """A closed, well-formed, FridgeLuck-shaped synthetic database (synthetic only)."""
    con = sqlite3.connect(str(path))
    try:
        con.executescript(
            """
            CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE cooking_history (id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL
                REFERENCES recipes(id));
            CREATE TABLE streaks (id INTEGER PRIMARY KEY, days INTEGER NOT NULL);
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL);
            INSERT INTO grdb_migrations VALUES ('v15_notification_rules_and_opportunities');
            """
        )
        con.execute("INSERT INTO recipes VALUES (1, ?)", (SENTINEL,))
        con.execute("INSERT INTO recipes VALUES (2, ?)", (SENTINEL,))
        con.execute("INSERT INTO cooking_history VALUES (1, 1)")
        con.execute("INSERT INTO streaks VALUES (1, 3)")
        con.commit()
    finally:
        con.close()
    return path


def make_ledger_db(path: pathlib.Path, identifier: str) -> pathlib.Path:
    """Same shape as make_healthy_db but with a chosen latest-migration identifier."""
    con = sqlite3.connect(str(path))
    try:
        con.executescript(
            """
            CREATE TABLE recipes (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE cooking_history (id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL
                REFERENCES recipes(id));
            CREATE TABLE streaks (id INTEGER PRIMARY KEY, days INTEGER NOT NULL);
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL);
            """
        )
        con.execute("INSERT INTO grdb_migrations VALUES (?)", (identifier,))
        con.execute("INSERT INTO recipes VALUES (1, 'synthetic')")
        con.commit()
    finally:
        con.close()
    return path


@pytest.fixture
def healthy_db(tmp_path):
    return make_healthy_db(tmp_path / "healthy.sqlite")


@pytest.fixture
def cli():
    """Run the CLI as a real subprocess; returns a run(*args) -> CompletedProcess helper."""
    import subprocess

    cli_path = DOCTOR_DIR / "cli.py"

    def run(*args, cwd=None):
        return subprocess.run(
            [sys.executable, str(cli_path), *args],
            capture_output=True, text=True, timeout=60, cwd=cwd,
        )

    return run
