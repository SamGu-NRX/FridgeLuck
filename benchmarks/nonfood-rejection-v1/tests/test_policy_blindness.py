"""Truth-mutation test: changing ground truth changes scores, never predictions.

The measured policy is stratum-blind. This suite proves it end-to-end
through the scorer: take a manifest + raw arm report, permute the ground
truth (stratum and role), keep every arm output byte-identical, and show

  1. every per-image MEASURED verdict is unchanged - predictions carry no
     truth information,
  2. the computed metrics DO change - the same predictions score
     differently against different truth,
  3. the ORACLE verdicts DO change - documenting that the oracle policy
     really does read the stratum (its privilege, not a defect), and
  4. the mutation actually moved the truth (guards against a vacuous test).
"""
import copy

import pytest

from policy import verdict
from score import evaluate

TAU_HIGH = 0.6
TAU_LOW = 0.2


def fixture():
    """Six test-split images: 2 visible-empty, 2 opaque-unknown, 2 controls."""
    strata = {
        "e1": "empty_visible", "e2": "empty_visible",
        "o1": "opaque_unknown", "o2": "opaque_unknown",
        "c1": "food_control", "c2": "food_control",
    }
    manifest = {
        "images": [
            {
                "image_id": iid, "stratum": s,
                "role": "food_control" if s == "food_control" else "negative",
                "split": "test",
            }
            for iid, s in strata.items()
        ],
    }
    scores = {"e1": 0.1, "e2": 0.8, "o1": 0.1, "o2": 0.3, "c1": 0.9, "c2": 0.15}
    report_images = [
        {
            "image_id": iid, "food_score": sc, "produced_food": False,
            "group_id": f"g{iid}", "split": "test", "series_id": f"s{iid}",
            "pair_id": None, "food_labels": [], "stratum": strata[iid],
        }
        for iid, sc in scores.items()
    ]
    return manifest, report_images


def relabel(manifest):
    """A truth mutation: rotate every stratum label one step."""
    rotation = {"empty_visible": "opaque_unknown", "opaque_unknown": "food_control", "food_control": "empty_visible"}
    mutated = copy.deepcopy(manifest)
    for m in mutated["images"]:
        m["stratum"] = rotation[m["stratum"]]
        m["role"] = "food_control" if m["stratum"] == "food_control" else "negative"
    return mutated


def test_measured_predictions_invariant_under_truth_mutation():
    manifest, report_images = fixture()
    base = evaluate(manifest, report_images, TAU_HIGH, TAU_LOW, "measured")[1]
    flipped = evaluate(relabel(manifest), copy.deepcopy(report_images), TAU_HIGH, TAU_LOW, "measured")[1]

    b = {r["image_id"]: r["verdict"] for r in base}
    f = {r["image_id"]: r["verdict"] for r in flipped}
    assert f == b  # predictions carry zero truth information

    # and the arm outputs the predictions were computed from are untouched
    for r in flipped:
        orig = next(x for x in report_images if x["image_id"] == r["image_id"])
        assert r["food_score"] == orig["food_score"]
        assert r["produced_food"] == orig["produced_food"]


def test_truth_mutation_changes_measured_scores():
    manifest, report_images = fixture()
    base = evaluate(manifest, report_images, TAU_HIGH, TAU_LOW, "measured")[0]["test"]
    flipped = evaluate(relabel(manifest), copy.deepcopy(report_images), TAU_HIGH, TAU_LOW, "measured")[0]["test"]

    # same predictions, different truth -> different scores
    assert flipped["false_addition_groups"] != base["false_addition_groups"]
    assert flipped["control_recall_images"] != base["control_recall_images"]


def test_oracle_predictions_do_move_under_truth_mutation():
    manifest, report_images = fixture()
    base = {r["image_id"]: r["verdict"] for r in evaluate(manifest, report_images, TAU_HIGH, TAU_LOW, "oracle")[1]}
    flipped = {
        r["image_id"]: r["verdict"]
        for r in evaluate(relabel(manifest), copy.deepcopy(report_images), TAU_HIGH, TAU_LOW, "oracle")[1]
    }
    assert flipped != base  # the oracle policy reads the stratum; that is its documented privilege


def test_mutation_is_not_vacuous():
    manifest, _ = fixture()
    mutated = relabel(manifest)
    before = {m["image_id"]: m["stratum"] for m in manifest["images"]}
    after = {m["image_id"]: m["stratum"] for m in mutated["images"]}
    assert all(after[k] != v for k, v in before.items()), "relabel moved every stratum"
