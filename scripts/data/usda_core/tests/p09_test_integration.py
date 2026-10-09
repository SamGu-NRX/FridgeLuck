"""Integration tests pinning how usda_core connects to the rest of the repository.

Companion to ``usda_core/.parts/p09-integration.md``; file:line references in
comments refer to base commit 1151588d6bc6f5dcc3e848b6115813ff36ffbf0d.

Pinned contracts:

- ``scripts/data/usda.py`` is the only importer of ``usda_core``; it registers
  exactly seven CLI commands whose path defaults come from ``usda_core.config``
  and are absolute (cwd-independent).
- The ``usda`` console script maps to ``usda:main`` and the distribution ships
  the ``usda_core*`` package (scripts/data/pyproject.toml:19-26).
- ``build-sqlite`` emits the ``ingredients`` / ``ingredient_aliases`` tables the
  iOS consumer reads at runtime
  (apps/ios/Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift),
  with lowercase aliases and exactly one row + alias set per canonical record.
- The review loop invariants: new candidates first in ``export-batch``;
  ``promote-batch`` freezes macros for existing fdc_ids, requires USDA
  provenance, and supports ``drop``.
- The legacy v1 scripts (``fetch_usda_ingredient_nutrition.py``,
  ``generate_usda_ingredient_swift_static.py``) run outside the v2 package and
  must not import ``usda_core``.
- ``USDA_FDC_API_KEY`` resolution order in ``usda._api_key``: ``--api-key``
  flag, then env var, else ``typer.BadParameter``.

All tests are offline and deterministic; writes go only to pytest tmp paths.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3
import tomllib
from contextlib import closing
from pathlib import Path

import pytest
import typer

import usda
from usda_core import config
from usda_core.batches import export_batch
from usda_core.build_sqlite import build_sqlite
from usda_core.io import load_canonical
from usda_core.promote import PromoteError, promote_batch
from usda_core.schema import (
    BatchPayload,
    BatchRow,
    CanonicalCatalog,
    CuratedIngredientRow,
    MacroSet,
    SourceMeta,
)

SCRIPTS_DATA_DIR = Path(__file__).resolve().parents[2]

LEGACY_SCRIPTS = (
    "fetch_usda_ingredient_nutrition.py",
    "generate_usda_ingredient_swift_static.py",
)

# Columns the primary SELECT reads from the bundled sqlite
# (apps/ios/Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift:20-36).
SWIFT_INGREDIENT_COLUMNS = frozenset(
    {
        "name",
        "calories",
        "protein",
        "carbs",
        "fat",
        "fiber",
        "sugar",
        "sodium",
        "notes",
        "description",
        "category_label",
        "sprite_group",
        "sprite_key",
    }
)


# ---------------------------------------------------------------------------
# CLI wiring (scripts/data/usda.py)
# ---------------------------------------------------------------------------


def test_usda_cli_registers_exactly_the_seven_documented_commands():
    names = {command.name for command in usda.app.registered_commands}
    assert names == {
        "bootstrap-canonical",
        "fetch-candidates",
        "export-batch",
        "promote-batch",
        "build-sqlite",
        "validate",
        "report",
    }
    assert callable(usda.main)


@pytest.mark.parametrize(
    ("function", "parameter", "expected"),
    [
        (usda.bootstrap_canonical, "canonical", config.CANONICAL_JSON),
        (usda.cmd_fetch_candidates, "out", config.CANDIDATE_DIR / "run_001.json"),
        (usda.cmd_fetch_candidates, "cache_db", config.CACHE_DB),
        (usda.cmd_export_batch, "canonical", config.CANONICAL_JSON),
        (usda.cmd_export_batch, "out", config.REVIEW_BATCH_DIR / "manual_batch_001.json"),
        (usda.cmd_promote_batch, "canonical", config.CANONICAL_JSON),
        (usda.cmd_build_sqlite, "canonical", config.CANONICAL_JSON),
        (usda.cmd_build_sqlite, "out", config.DEFAULT_SQLITE_OUT),
        (usda.cmd_validate, "canonical", config.CANONICAL_JSON),
        (usda.cmd_report, "canonical", config.CANONICAL_JSON),
        (usda.cmd_report, "out", config.DEFAULT_REPORT_OUT),
    ],
)
def test_cli_path_defaults_match_config_constants_and_are_absolute(
    function, parameter, expected
):
    """Every command's path default equals its usda_core.config constant.

    Guards the documented "defaults drift" failure mode: config.py anchors all
    paths at the repo root (config.py:5), so the defaults stay cwd-independent.
    The one known exception, ``bootstrap-canonical --from-clean`` (usda.py:55-57,
    a cwd-relative literal), is intentionally not listed here - see
    .parts/p09-integration.md, where it is flagged.
    """
    default = inspect.signature(function).parameters[parameter].default
    assert default == expected
    assert Path(default).is_absolute()


def test_load_queries_dedupes_case_insensitively_and_skips_comments(tmp_path):
    query_file = tmp_path / "queries.txt"
    query_file.write_text("# comment\n\n Olive Oil \nolive oil\n", encoding="utf-8")
    assert usda._load_queries(query_file=query_file, query=["tuna", "Tuna Salad"]) == [
        "tuna",
        "Tuna Salad",
        "Olive Oil",
    ]


def test_api_key_resolves_flag_then_env_then_bad_parameter(monkeypatch):
    monkeypatch.delenv("USDA_FDC_API_KEY", raising=False)
    assert usda._api_key("--flag-key") == "--flag-key"
    monkeypatch.setenv("USDA_FDC_API_KEY", " env-key ")
    assert usda._api_key(None) == "env-key"
    monkeypatch.delenv("USDA_FDC_API_KEY")
    with pytest.raises(typer.BadParameter, match="USDA_FDC_API_KEY"):
        usda._api_key(None)


# ---------------------------------------------------------------------------
# Packaging (scripts/data/pyproject.toml)
# ---------------------------------------------------------------------------


def test_pyproject_ships_usda_entry_point_and_usda_core_package():
    data = tomllib.loads((SCRIPTS_DATA_DIR / "pyproject.toml").read_text(encoding="utf-8"))
    assert data["project"]["scripts"]["usda"] == "usda:main"
    assert data["tool"]["setuptools"]["py-modules"] == ["usda"]
    assert data["tool"]["setuptools"]["packages"]["find"]["include"] == ["usda_core*"]


# ---------------------------------------------------------------------------
# build-sqlite output vs the iOS reader contract
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def canonical_catalog() -> CanonicalCatalog:
    return load_canonical(config.CANONICAL_JSON)


@pytest.fixture(scope="module")
def built_sqlite(tmp_path_factory, canonical_catalog) -> Path:
    out = tmp_path_factory.mktemp("p09") / "usda_ingredient_catalog.sqlite"
    build_sqlite(canonical_catalog, out)
    return out


def test_built_sqlite_contains_all_three_tables(built_sqlite):
    with closing(sqlite3.connect(f"file:{built_sqlite}?mode=ro", uri=True)) as conn:
        tables = {
            row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert {"ingredient_catalog", "ingredients", "ingredient_aliases"} <= tables


def test_built_ingredients_columns_cover_the_swift_select(built_sqlite):
    """The bundle's ingredients table has every column BundledDataLoaderUSDACatalog.swift:20-36 selects."""
    with closing(sqlite3.connect(f"file:{built_sqlite}?mode=ro", uri=True)) as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(ingredients)")}
    assert SWIFT_INGREDIENT_COLUMNS <= columns


def test_built_aliases_are_lowercase_and_join_on_ingredients_id(
    built_sqlite, canonical_catalog
):
    """Aliases must resolve through the same join Swift uses when hydrating.

    The builder stores aliases lowercased (build_sqlite.py:175-179) and Swift
    lowercases again on import (BundledDataLoaderUSDACatalog.swift:122), so no
    alias may differ from its lowercase form. The UNIQUE(ingredient_id, alias)
    constraint (build_sqlite.py:100) plus canonical's pre-deduped alt_names
    (schema.py:86-89) mean the alias count equals the total alt_names.
    """
    with closing(sqlite3.connect(f"file:{built_sqlite}?mode=ro", uri=True)) as conn:
        broken = conn.execute(
            "SELECT COUNT(*) FROM ingredient_aliases a "
            "JOIN ingredients i ON i.id = a.ingredient_id "
            "WHERE a.alias != lower(a.alias)"
        ).fetchone()[0]
        alias_count = conn.execute("SELECT COUNT(*) FROM ingredient_aliases").fetchone()[0]
    assert broken == 0
    expected = sum(len(row.alt_names) for row in canonical_catalog.records)
    assert alias_count == expected > 0


def test_built_ingredients_row_count_matches_canonical(built_sqlite, canonical_catalog):
    """One ingredients row per canonical record: the bundle is a pure render of the JSON."""
    with closing(sqlite3.connect(f"file:{built_sqlite}?mode=ro", uri=True)) as conn:
        count = conn.execute("SELECT COUNT(*) FROM ingredients").fetchone()[0]
    assert count == len(canonical_catalog.records) > 0


def test_built_v2_ingredient_catalog_table_pins_key_columns(built_sqlite):
    """The v2 table is written on every build (build_sqlite.py:38-68) but read by no
    Swift code at the base commit; pinned so its key columns do not silently
    disappear before a reader lands. See .parts/p09-integration.md.
    """
    with closing(sqlite3.connect(f"file:{built_sqlite}?mode=ro", uri=True)) as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(ingredient_catalog)")}
    assert {"fdc_id", "normalized_name", "search_text", "alt_names_json"} <= columns


# ---------------------------------------------------------------------------
# Human review loop (export-batch / promote-batch invariants)
# ---------------------------------------------------------------------------


def _row(fdc_id: int, display_name: str, **overrides) -> CuratedIngredientRow:
    kwargs: dict = dict(
        display_name=display_name,
        category_label="oil_fat",
        source_description=f"Oil, {display_name.lower()}",
        source_meta=SourceMeta(data_type="Foundation", food_category="Fats and oils"),
        macros=MacroSet(calories=884.0),
    )
    kwargs.update(overrides)
    return CuratedIngredientRow(fdc_id=fdc_id, **kwargs)


def _catalog(*rows: CuratedIngredientRow) -> CanonicalCatalog:
    return CanonicalCatalog(generated_at_utc="2030-01-01T00:00:00Z", records=list(rows))


def test_export_batch_prefers_new_candidates_then_existing_metadata_reviews():
    catalog = _catalog(_row(1, "Olive Oil"))
    new_candidate = _row(2, "Canola Oil")
    duplicate_candidate = _row(1, "Olive Oil (duplicate)")
    batch = export_batch(
        catalog,
        batch_id=1,
        batch_size=2,
        candidates=[new_candidate, duplicate_candidate],
    )
    assert [(record.row.fdc_id, record.action) for record in batch.records] == [
        (2, "upsert"),
        (1, "upsert"),
    ]
    assert [record.review_notes for record in batch.records] == [
        "new candidate from USDA",
        "review metadata quality",
    ]


def test_export_batch_stops_at_batch_size_on_new_candidates():
    catalog = _catalog(_row(1, "Olive Oil"))
    batch = export_batch(
        catalog,
        batch_id=1,
        batch_size=1,
        candidates=[_row(2, "Canola Oil"), _row(3, "Sunflower Oil")],
    )
    assert [record.row.fdc_id for record in batch.records] == [2]


def test_promote_batch_rejects_macro_drift_for_existing_fdc_ids():
    catalog = _catalog(_row(1, "Olive Oil", macros=MacroSet(calories=884.0)))
    drifted = _row(1, "Olive Oil", macros=MacroSet(calories=900.0))
    batch = BatchPayload(batch_id=7, batch_size=1, records=[BatchRow(action="upsert", row=drifted)])
    with pytest.raises(PromoteError, match="Macro freeze violation"):
        promote_batch(catalog, batch)


def test_promote_batch_accepts_metadata_edits_and_preserves_frozen_macros():
    catalog = _catalog(_row(1, "Olive Oil", macros=MacroSet(calories=884.0)))
    edited = _row(
        1,
        "Olive Oil",
        macros=MacroSet(calories=884.0),
        alt_names=["evoo"],
        description="Cold-pressed oil; nutrition values are per 100g.",
    )
    batch = BatchPayload(batch_id=7, batch_size=1, records=[BatchRow(action="upsert", row=edited)])
    merged = promote_batch(catalog, batch)
    assert merged.records[0].alt_names == ["evoo"]
    assert merged.records[0].macros == catalog.records[0].macros


def test_promote_batch_drop_action_removes_existing_row():
    catalog = _catalog(_row(1, "Olive Oil"), _row(2, "Canola Oil"))
    batch = BatchPayload(
        batch_id=9,
        batch_size=1,
        records=[BatchRow(action="drop", row=_row(1, "Olive Oil"))],
    )
    merged = promote_batch(catalog, batch)
    assert [row.fdc_id for row in merged.records] == [2]


def test_promote_batch_requires_usda_provenance_even_for_new_rows():
    catalog = _catalog(_row(1, "Olive Oil"))
    unverified = _row(3, "Canola Oil", source_meta=SourceMeta(verification_source="hand-entered"))
    batch = BatchPayload(batch_id=2, batch_size=1, records=[BatchRow(action="upsert", row=unverified)])
    with pytest.raises(PromoteError, match="missing USDA verification_source"):
        promote_batch(catalog, batch)


# ---------------------------------------------------------------------------
# Legacy v1 scripts stay outside the v2 package
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("script", LEGACY_SCRIPTS)
def test_legacy_v1_scripts_do_not_import_usda_core(script):
    """fetch_usda_ingredient_nutrition.py / generate_usda_ingredient_swift_static.py
    are the pre-v2 standalone pipeline; they must not grow usda_core imports
    without revisiting that decision (see .parts/p09-integration.md).
    """
    tree = ast.parse((SCRIPTS_DATA_DIR / script).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            assert all(alias.name.split(".")[0] != "usda_core" for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            assert (node.module or "").split(".")[0] != "usda_core"
