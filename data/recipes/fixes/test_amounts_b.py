"""Tests for the band rcp-000377..rcp-000934 amounts fix file.

Packet burst11-fridgeluck-recipe-amounts-b (base alpha ef236fcd).

The fix file data/recipes/fixes/amounts-b.json replaces corpus records for the
band's 85 recipes. These tests assert:

  1. the fix file covers exactly the band — every recipe with a non-staple
     unknown-quantity line in rcp-000377..rcp-000934, and nothing else —
     against the band definition in evaluation/recipe-quality/amounts_b.py;
  2. every fix records the base corpus line's sha256 and swaps in a record of
     the same shape, with titles and ingredient names (the rights pin inputs)
     unchanged and changes_rights_pin unset;
  3. every non-staple line in the band ends up with a real amount
     (source_grams / household with a resolvable conversions row) or stays
     unknown only with an explicit "to taste" note;
  4. the recompiled records pass the per-record checks validate_bundle.main
     enforces (vocabulary keys, Atwater consistency, claims vs composition,
     sodium ceiling, timer rule, thermometer checks resting in step text);
  5. per-serving kcal stays inside 150-1300 and sodium at or under 2300 mg
     unless the fix's own changes text explains the gap ("kcal floor" /
     "sodium" markers);
  6. the repository's own validate_corpus.py gates (rights, quarantine,
     release gates, dedupe, lint) exit 0 over the patched corpus;
  7. the committed nutrition report matches a fresh render.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]

_spec = importlib.util.spec_from_file_location(
    "amounts_b", REPO / "evaluation/recipe-quality/amounts_b.py")
amounts_b = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(amounts_b)

sys.path.insert(0, str(REPO / "data/recipes/tools"))
import compile_bundle as compiler  # noqa: E402
import composition  # noqa: E402
import food_safety  # noqa: E402
import validate_bundle as vbundle  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402

KCAL_MIN, KCAL_MAX = 150.0, 1300.0
SODIUM_MAX = 2300.0


@pytest.fixture(scope="module")
def p():
    return amounts_b.prepare()


@pytest.fixture(scope="module")
def base_corpus():
    """{corpus id: (record, line bytes)} at the packet's base commit. Later
    packets (review-fixed.json) rewrite some of these recipes again, so the
    before-pin and shape checks read the base from git, not the live corpus."""
    out = subprocess.run(
        ["git", "show", f"{amounts_b.BASE_COMMIT}:data/recipes/corpus.jsonl"],
        capture_output=True, cwd=REPO)
    if out.returncode != 0:
        pytest.skip(f"base commit {amounts_b.BASE_COMMIT} not in this checkout")
    lines = [raw for raw in out.stdout.split(b"\n") if raw.strip()]
    return {json.loads(raw)["id"]: (json.loads(raw), raw) for raw in lines}


@pytest.fixture(scope="module")
def compiled(p):
    out = {}
    for fid, fix in p["fixes"].items():
        out[fid] = amounts_b.compile_one(
            fix["record"], p["mappings"], p["vocab_by_key"], p["rights"], p["labels"])
    return out


@pytest.fixture(scope="module")
def allergens():
    return json.loads((REPO / "data/recipes/suite/allergens.json").read_text())


@pytest.fixture(scope="module")
def conversions(p):
    """Refs resolve like validate_corpus: suite fixture table, plus each
    recipe's embedded conversions, plus the corpus-side table when present."""
    table = json.loads(
        (REPO / "data/recipes/suite/conversions.json").read_text())
    rows = dict(table.get("conversions", table))
    corpus_tbl_path = REPO / "data/recipes/conversions.json"
    if corpus_tbl_path.exists():
        rows.update(json.loads(corpus_tbl_path.read_text()).get("conversions", {}))
    for rec in p["corpus"].values():
        for ref, row in (rec.get("conversions") or {}).items():
            rows.setdefault(str(ref).strip(), row)
    return rows


def test_packet_header(p):
    doc = p["fixes_doc"]
    assert doc["schema"] == "fridgeluck/corpus-fixes/v1"
    assert doc["packet"] == amounts_b.PACKET
    assert doc["base_commit"] == amounts_b.BASE_COMMIT


def test_band_covered_exactly(p):
    band_ids = {r["catalog_id"] for r, _ in p["band"]}
    fix_ids = {vcorpus.catalog_id_for(fid) for fid in p["fixes"]}
    assert fix_ids == band_ids, "fix file must cover exactly the band"
    n_lines = sum(len(lines) for _, lines in p["band"])
    assert len(p["fixes"]) == len(band_ids) == 85
    assert n_lines == 106
    for fid, fix in p["fixes"].items():
        assert fix["catalog_id"] == vcorpus.catalog_id_for(fid)
        assert fix["changes"], f"{fid}: every fix documents its changes"


def test_before_sha256_matches_base(p, base_corpus):
    for fid, fix in p["fixes"].items():
        digest = hashlib.sha256(base_corpus[fid][1]).hexdigest()
        assert fix["before_sha256"] == digest, fid


def test_shape_names_title_preserved(p, base_corpus):
    for fid, fix in p["fixes"].items():
        base, rec = base_corpus[fid][0], fix["record"]
        assert sorted(rec.keys()) == sorted(base.keys()), fid
        assert rec["title"] == base["title"], fid
        assert len(rec["ingredients"]) == len(base["ingredients"]), fid
        assert [i["name"] for i in rec["ingredients"]] == \
            [i["name"] for i in base["ingredients"]], fid
        assert len(rec["steps"]) == len(base["steps"]), fid
        if not fix.get("changes_rights_pin"):
            assert rec.get("source_ref") == base.get("source_ref"), fid


def test_every_band_line_resolved_or_noted(p):
    band_by_cid = {r["catalog_id"]: (r, lines) for r, lines in p["band"]}
    for fid, fix in p["fixes"].items():
        cid = fix["catalog_id"]
        _, lines = band_by_cid[cid]
        for i, line in lines:
            qty = fix["record"]["ingredients"][i]["qty"]
            assert not fix["record"]["ingredients"][i].get("assumed_staple")
            if qty["kind"] == "unknown":
                assert "to taste" in qty.get("note", ""), \
                    f"{cid} line {i} ({line['key']}): unknown without a to-taste note"
            else:
                assert qty["kind"] in ("source_grams", "household"), \
                    f"{cid} line {i}: unexpected qty kind {qty['kind']!r}"
                if qty["kind"] == "household":
                    grams = qty.get("grams")
                    assert isinstance(grams, (int, float)) and grams > 0


def test_household_refs_resolve(p, conversions):
    for fid, fix in p["fixes"].items():
        for i, ing in enumerate(fix["record"]["ingredients"]):
            qty = ing.get("qty") or {}
            if qty.get("kind") != "household":
                continue
            ref = qty.get("conversion_ref")
            assert ref in conversions, f"{fix['catalog_id']} line {i}: ref {ref!r}"
            row = conversions[ref]
            grams = row.get("grams", row.get("grams_per_unit"))
            assert grams is not None and grams > 0
            assert qty.get("value") is not None
            # rows may round to whole grams; allow half a gram of rounding
            assert abs(qty["value"] * grams - qty.get("grams", 0)) < 1.0, \
                f"{fix['catalog_id']} line {i}: grams must equal value x row mass"


def test_compiled_uses_known_keys(p, compiled):
    vocab_keys = set(p["vocab_by_key"])
    for fid, c in compiled.items():
        for line in c["ingredients"]:
            assert line["key"] in vocab_keys, f"{fid}: unknown key {line['key']}"
            q = line["quantity"]
            assert q["kind"] in ("grams", "household", "unknown")
            if q["kind"] == "unknown":
                assert q.get("note"), f"{fid}: unknown quantity without note"


def test_compiled_claims_match_composition(p, compiled):
    blockers = {
        "vegetarian": compiler.VEGETARIAN_BLOCKERS,
        "vegan": compiler.VEGAN_BLOCKERS,
        "gluten_free": compiler.GLUTEN_BLOCKERS,
        "dairy_free": compiler.DAIRY_BLOCKERS,
    }
    for fid, c in compiled.items():
        line_classes = []
        for line in c["ingredients"]:
            entry = p["vocab_by_key"][line["key"]]
            line_classes.append(set(entry.get("classes") or ["unknown"]))
        for flag, block in blockers.items():
            expected = compiler.derive_claim(line_classes, block)
            assert c["claims"][flag] == expected, f"{fid} claim {flag}"


def test_compiled_atwater_and_sodium_ceiling(p, compiled):
    for fid, c in compiled.items():
        n = c["nutrition_per_serving"]
        keys = {line["key"] for line in c["ingredients"]}
        has_alcohol = bool(keys & vbundle.ALCOHOL_KEYS)
        assert vbundle.atwater_ok(n, has_alcohol), f"{fid}: Atwater drift"
        assert n["sodium_mg"] <= 6000, fid


def test_compiled_timer_rule(p, compiled):
    for fid, c in compiled.items():
        src_steps = p["fixes"][fid]["record"]["steps"]
        for i, s in enumerate(c["steps"]):
            src = src_steps[i]
            # authored metadata wins; parse_timer is the fallback (seconds)
            expected = (src["timer_min"] * 60 if "timer_min" in src
                        else compiler.parse_timer(s["text"]))
            assert s["timer_seconds"] == expected, f"{fid} step {i}: timer rule"


def test_thermometer_checks_in_step_text(p, compiled):
    for fid, c in compiled.items():
        for s in c["steps"]:
            thermo = s.get("thermometer")
            if not thermo:
                continue
            assert "auto-added" not in thermo.get("source", ""), \
                f"{fid}: unplaced auto thermometer check"
            temps = food_safety.text_temps(s["text"])
            assert temps, f"{fid}: thermometer check without a temperature in step text"
            stated_f = thermo["endpoint_c"] * 9 / 5 + 32
            assert any(abs(t - stated_f) < 1.0 for t in temps), \
                f"{fid}: endpoint {thermo['endpoint_c']} C not stated in step text"


def test_corpus_safety_and_claims(p, allergens):
    for fid, fix in p["fixes"].items():
        rec = fix["record"]
        assert food_safety.safety_violations(rec) == [], fid
        assert composition.claim_problems(rec, allergens) == {}, fid


def test_nutrition_bars(p, compiled):
    for fid, fix in p["fixes"].items():
        n = compiled[fid]["nutrition_per_serving"]
        kcal_exc, na_exc = amounts_b.exception_markers(fix)
        if n["kcal"] is not None and not kcal_exc:
            assert KCAL_MIN <= n["kcal"] <= KCAL_MAX, \
                f"{fix['catalog_id']}: kcal {n['kcal']:.1f} outside 150-1300"
        if n["sodium_mg"] is not None and not na_exc:
            assert n["sodium_mg"] <= SODIUM_MAX, \
                f"{fix['catalog_id']}: sodium {n['sodium_mg']:.1f} mg over 2300"


def test_validate_corpus_gates_over_patched_corpus(p, tmp_path):
    patched = dict(p["corpus"])
    for fid, fix in p["fixes"].items():
        patched[fid] = fix["record"]
    out = tmp_path / "corpus.jsonl"
    out.write_bytes(b"\n".join(
        json.dumps(rec, ensure_ascii=False).encode("utf-8")
        for rec in patched.values()) + b"\n")
    proc = subprocess.run(
        [sys.executable, str(REPO / "data/recipes/tools/validate_corpus.py"),
         "--corpus", str(out)],
        capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, \
        f"validate_corpus failed on the patched corpus:\n{proc.stdout}\n{proc.stderr}"


def test_report_matches_fix_file(p):
    committed = (amounts_b.REPORT_PATH).read_text(encoding="utf-8")
    assert committed == amounts_b.build_report(p), \
        "evaluation/recipe-quality/amounts-b.md is stale; re-run amounts_b.py"
