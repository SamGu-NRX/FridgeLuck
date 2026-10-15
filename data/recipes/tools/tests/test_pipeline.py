"""Pipeline tests: normalization, FSIS helpers, determinism, and validation.

These are portable (no macOS/Xcode needed); they cover the Python pipeline
end to end by running the real builders against the committed corpus.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import jsonschema
import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

from pipeline.normalize import normalize_name, strip_prep  # noqa: E402
from pipeline import fsis  # noqa: E402

BUNDLE = REPO / "data/recipes/build/recipes-v2.json"


def run(*args: str) -> str:
    out = subprocess.run([sys.executable, *args], capture_output=True, text=True,
                         cwd=REPO)
    assert out.returncode == 0, out.stderr[-800:]
    return out.stdout


# ---- normalization ---------------------------------------------------------

def test_normalize_lowercases_and_compacts():
    assert normalize_name("Whole Milk") == "whole milk"
    assert normalize_name("  Red  Peppers! ") == "red peppers"


def test_strip_prep_removes_trailing_preparation_words():
    assert strip_prep("cod fillets") == "cod"
    assert strip_prep("rosemary sprigs") == "rosemary"
    assert strip_prep("cumin seeds lightly crushed") == "cumin seeds"
    assert strip_prep("cauliflower florets") == "cauliflower"


def test_strip_prep_keeps_qualifier_words():
    # words that change the food must survive
    assert strip_prep("cherry tomatoes") == "cherry tomatoes"
    assert strip_prep("ground pork") == "ground pork"


# ---- FSIS helpers ----------------------------------------------------------

def test_fsis_fahrenheit_to_celsius():
    assert fsis.f_to_c(165) == pytest.approx(73.9, abs=0.1)
    assert fsis.f_to_c(32) == pytest.approx(0.0, abs=0.01)


def test_fsis_poultry_endpoint_is_74c():
    # FSIS: 165 F for poultry, converted and pinned in Celsius
    assert fsis.FSIS_MIN_F["meat_poultry"][0] == 165
    assert fsis.f_to_c(165) == 73.9
    assert fsis.meets_endpoint("meat_poultry", 74.0)
    assert not fsis.meets_endpoint("meat_poultry", 73.0)
    assert fsis.meets_endpoint("egg", fsis.f_to_c(160))


# ---- mapping audit ---------------------------------------------------------

def test_every_corpus_ingredient_name_is_mapped():
    mappings = json.load((REPO / "data/ingredients/name-mappings.json").open())["mappings"]
    missing = set()
    for line in (REPO / "data/recipes/corpus.jsonl").read_text().splitlines():
        rec = json.loads(line)
        for ing in rec["ingredients"]:
            if normalize_name(ing["name"]) not in mappings:
                missing.add(ing["name"])
    assert not missing, f"unmapped corpus names: {sorted(missing)[:10]}"


# ---- vocabulary ------------------------------------------------------------

PER100_FIELDS = {"kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g",
                 "sodium_mg"}


def test_vocabulary_entries_are_complete():
    vocab = json.load((REPO / "data/ingredients/vocabulary.json").open())["entries"]
    keys = [e["key"] for e in vocab]
    assert len(keys) == len(set(keys)), "duplicate vocabulary keys"
    for e in vocab:
        assert e["fdc_id"] is None or e["fdc_id"] >= 100000
        p = e["per_100g"]
        if p is not None:
            assert PER100_FIELDS <= set(p), f"{e['key']}: per-100g missing fields"
            assert all(v >= 0 for v in p.values())


def test_identity_map_conforms_to_contract():
    schema = json.load(
        (REPO / "docs/spec/recipes/contracts/ingredient-identity.schema.json").open())
    doc = json.load((REPO / "data/recipes/legacy-ingredient-map.json").open())
    jsonschema.Draft202012Validator(schema).validate(doc)


# ---- bundle compile + validate --------------------------------------------

def test_bundle_exists_and_validates():
    out = run(str(TOOLS / "validate_bundle.py"), str(BUNDLE))
    assert out.strip().endswith("PASS")


def test_bundle_compiles_byte_identically():
    before = hashlib.md5(BUNDLE.read_bytes()).hexdigest()
    run(str(TOOLS / "build_vocab.py"))
    run(str(TOOLS / "compile_bundle.py"))
    after = hashlib.md5(BUNDLE.read_bytes()).hexdigest()
    assert before == after, "repeat compilation changed the bundle bytes"


def test_bundle_covers_whole_corpus():
    bundle = json.load(BUNDLE.open())
    corpus_ids = [json.loads(l)["id"] for l in
                  (REPO / "data/recipes/corpus.jsonl").read_text().splitlines()]
    assert len(bundle["recipes"]) == len(corpus_ids) == 401
    rights_ids = set(json.load(
        (REPO / "data/recipes/rights_manifest.json").open())["records"])
    assert rights_ids == set(corpus_ids)


def test_every_step_reference_and_quantity_is_wellformed():
    bundle = json.load(BUNDLE.open())
    ingredient_keys = {i["key"] for i in bundle["ingredients"]}
    for recipe in bundle["recipes"]:
        keys = [line["key"] for line in recipe["ingredients"]]
        assert all(k in ingredient_keys for k in keys)
        assert len(recipe["steps"]) >= 2
        assert len(recipe["ingredients"]) >= 2
        for step in recipe["steps"]:
            assert all(0 <= i < len(keys) for i in step["uses"])


# ---- validator catches seeded violations -----------------------------------

def test_validator_rejects_dangling_ingredient_reference():
    bundle = json.load(BUNDLE.open())
    bundle["recipes"][0]["ingredients"][0]["key"] = "not_an_ingredient"
    bad = REPO / "data/recipes/build/_seeded-bad.json"
    bad.write_text(json.dumps(bundle))
    try:
        out = subprocess.run([sys.executable, str(TOOLS / "validate_bundle.py"),
                              str(bad)], capture_output=True, text=True, cwd=REPO)
        assert out.returncode == 1
        assert "not_an_ingredient" in out.stdout
    finally:
        bad.unlink()


def test_validator_rejects_implausible_kcal():
    bundle = json.load(BUNDLE.open())
    n = bundle["recipes"][0]["nutrition_per_serving"]
    n["kcal"] = round(n["kcal"] * 5, 1)  # break the Atwater cross-check
    bad = REPO / "data/recipes/build/_seeded-bad-kcal.json"
    bad.write_text(json.dumps(bundle))
    try:
        out = subprocess.run([sys.executable, str(TOOLS / "validate_bundle.py"),
                              str(bad)], capture_output=True, text=True, cwd=REPO)
        assert out.returncode == 1
        assert "Atwater" in out.stdout
    finally:
        bad.unlink()
