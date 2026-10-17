"""Tests for the band rcp-000935..rcp-000994 cook-review packet.

Packet burst14-fridgeluck-review-new-recipes (base alpha af856008).

The band is the 60 newest catalog recipes — the two October 16 originals
packets as shipped by the catalog rebuild: 30 breakfasts
(data/recipe-sources/breakfast-2026-10) and 30 pantry lunches/dinners
(data/recipe-sources/pantry-2026-10). This packet adds:

  - data/recipes/fixes/review-new.json — two text fixes where a step's stated
    time contradicts its own thermometer endpoint (poached eggs in
    rcp-000956, shrimp in rcp-000940);
  - evaluation/recipe-quality/review-new/review.py + findings.json — the
    hand review (verdict per recipe) merged with the mechanical sweep.

These tests assert:

  1. the fix file covers exactly the band's two defects and nothing else;
  2. every fix records the base corpus line's sha256 and swaps in a record of
     the same shape, with titles and ingredient names (the rights pin inputs)
     unchanged and changes_rights_pin unset;
  3. every recipe in the band has a hand verdict, and the verdict counts
     match the committed findings.json;
  4. the band's 60 records recompile with the repository's own compiler
     (with the kcal rows burst14-fridgeluck-kcal-pins replaces applied in
     memory) and pass the per-record checks validate_bundle.main enforces
     (vocabulary keys, Atwater consistency, claims vs composition, sodium
     ceiling, timer rule, thermometer checks resting in step text);
  5. per-serving kcal stays inside 150-1300 and sodium at or under 2300 mg
     unless the recipe's findings text explains the gap ("kcal floor" /
     "sodium" markers);
  6. the repository's own validate_corpus.py gates (rights, quarantine,
     release gates, dedupe, lint) exit 0 over the patched corpus.
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
    "review_new", REPO / "evaluation/recipe-quality/review-new/review.py")
review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review)

sys.path.insert(0, str(REPO / "data/recipes/tools"))
import compile_bundle as compiler  # noqa: E402
import composition  # noqa: E402
import food_safety  # noqa: E402
import validate_bundle as vbundle  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402

KCAL_MIN, KCAL_MAX = 150.0, 1300.0
SODIUM_MAX = 2300.0
VERDICTS = {"cookable as written", "needs a fix", "should be cut"}


@pytest.fixture(scope="module")
def doc():
    return json.loads(review.FIXES.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def corpus():
    loaded, raw = review.load_corpus()
    return loaded, raw


@pytest.fixture(scope="module")
def band(corpus):
    loaded, raw = corpus
    ids = review.band_ids(loaded)
    assert len(ids) == 60
    return {vcorpus.catalog_id_for(rid): (loaded[rid], raw[rid]) for rid in ids}


@pytest.fixture(scope="module")
def data():
    mappings = json.loads((REPO / "data/ingredients/name-mappings.json")
                          .read_text(encoding="utf-8"))["mappings"]
    vocab_by_key = review.patch_vocab({e["key"]: e for e in json.loads(
        (REPO / "data/ingredients/vocabulary.json")
        .read_text(encoding="utf-8"))["entries"]})
    rights = json.loads((REPO / "data/recipes/rights_manifest.json")
                        .read_text(encoding="utf-8"))["records"]
    loaded, _ = review.load_corpus()
    ctx = vcorpus.load_rights_context()
    labels = {rid: compiler.rights_label_for(rec, ctx) for rid, rec in loaded.items()}
    return mappings, vocab_by_key, rights, labels


@pytest.fixture(scope="module")
def compiled(band, data):
    mappings, vocab_by_key, rights, labels = data
    out = {}
    for cid, (rec, _) in band.items():
        out[cid] = compiler.compile_recipe(rec, mappings, vocab_by_key, rights, labels)
    return out


def test_packet_header(doc):
    assert doc["schema"] == "fridgeluck/corpus-fixes/v1"
    assert doc["packet"] == review.PACKET
    assert doc["base_commit"] == review.BASE_COMMIT


def test_fixes_cover_exactly_the_reviewed_defects(doc):
    fix_ids = {vcorpus.catalog_id_for(f["id"]) for f in doc["fixes"]}
    assert fix_ids == {"rcp-000940", "rcp-000956"}, \
        "the band's two time-vs-temperature contradictions, and nothing else"
    for fix in doc["fixes"]:
        assert fix["catalog_id"] == vcorpus.catalog_id_for(fix["id"])
        assert fix["changes"], f"{fix['id']}: every fix documents its changes"
        for change in fix["changes"]:
            assert change["evidence"], f"{fix['id']}: every change cites evidence"
        assert not fix.get("changes_rights_pin")


def test_before_sha256_matches_base(doc, band):
    for fix in doc["fixes"]:
        cid = vcorpus.catalog_id_for(fix["id"])
        digest = hashlib.sha256(band[cid][1].encode("utf-8")).hexdigest()
        assert fix["before_sha256"] == digest, cid


def test_shape_names_title_preserved(doc, band):
    for fix in doc["fixes"]:
        cid = vcorpus.catalog_id_for(fix["id"])
        base, _ = band[cid]
        rec = fix["record"]
        assert sorted(rec.keys()) == sorted(base.keys()), cid
        assert rec["title"] == base["title"], cid
        assert len(rec["ingredients"]) == len(base["ingredients"]), cid
        assert [i["name"] for i in rec["ingredients"]] == \
            [i["name"] for i in base["ingredients"]], cid
        assert len(rec["steps"]) == len(base["steps"]), cid
        changed = [c["path"] for c in fix["changes"]]
        assert len(changed) == len(set(changed)), cid
        for change in fix["changes"]:
            i = int(change["path"].split("[")[1].split("]")[0])
            assert rec["steps"][i]["text"] != base["steps"][i]["text"], cid
        assert rec.get("source_ref") == base.get("source_ref"), cid


def test_hand_review_covers_the_band(band, compiled):
    findings_path = review.FINDINGS
    committed = json.loads(findings_path.read_text(encoding="utf-8"))
    by_cid = {r["catalog_id"]: r for r in committed["recipes"]}
    assert set(by_cid) == set(band), "findings.json covers exactly the band"
    counts = {"cookable as written": 0, "needs a fix": 0, "should be cut": 0}
    for cid, r in by_cid.items():
        assert r["verdict"] in VERDICTS, cid
        counts[r["verdict"]] += 1
        n = compiled[cid]["nutrition_per_serving"]
        assert r["compiled_kcal_per_serving"] == pytest.approx(n["kcal"]), cid
        assert r["compiled_sodium_mg_per_serving"] == pytest.approx(n["sodium_mg"]), cid
        for f in r["findings"]:
            assert f["criterion"] and f["location"] and f["evidence"], cid
    assert counts == committed["counts"], "committed counts must match verdicts"


def test_fixed_verdicts_match_fix_file(doc, band):
    by_cid = {r["catalog_id"]: r["verdict"]
              for r in json.loads(review.FINDINGS.read_text(encoding="utf-8"))["recipes"]}
    for fix in doc["fixes"]:
        cid = vcorpus.catalog_id_for(fix["id"])
        assert by_cid[cid] == "needs a fix", \
            f"{cid}: a fix file entry must carry a matching verdict"


def test_band_compiles_with_known_keys(band, compiled, data):
    _, vocab_by_key, _, _ = data
    for cid, c in compiled.items():
        for line in c["ingredients"]:
            assert line["key"] in vocab_by_key, f"{cid}: unknown key {line['key']}"
            q = line["quantity"]
            assert q["kind"] in ("grams", "household", "unknown")
            if q["kind"] == "unknown":
                assert q.get("note"), f"{cid}: unknown quantity without note"


def test_band_claims_match_composition(band, data, compiled):
    _, vocab_by_key, _, _ = data
    blockers = {
        "vegetarian": compiler.VEGETARIAN_BLOCKERS,
        "vegan": compiler.VEGAN_BLOCKERS,
        "gluten_free": compiler.GLUTEN_BLOCKERS,
        "dairy_free": compiler.DAIRY_BLOCKERS,
    }
    for cid, c in compiled.items():
        line_classes = []
        for line in c["ingredients"]:
            entry = vocab_by_key[line["key"]]
            line_classes.append(set(entry.get("classes") or ["unknown"]))
        for flag, block in blockers.items():
            expected = compiler.derive_claim(line_classes, block)
            assert c["claims"][flag] == expected, f"{cid} claim {flag}"


def test_band_atwater_and_sodium_ceiling(compiled):
    for cid, c in compiled.items():
        n = c["nutrition_per_serving"]
        keys = {line["key"] for line in c["ingredients"]}
        has_alcohol = bool(keys & vbundle.ALCOHOL_KEYS)
        assert vbundle.atwater_ok(n, has_alcohol), f"{cid}: Atwater drift"
        assert n["sodium_mg"] <= 6000, cid


def test_band_timer_rule(band, compiled):
    for cid, (rec, _) in band.items():
        c = compiled[cid]
        for i, s in enumerate(c["steps"]):
            src = rec["steps"][i]
            # authored metadata wins; parse_timer is the fallback (seconds)
            expected = (src["timer_min"] * 60 if "timer_min" in src
                        else compiler.parse_timer(s["text"]))
            assert s["timer_seconds"] == expected, f"{cid} step {i}: timer rule"


def test_thermometer_checks_in_step_text(compiled):
    for cid, c in compiled.items():
        for s in c["steps"]:
            thermo = s.get("thermometer")
            if not thermo:
                continue
            assert "auto-added" not in thermo.get("source", ""), \
                f"{cid}: unplaced auto thermometer check"
            temps = food_safety.text_temps(s["text"])
            assert temps, f"{cid}: thermometer check without a temperature in step text"
            stated_f = thermo["endpoint_c"] * 9 / 5 + 32
            assert any(abs(t - stated_f) < 1.0 for t in temps), \
                f"{cid}: endpoint {thermo['endpoint_c']} C not stated in step text"


def test_band_safety_and_claims(band, allergens_path="data/recipes/suite/allergens.json"):
    allergens = json.loads((REPO / allergens_path).read_text(encoding="utf-8"))
    for cid, (rec, _) in band.items():
        assert food_safety.safety_violations(rec) == [], cid
        assert composition.claim_problems(rec, allergens) == {}, cid


def test_nutrition_bars_with_explained_exceptions(band, compiled):
    findings = {r["catalog_id"]: r
                for r in json.loads(review.FINDINGS.read_text(encoding="utf-8"))["recipes"]}
    for cid, c in compiled.items():
        n = c["nutrition_per_serving"]
        notes = json.dumps(findings[cid]["findings"], ensure_ascii=False)
        kcal_exc, na_exc = "kcal floor" in notes, "sodium" in notes
        if n["kcal"] is not None and not kcal_exc:
            assert KCAL_MIN <= n["kcal"] <= KCAL_MAX, \
                f"{cid}: kcal {n['kcal']:.1f} outside 150-1300"
        if n["sodium_mg"] is not None and not na_exc:
            assert n["sodium_mg"] <= SODIUM_MAX, \
                f"{cid}: sodium {n['sodium_mg']:.1f} mg over 2300"


def test_validate_corpus_gates_over_patched_corpus(corpus, doc, tmp_path):
    loaded, raw = corpus
    for fix in doc["fixes"]:
        loaded[fix["id"]] = fix["record"]
    out = tmp_path / "corpus.jsonl"
    out.write_bytes(b"\n".join(
        json.dumps(rec, ensure_ascii=False).encode("utf-8")
        for rec in loaded.values()) + b"\n")
    proc = subprocess.run(
        [sys.executable, str(REPO / "data/recipes/tools/validate_corpus.py"),
         "--corpus", str(out)],
        capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, \
        f"validate_corpus failed on the patched corpus:\n{proc.stdout}\n{proc.stderr}"
