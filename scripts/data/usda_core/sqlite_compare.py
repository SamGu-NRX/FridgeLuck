"""Row-exact comparison of two catalog SQLite files.

Reads both databases read-only and diffs the three catalog tables
(``ingredient_catalog`` by fdc_id, ``ingredients`` by id,
``ingredient_aliases`` by (ingredient_id, alias)). Used to prove that a
rebundled SQLite changed exactly the audited rows and nothing else.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import orjson


def _read_table(conn: sqlite3.Connection, table: str, key_columns: list[str]) -> dict[tuple, dict[str, Any]]:
    cursor = conn.execute(f"SELECT * FROM {table}")
    names = [d[0] for d in cursor.description]
    rows: dict[tuple, dict[str, Any]] = {}
    for raw in cursor.fetchall():
        row = dict(zip(names, raw))
        key = tuple(row[c] for c in key_columns)
        rows[key] = row
    return rows


def compare_sqlite(old_path: Path, new_path: Path) -> dict[str, Any]:
    tables = {
        "ingredient_catalog": ["fdc_id"],
        "ingredients": ["id"],
        "ingredient_aliases": ["ingredient_id", "alias"],
    }
    old_conn = sqlite3.connect(f"file:{old_path}?mode=ro", uri=True)
    new_conn = sqlite3.connect(f"file:{new_path}?mode=ro", uri=True)
    report: dict[str, Any] = {"tables": {}}
    try:
        for table, keys in tables.items():
            old_rows = _read_table(old_conn, table, keys)
            new_rows = _read_table(new_conn, table, keys)
            added = sorted(new_rows.keys() - old_rows.keys())
            removed = sorted(old_rows.keys() - new_rows.keys())
            common = old_rows.keys() & new_rows.keys()
            changed = []
            for key in sorted(common):
                before, after = old_rows[key], new_rows[key]
                diff = {
                    column: {"old": before[column], "new": after[column]}
                    for column in names_diff(before, after)
                    if before[column] != after[column]
                }
                if diff:
                    changed.append({",".join(str(k) for k in key): diff})
            report["tables"][table] = {
                "n_old": len(old_rows),
                "n_new": len(new_rows),
                "n_added": len(added),
                "n_removed": len(removed),
                "n_changed": len(changed),
                "added_keys": [list(map(str, k)) for k in added[:50]],
                "removed_keys": [list(map(str, k)) for k in removed[:50]],
                "changed": changed[:100],
            }
        report["identical"] = all(
            t["n_added"] == 0 and t["n_removed"] == 0 and t["n_changed"] == 0
            for t in report["tables"].values()
        )
        return report
    finally:
        old_conn.close()
        new_conn.close()


def names_diff(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    return [c for c in before.keys() if c in after]


def save_report(report: dict[str, Any], path: Path) -> None:
    path.write_bytes(orjson.dumps(report, option=orjson.OPT_SORT_KEYS | orjson.OPT_INDENT_2) + b"\n")
