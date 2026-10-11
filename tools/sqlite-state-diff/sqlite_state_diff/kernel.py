"""Comparison kernel for sqlite-state-diff.

Deterministic, read-only comparison of two open connections. The result is a
JSON-serializable dict; row identities are opaque keyed hashes of the
identity columns, and raw row values never enter the output. Schema reads use
parameterized pragma table-valued functions and quoted identifiers; no user
SQL is executed and no view or virtual-table code is ever run.

Value semantics:
- storage classes are kept distinct: NULL/text/blob/integer/real;
- real values are compared by their binary64 bit pattern, so 0.0 vs -0.0 and
  one-ULP differences are reported; NaN cannot be stored in SQLite (it is
  normalized to NULL on write), so bit comparison never sees NaN;
- NULL vs NULL in the same cell is equal state, not SQL three-valued logic;
- integer and real are different even when numerically equal (1 vs 1.0).
"""

import hashlib
import re
import struct
import time

TYPE_NULL = "null"
TYPE_INTEGER = "integer"
TYPE_REAL = "real"
TYPE_TEXT = "text"
TYPE_BLOB = "blob"

DEFAULT_MAX_ROWS_PER_TABLE = 500_000
DEFAULT_TIME_BUDGET_SECONDS = 60.0
_CHUNK = 512


class KeyRefused(Exception):
    """No safe row identity exists for a selected table; refuse, never guess."""

    def __init__(self, code, table=None):
        self.code = code
        self.table = table
        super().__init__(f"{code} ({table})")


class BudgetExceeded(Exception):
    def __init__(self, code, table=None):
        self.code = code
        self.table = table
        super().__init__(f"{code} ({table})")


class Limits:
    """Hard bounds on work; a breach marks the whole result limited."""

    def __init__(self, max_rows_per_table=DEFAULT_MAX_ROWS_PER_TABLE,
                 time_budget_seconds=DEFAULT_TIME_BUDGET_SECONDS):
        self.max_rows_per_table = max_rows_per_table
        self.time_budget_seconds = time_budget_seconds
        self._deadline = (
            time.monotonic() + time_budget_seconds
            if time_budget_seconds is not None
            else None
        )

    def check(self, table=None):
        if self._deadline is not None and time.monotonic() >= self._deadline:
            raise BudgetExceeded("time_budget", table)


def quote_ident(name):
    return '"' + str(name).replace('"', '""') + '"'


def type_code(value):
    if value is None:
        return TYPE_NULL
    if isinstance(value, bytes):
        return TYPE_BLOB
    if isinstance(value, str):
        return TYPE_TEXT
    if isinstance(value, float):
        return TYPE_REAL
    return TYPE_INTEGER


def _canonical(value):
    tc = type_code(value)
    if tc == TYPE_NULL:
        return "n"
    if tc == TYPE_INTEGER:
        return "i" + str(value)
    if tc == TYPE_REAL:
        return "f" + struct.pack(">d", value).hex()
    if tc == TYPE_TEXT:
        return "t" + value
    return "b" + value.hex()


def _key_digest(table, key_values):
    h = hashlib.sha256()
    h.update(b"srd1\x1f")
    h.update(str(table).encode("utf-8", "surrogatepass"))
    for v in key_values:
        h.update(b"\x1f")
        h.update(type_code(v).encode("ascii"))
        h.update(b":")
        h.update(_canonical(v).encode("utf-8", "surrogatepass"))
    return h.hexdigest()


def _opaque_row_id(digest):
    return "r" + digest[:16]


# --- schema reads -----------------------------------------------------------

def _norm_sql(text):
    return None if text is None else " ".join(str(text).split())


def _table_columns(conn, table):
    rows = conn.execute(
        'SELECT cid, name, type, "notnull", dflt_value, pk '
        "FROM pragma_table_info(?) ORDER BY cid",
        (table,),
    ).fetchall()
    return [
        {"name": r[1], "type": r[2] or "", "notnull": bool(r[3]),
         "dflt": r[4], "pk": r[5]}
        for r in rows
    ]


def _object_kind(conn, name):
    row = conn.execute(
        "SELECT type, sql FROM sqlite_master WHERE name = ?", (name,)
    ).fetchone()
    if row is None:
        return None, None
    return row[0], row[1]


def _table_flags(sql):
    u = (sql or "").upper()
    return {
        "virtual": u.lstrip().startswith("CREATE VIRTUAL"),
        "strict": re.search(r"\bSTRICT\b", u) is not None,
        "without_rowid": re.search(r"WITHOUT\s+ROWID", u) is not None,
    }


def _table_indexes(conn, table):
    out = {}
    for name, uniq, origin, partial in conn.execute(
        'SELECT name, "unique", origin, "partial" FROM pragma_index_list(?) '
        "ORDER BY name",
        (table,),
    ):
        cols = [
            r[0]
            for r in conn.execute(
                "SELECT name FROM pragma_index_info(?) ORDER BY seqno", (name,)
            )
        ]
        sql_row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE name = ?", (name,)
        ).fetchone()
        out[name.lower()] = {
            "name": name,
            "unique": bool(uniq),
            "origin": origin,
            "partial": bool(partial),
            "columns": cols,
            "sql": _norm_sql(sql_row[0] if sql_row else None),
        }
    return out


def _table_fks(conn, table):
    rows = [
        {"parent_table": r[2], "from": r[3], "to": r[4],
         "on_update": r[5], "on_delete": r[6]}
        for r in conn.execute(
            'SELECT id, seq, "table", "from", "to", on_update, on_delete '
            "FROM pragma_foreign_key_list(?)",
            (table,),
        )
    ]
    rows.sort(key=lambda d: tuple("" if v is None else str(v) for v in d.values()))
    return rows


def _table_triggers(conn, table):
    rows = conn.execute(
        "SELECT name, sql FROM sqlite_master "
        "WHERE type = 'trigger' AND tbl_name = ? ORDER BY name",
        (table,),
    ).fetchall()
    return {r[0].lower(): {"name": r[0], "sql": _norm_sql(r[1])} for r in rows}


# --- schema comparison ------------------------------------------------------

def _display(columns, lower_name):
    for c in columns:
        if c["name"].lower() == lower_name:
            return c["name"]
    return lower_name


def _compare_schema(conn_a, conn_b, table):
    kind_a, sql_a = _object_kind(conn_a, table)
    kind_b, sql_b = _object_kind(conn_b, table)
    if kind_a is None and kind_b is None:
        raise KeyRefused("no_such_table", table)
    if kind_a == "view" or kind_b == "view":
        raise KeyRefused("not_a_table", table)
    if kind_a is None:
        return {"status": "b_only", "differences": [{"code": "table_b_only"}]}
    if kind_b is None:
        return {"status": "a_only", "differences": [{"code": "table_a_only"}]}
    flags_a = _table_flags(sql_a)
    flags_b = _table_flags(sql_b)
    if flags_a["virtual"] and flags_b["virtual"]:
        return {"status": "unsupported",
                "differences": [{"code": "virtual_table_unsupported"}]}
    if flags_a["virtual"] != flags_b["virtual"]:
        return {"status": "different",
                "differences": [{"code": "table_kind_changed"}]}

    diffs = []
    cols_a = _table_columns(conn_a, table)
    cols_b = _table_columns(conn_b, table)
    names_a = [c["name"].lower() for c in cols_a]
    names_b = [c["name"].lower() for c in cols_b]
    if names_a != names_b:
        set_a, set_b = set(names_a), set(names_b)
        for n in names_b:
            if n not in set_a:
                diffs.append({"code": "column_added", "column": _display(cols_b, n)})
        for n in names_a:
            if n not in set_b:
                diffs.append({"code": "column_removed", "column": _display(cols_a, n)})
        if set_a == set_b:
            diffs.append({"code": "column_order_changed"})
    map_a = {c["name"].lower(): c for c in cols_a}
    map_b = {c["name"].lower(): c for c in cols_b}
    for n in names_b:
        if n not in map_a:
            continue
        ca, cb = map_a[n], map_b[n]
        fields = (
            ("type", " ".join(ca["type"].split()).upper(),
             " ".join(cb["type"].split()).upper()),
            ("notnull", ca["notnull"], cb["notnull"]),
            ("default", _norm_sql(ca["dflt"]), _norm_sql(cb["dflt"])),
            ("pk", ca["pk"], cb["pk"]),
        )
        for field, fa, fb in fields:
            if fa != fb:
                diffs.append({"code": "column_changed", "column": cb["name"],
                              "field": field})
    for field in ("strict", "without_rowid"):
        if flags_a[field] != flags_b[field]:
            diffs.append({"code": "table_option_changed", "field": field})
    idx_a = _table_indexes(conn_a, table)
    idx_b = _table_indexes(conn_b, table)
    for n in sorted(set(idx_b) - set(idx_a)):
        diffs.append({"code": "index_added", "index": idx_b[n]["name"]})
    for n in sorted(set(idx_a) - set(idx_b)):
        diffs.append({"code": "index_removed", "index": idx_a[n]["name"]})
    for n in sorted(set(idx_a) & set(idx_b)):
        if idx_a[n] != idx_b[n]:
            diffs.append({"code": "index_changed", "index": idx_a[n]["name"]})
    fks_a = _table_fks(conn_a, table)
    fks_b = _table_fks(conn_b, table)
    if fks_a != fks_b:
        set_a = {tuple(sorted(d.items())) for d in fks_a}
        set_b = {tuple(sorted(d.items())) for d in fks_b}
        for item in sorted(set_b - set_a):
            diffs.append({"code": "foreign_key_added", "foreign_key": list(item)})
        for item in sorted(set_a - set_b):
            diffs.append({"code": "foreign_key_removed", "foreign_key": list(item)})
    trg_a = _table_triggers(conn_a, table)
    trg_b = _table_triggers(conn_b, table)
    for n in sorted(set(trg_b) - set(trg_a)):
        diffs.append({"code": "trigger_added", "trigger": trg_b[n]["name"]})
    for n in sorted(set(trg_a) - set(trg_b)):
        diffs.append({"code": "trigger_removed", "trigger": trg_a[n]["name"]})
    for n in sorted(set(trg_a) & set(trg_b)):
        if trg_a[n]["sql"] != trg_b[n]["sql"]:
            diffs.append({"code": "trigger_changed", "trigger": trg_a[n]["name"]})
    return {"status": "different" if diffs else "equal", "differences": diffs}


def _unsupported_objects(conn_a, conn_b):
    def collect(conn):
        out = {}
        for name, typ, sql in conn.execute(
            "SELECT name, type, sql FROM sqlite_master"
        ):
            if typ == "view":
                out[name.lower()] = ("view", name)
            elif typ == "table" and (sql or "").upper().lstrip().startswith(
                "CREATE VIRTUAL"
            ):
                out[name.lower()] = ("virtual_table", name)
        return out

    a, b = collect(conn_a), collect(conn_b)
    out = []
    for key in sorted(set(a) | set(b)):
        kind, disp = a.get(key) or b.get(key)
        side = "both" if key in a and key in b else ("a" if key in a else "b")
        out.append({"name": disp, "kind": kind, "side": side})
    return out


# --- row comparison ---------------------------------------------------------

def _resolve_key(explicit_key, columns_a, columns_b, table):
    lower_a = {c["name"].lower(): c["name"] for c in columns_a}
    lower_b = {c["name"].lower(): c["name"] for c in columns_b}
    if explicit_key is not None:
        key_a = []
        for k in explicit_key:
            if k.lower() not in lower_a or k.lower() not in lower_b:
                raise KeyRefused("unknown_key_column", table)
            key_a.append(lower_a[k.lower()])
        return key_a
    pk_a = [c["name"] for c in sorted(
        (c for c in columns_a if c["pk"] > 0), key=lambda c: c["pk"])]
    pk_b = [c["name"] for c in sorted(
        (c for c in columns_b if c["pk"] > 0), key=lambda c: c["pk"])]
    if not pk_a or not pk_b:
        raise KeyRefused("no_stable_identity", table)
    if [n.lower() for n in pk_a] != [n.lower() for n in pk_b]:
        raise KeyRefused("identity_mismatch", table)
    return pk_a


def _read_rows(conn, table, columns, key_cols, limits):
    limits.check(table)
    names = [c["name"] for c in columns]
    idx = {n.lower(): i for i, n in enumerate(names)}
    key_idx = [idx[k.lower()] for k in key_cols]
    qcols = ", ".join(quote_ident(n) for n in names)
    cur = conn.execute(f"SELECT {qcols} FROM {quote_ident(table)}")
    rows = {}
    count = 0
    while True:
        limits.check(table)
        chunk = cur.fetchmany(_CHUNK)
        if not chunk:
            break
        for r in chunk:
            count += 1
            if (limits.max_rows_per_table is not None
                    and count > limits.max_rows_per_table):
                raise BudgetExceeded("max_rows", table)
            key_vals = [r[i] for i in key_idx]
            if any(v is None for v in key_vals):
                raise KeyRefused("nullable_key", table)
            d = _key_digest(table, key_vals)
            if d in rows:
                raise KeyRefused("duplicate_key", table)
            rows[d] = r
    return rows


def _value_equal(a, b):
    ta, tb = type_code(a), type_code(b)
    if ta != tb:
        return False
    if ta == TYPE_REAL:
        return struct.pack(">d", a) == struct.pack(">d", b)
    return a == b


def _compare_rows(conn_a, conn_b, table, explicit_key, limits,
                  columns_a, columns_b):
    key_cols = _resolve_key(explicit_key, columns_a, columns_b, table)
    set_a = {c["name"].lower() for c in columns_a}
    set_b = {c["name"].lower() for c in columns_b}
    if set_a != set_b:
        return {"status": "not_compared", "reason": "column_set_differs",
                "added": [], "deleted": [], "changed": []}
    rows_a = _read_rows(conn_a, table, columns_a, key_cols, limits)
    rows_b = _read_rows(conn_b, table, columns_b, key_cols, limits)
    idx_a = {c["name"].lower(): i for i, c in enumerate(columns_a)}
    idx_b = {c["name"].lower(): i for i, c in enumerate(columns_b)}
    common = sorted(set(idx_a) & set(idx_b))
    digests_a = set(rows_a)
    digests_b = set(rows_b)
    added = sorted(_opaque_row_id(d) for d in digests_b - digests_a)
    deleted = sorted(_opaque_row_id(d) for d in digests_a - digests_b)
    changed = []
    for d in sorted(digests_a & digests_b):
        ra, rb = rows_a[d], rows_b[d]
        for n in common:
            va, vb = ra[idx_a[n]], rb[idx_b[n]]
            ta, tb = type_code(va), type_code(vb)
            if ta != tb:
                changed.append({"row": _opaque_row_id(d),
                                "column": _display(columns_b, n),
                                "code": "type_changed",
                                "old_type": ta, "new_type": tb})
            elif not _value_equal(va, vb):
                changed.append({"row": _opaque_row_id(d),
                                "column": _display(columns_b, n),
                                "code": "value_changed",
                                "old_type": ta, "new_type": tb})
    changed.sort(key=lambda e: (e["row"], e["column"]))
    has_diff = bool(added or deleted or changed)
    return {"status": "different" if has_diff else "equal",
            "added": added, "deleted": deleted, "changed": changed}


_EMPTY_ROWS = {"status": "not_compared", "reason": None,
               "added": [], "deleted": [], "changed": []}


# --- top level --------------------------------------------------------------

def compare_databases(conn_a, conn_b, tables, keys, limits):
    """Compare the selected tables; return the deterministic result dict."""
    selections = {
        "tables": sorted(tables),
        "keys": {t: list(keys.get(t, [])) for t in sorted(tables)},
    }
    schema_tables = []
    rows_out = {}
    triggered = None
    any_unsupported = False
    try:
        for table in sorted(tables):
            limits.check(table)
            sc = _compare_schema(conn_a, conn_b, table)
            schema_tables.append({"table": table, "status": sc["status"],
                                  "differences": sc["differences"]})
            cols_a = _table_columns(conn_a, table)
            cols_b = _table_columns(conn_b, table)
            key_spec = keys.get(table)
            if sc["status"] == "equal":
                rows_out[table] = _compare_rows(
                    conn_a, conn_b, table, key_spec, limits, cols_a, cols_b)
            elif sc["status"] == "different":
                if ({c["name"].lower() for c in cols_a}
                        == {c["name"].lower() for c in cols_b}):
                    rows_out[table] = _compare_rows(
                        conn_a, conn_b, table, key_spec, limits,
                        cols_a, cols_b)
                else:
                    not_compared = dict(_EMPTY_ROWS)
                    not_compared["reason"] = "column_set_differs"
                    rows_out[table] = not_compared
            else:
                not_compared = dict(_EMPTY_ROWS)
                not_compared["reason"] = sc["status"]
                rows_out[table] = not_compared
                if sc["status"] == "unsupported":
                    any_unsupported = True
    except BudgetExceeded as exc:
        triggered = {"code": exc.code, "table": exc.table}

    schema_diff = any(
        t["status"] in ("different", "a_only", "b_only") for t in schema_tables
    )
    rows_diff = any(
        r["status"] == "different" or r["added"] or r["deleted"] or r["changed"]
        for r in rows_out.values()
    )
    if triggered is not None or any_unsupported:
        result = "limited"
    elif schema_diff or rows_diff:
        result = "different"
    else:
        result = "equal"
    return {
        "tool": "sqlite-state-diff",
        "schema_version": 1,
        "result": result,
        "selections": selections,
        "schema": {"tables": schema_tables,
                   "unsupported": _unsupported_objects(conn_a, conn_b)},
        "rows": rows_out,
        "limits": {
            "max_rows_per_table": limits.max_rows_per_table,
            "time_budget_seconds": limits.time_budget_seconds,
            "triggered": triggered,
        },
    }
