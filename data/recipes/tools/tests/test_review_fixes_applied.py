"""The recipe-review fix packets reach the corpus and the shipped bundle.

data/recipes/fixes/review-new.json (#214) and review-fixed.json (#220) were
written by the cook's reviews and sat unapplied, so the bundle kept shipping
rcp-000247 "Almond and Honey Yogurt Bowl" with 3 tbsp of almonds measured as
435 g (1,564 kcal a serving). These tests pin:

  1. every fix in both packets is the corpus record (claims may only shrink,
     the one edit strip_unproven_claims.py makes after an apply);
  2. the shipped bundle (build copy and app copy) carries the fixed bodies:
     rcp-000247's almonds are tablespoon-sized and every fixed recipe sits in
     the 150-1300 kcal band the review held them to;
  3. every fixed recipe ships a higher revision than it did before the apply,
     so installed apps re-hydrate it;
  4. apply_corpus_fixes.py accepts a follow-up packet that pins an earlier
     fix's record, and still refuses two unrelated fixes of one recipe, a
     stale base, and a skipped chain link.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

import apply_corpus_fixes as acf  # noqa: E402
import bundle_revisions  # noqa: E402
import corpus_io  # noqa: E402

FIXES = REPO / "data/recipes/fixes"
PACKETS = ("review-new.json", "review-fixed.json")
BUNDLES = (REPO / "data/recipes/build/recipes-v2.json",
           REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json")

# Shipped revision of each fixed recipe before the packets were applied
# (bundle at dfa1dd28, PR #236). The fix changes every one of these bodies.
PRE_FIX_REVISION = {
    "rcp-000940": 1, "rcp-000956": 1, "rcp-000247": 1, "rcp-000391": 2,
    "rcp-000397": 2, "rcp-000401": 2, "rcp-000405": 1, "rcp-000406": 1,
    "rcp-000413": 1, "rcp-000442": 1, "rcp-000443": 1, "rcp-000444": 2,
    "rcp-000450": 2, "rcp-000463": 1, "rcp-000478": 2, "rcp-000561": 1,
}
KCAL_MIN, KCAL_MAX = 150.0, 1300.0
# 3 tbsp of toasted almonds is about 27 g; a tablespoon of whole or chopped
# almonds weighs well under 15 g, so 45 g for the whole bowl is a loose ceiling.
ALMOND_GRAMS_MAX = 45.0


def review_fixes() -> list[dict]:
    out = []
    for name in PACKETS:
        out.extend(json.loads((FIXES / name).read_text(encoding="utf-8"))["fixes"])
    return out


@pytest.fixture(scope="module", params=BUNDLES, ids=["build", "app"])
def shipped(request) -> dict[str, dict]:
    doc = json.loads(request.param.read_text(encoding="utf-8"))
    return {r["catalog_id"]: r for r in doc["recipes"]}


def test_packets_cover_the_expected_recipes():
    assert {f["catalog_id"] for f in review_fixes()} == set(PRE_FIX_REVISION)


def test_every_review_fix_is_the_corpus_record():
    corpus = {line.obj["id"]: line.obj for line in corpus_io.read_jsonl(corpus_io.CORPUS)}
    unapplied = []
    for fix in review_fixes():
        live, rec = corpus[fix["id"]], fix["record"]
        body_live = {k: v for k, v in live.items() if k != "claims"}
        body_fix = {k: v for k, v in rec.items() if k != "claims"}
        live_claims = {c["claim"] for c in live.get("claims", [])}
        fix_claims = {c["claim"] for c in rec.get("claims", [])}
        if body_live != body_fix or not live_claims <= fix_claims:
            unapplied.append(fix["catalog_id"])
    assert not unapplied, f"review fixes missing from corpus.jsonl: {unapplied}"


def test_rcp000247_almonds_are_tablespoon_sized(shipped):
    recipe = shipped["rcp-000247"]
    almonds = [line for line in recipe["ingredients"] if "almond" in line["key"]]
    assert almonds, "rcp-000247 lost its almonds line"
    grams = sum(line["quantity"]["grams"] for line in almonds)
    assert 0 < grams <= ALMOND_GRAMS_MAX, f"rcp-000247 ships {grams} g of almonds"
    kcal = recipe["nutrition_per_serving"]["kcal"]
    assert KCAL_MIN <= kcal <= 600, f"rcp-000247 ships {kcal} kcal a serving"


def test_fixed_recipes_ship_inside_the_kcal_band(shipped):
    outside = {cid: shipped[cid]["nutrition_per_serving"]["kcal"]
               for cid in PRE_FIX_REVISION
               if not KCAL_MIN <= shipped[cid]["nutrition_per_serving"]["kcal"] <= KCAL_MAX}
    assert not outside, f"kcal per serving outside 150-1300: {outside}"


def test_fixed_recipes_ship_a_higher_revision(shipped):
    ledger = bundle_revisions.load()
    stale = []
    for cid, before in PRE_FIX_REVISION.items():
        recipe = shipped[cid]
        assert ledger[cid][-1]["body_sha256"] == bundle_revisions.body_sha256(recipe), cid
        if recipe["revision"] <= before:
            stale.append(f"{cid} (revision {recipe['revision']})")
    assert not stale, f"fixed recipes keep their pre-fix revision: {stale}"


# ---- the applier on planted packets ----------------------------------------

def _record(rid: str, servings: int) -> dict:
    return {"id": rid, "title": f"Dish {rid}", "servings": servings}


def _line(record: dict) -> corpus_io.Line:
    raw = json.dumps(record, ensure_ascii=False)
    return corpus_io.Line(raw, json.loads(raw))


def _packet(tmp: Path, name: str, fixes: list[dict]) -> Path:
    path = tmp / name
    path.write_text(json.dumps({"schema": "fridgeluck/corpus-fixes/v1",
                                "packet": name, "fixes": fixes}), encoding="utf-8")
    return path


def _fix(base: dict, record: dict) -> dict:
    return {"id": base["id"], "before_sha256": acf.record_sha256(base), "record": record}


def test_applier_follows_a_review_chain(tmp_path):
    v0, v1, v2 = _record("r1", 2), _record("r1", 3), _record("r1", 4)
    first = _packet(tmp_path, "a.json", [_fix(v0, v1)])
    review = _packet(tmp_path, "b.json", [_fix(v1, v2)])
    # fresh corpus, every packet: the chain applies end to end
    assert acf.plan([first, review], [_line(v0)])["r1"][0] == v2
    # first packet already applied: only the follow-up is named
    assert acf.plan([first, review], [_line(v1)], {"b.json"})["r1"][0] == v2
    # ...and naming every packet then refuses the applied one as stale
    with pytest.raises(SystemExit, match="before_sha256"):
        acf.plan([first, review], [_line(v1)])


def test_applier_refuses_two_decisions_for_one_recipe(tmp_path):
    v0 = _record("r1", 2)
    one = _packet(tmp_path, "a.json", [_fix(v0, _record("r1", 3))])
    other = _packet(tmp_path, "b.json", [_fix(v0, _record("r1", 4))])
    with pytest.raises(SystemExit, match="one recipe, one decision"):
        acf.plan([one, other], [_line(v0)], {"b.json"})


def test_applier_refuses_a_stale_base(tmp_path):
    v0 = _record("r1", 2)
    packet = _packet(tmp_path, "a.json", [_fix(v0, _record("r1", 3))])
    with pytest.raises(SystemExit, match="corpus moved"):
        acf.plan([packet], [_line(_record("r1", 5))])


def test_applier_refuses_a_skipped_chain_link(tmp_path):
    v0, v1, v2, v3 = (_record("r1", n) for n in (2, 3, 4, 5))
    files = [_packet(tmp_path, "a.json", [_fix(v0, v1)]),
             _packet(tmp_path, "b.json", [_fix(v1, v2)]),
             _packet(tmp_path, "c.json", [_fix(v2, v3)])]
    with pytest.raises(SystemExit, match="skip a link"):
        acf.plan(files, [_line(v0)], {"a.json", "c.json"})


def test_record_sha256_is_the_packet_line_digest():
    record = {"id": "r1", "text": "145 °F"}
    assert acf.record_sha256(record) == hashlib.sha256(
        json.dumps(record, ensure_ascii=False).encode("utf-8")).hexdigest()
