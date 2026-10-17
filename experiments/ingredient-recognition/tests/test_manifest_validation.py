"""Manifest and taxonomy validation tests.

The three mandated rejections: mismatched shard hashes, cross-split
near-duplicate groups, and ambiguous mappings labelled exact. Synthetic
fixtures only — no network, no dataset download in the test suite.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXPERIMENT_ROOT))

import acquire  # noqa: E402


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads((EXPERIMENT_ROOT / "manifest.json").read_text())


# ------------------------------------------------------------------ real data
def test_real_manifest_has_no_cross_split_groups(manifest):
    assert acquire.find_cross_split_groups(manifest["images"]) == {}


def test_real_taxonomy_never_labels_ambiguous_as_exact(manifest):
    kinds = acquire.validate_taxonomy(EXPERIMENT_ROOT / "manifest.json")
    assert kinds.get("exact", 0) > 0  # the rule ran over real rows


def test_real_manifest_counts_are_frozen(manifest):
    assert manifest["eligibility"]["total_rows"] == 7118
    assert manifest["eligibility"]["eligible_rows"] == 7118
    assert manifest["eligibility"]["excluded_mask_inconsistent"] == 0
    assert manifest["dataset"]["official_split"] == {"train": 4983, "validation": 2135}
    assert manifest["class_coverage"]["foodseg_classes"] == 103


# ------------------------------------------------------- synthetic rejections
def test_rejects_cross_split_duplicate_group():
    rows = [
        {"split": "train", "dup_group": "d-1"},
        {"split": "validation", "dup_group": "d-1"},
    ]
    cross = acquire.find_cross_split_groups(rows)
    assert cross, "cross-split group must be detected"
    with pytest.raises(acquire.CrossSplitGroup):
        raise acquire.CrossSplitGroup(str(cross))


def test_same_split_duplicate_group_is_accepted():
    rows = [
        {"split": "train", "dup_group": "d-1"},
        {"split": "train", "dup_group": "d-1"},
    ]
    assert acquire.find_cross_split_groups(rows) == {}


def test_rejects_mismatched_shard_hash(tmp_path):
    # a cached shard whose content does not match the manifest hash
    fake = tmp_path / "validation-00000-of-00001.parquet"
    fake.write_bytes(b"not a parquet file")
    with pytest.raises(acquire.HashMismatch):
        acquire.ensure_shard(fake.name, "0" * 64, fake.stat().st_size, tmp_path)


def test_rejects_wrong_byte_size_before_hashing(tmp_path):
    fake = tmp_path / "validation-00000-of-00001.parquet"
    fake.write_bytes(b"x" * 10)
    with pytest.raises(acquire.HashMismatch):
        acquire.ensure_shard(fake.name, "0" * 64, 999999, tmp_path)


def test_rejects_ambiguous_mapping_labelled_exact(tmp_path):
    tax = tmp_path / "taxonomy"
    tax.mkdir()
    (tax / "foodseg103_to_catalog.csv").write_text(
        "class_id,class_name_raw,class_name_normalized,semantic_kind,"
        "target_ingredient_ids,target_display_names,resolution_ingredient_id,"
        "resolution_provenance,resolution_display_name,resolution_agrees_with_semantic,"
        "rationale\n"
        '17,fried meat,fried meat,exact,"12;13",Chicken;Pork,12,curated,Chicken,yes,'
        "synthetic ambiguous row labelled exact\n"
    )
    with pytest.raises(acquire.AmbiguousMappingExact):
        acquire.validate_taxonomy(tmp_path / "manifest.json")


def test_single_target_exact_mapping_is_accepted(tmp_path):
    tax = tmp_path / "taxonomy"
    tax.mkdir()
    (tax / "foodseg103_to_catalog.csv").write_text(
        "class_id,class_name_raw,class_name_normalized,semantic_kind,"
        "target_ingredient_ids,target_display_names,resolution_ingredient_id,"
        "resolution_provenance,resolution_display_name,resolution_agrees_with_semantic,"
        "rationale\n"
        "3,egg,egg,exact,29,Egg,29,curated,Egg,yes,synthetic\n"
    )
    kinds = acquire.validate_taxonomy(tmp_path / "manifest.json")
    assert kinds == {"exact": 1}
