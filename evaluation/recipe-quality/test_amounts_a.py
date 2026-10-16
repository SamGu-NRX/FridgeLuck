#!/usr/bin/env python3
"""Packet A tests — real amounts for band rcp-000167..rcp-000376.

Validates the COMMITTED fix file (data/recipes/fixes/amounts-a.json) against
the corpus and the shipped bundle; it never regenerates the fix file. The
generator that produced it is evaluation/recipe-quality/amounts_a.py.

The packet rule under test: in the amounts set (band recipes from the shipped
bundle with any non-staple line whose quantity.kind is unknown), every line is
either measured with a real amount, or left "to taste" with a note that says
why — and the note is only allowed for seasoning, garnish and heat.

Run:  pytest evaluation/recipe-quality/amounts-a.test.py -v
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

import compile_bundle  # noqa: E402
import validate_corpus  # noqa: E402

FIX_FILE = REPO / "data/recipes/fixes/amounts-a.json"
REPORT = REPO / "evaluation/recipe-quality/amounts-a.md"
BAND_LO, BAND_HI = "rcp-000167", "rcp-000376"
PACKET = "burst11-fridgeluck-recipe-amounts-a"
SCHEMA = "fridgeluck/corpus-fixes/v1"
MARK_KCAL = "kcal outside the 150-1300 bar"
MARK_SODIUM = "sodium above the 2300 mg bar"

# Recipes allowed outside the compile bar, and the marker their changes
# entries must carry. Everything else must land inside.
ALLOWED_EXCEEDANCES = {
    "rcp-000247": MARK_KCAL,
    "rcp-000330": MARK_KCAL,
    "rcp-000282": MARK_SODIUM,
    "rcp-000305": MARK_SODIUM,
    "rcp-000319": MARK_SODIUM,
    "rcp-000351": MARK_SODIUM,
}

# The only ingredient-name additions in the packet: molasses lines the
# titles promise. Each names the recipe that adds it.
ALLOWED_NAME_ADDITIONS = {"rcp-000194", "rcp-000199", "rcp-000201"}
ALLOWED_NAME = "molasses"

KCAL_MIN, KCAL_MAX = 150.0, 1300.0
SODIUM_MAX = 2300.0


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def corpus() -> dict[str, tuple[dict, str]]:
    out = {}
    for raw in (REPO / "data/recipes/corpus.jsonl").read_text(encoding="utf-8").splitlines():
        if raw.strip():
            rec = json.loads(raw)
            out[rec["id"]] = (rec, raw)
    return out


@pytest.fixture(scope="module")
def fix() -> dict:
    return json.loads(FIX_FILE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def bundle() -> dict:
    return json.loads(
        (REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def band(bundle: dict) -> dict[str, list[dict]]:
    """The amounts set: band recipes with any non-staple unknown line."""
    out = {}
    for r in bundle["recipes"]:
        if not BAND_LO <= r["catalog_id"] <= BAND_HI:
            continue
        lines = [{"index": i, "key": l["key"]}
                 for i, l in enumerate(r["ingredients"])
                 if l["quantity"]["kind"] == "unknown" and not l["assumed_staple"]]
        if lines:
            out[r["catalog_id"]] = lines
    return out


@pytest.fixture(scope="module")
def ctx():
    mappings = json.load((REPO / "data/ingredients/name-mappings.json").open())["mappings"]
    vocab = json.load((REPO / "data/ingredients/vocabulary.json").open())["entries"]
    rights = json.load((REPO / "data/recipes/rights_manifest.json").open())["records"]
    rights_ctx = validate_corpus.load_rights_context()
    labels = {}
    for rec, _ in corpus_raw_map():
        labels[rec["id"]] = compile_bundle.rights_label_for(rec, rights_ctx)
    return {
        "mappings": mappings,
        "vocab_by_key": {e["key"]: e for e in vocab},
        "rights": rights,
        "labels": labels,
        "rights_ctx": rights_ctx,
    }


def corpus_raw_map() -> list[tuple[dict, str]]:
    out = []
    for raw in (REPO / "data/recipes/corpus.jsonl").read_text(encoding="utf-8").splitlines():
        if raw.strip():
            out.append((json.loads(raw), raw))
    return out


def catalog_id_for(corpus_id: str) -> str:
    seq = int(corpus_id.rsplit("-", 1)[-1])
    return f"rcp-{167 + seq - 1:06d}"


def corpus_id_for(catalog_id: str) -> str:
    seq = int(catalog_id.rsplit("-", 1)[-1]) - 166
    return f"fl-original-{seq:04d}"


def compile_one(rec: dict, ctx: dict) -> dict:
    return compile_bundle.compile_recipe(
        rec, ctx["mappings"], ctx["vocab_by_key"], ctx["rights"], ctx["labels"])


# ---------------------------------------------------------------------------
# Fix-file shape and pins
# ---------------------------------------------------------------------------

def test_fix_file_shape(fix):
    assert fix["schema"] == SCHEMA
    assert fix["packet"] == PACKET
    assert fix["base_commit"].startswith("ef236fcd")
    assert isinstance(fix["fixes"], list) and len(fix["fixes"]) == 86
    ids = [f["id"] for f in fix["fixes"]]
    cats = [f["catalog_id"] for f in fix["fixes"]]
    assert len(set(ids)) == len(ids) and len(set(cats)) == len(cats)
    for f in fix["fixes"]:
        assert set(f.keys()) == {"id", "catalog_id", "before_sha256", "record",
                                 "changes", "changes_rights_pin"}
        assert f["catalog_id"] == catalog_id_for(f["id"])
        assert isinstance(f["changes"], list) and f["changes"]
        for c in f["changes"]:
            assert set(c.keys()) == {"path", "reason", "evidence"}
            assert c["reason"].strip() and c["evidence"].strip()


def test_before_sha256_matches_corpus(fix, corpus):
    for f in fix["fixes"]:
        rec, raw = corpus[f["id"]]
        assert f["before_sha256"] == hashlib.sha256(raw.encode("utf-8")).hexdigest(), f["id"]


def test_fix_set_equals_band(fix, band):
    assert {f["catalog_id"] for f in fix["fixes"]} == set(band)


# ---------------------------------------------------------------------------
# Every band line gets exactly one decision: measured, or to taste with a note
# ---------------------------------------------------------------------------

def _qty_state(rec: dict, catalog_id: str) -> dict[int, dict]:
    """Band line -> the line's qty in a record, with insertions removed."""
    rid = corpus_id_for(catalog_id)
    fixed = rec
    names = [i["name"] for i in fixed["ingredients"]]
    if catalog_id in ALLOWED_NAME_ADDITIONS:
        idx = names.index(ALLOWED_NAME)
        names = names[:idx] + names[idx + 1:]
        qtys = [i["qty"] for i in fixed["ingredients"]]
        qtys = qtys[:idx] + qtys[idx + 1:]
        return dict(enumerate(qtys))
    return {i: ing["qty"] for i, ing in enumerate(fixed["ingredients"])}


def _corpus_qty_state(rec: dict) -> dict[int, dict]:
    return {i: ing["qty"] for i, ing in enumerate(rec["ingredients"])}


def test_every_band_line_is_measured_or_noted_with_reason(fix, corpus, band, ctx):
    measured, noted = 0, 0
    for f in fix["fixes"]:
        cat = f["catalog_id"]
        rid = corpus_id_for(cat)
        rec0, _ = corpus[rid]
        before = _corpus_qty_state(rec0)
        after = _qty_state(f["record"], cat)
        assert set(after.keys()) == set(before.keys())
        for idx, line in enumerate(band[cat]):
            q0, q1 = before[line["index"]], after[line["index"]]
            kind0 = q0.get("kind")
            kind1 = q1.get("kind")
            assert kind0 == "unknown"
            if kind1 in ("source_grams", "household"):
                measured += 1
                assert not (kind1 == "household") or q1.get("conversion_ref"), \
                    f"{cat} line {idx}: household amount without conversion_ref"
            else:
                assert kind1 == "unknown"
                note = q1.get("note", "")
                assert note.startswith("to taste"), \
                    f"{cat} line {idx} ({line['key']}): left unknown without a to-taste note"
                noted += 1
    assert measured + noted == 118
    assert noted == 15


def test_to_taste_lines_are_seasoning_garnish_or_heat(fix, corpus, band):
    """The packet rule: to taste stays only for seasoning, garnish and heat.
    The allowlist below is the closed set of notes the packet ships; a new
    to-taste line must extend this list deliberately, in the test and the
    report, not silently."""
    allowed_keys = {
        ("rcp-000182", 5), ("rcp-000189", 3), ("rcp-000197", 5), ("rcp-000199", 4),
        ("rcp-000200", 6), ("rcp-000204", 2), ("rcp-000227", 2), ("rcp-000232", 5),
        ("rcp-000279", 1), ("rcp-000322", 6), ("rcp-000330", 5), ("rcp-000364", 6),
        ("rcp-000366", 7), ("rcp-000368", 7), ("rcp-000373", 7),
    }
    got = set()
    for f in fix["fixes"]:
        cat = f["catalog_id"]
        after = _qty_state(f["record"], cat)
        for line in band[cat]:
            q = after[line["index"]]
            if q.get("kind") == "unknown" and q.get("note", "").startswith("to taste"):
                got.add((cat, line["index"]))
    assert got == allowed_keys


def test_rights_pin_flag_matches_name_additions(fix):
    for f in fix["fixes"]:
        names = [i["name"] for i in f["record"]["ingredients"]]
        adds = ALLOWED_NAME in names
        assert f["changes_rights_pin"] == (f["catalog_id"] in ALLOWED_NAME_ADDITIONS)
        assert adds == (f["catalog_id"] in ALLOWED_NAME_ADDITIONS), f["catalog_id"]


# ---------------------------------------------------------------------------
# Nothing outside the owned paths changes
# ---------------------------------------------------------------------------

def _diff(a, b, path, out):
    if type(a) is not type(b):
        out.append(path)
    elif isinstance(a, dict):
        for k in set(a) | set(b):
            _diff(a.get(k), b.get(k), f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(path)
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                _diff(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(path)


def test_only_owned_paths_change(fix, corpus):
    for f in fix["fixes"]:
        cat, rid = f["catalog_id"], corpus_id_for(f["catalog_id"])
        rec0, _ = corpus[rid]
        rec1 = f["record"]
        diffs: list[str] = []
        _diff(rec0, rec1, "", diffs)
        paths = set()
        for d in diffs:
            paths.add(d.lstrip(".").split("[")[0])
        allowed = {"ingredients"} | ({"steps"} if cat in ALLOWED_NAME_ADDITIONS else set())
        unexpected = paths - allowed
        assert not unexpected, f"{cat}: changed {sorted(unexpected)}"
        # servings, rights, composition, title all byte-equal
        for k in ("title", "servings", "rights", "composition_classes", "allergens"):
            assert rec0.get(k) == rec1.get(k), f"{cat}: {k} changed"


def test_name_additions_only_molasses_with_step_edit(fix, corpus):
    for f in fix["fixes"]:
        cat = f["catalog_id"]
        rec0, _ = corpus[corpus_id_for(cat)]
        n0 = [i["name"] for i in rec0["ingredients"]]
        n1 = [i["name"] for i in f["record"]["ingredients"]]
        if cat in ALLOWED_NAME_ADDITIONS:
            assert len(n1) == len(n0) + 1 and ALLOWED_NAME in n1
            added = [i for i in f["record"]["ingredients"] if i["name"] == ALLOWED_NAME][0]
            assert added["qty"]["kind"] == "source_grams" and added["qty"]["grams"] > 0
            step_texts = " ".join(s["text"] for s in f["record"]["steps"])
            assert ALLOWED_NAME in step_texts, f"{cat}: molasses line unused by the steps"
        else:
            assert n0 == n1, f"{cat}: ingredient names changed"


# ---------------------------------------------------------------------------
# Compilation: the shipped compiler, never a re-implementation
# ---------------------------------------------------------------------------

def _nutrition(compiled: dict) -> dict:
    n = compiled["nutrition_per_serving"]
    return {k: n[k] for k in ("kcal", "protein_g", "sodium_mg")}


def test_before_compiles_to_shipped_bundle_numbers(fix, corpus, bundle, ctx):
    """The corpus record compiles to exactly the bundle's shipped nutrition —
    the packet's 'before' column is the app's own math, not ours."""
    shipped = {r["catalog_id"]: r["nutrition_per_serving"] for r in bundle["recipes"]}
    for f in fix["fixes"]:
        rec0, _ = corpus[corpus_id_for(f["catalog_id"])]
        n = _nutrition(compile_one(rec0, ctx))
        s = shipped[f["catalog_id"]]
        assert n["kcal"] == pytest.approx(s["kcal"], abs=0.1), f["catalog_id"]
        assert n["protein_g"] == pytest.approx(s["protein_g"], abs=0.1), f["catalog_id"]
        assert n["sodium_mg"] == pytest.approx(s["sodium_mg"], abs=0.1), f["catalog_id"]


def test_after_compiles_within_bar_or_explains(fix, ctx):
    for f in fix["fixes"]:
        cat = f["catalog_id"]
        n = _nutrition(compile_one(f["record"], ctx))
        marker = ALLOWED_EXCEEDANCES.get(cat)
        if marker is None:
            assert KCAL_MIN <= n["kcal"] <= KCAL_MAX, \
                f"{cat}: kcal {n['kcal']} outside the bar without an explanation"
            assert n["sodium_mg"] <= SODIUM_MAX, \
                f"{cat}: sodium {n['sodium_mg']} above the bar without an explanation"
        else:
            evidence = " ".join(c["evidence"] + " " + c["reason"] for c in f["changes"])
            assert marker in evidence, \
                f"{cat}: outside the bar without the {marker!r} explanation in changes"


def test_explained_exceedance_values_match_the_evidence(fix, ctx):
    """The numbers quoted in the explanations are the compiled numbers."""
    expected = {"rcp-000247": ("kcal", 1588.3), "rcp-000330": ("kcal", 1413.3),
                "rcp-000282": ("sodium_mg", 2392.4), "rcp-000305": ("sodium_mg", 3148.7),
                "rcp-000319": ("sodium_mg", 2357.9), "rcp-000351": ("sodium_mg", 2810.0)}
    for cat, (metric, want) in expected.items():
        f = next(x for x in fix["fixes"] if x["catalog_id"] == cat)
        n = _nutrition(compile_one(f["record"], ctx))
        assert n[metric] == pytest.approx(want, abs=0.2), cat


# ---------------------------------------------------------------------------
# The report agrees with the compiled numbers
# ---------------------------------------------------------------------------

def test_report_table_matches_compiled_values(fix, ctx):
    text = REPORT.read_text(encoding="utf-8")
    for f in fix["fixes"]:
        cat = f["catalog_id"]
        assert cat in text, f"{cat} missing from the report"
    n = _nutrition(compile_one(next(x for x in fix["fixes"]
                                    if x["catalog_id"] == "rcp-000189")["record"], ctx))
    row = next(line for line in text.splitlines() if line.startswith("| rcp-000189 "))
    cells = [c.strip() for c in row.split("|")]
    assert f"74.7 → {n['kcal']}" == cells[5], cells[5]
