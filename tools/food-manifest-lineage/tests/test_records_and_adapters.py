"""Adapter and record schema tests against the synthetic contract fixtures."""

import hashlib
from pathlib import Path

import pytest

from lineage.adapters import AdapterInput, run_adapter
from lineage.records import UNKNOWN

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def load(adapter: str, name: str, kind: str, file: str, **kwargs):
    inp = AdapterInput(name=name, kind=kind, adapter=adapter, **kwargs)
    return run_adapter(inp, (FIXTURES / file).read_bytes(), blob_resolver=None)


def test_usda_manual_overrides_adapter():
    recs = load(
        "usda-manual-overrides",
        "fx-usda-overrides",
        "product",
        "data/usda_manual_overrides.json",
    )
    assert [r.item_id for r in recs] == ["override-000000", "override-000001"]
    first = recs[0]
    assert first.origin == "usda-fdc"
    assert first.source_id == "167599"
    assert first.label == "Fixture Butter Override"
    # Overrides declare no group, revision, or hash of their own.
    assert first.product_revision == UNKNOWN
    assert first.declared_group == UNKNOWN
    assert first.content_hash == UNKNOWN


def test_nutrition_compact_adapter():
    recs = load(
        "nutrition-compact",
        "fx-nutrition-compact",
        "product",
        "data/usda_nutrition_compact.json",
    )
    assert [r.item_id for r in recs] == ["1", "2"]
    assert recs[0].origin == "usda-fdc"
    assert recs[0].source_id == "170893"
    assert recs[0].product_revision == "SR Legacy"
    assert recs[0].label == "egg"
    assert recs[0].declared_group == UNKNOWN
    assert recs[0].content_hash == UNKNOWN
    # Unmatched ingredient keeps its unknown source id.
    assert recs[1].source_id == UNKNOWN
    assert recs[1].product_revision == UNKNOWN



def test_dish_ambiguity_adapter_fields():
    recs = load("dish-ambiguity", "fx-dish-a", "image", "data/dish_manifest_a.json")
    assert len(recs) == 3
    first = recs[0]
    assert first.origin == "food-101"
    assert first.source_id == "fx_images/alpha_pie/1001.jpg"
    assert first.content_hash.startswith("aa01")
    assert first.hash_provenance == "declared"
    assert first.declared_group == "alpha_pie/test"
    assert first.location == first.source_id
    assert first.declared_dhash is not None


def test_nonfood_adapter_fields():
    recs = load("nonfood-rejection", "fx-nonfood", "image", "data/nonfood_manifest.json")
    assert len(recs) == 4
    n1 = recs[0]
    assert n1.origin == "openimages"
    assert n1.source_id == "affe000000000001"
    assert n1.declared_group == "test/negative"
    assert n1.location.endswith("/test/affe000000000001.jpg")
    # upstream revision not declared by this manifest
    assert n1.product_revision == UNKNOWN


def test_multiplate_adapter_dhash_canonical():
    recs = load(
        "multiplate",
        "fx-multiplate",
        "plate",
        "data/multiplate_manifest.json",
        declared_revision="openimages-2018_04",
    )
    assert recs[0].declared_dhash == "37b30949d4dcc964"
    assert recs[0].product_revision == "openimages-2018_04"
    assert recs[0].kind == "plate"


def test_foodseg_ids_are_split_scoped():
    recs = load("foodseg-csv", "fx-foodseg", "image", "data/foodseg_manifest.csv")
    by_row = {r.item_id: r for r in recs}
    assert by_row["row-000000"].source_id == "validation/7"
    assert by_row["row-000001"].source_id == "test/77"
    assert by_row["row-000003"].content_hash == UNKNOWN
    assert by_row["row-000003"].declared_group == "validation/va-9"


def test_bundled_demo_hashes_unknown_without_resolver():
    recs = load(
        "bundled-demo",
        "fx-demo",
        "image",
        "data/demo_manifest.json",
        options={"asset_root": "apps/ios/Resources"},
    )
    assert len(recs) == 2
    assert all(r.content_hash == UNKNOWN for r in recs)
    assert all(r.hash_provenance == UNKNOWN for r in recs)
    assert recs[0].declared_group == "tutorial,breakfast"


def test_bundled_demo_hashes_computed_with_resolver():
    blob = b"fake png bytes"

    def resolver(repo_path: str) -> bytes:
        if repo_path.endswith("fixture_breakfast.png"):
            return blob
        raise FileNotFoundError(repo_path)

    inp = AdapterInput(
        name="fx-demo",
        kind="image",
        adapter="bundled-demo",
        options={"asset_root": "apps/ios/Resources"},
    )
    recs = run_adapter(inp, (FIXTURES / "data/demo_manifest.json").read_bytes(), resolver)
    by_id = {r.item_id: r for r in recs}
    assert by_id["fixture_breakfast"].content_hash == hashlib.sha256(blob).hexdigest()
    assert by_id["fixture_breakfast"].hash_provenance == "computed"
    assert by_id["fixture_lunch"].content_hash == UNKNOWN


def test_usda_catalog_records():
    recs = load("usda-catalog", "fx-usda-catalog", "product", "data/usda_catalog.json")
    by_id = {r.item_id: r for r in recs}
    c1 = by_id["fdc-167599"]
    assert c1.origin == "usda-fdc"
    assert c1.source_id == "167599"
    assert c1.product_revision == "SR Legacy"
    assert c1.declared_group == "fat"
    assert c1.content_hash == UNKNOWN


def test_review_batch_adapter():
    recs = load("usda-review-batches", "fx-usda-review", "product", "data/usda_review_batch.json")
    assert [r.item_id for r in recs] == ["batch1-rec-000000", "batch1-rec-000001"]
    assert recs[0].source_id == "167599"
    assert recs[0].label == "Fixture Butter (Raw) v2"


def test_preparation_adapter_maps_members():
    recs = load("preparation-state", "fx-preparation", "product", "data/preparation_manifest.json")
    by_id = {r.item_id: r for r in recs}
    raw = by_id["group-00000-member-00000"]
    assert raw.source_id == "167599"
    assert raw.declared_group == "fixture butter"
    assert raw.product_revision == "Raw"
    plain = by_id["group-00001-member-00000"]
    assert plain.product_revision == UNKNOWN
    assert plain.declared_group == "fixture jam"


def test_nutrition5k_summary_stays_unknown():
    recs = load("nutrition5k-summary", "fx-n5k-summary", "plate", "data/nutrition5k_summary.json")
    assert len(recs) == 1
    rec = recs[0]
    assert rec.origin == "nutrition5k"
    assert rec.source_id == UNKNOWN
    assert rec.content_hash == UNKNOWN
    assert rec.declared_group == UNKNOWN


def test_nutrition5k_dishes_declared_groups():
    recs = load("nutrition5k-dishes", "fx-n5k-dishes", "plate", "data/nutrition5k_dishes.csv")
    assert len(recs) == 3
    first = recs[0]
    assert first.source_id == "dish_1000000001"
    assert first.declared_group == "train/cafe1_c00001"
    assert first.content_hash == UNKNOWN


def test_unknown_adapter_rejected():
    with pytest.raises(KeyError):
        load("no-such-adapter", "fx", "image", "data/demo_manifest.json")
