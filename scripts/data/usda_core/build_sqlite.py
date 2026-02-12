from __future__ import annotations

import json
import os
import sqlite3
import tempfile
from pathlib import Path

from filelock import FileLock

from .schema import CanonicalCatalog, row_to_search_text
from .sprite_rules import infer_sprite_group


def build_sqlite(catalog: CanonicalCatalog, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(str(out_path) + ".lock")
    lock = FileLock(str(lock_path))
    with lock:
        with tempfile.NamedTemporaryFile(dir=str(out_path.parent), delete=False, suffix=".sqlite") as tmp:
            temp_path = Path(tmp.name)
        try:
            _build_sqlite_file(catalog, temp_path)
            os.replace(temp_path, out_path)
        finally:
            if temp_path.exists():
                temp_path.unlink()
    if lock_path.exists():
        try:
            lock_path.unlink()
        except OSError:
            pass


def _build_sqlite_file(catalog: CanonicalCatalog, out_path: Path) -> None:
    conn = sqlite3.connect(str(out_path))
    try:
        conn.execute(
            """
            CREATE TABLE ingredient_catalog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fdc_id INTEGER NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                category_label TEXT NOT NULL,
                sprite_group TEXT NOT NULL,
                sprite_key TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                alt_names_json TEXT NOT NULL DEFAULT '[]',
                source_description TEXT NOT NULL,
                data_type TEXT NOT NULL,
                food_category TEXT NOT NULL,
                verification_source TEXT NOT NULL,
                verified_at_utc TEXT NOT NULL,
                search_text TEXT NOT NULL,
                calories REAL NOT NULL,
                protein REAL NOT NULL,
                carbs REAL NOT NULL,
                fat REAL NOT NULL,
                fiber REAL NOT NULL,
                sugar REAL NOT NULL,
                sodium REAL NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX idx_catalog_display_name ON ingredient_catalog(display_name)")
        conn.execute("CREATE INDEX idx_catalog_category ON ingredient_catalog(category_label)")
        conn.execute("CREATE INDEX idx_catalog_search ON ingredient_catalog(search_text)")

        conn.execute(
            """
            CREATE TABLE ingredients (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                calories REAL NOT NULL,
                protein REAL NOT NULL,
                carbs REAL NOT NULL,
                fat REAL NOT NULL,
                fiber REAL NOT NULL,
                sugar REAL NOT NULL,
                sodium REAL NOT NULL,
                typical_unit TEXT,
                storage_tip TEXT,
                pairs_with TEXT,
                notes TEXT,
                description TEXT,
                category_label TEXT,
                sprite_group TEXT,
                sprite_key TEXT
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE ingredient_aliases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ingredient_id INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
                alias TEXT NOT NULL,
                UNIQUE(ingredient_id, alias)
            )
            """
        )
        conn.execute("CREATE INDEX idx_ingredient_aliases_alias ON ingredient_aliases(alias)")

        for row in sorted(catalog.records, key=lambda item: item.fdc_id):
            normalized_name = row.display_name.strip().lower()
            search_text = row_to_search_text(row)
            sprite_group = row.sprite_group
            if (not sprite_group or sprite_group == "other") and row.category_label != "other":
                sprite_group = infer_sprite_group(row.category_label)
            notes = (
                f"source={row.source_meta.data_type}; food_category={row.source_meta.food_category}; "
                f"verified={row.source_meta.verified_at_utc}; source_system={row.source_meta.verification_source}"
            )
            conn.execute(
                """
                INSERT INTO ingredient_catalog (
                    fdc_id, display_name, normalized_name, category_label, sprite_group, sprite_key,
                    description, alt_names_json, source_description, data_type, food_category,
                    verification_source, verified_at_utc, search_text,
                    calories, protein, carbs, fat, fiber, sugar, sodium
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    row.fdc_id,
                    row.display_name,
                    normalized_name,
                    row.category_label,
                    sprite_group,
                    row.sprite_key,
                    row.description,
                    json.dumps(row.alt_names, ensure_ascii=True),
                    row.source_description,
                    row.source_meta.data_type,
                    row.source_meta.food_category,
                    row.source_meta.verification_source,
                    row.source_meta.verified_at_utc,
                    search_text,
                    row.macros.calories,
                    row.macros.protein_g,
                    row.macros.carbs_g,
                    row.macros.fat_g,
                    row.macros.fiber_g,
                    row.macros.sugar_g,
                    row.macros.sodium_g,
                ],
            )
            conn.execute(
                """
                INSERT INTO ingredients (
                    id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                    typical_unit, storage_tip, pairs_with, notes,
                    description, category_label, sprite_group, sprite_key
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, ?)
                """,
                [
                    row.fdc_id,
                    row.display_name,
                    row.macros.calories,
                    row.macros.protein_g,
                    row.macros.carbs_g,
                    row.macros.fat_g,
                    row.macros.fiber_g,
                    row.macros.sugar_g,
                    row.macros.sodium_g,
                    notes,
                    row.description,
                    row.category_label,
                    sprite_group,
                    row.sprite_key,
                ],
            )
            for alias in row.alt_names:
                conn.execute(
                    "INSERT OR IGNORE INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
                    [row.fdc_id, alias.lower()],
                )

        conn.commit()
    finally:
        conn.close()
