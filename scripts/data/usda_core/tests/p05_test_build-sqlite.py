"""Tests for usda_core.build_sqlite (documentation fleet part p05).

All tests are offline and deterministic: they build tiny in-memory catalogs
and inspect the SQLite file that ``build_sqlite`` / ``_build_sqlite_file``
write into ``tmp_path``. No network, no wall-clock time, no iteration-order
assumptions (sets are compared via sorted()).
"""

from __future__ import annotations

import hashlib
import json
import sqlite3

import pytest

from usda_core.build_sqlite import _build_sqlite_file, build_sqlite
from usda_core.schema import (
    CanonicalCatalog,
    CuratedIngredientRow,
    MacroSet,
    SourceMeta,
    row_to_search_text,
)
from usda_core.sprite_rules import infer_sprite_group

GENERATED_AT = "2026-01-01T00:00:00Z"


def _row(fdc_id: int, display_name: str, **overrides: object) -> CuratedIngredientRow:
    params: dict[str, object] = {
        "fdc_id": fdc_id,
        "display_name": display_name,
        "category_label": "other",
        "source_meta": SourceMeta(),
        "macros": MacroSet(),
    }
    params.update(overrides)
    return CuratedIngredientRow(**params)


def _catalog(*rows: CuratedIngredientRow) -> CanonicalCatalog:
    return CanonicalCatalog(generated_at_utc=GENERATED_AT, records=list(rows))


def _build(catalog: CanonicalCatalog, out_path) -> sqlite3.Connection:
    build_sqlite(catalog, out_path)
    return sqlite3.connect(str(out_path))


def _scalar(conn: sqlite3.Connection, sql: str) -> object:
    return conn.execute(sql).fetchone()[0]


def test_both_schemas_populated(tmp_path):
    out = tmp_path / "catalog.sqlite"
    conn = _build(
        _catalog(
            _row(170211, "Milk", category_label="dairy_egg"),
            _row(900123, "Fuji Apple", category_label="fruit"),
        ),
        out,
    )
    try:
        tables = sorted(
            name
            for (name,) in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
        )
        assert tables == ["ingredient_aliases", "ingredient_catalog", "ingredients"]
        assert _scalar(conn, "SELECT COUNT(*) FROM ingredient_catalog") == 2
        assert _scalar(conn, "SELECT COUNT(*) FROM ingredients") == 2
        # ingredients.id IS the fdc_id; ingredient_catalog keeps its own surrogate id.
        assert conn.execute("SELECT id, name FROM ingredients ORDER BY id").fetchall() == [
            (170211, "Milk"),
            (900123, "Fuji Apple"),
        ]
        assert {fdc for (fdc,) in conn.execute("SELECT fdc_id FROM ingredient_catalog")} == {
            170211,
            900123,
        }
    finally:
        conn.close()


def test_rows_written_in_fdc_id_order(tmp_path):
    out = tmp_path / "catalog.sqlite"
    conn = _build(
        _catalog(
            _row(900123, "Zucchini", category_label="vegetable"),
            _row(170211, "Milk", category_label="dairy_egg"),
            _row(500, "Yam", category_label="vegetable"),
        ),
        out,
    )
    try:
        # ingredient_catalog.id is a surrogate assigned in ascending fdc_id order.
        assert conn.execute(
            "SELECT id, fdc_id FROM ingredient_catalog ORDER BY id"
        ).fetchall() == [(1, 500), (2, 170211), (3, 900123)]
        # Rowid order equals physical insert order (fdc_id ascending). A bare
        # SELECT without ORDER BY is NOT deterministic here: SQLite may satisfy
        # `SELECT id` from the UNIQUE(name) covering index instead of the table.
        assert [row for row in conn.execute("SELECT id FROM ingredients ORDER BY rowid")] == [
            (500,),
            (170211,),
            (900123,),
        ]
    finally:
        conn.close()


def test_alias_rows_lowercased_and_deduped(tmp_path):
    out = tmp_path / "catalog.sqlite"
    conn = _build(
        _catalog(
            _row(1, "Milk", alt_names=["Milk", "MILK", "Cow Juice"]),
            _row(2, "Yam", alt_names=["Cow Juice"]),
        ),
        out,
    )
    try:
        # Case-collapsing happens upstream: the CuratedIngredientRow validator
        # canonicalizes alt_names (dedupe_keep_order), so "Milk"/"MILK" arrive
        # already deduped to "milk". The SQL-side INSERT OR IGNORE is defensive.
        # The same spelling on a different ingredient is kept.
        assert conn.execute(
            "SELECT alias FROM ingredient_aliases WHERE ingredient_id = 1 ORDER BY alias"
        ).fetchall() == [("cow juice",), ("milk",)]
        assert conn.execute(
            "SELECT alias FROM ingredient_aliases WHERE ingredient_id = 2"
        ).fetchall() == [("cow juice",)]
    finally:
        conn.close()


def test_sprite_group_backfilled_in_both_tables(tmp_path):
    out = tmp_path / "catalog.sqlite"
    catalog = _catalog(
        # "other" + a mappable category -> backfilled to the mapped group.
        _row(1, "Honey", category_label="sweetener_baking"),
        # Explicit non-"other" group -> preserved untouched.
        _row(2, "Strawberries", category_label="fruit", sprite_group="berries"),
        # Category "other" -> left as "other" (no backfill).
        _row(3, "Mystery Meal", category_label="other"),
    )
    conn = _build(catalog, out)
    try:
        expected_backfilled = infer_sprite_group("sweetener_baking")
        assert expected_backfilled == "sweetener"
        assert conn.execute(
            "SELECT sprite_group FROM ingredient_catalog WHERE fdc_id = 1"
        ).fetchone() == ("sweetener",)
        assert conn.execute(
            "SELECT sprite_group FROM ingredients WHERE id = 1"
        ).fetchone() == ("sweetener",)
        assert conn.execute(
            "SELECT sprite_group FROM ingredient_catalog WHERE fdc_id = 2"
        ).fetchone() == ("berries",)
        assert conn.execute(
            "SELECT sprite_group FROM ingredient_catalog WHERE fdc_id = 3"
        ).fetchone() == ("other",)
    finally:
        conn.close()
    # The backfill is a build-time safety net: the in-memory catalog is not mutated.
    assert catalog.records[0].sprite_group == "other"


def test_normalized_name_is_strip_lower_only(tmp_path):
    out = tmp_path / "catalog.sqlite"
    conn = _build(_catalog(_row(1, "Fuji_Apple")), out)
    try:
        # Underscores survive: build_sqlite uses display_name.strip().lower(),
        # NOT utils.canonical() (which would yield "fuji apple").
        assert conn.execute(
            "SELECT display_name, normalized_name FROM ingredient_catalog WHERE fdc_id = 1"
        ).fetchone() == ("Fuji_Apple", "fuji_apple")
    finally:
        conn.close()


def test_build_is_byte_deterministic(tmp_path):
    catalog = _catalog(
        _row(170211, "Milk", category_label="dairy_egg", alt_names=["Whole Milk"]),
        _row(900123, "Fuji Apple", category_label="fruit"),
    )
    first = tmp_path / "a.sqlite"
    second = tmp_path / "b.sqlite"
    build_sqlite(catalog, first)
    build_sqlite(catalog, second)
    assert (
        hashlib.sha256(first.read_bytes()).hexdigest()
        == hashlib.sha256(second.read_bytes()).hexdigest()
    )


def test_lock_and_temp_files_cleaned_up(tmp_path):
    out = tmp_path / "catalog.sqlite"
    conn = _build(_catalog(_row(1, "Milk")), out)
    conn.close()
    # Only the database remains: the <out>.lock file and the temp build file are gone.
    assert sorted(p.name for p in tmp_path.iterdir()) == ["catalog.sqlite"]


def test_notes_provenance_string(tmp_path):
    out = tmp_path / "catalog.sqlite"
    row = _row(
        1,
        "Milk",
        source_meta=SourceMeta(
            data_type="Foundation (SR Legacy)",
            food_category="Dairy and Egg Products",
            verified_at_utc=GENERATED_AT,
            verification_source="USDA FoodData Central API",
        ),
    )
    conn = _build(_catalog(row), out)
    try:
        assert conn.execute("SELECT notes FROM ingredients WHERE id = 1").fetchone() == (
            "source=Foundation (SR Legacy); food_category=Dairy and Egg Products; "
            f"verified={GENERATED_AT}; source_system=USDA FoodData Central API",
        )
        # The pipeline never populates these three legacy columns.
        assert conn.execute(
            "SELECT typical_unit, storage_tip, pairs_with FROM ingredients WHERE id = 1"
        ).fetchone() == (None, None, None)
    finally:
        conn.close()


def test_search_text_and_alt_names_json(tmp_path):
    out = tmp_path / "catalog.sqlite"
    row = _row(1, "Crème Fraîche", alt_names=["Double Cream"], description="Cultured cream")
    conn = _build(_catalog(row), out)
    try:
        assert conn.execute(
            "SELECT search_text FROM ingredient_catalog WHERE fdc_id = 1"
        ).fetchone() == (row_to_search_text(row),)
        raw_json = conn.execute(
            "SELECT alt_names_json FROM ingredient_catalog WHERE fdc_id = 1"
        ).fetchone()[0]
        # The schema layer canonicalized "Double Cream" to "double cream" before
        # build_sqlite ever saw it (dedupe_keep_order in the alt_names validator).
        assert raw_json == json.dumps(row.alt_names, ensure_ascii=True)
        assert raw_json == '["double cream"]'
        assert json.loads(raw_json) == ["double cream"]
    finally:
        conn.close()


def test_rebuild_into_existing_file_raises(tmp_path):
    path = tmp_path / "catalog.sqlite"
    _build_sqlite_file(_catalog(_row(1, "Milk")), path)
    with pytest.raises(sqlite3.OperationalError):
        _build_sqlite_file(_catalog(_row(2, "Yam")), path)


def test_existing_output_replaced(tmp_path):
    out = tmp_path / "catalog.sqlite"
    _build(_catalog(_row(1, "Milk")), out).close()
    conn = _build(_catalog(_row(2, "Yam", category_label="vegetable")), out)
    try:
        assert conn.execute("SELECT id, name FROM ingredients").fetchall() == [(2, "Yam")]
        assert _scalar(conn, "SELECT COUNT(*) FROM ingredient_catalog") == 1
    finally:
        conn.close()
