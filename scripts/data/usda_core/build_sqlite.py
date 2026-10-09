"""Build the bundled USDA ingredient SQLite database from the canonical JSON catalog.

Role in the pipeline
--------------------
This is the final build stage of FridgeLuck's USDA ingredient pipeline. The
``usda build-sqlite`` typer command (``scripts/data/usda.py``,
``cmd_build_sqlite``) loads the canonical catalog
(``scripts/data/catalog/usda_curated_ingredients.json``, maintained by
``promote.py``) and passes the parsed :class:`~usda_core.schema.CanonicalCatalog`
to :func:`build_sqlite`, which writes the single-file database the iOS app
bundles as ``apps/ios/Resources/usda_ingredient_catalog.sqlite``.

One file, two schemas
---------------------
Every catalog row is inserted into BOTH schemas:

* ``ingredient_catalog`` -- the v2 schema (rich provenance, ``search_text``,
  ``alt_names_json``). No Swift code reads this table yet; it exists so a
  future app migration can switch to it without another pipeline format change.
* ``ingredients`` + ``ingredient_aliases`` -- the legacy schema the app
  consumes today (see ``apps/ios/Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift``,
  which imports these tables read-only into the app's runtime database, and
  ``apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift``,
  which queries the runtime copies).

Invariants
----------
* Rows are written in ascending ``fdc_id`` order, so ``ingredient_catalog.id``
  is a stable surrogate (1..N in ``fdc_id`` order) while ``ingredients.id``
  equals the row's ``fdc_id`` (aliases reference it via ``ingredient_id``).
* ``ingredients.name`` is the raw ``display_name``; the v2 table additionally
  stores a lowercased ``normalized_name``.
* Macros are copied verbatim from the catalog -- this module never recomputes
  them (macros are frozen per ``fdc_id`` at promote time).
* The build is deterministic: the same catalog produces a byte-identical
  database file.
"""

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
    """Write ``catalog`` to ``out_path`` as the bundled ingredient SQLite database.

    The build is atomic from a reader's point of view: the database is fully
    constructed in a temporary file next to ``out_path`` and then moved into
    place with :func:`os.replace`, so ``out_path`` is either the previous file
    or the complete new one, never a half-written database.

    Args:
        catalog: A validated canonical catalog. Rows are written in ascending
            ``fdc_id`` order regardless of the order of ``catalog.records``.
        out_path: Destination file. Parent directories are created if missing;
            an existing file at this path is silently replaced.

    Side effects:
        Creates ``str(out_path) + ".lock"`` and holds an exclusive
        :class:`filelock.FileLock` on it for the duration of the build, so two
        concurrent invocations targeting the same ``out_path`` are serialized.
        The lock file is unlinked after release (best effort; ``OSError`` is
        ignored). If the build fails, the temporary file is removed and
        ``out_path`` is left untouched.

    Raises:
        sqlite3.Error: If the embedded SQL fails (e.g. a duplicate ``fdc_id``
            in the catalog violates the ``UNIQUE`` constraint).
        OSError: If the destination directory cannot be created or written.

    Example -- build a one-row catalog and inspect the resulting tables:

    >>> import sqlite3
    >>> import tempfile
    >>> from pathlib import Path
    >>> from usda_core.build_sqlite import build_sqlite
    >>> from usda_core.schema import CanonicalCatalog, CuratedIngredientRow, MacroSet, SourceMeta
    >>> catalog = CanonicalCatalog(
    ...     generated_at_utc="2026-01-01T00:00:00Z",
    ...     records=[
    ...         CuratedIngredientRow(
    ...             fdc_id=170211,
    ...             display_name="Milk",
    ...             category_label="dairy_egg",
    ...             alt_names=["Whole Milk"],
    ...             macros=MacroSet(calories=42.0),
    ...             source_meta=SourceMeta(),
    ...         )
    ...     ],
    ... )
    >>> with tempfile.TemporaryDirectory() as tmp:
    ...     out = Path(tmp) / "catalog.sqlite"
    ...     build_sqlite(catalog, out)
    ...     conn = sqlite3.connect(str(out))
    ...     tables = sorted(
    ...         name
    ...         for (name,) in conn.execute(
    ...             "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ...         )
    ...     )
    ...     legacy_ids = [list(row) for row in conn.execute("SELECT id FROM ingredients ORDER BY id")]
    ...     aliases = [list(row) for row in conn.execute("SELECT ingredient_id, alias FROM ingredient_aliases")]
    ...     conn.close()
    >>> tables
    ['ingredient_aliases', 'ingredient_catalog', 'ingredients']
    >>> legacy_ids
    [[170211]]
    >>> aliases
    [[170211, 'whole milk']]
    """
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
    """Create a fresh SQLite file at ``out_path`` holding all three ingredient tables.

    Called by :func:`build_sqlite` on the temporary path; the caller owns the
    atomic swap. ``out_path`` must not already be a populated database -- the
    three tables are created with plain ``CREATE TABLE`` (no ``IF NOT EXISTS``),
    so calling this twice on the same path raises ``sqlite3.OperationalError``.

    Per-row mapping, applied to every record in ``catalog`` sorted by ascending
    ``fdc_id``:

    * ``ingredient_catalog`` (v2) gets ``normalized_name`` defined inline as
      ``display_name.strip().lower()`` -- deliberately simpler than
      :func:`usda_core.utils.canonical`, so underscores and punctuation survive
      (``"Fuji_Apple"`` stays ``"fuji_apple"`` instead of becoming ``"fuji
      apple"``).
    * ``sprite_group`` is backfilled locally (never written back into
      ``catalog``) when empty or ``"other"`` and the ``category_label`` is not
      ``"other"`` -- the same rule ``promote.py`` applies when the row enters
      the canonical JSON; this rebuild-time pass is a safety net for rows that
      predate it. See :func:`usda_core.sprite_rules.infer_sprite_group`.
    * ``ingredients.notes`` is synthesized as
      ``"source=<data_type>; food_category=<food_category>; verified=<verified_at_utc>; source_system=<verification_source>"``
      and ``typical_unit``/``storage_tip``/``pairs_with`` are left ``NULL``
      (the pipeline never populates them).
    * ``alt_names`` reach this module already canonicalized: the
      ``CuratedIngredientRow`` validator runs them through
      :func:`usda_core.utils.dedupe_keep_order`, which lowercases, strips
      punctuation, and dedupes. The alias insert's ``.lower()`` and ``INSERT
      OR IGNORE`` are therefore defensive no-ops for validated catalogs.
      Aliases go only into ``ingredient_aliases``; the v2 table carries the
      same list as ``alt_names_json`` (``json.dumps`` with
      ``ensure_ascii=True``).

    Args:
        catalog: A validated canonical catalog.
        out_path: Destination file, created from scratch.

    Side effects:
        Creates and closes a SQLite connection; commits once at the end.

    Raises:
        sqlite3.Error: On any SQL failure, including duplicate ``fdc_id``
            (``UNIQUE`` on ``ingredient_catalog.fdc_id`` and the implicit
            ``ingredients`` rowid conflict).
    """
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
