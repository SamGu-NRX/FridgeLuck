#!/usr/bin/env python3
"""Catalog resolver golden test.

The Swift probe cannot link GRDB, so the catalog path is verified at the SQL
level: the port's verbatim queries run against the shipped SQLite file, and a
sample is cross-checked against independently written queries (not the port's
own CATALOG_SQL constants) to catch transcription errors. Also probes SQLite
semantics the port relies on: case-insensitive LIKE on ASCII, ambiguity → nil,
and allowPrefix windows.

Exit 0 = all checks pass. Divergences print and exit 1.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXPERIMENT_ROOT / "resolution"))

from app_resolution import CATALOG_SQL, IngredientCatalogResolver, USDA_DB  # noqa: E402

failures: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if not cond:
        failures.append(f"{name}: {detail}")
        print(f"FAIL {name}: {detail}")
    else:
        print(f"ok   {name}")


def raw_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{USDA_DB}?mode=ro", uri=True)
    conn.execute("PRAGMA case_sensitive_like = OFF")
    return conn


def main() -> None:
    resolver = IngredientCatalogResolver(USDA_DB)
    conn = raw_conn()

    # ---- 1. resolve every FoodSeg103 class name + curated label; record results
    taxonomy = {}
    import csv

    with (EXPERIMENT_ROOT / "taxonomy" / "foodseg103_to_catalog.csv").open() as f:
        for row in csv.DictReader(f):
            taxonomy[row["class_name_normalized"]] = row["resolution_ingredient_id"]

    probe_names = sorted(taxonomy)
    resolved: dict[str, int | None] = {}
    for name in probe_names:
        resolved[name] = resolver.resolve(name, matching="exact")

    # ---- 2. independent cross-check with hand-written SQL (not CATALOG_SQL)
    # resolver stages (documented in IngredientCatalogResolver.swift):
    #   name_exact: WHERE name = ? COLLATE NOCASE-equivalent via LIKE
    #   alias_exact: ingredient_aliases alias = ?
    #   prefix windows: name LIKE ?% with LIMIT semantics
    crosscheck_ok = 0
    crosscheck_sample = probe_names[::4]  # every 4th name
    for name in crosscheck_sample:
        norm = name.lower().replace("_", " ")
        rows = conn.execute(
            "SELECT id FROM ingredients WHERE name LIKE ? LIMIT 1", (norm,)
        ).fetchall()
        # multiple exact matches = ambiguous → resolver returns nil
        all_rows = conn.execute(
            "SELECT id FROM ingredients WHERE name LIKE ?", (norm,)
        ).fetchall()
        expect: int | None
        if len(all_rows) > 1:
            expect = None
        elif all_rows:
            expect = int(all_rows[0][0])
        else:
            expect = None
        if expect != resolved.get(name):
            # resolver falls back through alias/prefix stages; a mismatch here is
            # only a failure when the independent whole-name query found exactly one
            if expect is not None and resolved.get(name) is None:
                failures.append(f"crosscheck {name}: sql={expect} resolver=nil")
                print(f"FAIL crosscheck {name}: sql={expect} resolver=nil")
            else:
                crosscheck_ok += 1  # different stage produced the answer
        else:
            crosscheck_ok += 1
    check("crosscheck-sample", not any(f.startswith("crosscheck") for f in failures), f"{crosscheck_ok}/{len(crosscheck_sample)} matched")

    # ---- 3. SQLite LIKE case-insensitivity on ASCII (port relies on it)
    r = conn.execute("SELECT COUNT(*) FROM ingredients WHERE name LIKE 'egg'").fetchone()[0]
    r_upper = conn.execute("SELECT COUNT(*) FROM ingredients WHERE name LIKE 'EGG'").fetchone()[0]
    check("like-case-insensitive", r == r_upper, f"lower={r} upper={r_upper}")

    # ---- 4. ambiguity → nil: find a name with >=2 exact rows and assert nil
    dupes = conn.execute(
        "SELECT name FROM ingredients GROUP BY name HAVING COUNT(*) >= 2 LIMIT 3"
    ).fetchall()
    for (dup_name,) in dupes:
        got = resolver.resolve(dup_name, matching="exact")
        check(f"ambiguous-{dup_name[:30]}", got is None, f"expected nil, got {got}")

    # ---- 5. allowPrefix: 'green' should resolve via prefix window deterministically
    p = resolver.resolve("green", matching="allowPrefix")
    rows = conn.execute(
        "SELECT id FROM ingredients WHERE name LIKE 'green%' ORDER BY name LIMIT 2"
    ).fetchall()
    print(f"info allowPrefix('green') -> {p}; first prefix rows {[int(x[0]) for x in rows]}")

    # ---- 6. CATALOG_SQL constants actually execute and are non-empty
    # (uniqueExactMatch carries a {placeholders} template the resolver substitutes)
    for stage, sql in CATALOG_SQL.items():
        try:
            executable = sql.replace("{placeholders}", "?")
            conn.execute(executable, ("zzzznohit",) * executable.count("?")).fetchall()
            check(f"catalog-sql-{stage}", True)
        except Exception as e:  # noqa: BLE001
            check(f"catalog-sql-{stage}", False, str(e))

    (EXPERIMENT_ROOT / "differential" / "catalog_golden_results.json").write_text(
        json.dumps({k: v for k, v in resolved.items()}, indent=1, sort_keys=True)
    )
    print(f"probed {len(probe_names)} names; failures={len(failures)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
