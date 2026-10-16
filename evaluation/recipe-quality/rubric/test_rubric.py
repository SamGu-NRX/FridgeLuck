"""Rubric-audit gates: fix-packet integrity, rights pins, RS lint, nutrition bands, sample integrity.

Run from the repo root:
    python3 -m pytest evaluation/recipe-quality/rubric/test_rubric.py -q
"""
import copy
import json
import random
import sys
from pathlib import Path

import pytest

RUBRIC_DIR = Path(__file__).resolve().parent
REPO = RUBRIC_DIR.parents[2]
for p in (str(RUBRIC_DIR), str(REPO / "data" / "recipes" / "tools"),
          str(REPO / "data" / "recipes" / "suite")):
    if p not in sys.path:
        sys.path.insert(0, p)

import audit  # noqa: E402
import rs as rs_suite  # noqa: E402
import validate_corpus  # noqa: E402
from bands import CUISINE_SET, SLOT_SET  # noqa: E402
from pipeline.normalize import normalize_name  # noqa: E402


@pytest.fixture(scope="module")
def corpus():
    return audit.load_corpus()


@pytest.fixture(scope="module")
def fixes():
    path = audit.FIXES
    assert path.exists(), f"fix packet missing: {path}"
    packet = json.loads(path.read_text(encoding="utf-8"))
    return packet["fixes"]


@pytest.fixture(scope="module")
def rs_tables():
    suite_dir = REPO / "data" / "recipes" / "suite"
    conv_raw = json.loads((suite_dir / "conversions.json").read_text())
    conversions = conv_raw.get("conversions", conv_raw)
    allergens = json.loads((suite_dir / "allergens.json").read_text())
    return CUISINE_SET, SLOT_SET, conversions, rs_suite.AllergenScanner(allergens)


# ---- fix packet integrity ---------------------------------------------------

def test_fix_count_within_budget(fixes):
    assert 0 < len(fixes) <= 25, f"{len(fixes)} fixes exceeds the 25-fix budget"


def test_fix_ids_unique_and_in_corpus(fixes, corpus):
    _, raw = corpus
    ids = [f["id"] for f in fixes]
    assert len(ids) == len(set(ids)), "duplicate fix ids"
    for rid in ids:
        assert rid in raw, f"{rid} not in corpus"


def test_before_sha_pins_the_base_record(fixes, corpus):
    _, raw = corpus
    for f in fixes:
        assert audit.sha_of(raw[f["id"]]) == f["before_sha256"], (
            f"{f['id']}: fix was made against a different base record")


def test_catalog_ids_line_up(fixes):
    for f in fixes:
        assert validate_corpus.catalog_id_for(f["id"]) == f["catalog_id"], f["id"]


def test_every_fix_carries_evidence(fixes):
    for f in fixes:
        assert f.get("changes"), f["id"]
        for row in f["changes"]:
            assert isinstance(row, dict), f["id"]
            assert isinstance(row.get("path"), str) and row["path"], f["id"]
            assert isinstance(row.get("reason"), str) and len(row["reason"]) > 20, (
                f["id"], row.get("path"))


# ---- rights pins -------------------------------------------------------------

def test_rights_pins_hold(fixes, corpus):
    recs, _ = corpus
    by_id = {r["id"]: r for r in recs}
    for f in fixes:
        if f.get("changes_rights_pin"):
            continue
        base, fixed = by_id[f["id"]], f["record"]
        assert base["title"] == fixed["title"], f"{f['id']}: title changed without a rights pin"
        assert [i["name"] for i in base["ingredients"]] == \
               [i["name"] for i in fixed["ingredients"]], (
            f"{f['id']}: ingredient names changed without a rights pin")


def test_pinned_fixes_explain_the_move(fixes):
    for f in fixes:
        if f.get("changes_rights_pin"):
            assert f["changes"], f["id"]  # the pin reason rides the change rows


# ---- edits resolve and lint ---------------------------------------------------

def test_edited_lines_resolve_and_have_conversions(fixes, corpus, rs_tables):
    _, _, conversions, _ = rs_tables
    recs, _ = corpus
    by_id = {r["id"]: r for r in recs}
    for f in fixes:
        base_names = {i["name"] for i in by_id[f["id"]]["ingredients"]}
        for ing in f["record"]["ingredients"]:
            if ing["name"] in base_names:
                continue  # unchanged identity; only quantities may differ
            entry = audit.Context().mappings.get(normalize_name(ing["name"]))
            assert entry, f"{f['id']}: new line {ing['name']!r} does not resolve in name-mappings"
            qty = ing["qty"]
            if qty["kind"] == "household":
                ref = qty.get("conversion_ref")
                assert ref in conversions, (
                    f"{f['id']}: household line {ing['name']!r} lacks conversion {ref!r}")
                assert conversions[ref].get("grams_per_unit"), (f["id"], ing["name"])


def test_fixes_introduce_no_new_lint_violations(fixes, corpus, rs_tables):
    """Fixes may inherit the base record's anticipated R2 conversion flags, but
    must never add a lint violation the base record did not already carry."""
    cuisines, slots, conversions, scanner = rs_tables
    recs, _ = corpus
    by_id = {r["id"]: r for r in recs}
    for f in fixes:
        vb = set(rs_suite.lint_recipe(copy.deepcopy(by_id[f["id"]]),
                                      cuisines=cuisines, meal_slots=slots,
                                      conversions=conversions, allergen_scan=scanner))
        vf = set(rs_suite.lint_recipe(copy.deepcopy(f["record"]),
                                      cuisines=cuisines, meal_slots=slots,
                                      conversions=conversions, allergen_scan=scanner))
        new = vf - vb
        assert not new, (f["id"], sorted(new))


# ---- nutrition bands ----------------------------------------------------------

def test_fixed_records_within_bands(fixes):
    ctx = audit.Context()
    for f in fixes:
        sig = audit.evaluate(f["record"], ctx)
        kc, na = sig["kcal_per_serving"], sig["sodium_mg_per_serving"]
        assert kc is not None and audit.KCAL_MIN <= kc <= audit.KCAL_MAX, (f["id"], kc)
        assert na is not None and na <= audit.SODIUM_DV, (f["id"], na)


def test_mechanical_outliers_cleared_after_fixes(corpus, fixes):
    recs, _ = corpus
    ctx = audit.Context()
    scoped = {r["id"]: r for r in audit.in_scope(recs, audit.amounts_set())}
    applied = {f["id"]: f["record"] for f in fixes}
    over_kcal = over_na = 0
    for rid, rec in scoped.items():
        sig = audit.evaluate(applied.get(rid, rec), ctx)
        kc, na = sig["kcal_per_serving"], sig["sodium_mg_per_serving"]
        if kc is not None and kc > audit.KCAL_MAX:
            over_kcal += 1
        if na is not None and na > audit.SODIUM_DV:
            over_na += 1
    assert over_kcal == 0, f"{over_kcal} in-scope recipes still over {audit.KCAL_MAX} kcal"
    assert over_na == 0, f"{over_na} in-scope recipes still over {audit.SODIUM_DV} mg"


# ---- hand-score sample ---------------------------------------------------------

def test_sample_scores_reproduce_from_seed():
    doc = json.loads((RUBRIC_DIR / "sample-scores.json").read_text(encoding="utf-8"))
    recs, _ = audit.load_corpus()
    scoped = {r["id"]: r for r in audit.in_scope(recs, audit.amounts_set())}
    expected = sorted(random.Random(audit.SEED).sample(sorted(scoped), audit.SAMPLE_SIZE))
    assert doc["sample_ids"] == expected, "sample-scores.json ids do not reproduce from the seed"
    assert len(doc["recipes"]) == audit.SAMPLE_SIZE
    assert {r["id"] for r in doc["recipes"]} == set(expected), "scored set != sample set"
    for r in doc["recipes"]:
        assert set(r["scores"]) == {f"C{i}" for i in range(1, 8)}, r["id"]
        for k, pair in r["scores"].items():
            n, reason = pair
            assert n in (0, 1, 2), (r["id"], k, n)
            assert isinstance(reason, str) and reason, (r["id"], k)
        assert 0 <= sum(n for n, _ in r["scores"].values()) <= 14, r["id"]
