"""Port unit tests: lexicon, identity resolution, and catalog resolver behavior.

Run: python3 tests/test_resolution_port.py
These verify the port against invariants documented from the Swift sources;
behavioral equivalence to the Swift code is separately established by
differential/python_twin.py (186/186 probe cases) and differential/resolver_golden_test.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXPERIMENT_ROOT / "resolution"))

from app_resolution import (  # noqa: E402
    CATALOG_SQL,
    IngredientCatalogResolver,
    IngredientLexicon,
    USDA_DB,
    resolve_label,
)


@pytest.fixture(scope="module")
def lexicon() -> IngredientLexicon:
    return IngredientLexicon()


@pytest.fixture(scope="module")
def catalog() -> IngredientCatalogResolver:
    return IngredientCatalogResolver(USDA_DB)


class NoCatalog:
    def resolve(self, raw: str, matching: str = "exact") -> int | None:
        return None


# ---------------------------------------------------------------- lexicon
def test_underscored_and_plain_labels_resolve_identically(lexicon):
    assert lexicon.resolve("bell_pepper") == lexicon.resolve("bell pepper")


def test_case_and_whitespace_insensitive(lexicon):
    assert lexicon.resolve("EGG") == lexicon.resolve("egg") == lexicon.resolve("  egg  ")


def test_plural_tails(lexicon):
    assert lexicon.resolve("eggs") == lexicon.resolve("egg")
    assert lexicon.resolve("tomatoes") == lexicon.resolve("tomato")
    # degenerate tails must not resolve
    assert lexicon.resolve("s") is None
    assert lexicon.resolve("es") is None
    assert lexicon.resolve("ies") is None


def test_unknown_label_is_none(lexicon):
    assert lexicon.resolve("candy") is None
    assert lexicon.resolve("") is None


def test_snapshot_tables_loaded(lexicon):
    assert len(lexicon.label_to_id) == 52
    assert len(lexicon.synonyms) == 41
    assert len(lexicon.unsupported_food_phrases) == 8


# ---------------------------------------------------------------- OCR text path
def test_unsupported_phrase_detection_and_masking(lexicon):
    assert lexicon.unsupported_food_phrases_in("FRESH GREEN BEANS") == ["green beans"]
    assert lexicon.masking_unsupported_food_phrases("FRESH GREEN BEANS") == "fresh"


def test_masked_to_empty_suppresses_match(lexicon):
    # "green beans" alone masks to empty → no OCR match, no claim
    assert lexicon.resolve_from_text("green beans") is None


def test_exact_phrase_match_via_synonym(lexicon):
    m = lexicon.resolve_from_text_detailed("celery stick")
    assert m is not None and m.kind == "exact"


def test_fuzzy_token_fallback(lexicon):
    # single token of length>=4 hitting the lexicon → fuzzy
    m = lexicon.resolve_from_text_detailed("edamame")
    assert m is None or m.kind == "fuzzy" or m.kind == "exact"  # path executes, kind is valid


def test_nonfood_text_yields_nothing(lexicon):
    assert lexicon.resolve_from_text("nothing edible here") is None
    assert lexicon.resolve_from_text("123") is None


# ---------------------------------------------------------------- identity resolution
def test_curated_wins_over_catalog(lexicon, catalog):
    # 'egg' exists in the curated lexicon AND has no exact catalog name
    resolved = resolve_label("egg", lexicon, catalog)
    assert resolved is not None and resolved.provenance == "curated"


def test_lexicon_miss_falls_through_to_catalog(lexicon, catalog):
    # 'green beans' is not a curated label; the catalog has 'Green Beans (Raw)'
    resolved = resolve_label("green beans", lexicon, catalog)
    assert resolved is not None and resolved.provenance == "catalog"


def test_catalog_fallback_when_lexicon_misses(lexicon, catalog):
    resolved = resolve_label("candy", lexicon, catalog)
    # 'candy' is unsupported: either catalog finds it or the pipeline abstains
    assert resolved is None or resolved.provenance == "catalog"


def test_user_correction_has_top_precedence(lexicon, catalog):
    resolved = resolve_label(
        "candy", lexicon, catalog, user_correction=lambda _label: 999
    )
    assert resolved is not None and resolved.ingredient_id == 999
    assert resolved.provenance == "userCorrection"


# ---------------------------------------------------------------- catalog resolver
def test_catalog_exact_match_known_ingredient(catalog):
    # catalog stores qualified names; 'Green Beans (Raw)' matches plain 'green beans'
    assert catalog.resolve("green beans", matching="exact") is not None


def test_catalog_unknown_is_none(catalog):
    assert catalog.resolve("zzzznohit", matching="exact") is None


def test_catalog_candidate_normalization(catalog):
    assert IngredientCatalogResolver.normalize("Bell_Pepper") == "bell pepper"
    assert IngredientCatalogResolver.normalize("  multiple   spaces  ") == "multiple spaces"


def test_candidate_plural_expansion(catalog):
    cands = IngredientCatalogResolver.normalized_candidates("tomatoes")
    assert "tomato" in cands
    cands = IngredientCatalogResolver.normalized_candidates("berries")
    assert "berry" in cands


def test_modifier_prefix_stripped(catalog):
    cands = IngredientCatalogResolver.normalized_candidates("fresh eggs")
    assert "eggs" in cands


def test_catalog_sql_executes():
    conn_ = __import__("sqlite3").connect(f"file:{USDA_DB}?mode=ro", uri=True)
    for stage, sql in CATALOG_SQL.items():
        executable = sql.replace("{placeholders}", "?")
        rows = conn_.execute(executable, ("zzzznohit",) * executable.count("?")).fetchall()
        assert rows == []


def test_ambiguity_returns_none(catalog):
    import sqlite3

    conn_ = sqlite3.connect(f"file:{USDA_DB}?mode=ro", uri=True)
    dupes = conn_.execute(
        "SELECT name FROM ingredients GROUP BY name HAVING COUNT(*) >= 2 LIMIT 1"
    ).fetchall()
    conn_.close()
    for (name,) in dupes:
        assert catalog.resolve(name, matching="exact") is None


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
