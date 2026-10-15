"""Manifest checker tests: a valid small manifest passes, and each planted
defect is caught by the named check. The real 1,200-image manifest uses the
same validate() with default counts (300/300/600).
"""
import hashlib
import json
from pathlib import Path

import pytest

from check_manifest import validate

SMALL_COUNTS = {"empty_visible": 2, "opaque_unknown": 2, "food_control": 4}
CC_BY = "https://creativecommons.org/licenses/by/2.0/"


def _img(iid, stratum, split, pair, ctx, occ, food, group, series, sha="ab" * 32):
    return {
        "image_id": iid,
        "subset": "validation",
        "s3_url": f"https://open-images-dataset.s3.amazonaws.com/validation/{iid}.jpg",
        "role": "food_control" if stratum == "food_control" else "negative",
        "stratum": stratum,
        "split": split,
        "match_key": "Refrigerator",
        "pair_id": pair,
        "match_quality": "exact_context",
        "food_absence_verified": stratum != "food_control",
        "label_source": "human",
        "context_labels": ctx,
        "occluder_labels": occ,
        "food_labels": food,
        "author": "A",
        "author_profile_url": "https://flickr.com/people/a",
        "license": CC_BY,
        "landing_url": "https://flickr.com",
        "original_url": "https://x",
        "group_id": group,
        "series_id": series,
        "sha256": sha,
        "bytes": 10,
        "width": 1,
        "height": 1,
    }


@pytest.fixture
def good_manifest():
    return {
        "meta": {
            "name": "nonfood-rejection-v1",
            "license_note": "CC-BY 2.0",
            "source_urls": {},
            "eligible_and_ambiguous_counts": {},
            "split_rule": "50/50",
        },
        "images": [
            _img("ev" + "0" * 14, "empty_visible", "dev", "pair-0", ["Refrigerator"], [], [], "g1", "s1"),
            _img("ev" + "1" * 14, "empty_visible", "test", "pair-1", ["Cupboard"], [], [], "g2", "s2"),
            _img("ou" + "0" * 14, "opaque_unknown", "dev", "pair-2", ["Shelf"], ["Tin can"], [], "g3", "s3"),
            _img("ou" + "1" * 14, "opaque_unknown", "test", "pair-3", ["Shelf"], ["Box"], [], "g4", "s4"),
            _img("fc" + "0" * 14, "food_control", "dev", "pair-0", ["Refrigerator"], [], ["Apple"], "g5", "s5"),
            _img("fc" + "1" * 14, "food_control", "dev", "pair-2", ["Shelf"], [], ["Bread"], "g6", "s6"),
            _img("fc" + "2" * 14, "food_control", "test", "pair-1", ["Cupboard"], [], ["Milk"], "g7", "s7"),
            _img("fc" + "3" * 14, "food_control", "test", "pair-3", ["Shelf"], [], ["Egg"], "g8", "s8"),
        ],
    }


def test_valid_manifest_passes(good_manifest):
    failures, counts = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert failures == []
    assert counts == {"empty_visible": 2, "opaque_unknown": 2, "food_control": 4}


def test_missing_license_url_flagged(good_manifest):
    good_manifest["images"][0]["license"] = "https://example.com/other"
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any(f.startswith("licenses:") for f in failures)


def test_group_spanning_splits_flagged(good_manifest):
    # fc2 is a test-split control; put it in the group of a dev negative
    # (ev0): the same group_id now spans dev and test
    good_manifest["images"][6]["group_id"] = good_manifest["images"][0]["group_id"]
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("group_binding" in f and "group_id" in f for f in failures)


def test_series_spanning_splits_flagged(good_manifest):
    good_manifest["images"][6]["series_id"] = good_manifest["images"][0]["series_id"]
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("group_binding" in f and "series_id" in f for f in failures)


def test_occluder_on_empty_visible_flagged(good_manifest):
    good_manifest["images"][0]["occluder_labels"] = ["Box"]
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("stratum_binding" in f for f in failures)


def test_opaque_unknown_without_occluder_flagged(good_manifest):
    good_manifest["images"][2]["occluder_labels"] = []
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("stratum_binding" in f for f in failures)


def test_food_control_without_food_labels_flagged(good_manifest):
    good_manifest["images"][4]["food_labels"] = []
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("stratum_binding" in f for f in failures)


def test_unpaired_negative_flagged(good_manifest):
    good_manifest["images"][0]["pair_id"] = None
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("match_pairs" in f and "no pair_id" in f for f in failures)


def test_pair_with_two_negatives_flagged(good_manifest):
    for r in good_manifest["images"]:
        if r["image_id"] == "fc" + "0" * 14:
            r["role"] = "negative"
            r["stratum"] = "empty_visible"
            r["food_labels"] = []
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("roles" in f for f in failures)


def test_wrong_counts_flagged(good_manifest):
    good_manifest["images"].pop()  # drop a control
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any(f.startswith("counts:") for f in failures)


def test_unknowable_stratum_flagged(good_manifest):
    good_manifest["images"][0]["stratum"] = "mystery"
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any("unknown stratum" in f for f in failures)


def test_duplicate_image_id_flagged(good_manifest):
    good_manifest["images"][1]["image_id"] = good_manifest["images"][0]["image_id"]
    failures, _ = validate(good_manifest, expected_counts=SMALL_COUNTS)
    assert any(f.startswith("unique_images:") for f in failures)


def test_planted_hash_swap_flagged(good_manifest, tmp_path):
    # cache holds bytes whose hash differs from the manifest record
    cache = tmp_path / "cache"
    (cache / "images" / "validation").mkdir(parents=True)
    iid = good_manifest["images"][0]["image_id"]
    p = cache / "images" / "validation" / f"{iid}.jpg"
    p.write_bytes(b"planted-swap")
    good_manifest["images"][0]["sha256"] = hashlib.sha256(b"original").hexdigest()
    failures, _ = validate(good_manifest, cache_dir=cache, expected_counts=SMALL_COUNTS)
    assert any("image_hashes" in f and "mismatch" in f for f in failures)


def test_matching_cache_passes_hash_check(good_manifest, tmp_path):
    cache = tmp_path / "cache"
    (cache / "images" / "validation").mkdir(parents=True)
    for r in good_manifest["images"]:
        data = r["image_id"].encode()
        (cache / "images" / "validation" / f"{r['image_id']}.jpg").write_bytes(data)
        r["sha256"] = hashlib.sha256(data).hexdigest()
    failures, _ = validate(good_manifest, cache_dir=cache, expected_counts=SMALL_COUNTS)
    assert failures == []
