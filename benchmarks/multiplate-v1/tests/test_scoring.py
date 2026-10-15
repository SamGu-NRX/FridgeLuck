"""Unit tests for score.py metric computation (synthetic manifest + preds)."""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import score  # noqa: E402


def manifest_entry(image_id: str, role: str, boxes: list[tuple]) -> dict:
    return {
        "image_id": image_id,
        "role": role,
        "boxes": [
            {
                "label_name": label,
                "xmin": x0,
                "ymin": y0,
                "xmax": x1,
                "ymax": y1,
            }
            for label, x0, y0, x1, y1 in boxes
        ],
    }


def det(label: str, box: list[float], conf: float = 0.9) -> dict:
    return {"label": label, "box": box, "confidence": conf}


MANIFEST = {
    "classes": [{"name": "Pizza"}, {"name": "Cake"}],
    "images": [
        manifest_entry("img1", "multi", [("Pizza", 0.0, 0.0, 0.5, 0.5), ("Cake", 0.5, 0.5, 1.0, 1.0)]),
        # control image with one tiny GT region (1% of area): small-region tracking
        manifest_entry("img2", "control", [("Pizza", 0.0, 0.0, 0.1, 0.1)]),
    ],
}


def test_perfect_predictions_score_one():
    preds = {
        "img1": {"detections": [det("Pizza", [0.0, 0.0, 0.5, 0.5]), det("Cake", [0.5, 0.5, 1.0, 1.0])]},
        "img2": {"detections": [det("Pizza", [0.0, 0.0, 0.1, 0.1])]},
    }
    m = score.evaluate_arm(MANIFEST, preds)
    assert m["overall"]["precision"] == 1.0
    assert m["overall"]["recall"] == 1.0
    assert m["missed_small_regions"]["missed_frac"] == 0.0
    assert m["duplicates_on_matched_gt"] == 0


def test_missed_and_wrong_label():
    # img1: Pizza found, Cake missed. img2: small region missed.
    preds = {
        "img1": {"detections": [det("Pizza", [0.0, 0.0, 0.5, 0.5])]},
        "img2": {"detections": []},
    }
    m = score.evaluate_arm(MANIFEST, preds)
    assert m["overall"]["true_positives"] == 1
    assert m["overall"]["recall"] == pytest.approx(1 / 3, abs=1e-3)
    assert m["missed_small_regions"]["missed_frac"] == 1.0
    assert m["region_count_error"]["mean_abs"] == pytest.approx((1 + 1) / 2)


def test_duplicate_detection_counts():
    # two identical Pizza detections on the same GT region: 1 TP + 1 duplicate
    preds = {
        "img1": {"detections": [det("Pizza", [0.0, 0.0, 0.5, 0.5]), det("Pizza", [0.01, 0.0, 0.51, 0.5])]},
        "img2": {"detections": []},
    }
    m = score.evaluate_arm(MANIFEST, preds)
    assert m["overall"]["true_positives"] == 1
    assert m["duplicates_on_matched_gt"] == 1


def test_cross_class_confusion_recorded():
    # Cake detection covering the Pizza GT region -> confusion Pizza -> Cake
    preds = {
        "img1": {"detections": [det("Cake", [0.0, 0.0, 0.5, 0.5])]},
        "img2": {"detections": []},
    }
    m = score.evaluate_arm(MANIFEST, preds)
    assert m["category_confusion_top"].get("Cake -> Pizza") == 1
    assert m["overall"]["true_positives"] == 0


def test_oracle_scores_crop_accuracy():
    preds = {
        "img1": {
            "detections": [
                {"label": "Pizza", "gt_label": "Pizza", "box": [0, 0, 0.5, 0.5], "confidence": 0.9},
                {"label": "Pizza", "gt_label": "Cake", "box": [0.5, 0.5, 1, 1], "confidence": 0.4},
            ]
        },
        "img2": {"detections": []},  # small region rejected by classifier
    }
    m = score.evaluate_arm(MANIFEST, preds, is_oracle=True)
    assert m["oracle_gt_total"] == 3
    assert m["oracle_crops_classified"] == 2
    assert m["oracle_coverage"] == pytest.approx(2 / 3, abs=1e-3)
    assert m["oracle_crop_accuracy"] == pytest.approx(0.5)
