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
    # Self-contained on a fresh clone: the compiler reads only committed inputs
    # (corpus, vocabulary, mappings, rights) with a pinned GENERATED_AT, so the
    # committed build copy must equal a fresh compile's bytes. The vocabulary
    # REBUILD is a separate operator-only property (see
    # test_vocab_rebuild_deterministic) because it needs pinned external
    # downloads that cannot be committed.
    before = hashlib.md5(BUNDLE.read_bytes()).hexdigest()
    run(str(TOOLS / "compile_bundle.py"))
    after = hashlib.md5(BUNDLE.read_bytes()).hexdigest()
    assert before == after, "recompilation changed the bundle bytes"


def test_vocab_rebuild_deterministic():
    # build_vocab.py needs the pinned external inputs (/tmp/fdc USDA bulk CSVs,
    # /tmp/canon ingredient-facts) documented in its header; those cannot be
    # committed (size/licence). When an operator with the pinned inputs runs
    # the suite, the rebuild must stay byte-stable.
    fdc = Path("/tmp/fdc/FoodData_Central_survey_food_csv_2024-10-31")
    canon = Path("/tmp/canon/identities.json")
    if not (fdc.is_dir() and canon.is_file()):
        pytest.skip("pinned external FDC/canon inputs not present (operator-only)")
    vocab = REPO / "data/ingredients/vocabulary.json"
    before = hashlib.md5(vocab.read_bytes()).hexdigest()
    run(str(TOOLS / "build_vocab.py"))
    after = hashlib.md5(vocab.read_bytes()).hexdigest()
    assert before == after, "vocabulary rebuild changed the bytes"


def test_bundle_covers_whole_corpus():
    bundle = json.load(BUNDLE.open())
    corpus_ids = [json.loads(l)["id"] for l in
                  (REPO / "data/recipes/corpus.jsonl").read_text().splitlines()]
    assert len(bundle["recipes"]) == len(corpus_ids) == 822
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


def _seed(mutate):
    """Load the bundle, apply mutate(bundle), write it to a scratch file."""
    bundle = json.load(BUNDLE.open())
    mutate(bundle)
    bad = REPO / "data/recipes/build/_seeded-review.json"
    bad.write_text(json.dumps(bundle))
    return bad


def _run_validator(path):
    return subprocess.run([sys.executable, str(TOOLS / "validate_bundle.py"),
                           str(path)], capture_output=True, text=True, cwd=REPO)


def _recipe_with_class(bundle, want):
    """First recipe holding a line whose vocabulary classes contain want."""
    import build_vocab
    classes = {e["key"]: set(e.get("classes", []))
               for e in json.load(
                   (REPO / "data/ingredients/vocabulary.json").open())["entries"]}
    for recipe in bundle["recipes"]:
        for idx, line in enumerate(recipe["ingredients"]):
            if want in classes.get(line["key"], set()):
                return recipe, idx
    raise AssertionError(f"no recipe with a {want!r} line")


def test_validator_rejects_vegetarian_claim_on_meat_line():
    # Review finding 1: the claim check must actually fire. Before the fix
    # (singular 'class' lookup) this seeded bundle validated PASS.
    def seed(bundle):
        recipe, _ = _recipe_with_class(bundle, "meat")
        recipe["claims"]["vegetarian"] = True
    bad = _seed(seed)
    try:
        out = _run_validator(bad)
        assert out.returncode == 1, f"claim check is fail-open: {out.stdout[-300:]}"
        assert "claims vegetarian" in out.stdout
    finally:
        bad.unlink()


def test_claim_blockers_use_real_class_names():
    # Review finding 1, second half: 'dairy_egg' is a category, not a class;
    # blockers must name classes the vocabulary actually emits.
    import validate_bundle
    vocab_classes = {c for e in json.load(
        (REPO / "data/ingredients/vocabulary.json").open())["entries"]
        for c in e.get("classes", [])}
    for claim, blockers in validate_bundle.CLAIM_BLOCKERS.items():
        assert blockers <= vocab_classes, f"{claim} blocks non-existent classes"
    assert validate_bundle.CLAIM_BLOCKERS["vegan"] == {
        "meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"}
    # 'animal' and 'honey' are real classes the vocabulary emits (ghee, honey,
    # mayonnaise are coarse 'animal' entries); a vegan gate that ignored them
    # would fail open on those lines.
    # lacto-ovo convention: shellfish is out for vegetarian too
    assert validate_bundle.CLAIM_BLOCKERS["vegetarian"] == {
        "meat", "fish", "shellfish"}


def test_validator_rejects_sub_fsis_thermometer_endpoint():
    # Review finding 2: a real endpoint below the FSIS minimum of the check's
    # OWN cited class must fail. 60 C is under every meat/fish/egg minimum.
    def seed(bundle):
        recipe, idx = _recipe_with_class(bundle, "meat")
        recipe["steps"][0]["uses"] = [idx]
        recipe["steps"][0]["thermometer"] = {
            "endpoint_c": 60.0, "food": "poultry", "fsis_class": "meat_poultry",
            "source": "usda-fsis: meat_poultry 165 F"}
    bad = _seed(seed)
    try:
        out = _run_validator(bad)
        assert out.returncode == 1, f"endpoint check is fail-open: {out.stdout[-300:]}"
        assert "below the FSIS minimum" in out.stdout
    finally:
        bad.unlink()


def test_validator_accepts_compliant_thermometer_endpoint():
    # A compliant endpoint must not trip the class-relevance gate nor the
    # per-class minimum check: the vocabulary's coarse 'meat' class allows a
    # 165 F poultry row (the old strictest-of-classes proxy rejected it).
    def seed(bundle):
        recipe, idx = _recipe_with_class(bundle, "meat")
        recipe["steps"][0]["uses"] = [idx]
        recipe["steps"][0]["thermometer"] = {
            "endpoint_c": 74.0, "food": "poultry", "fsis_class": "meat_poultry",
            "source": "usda-fsis: meat_poultry 165 F"}
    bad = _seed(seed)
    try:
        out = _run_validator(bad)
        assert out.returncode == 0, out.stdout[-400:]
    finally:
        bad.unlink()


def test_validator_rejects_thermometer_class_without_basis():
    # A check whose class has no basis in the recipe (no meat/fish/shellfish/egg
    # line, not leftovers, nothing required by the gate) is a defect even at a
    # compliant temperature — a fruit salad claiming a poultry rule.
    def seed(bundle):
        recipe, idx = _recipe_with_class(bundle, "plant")
        recipe["steps"][0]["uses"] = [idx]
        recipe["steps"][0]["thermometer"] = {
            "endpoint_c": 74.0, "food": "poultry", "fsis_class": "meat_poultry",
            "source": "usda-fsis: meat_poultry 165 F"}
    bad = _seed(seed)
    try:
        out = _run_validator(bad)
        assert out.returncode == 1, out.stdout[-300:]
        assert "has no basis in this recipe" in out.stdout
    finally:
        bad.unlink()


def test_per_serving_kcal_fails_loud_outside_range():
    # Review finding 3: the compiler must refuse out-of-range kcal instead of
    # silently clamping to 10 or 2500 (sodium already fails loudly).
    import compile_bundle
    totals = {"kcal": 2600.0 * 4}  # 4 servings
    with pytest.raises(SystemExit):
        compile_bundle.per_serving_kcal(totals, 4)
    with pytest.raises(SystemExit):
        compile_bundle.per_serving_kcal({"kcal": 5.0 * 4}, 4)
    assert compile_bundle.per_serving_kcal({"kcal": 500.0 * 4}, 4) == 500.0


def test_bundle_contains_no_clamped_values():
    # The fail-loud switch changes no shipped number: no recipe sits on a
    # clamp bound (verified live max 1844.7 kcal, min 25.3).
    bundle = json.load(BUNDLE.open())
    for recipe in bundle["recipes"]:
        kcal = recipe["nutrition_per_serving"]["kcal"]
        assert kcal not in (10.0, 2500.0), recipe["catalog_id"]


def test_surface_mapping_targets_all_exist_in_vocabulary():
    # Review finding 4: KEY_OVERRIDES must not carry entries whose target key
    # the vocabulary never emits — 'cherry tomatoes' -> 'cherry_tomato' was
    # shadowed by a later duplicate and silently dead.
    import build_vocab
    vocab_keys = {e["key"] for e in json.load(
        (REPO / "data/ingredients/vocabulary.json").open())["entries"]}
    targets = {target for target, _ in build_vocab.KEY_OVERRIDES.values()}
    assert targets <= vocab_keys, f"dead targets: {sorted(targets - vocab_keys)}"


def test_vocabulary_every_entry_carries_classes():
    # The bundle claim/FSIS gates read the vocabulary's classes list; an entry
    # without one would silently lose every gate. 'unknown' is the documented
    # fail-closed marker (composition.py): five keys are fully unknown
    # (stocks, dashi, curry pastes), and partial carriers must keep at least
    # one decisive class so their known gates still work.
    entries = json.load((REPO / "data/ingredients/vocabulary.json").open())["entries"]
    missing = [e["key"] for e in entries if not e.get("classes")]
    assert not missing, f"entries without classes: {missing[:5]}"
    fully_unknown = sorted(e["key"] for e in entries
                           if set(e["classes"]) == {"unknown"})
    assert fully_unknown == ["broth", "dashi", "green_curry_paste",
                             "massaman_curry_paste", "stock"]
    partial = [e for e in entries
               if "unknown" in e["classes"] and set(e["classes"]) != {"unknown"}]
    undecided = [e["key"] for e in partial if not (set(e["classes"]) - {"unknown"})]
    assert not undecided, f"partial unknown without any decisive class: {undecided}"


def test_bundle_ingredients_carry_vocabulary_classes():
    # The app's diet/allergen gate reads classes off bundle ingredients; the
    # vocabulary is the evidence the bundle must not drift from.
    import validate_bundle
    bundle = json.load(BUNDLE.open())
    vocab_classes = {e["key"]: set(e.get("classes") or []) for e in json.load(
        (REPO / "data/ingredients/vocabulary.json").open())["entries"]}
    for ing in bundle["ingredients"]:
        assert set(ing["classes"]) == vocab_classes[ing["key"]], ing["key"]


def test_bundle_thermometers_carry_fsis_class():
    # Every shipped check must name its FSIS row and meet that row's minimum —
    # the endpoint check governs the cited row, not a coarse class proxy.
    from pipeline import fsis
    bundle = json.load(BUNDLE.open())
    carried = 0
    for recipe in bundle["recipes"]:
        for step in recipe["steps"]:
            thermo = step["thermometer"]
            if thermo is None:
                continue
            carried += 1
            cls = thermo["fsis_class"]
            assert cls in fsis.FSIS_MIN_F, (recipe["catalog_id"], cls)
            min_c = fsis.f_to_c(fsis.FSIS_MIN_F[cls][0])
            assert thermo["endpoint_c"] + 1e-9 >= min_c, recipe["catalog_id"]
    assert carried > 400, carried  # the corpus's 468 authored safety blocks


def test_bundle_timers_prefer_authored_metadata():
    # Corpus steps with an authored timer_min must ship exactly those seconds;
    # steps without one fall back to the text parser.
    import validate_corpus, compile_bundle
    corpus = [json.loads(line)
              for line in (REPO / "data/recipes/corpus.jsonl")
              .read_text(encoding="utf-8").splitlines() if line.strip()]
    bundle = json.load(BUNDLE.open())
    by_id = {r["catalog_id"]: r for r in bundle["recipes"]}
    checked = 0
    for rec in corpus:
        recipe = by_id[validate_corpus.catalog_id_for(rec["id"])]
        for i, step in enumerate(rec["steps"]):
            shipped = recipe["steps"][i]["timer_seconds"]
            if "timer_min" in step:
                assert shipped == step["timer_min"] * 60, (rec["id"], i)
                checked += 1
            elif step.get("safety") is None:
                # no authored metadata: the text parse is the only source left
                assert shipped == compile_bundle.parse_timer(step["text"]), (rec["id"], i)
    assert checked > 900, checked


def test_bundle_claims_derive_from_classes_fail_closed():
    # Derivation is a safety net over the authored claims: on this corpus every
    # class-supported true claim is already authored (it adds none), but it
    # must never let a shipped-true claim stand against a blocking class, and
    # a shipped-false claim must never sit on all-known supporting lines.
    import compile_bundle
    bundle = json.load(BUNDLE.open())
    ingredients = {i["key"]: i for i in bundle["ingredients"]}
    contradictions = []
    false_on_supporting = []
    for recipe in bundle["recipes"]:
        line_classes = [set(ingredients[line["key"]]["classes"])
                        for line in recipe["ingredients"]]
        for claim, blockers in validate_bundle_claim_blockers():
            shipped = recipe["claims"][claim]
            derived = compile_bundle.derive_claim(line_classes, blockers)
            if shipped is True and derived is False:
                contradictions.append((recipe["catalog_id"], claim))
            if shipped is False and derived is True:
                false_on_supporting.append((recipe["catalog_id"], claim))
    assert not contradictions, contradictions[:5]
    assert not false_on_supporting, false_on_supporting[:5]


def validate_bundle_claim_blockers():
    import validate_bundle
    return sorted(validate_bundle.CLAIM_BLOCKERS.items())


def test_compiler_auto_adds_uncovered_thermometer_check():
    # A corpus edit that leaves a charted class uncovered cannot compile
    # silently: the compiler auto-adds a check on the first step that cooks
    # one of the class's ingredients (the committed corpus is gate-clean, so
    # this exercises the synthetic path).
    import compile_bundle
    rec = {
        "id": "test-auto-check",
        "title": "Chicken Soup",
        "ingredients": [{"name": "chicken breasts"}, {"name": "carrot"}],
        "steps": [
            {"text": "Slice the carrot into rounds and set aside."},
            {"text": "Simmer the chicken breasts in water until cooked through."},
        ],
    }
    import food_safety
    required = food_safety.required_classes(rec)
    assert set(required) == {"meat_poultry"}
    placed = compile_bundle.thermometer_checks(rec)
    assert set(placed) == {1}
    check = placed[1]
    assert check["fsis_class"] == "meat_poultry"
    assert check["endpoint_c"] >= 73.8  # 165 F
    assert "auto-added" in check["source"]
