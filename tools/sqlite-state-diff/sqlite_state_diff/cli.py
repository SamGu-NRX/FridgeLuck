"""Command-line entry point for sqlite-state-diff.

Deterministic JSON on stdout; short code-only diagnostics on stderr (no
paths, no exception dumps). Exit codes: 0 equal, 1 different, 2 invalid
input or refusal, 3 limited by bounds or cancellation. A partial, timed-out,
or cancelled comparison is never reported equal.
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

if __package__:
    from . import kernel, readers
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import kernel, readers

EXIT_EQUAL = 0
EXIT_DIFFERENT = 1
EXIT_INVALID = 2
EXIT_LIMITED = 3

_REFUSAL_DETAIL = {
    "missing": "input file does not exist (inputs are never created)",
    "not_regular": "input is not a regular file",
    "symlink": "final path component of an input is a symlink",
    "escape": "input path contains parent traversal",
    "sidecar": "an active -wal/-shm/-journal sidecar exists; refusing a non-quiescent input",
    "wal_mode": "database header declares WAL mode; refusing a host-dependent read",
    "not_sqlite": "input lacks the SQLite 3 file header",
    "unreadable": "input could not be opened or read as SQLite",
    "no_such_table": "selected table exists on neither side",
    "not_a_table": "selected name is a view; view code is never executed",
    "no_stable_identity": "no declared primary key and no explicit key; refusing to guess row order",
    "unknown_key_column": "explicit key names a column that does not exist",
    "identity_mismatch": "declared primary keys differ between the two sides",
    "nullable_key": "a key column holds NULL; row identity is not stable",
    "duplicate_key": "a key value repeats; row identity is not unique",
    "key_malformed": "key must be TABLE:COL[,COL...] with non-empty parts",
    "key_for_unselected_table": "key given for a table that is not selected",
    "duplicate_table": "table selected twice",
    "bad_limit": "limits must satisfy max-rows >= 1 and time-budget >= 0",
}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sqlite-state-diff",
        description=(
            "Read-only comparison of two closed synthetic SQLite fixtures. "
            "Reports schema, row, and typed-value differences as deterministic JSON."
        ),
    )
    p.add_argument("a", metavar="A", help="first fixture file (opened read-only, never modified)")
    p.add_argument("b", metavar="B", help="second fixture file (opened read-only, never modified)")
    p.add_argument(
        "--table",
        action="append",
        required=True,
        metavar="NAME",
        help="table to compare (repeat for several tables)",
    )
    p.add_argument(
        "--key",
        action="append",
        default=[],
        metavar="TABLE:COL[,COL...]",
        help=(
            "explicit row identity for a table; required when the table has no "
            "stable declared primary key. Without a stable identity the tool "
            "refuses rather than guess row order."
        ),
    )
    p.add_argument(
        "--max-rows-per-table",
        type=int,
        default=None,
        metavar="N",
        help="row bound per table (default %d); a breach marks the result limited"
        % kernel.DEFAULT_MAX_ROWS_PER_TABLE,
    )
    p.add_argument(
        "--time-budget-seconds",
        type=float,
        default=None,
        metavar="S",
        help="wall-clock bound (default %g); a breach marks the result limited"
        % kernel.DEFAULT_TIME_BUDGET_SECONDS,
    )
    return p


def _emit_doc(doc):
    print(json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=True))


def _refuse(code, table=None):
    _emit_doc({
        "tool": "sqlite-state-diff",
        "schema_version": 1,
        "result": "invalid",
        "refusal": {
            "code": code,
            "table": table,
            "detail": _REFUSAL_DETAIL.get(code, "refused"),
        },
    })
    print(f"refused: {code}" + (f" table={table}" if table else ""), file=sys.stderr)
    return EXIT_INVALID


def _parse_keys(specs):
    keys = {}
    for spec in specs:
        if ":" not in spec:
            raise _KeyError("key_malformed")
        table, cols = spec.split(":", 1)
        col_list = [c.strip() for c in cols.split(",")]
        if not table.strip() or not col_list or not all(col_list):
            raise _KeyError("key_malformed")
        if table in keys:
            raise _KeyError("key_malformed")
        keys[table] = col_list
    return keys


class _KeyError(Exception):
    def __init__(self, code):
        self.code = code


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        keys = _parse_keys(args.key)
    except _KeyError as e:
        return _refuse(e.code)

    tables = args.table
    if len(set(tables)) != len(tables):
        return _refuse("duplicate_table")
    for t in keys:
        if t not in tables:
            return _refuse("key_for_unselected_table", t)
    if args.max_rows_per_table is not None and args.max_rows_per_table < 1:
        return _refuse("bad_limit")
    if args.time_budget_seconds is not None and args.time_budget_seconds < 0:
        return _refuse("bad_limit")

    max_rows = (args.max_rows_per_table if args.max_rows_per_table is not None
                else kernel.DEFAULT_MAX_ROWS_PER_TABLE)
    time_budget = (args.time_budget_seconds if args.time_budget_seconds is not None
                   else kernel.DEFAULT_TIME_BUDGET_SECONDS)
    limits = kernel.Limits(max_rows_per_table=max_rows,
                           time_budget_seconds=time_budget)

    try:
        readers.validate_input(args.a)
        readers.validate_input(args.b)
        conn_a = readers.open_database_ro(args.a)
        conn_b = readers.open_database_ro(args.b)
    except readers.InputRejected as e:
        return _refuse(e.code)
    except sqlite3.Error:
        return _refuse("unreadable")

    try:
        result = kernel.compare_databases(conn_a, conn_b, tables, keys, limits)
    except kernel.KeyRefused as e:
        return _refuse(e.code, e.table)
    except sqlite3.Error:
        return _refuse("unreadable")
    except KeyboardInterrupt:
        _emit_doc({
            "tool": "sqlite-state-diff",
            "schema_version": 1,
            "result": "limited",
            "limits": {"triggered": {"code": "cancelled", "table": None}},
        })
        return EXIT_LIMITED
    finally:
        conn_a.close()
        conn_b.close()

    _emit_doc(result)
    return {
        "equal": EXIT_EQUAL,
        "different": EXIT_DIFFERENT,
        "limited": EXIT_LIMITED,
    }[result["result"]]


if __name__ == "__main__":
    sys.exit(main())
