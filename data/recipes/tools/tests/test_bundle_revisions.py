"""bundle_revisions: the compiled bundle's revisions come from the ledger, a
changed body never ships under an old revision, and history is append-only."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

import bundle_revisions  # noqa: E402

BUNDLE = REPO / "data/recipes/build/recipes-v2.json"


def recipe(cid: str, kcal: float) -> dict:
    return {"catalog_id": cid, "revision": None, "title": "Rice bowl",
            "nutrition_per_serving": {"kcal": kcal}}


def entry(revision: int, r: dict) -> dict:
    return {"revision": revision, "body_sha256": bundle_revisions.body_sha256(r)}


def test_body_hash_ignores_revision_and_key_order():
    a = recipe("rcp-1", 453.1)
    b = {"nutrition_per_serving": {"kcal": 453.1}, "title": "Rice bowl",
         "revision": 7, "catalog_id": "rcp-1"}
    assert bundle_revisions.body_sha256(a) == bundle_revisions.body_sha256(b)
    assert bundle_revisions.body_sha256(a) != bundle_revisions.body_sha256(
        recipe("rcp-1", 866.1))


def test_unchanged_body_keeps_its_revision():
    r = recipe("rcp-1", 453.1)
    ledger = {"rcp-1": [entry(1, recipe("rcp-1", 866.1)), entry(2, r)]}
    assert bundle_revisions.assign([r], ledger, bump=False) == []
    assert r["revision"] == 2


def test_changed_body_refuses_without_bump_naming_the_recipe():
    old, new = recipe("rcp-261", 866.1), recipe("rcp-261", 453.1)
    ledger = {"rcp-261": [entry(1, old)]}
    with pytest.raises(SystemExit, match="rcp-261.*--bump-revisions"):
        bundle_revisions.assign([new], ledger, bump=False)
    assert ledger == {"rcp-261": [entry(1, old)]}


def test_bump_appends_and_keeps_the_old_revision_frozen():
    old, new = recipe("rcp-261", 866.1), recipe("rcp-261", 453.1)
    ledger = {"rcp-261": [entry(1, old)]}
    assert bundle_revisions.assign([new], ledger, bump=True) == ["rcp-261"]
    assert new["revision"] == 2
    assert ledger["rcp-261"] == [entry(1, old), entry(2, new)]


def test_returning_to_an_older_body_still_moves_forward():
    a, b = recipe("rcp-1", 100.0), recipe("rcp-1", 200.0)
    ledger = {"rcp-1": [entry(1, a), entry(2, b)]}
    back = recipe("rcp-1", 100.0)
    with pytest.raises(SystemExit):
        bundle_revisions.assign([back], ledger, bump=False)
    bundle_revisions.assign([back], ledger, bump=True)
    assert back["revision"] == 3


def test_new_recipe_needs_bump_and_starts_at_one():
    r = recipe("rcp-new", 300.0)
    with pytest.raises(SystemExit, match="rcp-new"):
        bundle_revisions.assign([r], {}, bump=False)
    ledger: dict = {}
    bundle_revisions.assign([r], ledger, bump=True)
    assert r["revision"] == 1 and ledger == {"rcp-new": [entry(1, r)]}


def test_write_load_round_trip_and_seed_refuses_to_overwrite(tmp_path):
    r1, r2 = recipe("rcp-2", 1.0), recipe("rcp-1", 2.0)
    ledger = {"rcp-2": [entry(1, r1)], "rcp-1": [entry(1, r2), entry(2, r1)]}
    path = tmp_path / "revisions.json"
    bundle_revisions.write(ledger, path)
    assert bundle_revisions.load(path) == ledger
    with pytest.raises(SystemExit, match="already exists"):
        bundle_revisions.seed(BUNDLE, path)


def test_shipped_bundle_matches_the_committed_ledger():
    ledger = bundle_revisions.load()
    for r in json.load(BUNDLE.open())["recipes"]:
        history = ledger.get(r["catalog_id"])
        assert history, f"{r['catalog_id']} has no recorded revision"
        assert history[-1] == {"revision": r["revision"],
                               "body_sha256": bundle_revisions.body_sha256(r)}, \
            f"{r['catalog_id']} ships a body or revision the ledger does not record"
    for cid, history in ledger.items():
        revs = [e["revision"] for e in history]
        assert revs == sorted(set(revs)) and revs[0] >= 1, f"{cid}: {revs}"
        hashes = [e["body_sha256"] for e in history]
        assert all(a != b for a, b in zip(hashes, hashes[1:])), \
            f"{cid}: a revision was bumped without a body change"
