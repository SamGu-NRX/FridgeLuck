"""Test path bootstrap + shared synthetic-fixture helpers. Owned by: TESTS stream (integrator)."""
from __future__ import annotations

import pathlib
import sqlite3
import hashlib
import os

TOOL_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(TOOL_DIR) not in __import__("sys").path:
    __import__("sys").path.insert(0, str(TOOL_DIR))

SENTINEL = "TOPSECRET-SENTINEL-7f3a"


def sha256_and_listing(path: pathlib.Path):
    """File digest + directory snapshot used to assert zero byte/dir changes."""
    h = hashlib.sha256()
    if path.exists():
        h.update(path.read_bytes())
    listing = sorted(
        (p.name, p.stat().st_size if p.is_file() else -1) for p in path.parent.iterdir()
    ) if path.parent.exists() else []
    return h.hexdigest(), listing


def make_healthy_db(path: pathlib.Path, rows: int = 2) -> pathlib.Path:
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
