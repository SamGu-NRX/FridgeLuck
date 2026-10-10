"""Planted-failure fixtures for check_manifest.py.

These tests prove the validator rejects the two conflict classes the task names:
  1. a duplicate group - the same bundled recipe claimed by two classes;
  2. an unsupported class asserting an exact recipe - an 'unsupported' entry that
     also claims recipes, or an ambiguous candidate that double-books an exact answer.
They also prove the real committed mapping passes end-to-end.
"""
import json
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BENCH))

import check_manifest as cm  # noqa: E402

STUB_CLASSES = "cls_a\ncls_b\ncls_c\ncls_d\n"


def write_mapping(tmp_path, classes, catalog=None):
    mapping = {
        "schemaVersion": "dish-ambiguity-mapping-v1",
        "dataset": "food-101",
        "catalog": "apps/ios/Resources/data.json",
        "classes": classes,
    }
    p = tmp_path / "mapping.json"
    p.write_text(json.dumps(mapping))
    classes_file = tmp_path / "classes.txt"
    classes_file.write_text(STUB_CLASSES)
    return p, classes_file, catalog or tmp_path / "catalog.json"


def write_catalog(tmp_path):
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({"recipes": [
        [10, "Recipe Ten", 15, 2, [[1, 100]], [], "steps", 1],
        [20, "Recipe Twenty", 15, 2, [[1, 100]], [], "steps", 1],
        [21, "Recipe Twenty One", 15, 2, [[1, 100]], [], "steps", 1],
        [30, "Recipe Thirty", 15, 2, [[1, 100]], [], "steps", 1],
        [31, "Recipe Thirty One", 15, 2, [[1, 100]], [], "steps", 1],
        [40, "Recipe Forty", 15, 2, [[1, 100]], [], "steps", 1],
    ]}))
    return catalog


def valid_classes():
    return {
        "cls_a": {"status": "exact", "recipes": [10], "reason": "the dish itself", "nearMiss": "none"},
        "cls_b": {"status": "coarse", "recipes": [20, 21], "reason": "interchangeable renderings",
                  "nearMiss": "none"},
        "cls_c": {"status": "ambiguous", "recipes": [30, 31], "reason": "non-equivalent candidates",
                  "nearMiss": "no exact candidate exists"},
        "cls_d": {"status": "unsupported", "recipes": [], "reason": "no plausible rendering",
                  "nearMiss": "40 rejected: different dish"},
    }


def run_validate(tmp_path, classes, catalog=None):
    errs = cm.Errors()
    p, classes_file, _ = write_mapping(tmp_path, classes, catalog)
    cat = catalog or write_catalog(tmp_path)
    cm.validate_mapping(p, errs, catalog_path=cat,
                        classes_file=classes_file, expected_class_count=len(STUB_CLASSES.strip().splitlines()))
    return errs


def test_valid_mapping_passes(tmp_path):
    errs = run_validate(tmp_path, valid_classes())
    assert errs.ok, errs.items


def test_duplicate_group_fails(tmp_path):
    """Plant: recipe 10 claimed by two different classes."""
    classes = valid_classes()
    classes["cls_d"] = {"status": "exact", "recipes": [10],
                        "reason": "planted duplicate of cls_a's recipe", "nearMiss": "planted"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("already claimed" in e and "cls_d" in e for e in errs.items), errs.items


def test_duplicate_inside_coarse_group_fails(tmp_path):
    classes = valid_classes()
    classes["cls_b"] = {"status": "coarse", "recipes": [20, 20],
                        "reason": "planted duplicate inside one group", "nearMiss": "none"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok


def test_unsupported_exact_recipe_fails(tmp_path):
    """Plant: an 'unsupported' class that also asserts an exact recipe."""
    classes = valid_classes()
    classes["cls_d"] = {"status": "unsupported", "recipes": [10],
                        "reason": "planted: unsupported but also claims an exact recipe",
                        "nearMiss": "planted"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("unsupported class must not claim recipes" in e for e in errs.items), errs.items


def test_ambiguous_candidate_double_booking_exact_answer_fails(tmp_path):
    """Plant: an ambiguous candidate that is already an exact answer elsewhere."""
    classes = valid_classes()
    classes["cls_c"] = {"status": "ambiguous", "recipes": [10, 31],
                        "reason": "planted: candidate 10 is cls_a's exact answer",
                        "nearMiss": "planted"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("already an exact/coarse answer" in e for e in errs.items), errs.items


def test_missing_reason_fails(tmp_path):
    classes = valid_classes()
    del classes["cls_a"]["reason"]
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("reason" in e for e in errs.items)


def test_ambiguous_needs_two_candidates(tmp_path):
    classes = valid_classes()
    classes["cls_c"] = {"status": "ambiguous", "recipes": [30],
                        "reason": "planted: single candidate cannot be ambiguous",
                        "nearMiss": "planted"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("ambiguous" in e and ">= 2" in e for e in errs.items)


def test_unknown_recipe_id_fails(tmp_path):
    classes = valid_classes()
    classes["cls_a"] = {"status": "exact", "recipes": [9999],
                        "reason": "planted: recipe does not exist in catalog", "nearMiss": "none"}
    errs = run_validate(tmp_path, classes)
    assert not errs.ok
    assert any("not in bundled catalog" in e for e in errs.items)


def test_status_count_mismatch_fails(tmp_path):
    classes = valid_classes()
    errs = run_validate(tmp_path, classes)
    assert errs.ok  # no statusCountsExpected key on the stub: fine
    classes["cls_a"]["status"] = "coarse"
    errs2 = run_validate(tmp_path, classes)
    assert not errs2.ok  # coarse requires >= 2 recipes


def test_real_committed_mapping_and_class_list_pass():
    """End-to-end: the committed taxonomy validates against the real catalog."""
    errs = cm.Errors()
    cm.validate_mapping(BENCH / "mapping.food101-v1.json", errs)
    assert errs.ok, errs.items


def test_dev_near_duplicate_discipline_rejects(tmp_path):
    """A dev image whose dHash is within threshold of a test image must be flagged."""
    errs = cm.Errors()
    test = [{"path": "images/test.jpg", "class": "cls_a", "sha256": "x", "dhash": 0}]
    dev = [{"path": "images/dev.jpg", "class": "cls_a", "sha256": "y", "dhash": (1 << 63) - 1}]
    # dhash 0 vs all-ones except bit 63: hamming distance 63 > 10 -> ok
    cm.check_near_duplicate_discipline(test, dev, errs)
    assert errs.ok
    dev_close = [{"path": "images/dev2.jpg", "class": "cls_a", "sha256": "z",
                  "dhash": (1 << 3)}]  # hamming 1 from test hash 0
    errs2 = cm.Errors()
    cm.check_near_duplicate_discipline(test, dev_close, errs2)
    assert not errs2.ok
    assert any("near-duplicate" in e for e in errs2.items)


def test_manifest_validation_requires_stratification(tmp_path):
    classes_file = tmp_path / "classes.txt"
    classes_file.write_text(STUB_CLASSES)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({
        "schemaVersion": "dish-ambiguity-sampling-v1",
        "dataset": "food-101",
        "split": "test",
        "images": [
            {"path": "images/a.jpg", "class": "cls_a", "sha256": "h", "dhash": 5},
            {"path": "images/b.jpg", "class": "cls_a", "sha256": "h", "dhash": 6},
        ],
    }))
    errs = cm.Errors()
    cm.validate_manifest(manifest, None, "manifest", errs, require_2000=True,
                         classes_file=classes_file,
                         expected_class_count=len(STUB_CLASSES.strip().splitlines()))
    assert not errs.ok
    assert any(">= 2000" in e for e in errs.items), errs.items
    assert any("does not cover all 101 classes" in e or "stratification" in e
               for e in errs.items), errs.items
