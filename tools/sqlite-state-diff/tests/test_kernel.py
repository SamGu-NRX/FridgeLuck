"""Literal tests for the comparison kernel.

Every expected difference below is written out exactly (column, code, old
type, new type, counts) from the fixture definitions — never derived by
running the tool twice and trusting agreement.
"""

import json
import math
import sqlite3

import pytest

from sqlite_state_diff import kernel, readers


def build(path, statements):
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(str(path))
    for statement in statements:
        conn.execute(statement)
    conn.commit()
    conn.close()


def compare(tmp_path, side_a, side_b, tables, keys=None, limits=None):
    """side_* = list of SQL statements (schema DDL + row DML)."""
    pa = tmp_path / "a.sqlite"
    pb = tmp_path / "b.sqlite"
    build(pa, side_a)
    build(pb, side_b)
    ca = readers.open_database_ro(str(pa))
    cb = readers.open_database_ro(str(pb))
    try:
        return kernel.compare_databases(ca, cb, tables, keys or {},
                                        limits or kernel.Limits())
    finally:
        ca.close()
        cb.close()


T = "CREATE TABLE t (id INTEGER PRIMARY KEY, v)"


def test_equal_databases(tmp_path):
    rows = ["INSERT INTO t VALUES (1, 10)", "INSERT INTO t VALUES (2, NULL)",
            "INSERT INTO t VALUES (3, X'01')"]
    result = compare(tmp_path, [T] + rows, [T] + rows, ["t"])
    assert result["result"] == "equal"
    assert result["rows"]["t"]["status"] == "equal"
    assert result["rows"]["t"]["added"] == []
    assert result["rows"]["t"]["deleted"] == []
    assert result["rows"]["t"]["changed"] == []


def test_row_order_is_not_identity(tmp_path):
    rows = ["INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')",
            "INSERT INTO t VALUES (3, 'c')"]
    reordered = [rows[2], rows[0], rows[1]]
    result = compare(tmp_path, [T] + rows, [T] + reordered, ["t"])
    assert result["result"] == "equal"


def test_integer_versus_text_same_numeral(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, 7)"],
                     [T, "INSERT INTO t VALUES (1, '7')"], ["t"])
    assert result["result"] == "different"
    assert result["rows"]["t"]["changed"] == [
        {"row": result["rows"]["t"]["changed"][0]["row"],
         "column": "v", "code": "type_changed",
         "old_type": "integer", "new_type": "text"}]


def test_integer_versus_real_numerically_equal(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, 1)"],
                     [T, "INSERT INTO t VALUES (1, 1.0)"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"],
            changed[0]["old_type"], changed[0]["new_type"]) == (
        "v", "type_changed", "integer", "real")


def test_null_versus_zero(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, NULL)"],
                     [T, "INSERT INTO t VALUES (1, 0)"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"],
            changed[0]["old_type"], changed[0]["new_type"]) == (
        "v", "type_changed", "null", "integer")


def test_blob_length_change(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, X'01')"],
                     [T, "INSERT INTO t VALUES (1, X'0100')"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"],
            changed[0]["old_type"], changed[0]["new_type"]) == (
        "v", "value_changed", "blob", "blob")


def test_blob_versus_text_same_bytes(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, X'414243')"],
                     [T, "INSERT INTO t VALUES (1, 'ABC')"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"],
            changed[0]["old_type"], changed[0]["new_type"]) == (
        "v", "type_changed", "blob", "text")


def test_one_ulp_real_difference(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, 2.5)"],
                     [T, f"INSERT INTO t VALUES (1, {repr(math.nextafter(2.5, math.inf))})"],
                     ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"],
            changed[0]["old_type"], changed[0]["new_type"]) == (
        "v", "value_changed", "real", "real")


def test_bit_equal_reals_are_equal(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, 2.5)"],
                     [T, "INSERT INTO t VALUES (1, 2.5)"], ["t"])
    assert result["result"] == "equal"


def test_negative_zero_versus_zero_real(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, -0.0)"],
                     [T, "INSERT INTO t VALUES (1, 0.0)"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["code"], changed[0]["old_type"],
            changed[0]["new_type"]) == ("value_changed", "real", "real")


def test_large_integers_exact(tmp_path):
    big = 2 ** 62
    result = compare(tmp_path, [T, f"INSERT INTO t VALUES (1, {big})"],
                     [T, f"INSERT INTO t VALUES (1, {big + 1})"], ["t"])
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["code"], changed[0]["old_type"],
            changed[0]["new_type"]) == ("value_changed", "integer", "integer")


def test_added_and_deleted_direction(tmp_path):
    side_a = [T, "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')"]
    side_b = [T, "INSERT INTO t VALUES (2, 'b')", "INSERT INTO t VALUES (3, 'c')"]
    result = compare(tmp_path, side_a, side_b, ["t"])
    assert len(result["rows"]["t"]["added"]) == 1      # b-only
    assert len(result["rows"]["t"]["deleted"]) == 1    # a-only
    assert result["rows"]["t"]["added"][0] != result["rows"]["t"]["deleted"][0]


def test_schema_only_index_difference(tmp_path):
    rows = ["INSERT INTO t VALUES (1, 'a')"]
    side_b = [T, "CREATE INDEX idx_t_v ON t(v)"] + rows
    result = compare(tmp_path, [T] + rows, side_b, ["t"])
    assert result["result"] == "different"
    assert result["schema"]["tables"][0]["differences"] == [
        {"code": "index_added", "index": "idx_t_v"}]
    assert result["rows"]["t"]["added"] == []
    assert result["rows"]["t"]["deleted"] == []
    assert result["rows"]["t"]["changed"] == []


def test_foreign_key_structure_difference(tmp_path):
    fa = ("CREATE TABLE p (id INTEGER PRIMARY KEY)",
          "CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id), x INTEGER)")
    fb = ("CREATE TABLE p (id INTEGER PRIMARY KEY)",
          "CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER, x INTEGER)")
    result = compare(tmp_path, list(fa), list(fb), ["c"])
    codes = {d["code"] for d in result["schema"]["tables"][0]["differences"]}
    assert codes == {"foreign_key_removed"}
    assert result["result"] == "different"


def test_column_constraint_difference_still_compares_rows(tmp_path):
    sa = ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)",
          "INSERT INTO t VALUES (1, 'a')"]
    sb = ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)",
          "INSERT INTO t VALUES (1, 'a')"]
    result = compare(tmp_path, sa, sb, ["t"])
    assert result["schema"]["tables"][0]["differences"] == [
        {"code": "column_changed", "column": "v", "field": "notnull"}]
    assert result["rows"]["t"]["status"] == "equal"
    assert result["result"] == "different"


def test_column_set_difference_blocks_row_comparison(tmp_path):
    sa = [T, "INSERT INTO t VALUES (1, 'a')"]
    sb = ["CREATE TABLE t (id INTEGER PRIMARY KEY, v, w)",
          "INSERT INTO t VALUES (1, 'a', 'b')"]
    result = compare(tmp_path, sa, sb, ["t"])
    assert result["rows"]["t"]["status"] == "not_compared"
    assert result["rows"]["t"]["reason"] == "column_set_differs"
    assert result["result"] == "different"


def test_composite_key_matched_cell_change(tmp_path):
    s = ("CREATE TABLE c (food_id INTEGER, day TEXT, grams INTEGER, "
         "PRIMARY KEY (food_id, day))")
    ra = ["INSERT INTO c VALUES (1, 'mon', 30)", "INSERT INTO c VALUES (1, 'tue', 45)"]
    rb = ["INSERT INTO c VALUES (1, 'mon', 31)", "INSERT INTO c VALUES (1, 'tue', 45)"]
    result = compare(tmp_path, [s] + ra, [s] + rb, ["c"])
    changed = result["rows"]["c"]["changed"]
    assert len(changed) == 1
    assert (changed[0]["column"], changed[0]["code"]) == ("grams", "value_changed")
    assert changed[0]["old_type"] == "integer"


def test_no_pk_and_no_key_refuses(tmp_path):
    s = "CREATE TABLE t (a TEXT, b INTEGER)"
    r = ["INSERT INTO t VALUES ('x', 1)"]
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, [s] + r, [s] + r, ["t"])
    assert caught.value.code == "no_stable_identity"


def test_explicit_key_on_keyless_table(tmp_path):
    s = "CREATE TABLE t (a TEXT, b INTEGER, v TEXT)"
    ra = ["INSERT INTO t VALUES ('k1', 1, 'x')", "INSERT INTO t VALUES ('k2', 2, 'y')"]
    rb = ["INSERT INTO t VALUES ('k1', 1, 'x')", "INSERT INTO t VALUES ('k2', 2, 'z')"]
    result = compare(tmp_path, [s] + ra, [s] + rb, ["t"], keys={"t": ["a"]})
    changed = result["rows"]["t"]["changed"]
    assert len(changed) == 1
    assert changed[0]["column"] == "v"


def test_unknown_key_column_refuses(tmp_path):
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, [T], [T], ["t"], keys={"t": ["nope"]})
    assert caught.value.code == "unknown_key_column"


def test_pk_mismatch_without_explicit_key_refuses(tmp_path):
    sa = ["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)"]
    sb = ["CREATE TABLE t (id INTEGER, v TEXT PRIMARY KEY)"]
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, sa, sb, ["t"])
    assert caught.value.code == "identity_mismatch"


def test_nullable_pk_data_refuses_but_explicit_key_saves_it(tmp_path):
    s = "CREATE TABLE t (a TEXT PRIMARY KEY, v INTEGER)"
    ra = ["INSERT INTO t VALUES (NULL, 1)", "INSERT INTO t VALUES ('k', 2)"]
    rb = ["INSERT INTO t VALUES (NULL, 1)", "INSERT INTO t VALUES ('k', 2)"]
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, [s] + ra, [s] + rb, ["t"])
    assert caught.value.code == "nullable_key"
    result = compare(tmp_path, [s] + ra, [s] + rb, ["t"],
                     keys={"t": ["v"]})
    assert result["result"] == "equal"


def test_duplicate_key_data_refuses(tmp_path):
    # A declared PK enforces uniqueness at insert time, so duplicate key
    # values can only arise on a keyless table compared with an explicit key.
    s = "CREATE TABLE t (a TEXT, v INTEGER)"
    r = ["INSERT INTO t VALUES ('k', 1)", "INSERT INTO t VALUES ('k', 2)"]
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, [s] + r, [s] + r, ["t"], keys={"t": ["a"]})
    assert caught.value.code == "duplicate_key"


def test_virtual_table_selected_is_limited_not_equal(tmp_path):
    s = ["CREATE TABLE t (id INTEGER PRIMARY KEY, v)", "INSERT INTO t VALUES (1, 'x')"]
    v = ["CREATE VIRTUAL TABLE vt USING fts5(x)"]  # module never invoked by the tool
    result = compare(tmp_path, s + v, s + v, ["t", "vt"])
    assert result["result"] == "limited"
    assert result["schema"]["tables"][1]["status"] == "unsupported"
    assert result["rows"]["vt"]["reason"] == "unsupported"
    assert result["schema"]["tables"][0]["status"] == "equal"


def test_selected_view_refuses(tmp_path):
    s = [T, "CREATE VIEW vv AS SELECT * FROM t"]
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, s, s, ["vv"])
    assert caught.value.code == "not_a_table"


def test_table_on_neither_side_refuses(tmp_path):
    with pytest.raises(kernel.KeyRefused) as caught:
        compare(tmp_path, [T], [T], ["ghost"])
    assert caught.value.code == "no_such_table"


def test_table_on_one_side_only_is_different(tmp_path):
    result = compare(tmp_path, [T], [T, "CREATE TABLE u (id INTEGER PRIMARY KEY)"],
                     ["t", "u"])
    by_name = {t["table"]: t for t in result["schema"]["tables"]}
    assert by_name["u"]["status"] == "b_only"
    assert by_name["u"]["differences"] == [{"code": "table_b_only"}]
    assert result["result"] == "different"


def test_row_limit_breach_is_limited(tmp_path):
    rows = [f"INSERT INTO t VALUES ({i}, 'x')" for i in range(1, 6)]
    result = compare(tmp_path, [T] + rows, [T] + rows, ["t"],
                     limits=kernel.Limits(max_rows_per_table=2))
    assert result["result"] == "limited"
    assert result["limits"]["triggered"] == {"code": "max_rows", "table": "t"}


def test_time_budget_zero_is_limited(tmp_path):
    result = compare(tmp_path, [T, "INSERT INTO t VALUES (1, 'x')"],
                     [T, "INSERT INTO t VALUES (1, 'x')"], ["t"],
                     limits=kernel.Limits(time_budget_seconds=0.0))
    assert result["result"] == "limited"
    assert result["limits"]["triggered"]["code"] == "time_budget"


def test_output_never_contains_raw_values(tmp_path):
    side = [T, "INSERT INTO t VALUES (1, 'secret-snack-42')"]
    result = compare(tmp_path, side, side, ["t"])
    rendered = json.dumps(result)
    assert "secret-snack-42" not in rendered
    assert result["result"] == "equal"


def test_row_identity_stable_and_distinct(tmp_path):
    rows_a = [T, "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')"]
    rows_b = [T, "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (3, 'c')"]
    result = compare(tmp_path, rows_a, rows_b, ["t"])
    added = result["rows"]["t"]["added"][0]
    deleted = result["rows"]["t"]["deleted"][0]
    assert added.startswith("r") and len(added) == 17
    assert deleted.startswith("r") and len(deleted) == 17
    assert added != deleted
    # row 1 is unchanged in both comparisons: same stable identity
    again = compare(tmp_path, rows_a, [T, "INSERT INTO t VALUES (1, 'a')",
                                       "INSERT INTO t VALUES (9, 'z')"], ["t"])
    assert again["rows"]["t"]["deleted"][0] == deleted
