#!/usr/bin/env python3
"""Deterministically build the committed synthetic fixture databases.

Usage: python3 build_fixtures.py <target-dir>

Everything here is closed, synthetic, and obviously fake (alpha-bar,
beta-bites, ...). No real or production data. Building opens writable
connections because fixture CONSTRUCTION writes; the diff tool itself only
ever reads. Rebuilding reproduces the same logical content.
"""

import math
import os
import sqlite3
import sys

SNACKS_SCHEMA = """CREATE TABLE snacks (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    calories REAL,
    tag TEXT,
    data BLOB,
    qty INTEGER
)"""
SERVINGS_SCHEMA = """CREATE TABLE servings (
    food_id INTEGER NOT NULL REFERENCES snacks(id),
    day TEXT NOT NULL,
    grams INTEGER NOT NULL,
    PRIMARY KEY (food_id, day)
)"""
NAME_INDEX = "CREATE INDEX idx_snacks_name ON snacks(name)"
NOTE_TRIGGER = """CREATE TRIGGER trg_snack_note AFTER INSERT ON snacks
BEGIN
    UPDATE snacks SET tag = tag WHERE id = NEW.id;
END"""
TAG_INDEX = "CREATE INDEX idx_snacks_tag ON snacks(tag)"


def _build(path, snacks_rows, servings_rows, with_trigger, with_tag_index):
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    # The FK on servings stays DECLARED in the schema (that is what the diff
    # tool compares); enforcement is off only so the deleted-row fixture may
    # leave a dangling parent reference during construction.
    conn.execute(SNACKS_SCHEMA)
    conn.execute(SERVINGS_SCHEMA)
    conn.execute(NAME_INDEX)
    if with_trigger:
        conn.execute(NOTE_TRIGGER)
    if with_tag_index:
        conn.execute(TAG_INDEX)
    conn.executemany("INSERT INTO snacks VALUES (?,?,?,?,?,?)", snacks_rows)
    conn.executemany("INSERT INTO servings VALUES (?,?,?)", servings_rows)
    conn.commit()
    conn.close()


def build_equal(path):
    rows = [
        (1, "alpha-bar", 120.5, "a", b"\x00\x01\xff", 3),
        (2, "beta-bites", None, "b", None, 0),
        (3, "gamma-gems", 2.75, "c", b"\x01", 7),
    ]
    servings = [(1, "mon", 30), (1, "tue", 45), (2, "mon", 10)]
    _build(path, rows, servings, with_trigger=True, with_tag_index=False)


def build_diff(path):
    rows = [
        (1, "alpha-bar", 120.5, "a", b"\x00\x01\xff", 3),
        (2, "beta-bites", None, "b", None, 0),
        (3, "gamma-gems", 2.75, "c", b"\x01", 7),
        (4, "delta-drops", 90.0, "d", b"\x00\x01\xff", 2),
    ]
    servings = [(1, "mon", 30), (1, "tue", 45), (2, "mon", 10)]
    _build(path, rows, servings, with_trigger=True, with_tag_index=False)


def build_diff_b(path):
    one_ulp = math.nextafter(120.5, math.inf)
    rows = [
        (1, "alpha-bar", one_ulp, "a", b"\x00\x01\xff", 3),
        (3, "gamma-gems", 2.75, "c", b"\x01", "7"),
        (4, "delta-drops", 90.0, "d", b"\x00\x02\xff", 2),
        (5, "epsilon-chips", 210.25, "e", b"\x07", 1),
    ]
    servings = [(1, "mon", 30), (1, "tue", 45), (2, "mon", 10)]
    _build(path, rows, servings, with_trigger=False, with_tag_index=True)


def main():
    if len(sys.argv) != 2:
        print("usage: build_fixtures.py <target-dir>", file=sys.stderr)
        return 2
    target = sys.argv[1]
    os.makedirs(target, exist_ok=True)
    build_equal(os.path.join(target, "equal_a.sqlite"))
    build_equal(os.path.join(target, "equal_b.sqlite"))
    build_diff(os.path.join(target, "diff_a.sqlite"))
    build_diff_b(os.path.join(target, "diff_b.sqlite"))
    print("fixtures written to", target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
