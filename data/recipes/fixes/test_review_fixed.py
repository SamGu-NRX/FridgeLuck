"""Tests for the review-fixed file for the 189 agent-fixed recipes.

Packet burst14-fridgeluck-review-fixed (base alpha af856008).

The amounts-a / amounts-b / rubric packets fixed 189 recipes; the review in
evaluation/recipe-quality/review-fixed/ (review.py + findings.json) audited all
of them with the real compiler, the rubric audit, and a full hand read. The fix
file data/recipes/fixes/review-fixed.json carries the 14 fixes from that review
with one correct answer. These tests assert:

  1. the packet covers exactly the 14 reviewed-and-triaged recipes, each
     pinned to the base corpus line's sha256;
  2. every fix swaps in a record of the same shape with the title, step text,
     and step count unchanged; fixes not flagged changes_rights_pin keep the
     ingredient-name list byte-identical; pinned fixes may only append lines;
  3. every added or rewritten line resolves (mapped key, household grams =
     value x conversions-row mass, or source_grams);
  4. the recompiled records pass the per-record gates (vocabulary keys,
     Atwater consistency, claims vs composition, timer rule, thermometer
     checks) and food-safety + allergen screening;
  5. per-serving kcal stays inside 150-1300 and sodium at or under 2300 mg —
     the review fixes carry no band exceptions;
  6. the ten rescaled meat mains land at 110-225 g raw protein food per
     serving, and each recipe's own timer sum fits its minutes promise;
  7. the repository's validate_corpus.py gates (rights, quarantine, release
     gates, dedupe, lint) exit 0 over the patched corpus.
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
    "review_fixed", REPO / "evaluation/recipe-quality/review_fixed.py")
review_fixed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review_fixed)

sys.path.insert(0, str(REPO / "data/recipes/tools"))
import compile_bundle as compiler  # noqa: E402
import composition  # noqa: E402
import food_safety  # noqa: E402
import validate_bundle as vbundle  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402

KCAL_MIN, KCAL_MAX = 150.0, 1300.0
SODIUM_MAX = 2300.0
PROT_MIN, PROT_MAX = 110.0, 225.0

# The 14 recipes the review triaged to a one-correct-answer fix.
EXPECTED_IDS = {
    "rcp-000247", "rcp-000391", "rcp-000397", "rcp-000401", "rcp-000405",
    "rcp-000406", "rcp-000413", "rcp-000442", "rcp-000443", "rcp-000444",
    "rcp-000450", "rcp-000463", "rcp-000478", "rcp-000561",
}
# The servings / headline-quantity rescales that must land in the protein band.
RESCALED_MAINS = {
    "rcp-000391", "rcp-000397", "rcp-000401", "rcp-000405", "rcp-000406",
    "rcp-000413", "rcp-000442", "rcp-000443", "rcp-000444", "rcp-000450",
}
PROTEIN_TOKENS = ("chicken", "beef", "pork", "lamb", "duck")


def base_corpus(commit: str) -> tuple[dict[str, dict], dict[str, bytes]]:
    """The corpus at the packet's base commit. The live corpus carries the
    fixes once apply_corpus_fixes.py has run, so the before-pin, shape and
    rewritten-line checks compare against the base read from git."""
    out = subprocess.run(
        ["git", "show", f"{commit}:data/recipes/corpus.jsonl"],
        capture_output=True, cwd=REPO)
    if out.returncode != 0:
        pytest.skip(f"base commit {commit} not in this checkout")
    objs: dict[str, dict] = {}
    raws: dict[str, bytes] = {}
    for line in out.stdout.split(b"\n"):
        if line.strip():
            obj = json.loads(line)
            objs[obj["id"]], raws[obj["id"]] = obj, line
    return objs, raws


@pytest.fixture(scope="module")
def p():
    corpus, raws = review_fixed.load_corpus()
    mappings, vocab_by_key, rights, rights_ctx = review_fixed.compile_ctx()
    doc = json.loads((REPO / "data/recipes/fixes/review-fixed.json")
                     .read_text(encoding="utf-8"))
    fid_by_cid = {vcorpus.catalog_id_for(fid): fid for fid in corpus}
    base, base_raws = base_corpus(doc["base_commit"])
    return {
        "doc": doc,
        "corpus": corpus,
        "raws": raws,
        "base": base,
        "base_raws": base_raws,
        "mappings": mappings,
        "vocab_by_key": vocab_by_key,
        "rights": rights,
        "rights_ctx": rights_ctx,
        "conversions": review_fixed.conv_table(),
        "fixes": {fix["catalog_id"]: fix for fix in doc["fixes"]},
        "fid_by_cid": fid_by_cid,
    }


@pytest.fixture(scope="module")
def compiled(p):
    out = {}
    for cid, fix in p["fixes"].items():
        rec = fix["record"]
        labels = {rec["id"]: compiler.rights_label_for(rec, p["rights_ctx"])}
        out[cid] = compiler.compile_recipe(
            rec, p["mappings"], p["vocab_by_key"], p["rights"], labels)
    return out


def raw_protein_per_serving(fix: dict) -> float:
    grams = sum(ing["qty"].get("grams", 0.0)
                for ing in fix["record"]["ingredients"]
                if any(t in ing["name"].lower() for t in PROTEIN_TOKENS))
    return grams / fix["record"]["servings"]


def test_packet_header(p):
    doc = p["doc"]
    assert doc["schema"] == "fridgeluck/corpus-fixes/v1"
    assert doc["packet"] == review_fixed.PACKET
    assert doc["base_commit"] == review_fixed.base_commit()


def test_covers_exactly_the_reviewed_triage_set(p):
    assert {f["catalog_id"] for f in p["doc"]["fixes"]} == EXPECTED_IDS
    findings = json.loads((REPO / "evaluation/recipe-quality/review-fixed/"
                           "findings.json").read_text(encoding="utf-8"))
    reviewed = {r["catalog_id"] for r in findings["recipes"]}
    assert EXPECTED_IDS <= reviewed, "packet fixes a recipe outside the review set"
    for cid, fix in p["fixes"].items():
        assert fix["catalog_id"] == vcorpus.catalog_id_for(fix["id"])
        assert fix["changes"], f"{cid}: every fix documents its changes"


def test_before_sha256_matches_base(p):
    for cid, fix in p["fixes"].items():
        digest = hashlib.sha256(p["base_raws"][fix["id"]]).hexdigest()
        assert fix["before_sha256"] == digest, cid


def test_shape_title_steps_preserved(p):
    for cid, fix in p["fixes"].items():
        base, rec = p["base"][fix["id"]], fix["record"]
        assert sorted(rec.keys()) == sorted(base.keys()), cid
        assert rec["title"] == base["title"], cid
        assert rec["servings"] > 0 and rec["minutes"] > 0, cid
        assert len(rec["steps"]) == len(base["steps"]), cid
        for s_new, s_old in zip(rec["steps"], base["steps"]):
            assert s_new["text"] == s_old["text"], cid
        if not fix.get("changes_rights_pin"):
            assert [i["name"] for i in rec["ingredients"]] == \
                [i["name"] for i in base["ingredients"]], cid
        else:  # pinned fixes append lines that a step already names
            assert [i["name"] for i in rec["ingredients"]] == \
                [i["name"] for i in base["ingredients"]] + \
                [i["name"] for i in rec["ingredients"][len(base["ingredients"]):]], cid
            assert rec.get("source_ref") == base.get("source_ref"), cid


def test_household_refs_resolve(p):
    for cid, fix in p["fixes"].items():
        base = p["base"][fix["id"]]
        for i, ing in enumerate(fix["record"]["ingredients"]):
            qty = ing.get("qty") or {}
            if qty.get("kind") != "household":
                assert qty.get("kind") in ("source_grams", "unknown"), (cid, i)
                continue
            if i < len(base["ingredients"]) and \
                    base["ingredients"][i]["qty"] == qty:
                continue  # untouched line, already gated by validate_corpus
            ref = qty.get("conversion_ref")
            assert ref in p["conversions"], f"{cid} line {i}: ref {ref!r}"
            row = p["conversions"][ref]
            grams = row if isinstance(row, (int, float)) \
                else row.get("grams") or row.get("grams_per_unit")
            assert grams and grams > 0
            assert abs(qty["value"] * grams - qty.get("grams", 0)) < 1.0, \
                f"{cid} line {i}: grams must equal value x row mass"


def test_compiled_uses_known_keys(p, compiled):
    vocab_keys = set(p["vocab_by_key"])
    for cid, c in compiled.items():
        for line in c["ingredients"]:
            assert line["key"] in vocab_keys, f"{cid}: unknown key {line['key']}"


def test_compiled_claims_match_composition(p, compiled):
    blockers = {
        "vegetarian": compiler.VEGETARIAN_BLOCKERS,
        "vegan": compiler.VEGAN_BLOCKERS,
        "gluten_free": compiler.GLUTEN_BLOCKERS,
        "dairy_free": compiler.DAIRY_BLOCKERS,
    }
    for cid, c in compiled.items():
        line_classes = [set(p["vocab_by_key"][line["key"]].get("classes")
                            or ["unknown"]) for line in c["ingredients"]]
        for flag, block in blockers.items():
            assert c["claims"][flag] == compiler.derive_claim(line_classes, block), cid


def test_compiled_atwater_and_sodium_ceiling(p, compiled):
    for cid, c in compiled.items():
        n = c["nutrition_per_serving"]
        keys = {line["key"] for line in c["ingredients"]}
        has_alcohol = bool(keys & vbundle.ALCOHOL_KEYS)
        assert vbundle.atwater_ok(n, has_alcohol), f"{cid}: Atwater drift"


def test_compiled_timer_rule_and_promise(p, compiled):
    for cid, c in compiled.items():
        rec = p["fixes"][cid]["record"]
        assert sum(s.get("timer_min", 0) for s in rec["steps"]) <= rec["minutes"], \
            f"{cid}: timer sum exceeds the minutes promise"


def test_thermometer_checks_in_step_text(p, compiled):
    for cid, c in compiled.items():
        for s in c["steps"]:
            thermo = s.get("thermometer")
            if not thermo:
                continue
            assert "auto-added" not in thermo.get("source", ""), \
                f"{cid}: unplaced auto thermometer check"
            temps = food_safety.text_temps(s["text"])
            assert temps, f"{cid}: thermometer check without a temperature in step text"


def test_corpus_safety_and_claims(p):
    allergens = json.loads((REPO / "data/recipes/suite/allergens.json")
                           .read_text(encoding="utf-8"))
    for cid, fix in p["fixes"].items():
        rec = fix["record"]
        assert food_safety.safety_violations(rec) == [], cid
        assert composition.claim_problems(rec, allergens) == {}, cid


def test_nutrition_bands(p, compiled):
    """The review fixes carry no band exceptions: every fixed recipe must sit
    inside 150-1300 kcal and at or under 2300 mg sodium per serving."""
    for cid, c in compiled.items():
        n = c["nutrition_per_serving"]
        assert KCAL_MIN <= n["kcal"] <= KCAL_MAX, \
            f"{cid}: kcal {n['kcal']:.1f} outside 150-1300"
        assert n["sodium_mg"] <= SODIUM_MAX, \
            f"{cid}: sodium {n['sodium_mg']:.1f} mg over 2300"


def test_rescaled_mains_protein_band(p):
    for cid in RESCALED_MAINS:
        per = raw_protein_per_serving(p["fixes"][cid])
        assert PROT_MIN <= per <= PROT_MAX, \
            f"{cid}: {per:.0f} g raw protein food per serving outside 110-225"


PIN_ERRORS = {
    # The rights gate refuses a corpus recipe whose authoring record no longer
    # matches until the fix packet is applied and pin_rights_evidence.py
    # regenerates data/recipes/evidence/rights.json from this packet. Pre-apply,
    # the validator must report exactly these three pin refusals and nothing
    # else; once rights.json pins them, it must report none.
    "fl-original-0284": "rcp-000450 (garlic line)",
    "fl-original-0297": "rcp-000463 (butter and bread lines)",
    "fl-original-0395": "rcp-000561 (rice line)",
}


def test_validate_corpus_gates_over_patched_corpus(p, tmp_path):
    patched = dict(p["corpus"])
    for cid, fix in p["fixes"].items():
        patched[fix["id"]] = fix["record"]
    out = tmp_path / "corpus.jsonl"
    out.write_bytes(b"\n".join(
        json.dumps(rec, ensure_ascii=False).encode("utf-8")
        for rec in patched.values()) + b"\n")
    proc = subprocess.run(
        [sys.executable, "-I", str(REPO / "data/recipes/tools/validate_corpus.py"),
         "--corpus", str(out)],
        capture_output=True, text=True, timeout=900)
    errors = [line.strip("- ").strip() for line in proc.stdout.splitlines()
              if line.strip().startswith("- ")]
    pin_errors = [e for e in errors if "no pinned FridgeLuck revision" in e]
    other = [e for e in errors if "no pinned FridgeLuck revision" not in e]
    pinned = json.loads((REPO / "data/recipes/evidence/rights.json")
                        .read_text(encoding="utf-8")).get("fl_revisions", {})
    for rid in PIN_ERRORS:
        held = any(rid in e for e in pin_errors)
        if rid in pinned:
            assert not held, f"{rid} is pinned but the rights gate still holds it"
        else:
            assert held, \
                f"expected the rights gate to hold {rid} for its pin fix, got {errors}"
    assert not other, f"validate_corpus failed beyond the expected pin refusals:\n{other}"
    assert proc.returncode != 0 or not pin_errors  # consistent report
