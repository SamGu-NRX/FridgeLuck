"""Contract-reader tests, including the required negative controls:

- deliberately leaked test groups (a plate cluster shared by dev and scored test)
- swapped gram/kcal controls (header swap in the target table; per-row y_true swap)
"""

from __future__ import annotations

import copy
import csv as csv_mod

import pytest

import reader
from reader import ContractError


def base_rows():
    """Five dishes, three clusters: dev(c1: d1,d2), train(c2: d3), test(c3: d4,d5)."""
    return [
        ["d1", "cafe1", "1550000001", "train", "train", "cafe1_c00001", "dev", "100.0", "200.0", "1", "rice"],
        ["d2", "cafe1", "1550000002", "train", "train", "cafe1_c00001", "dev", "300.0", "400.0", "2", "rice|beans"],
        ["d3", "cafe1", "1550000010", "train", "train", "cafe1_c00002", "train", "150.0", "250.0", "1", "pasta"],
        ["d4", "cafe1", "1550000100", "test", "test", "cafe1_c00003", "test", "120.0", "220.0", "1", "salad"],
        ["d5", "cafe1", "1550000105", "test", "test", "cafe1_c00003", "test", "80.0", "180.0", "1", "soup"],
    ]


def test_valid_inputs_pass_and_count(make_inputs):
    targets_p, estimates_p, frozen_p = make_inputs()
    report = reader.validate(targets_p, estimates_p, frozen_p)
    sp = report["split_provenance"]
    assert sp["test_dishes_in_targets"] == 2
    assert sp["test_dishes_with_predictions"] == 2
    assert sp["test_dishes_without_predictions_unknown"] == 0
    assert sp["populations"]["rgb_test"] == {"n_dishes": 2, "n_clusters": 1}
    assert report["unit_flags"]["mass_g"]["implausible_outside_range"] == 0
    assert report["median_anchors"]["mass_g"]["status"] == "ok"


def test_straddle_detected_and_reported_not_fatal(make_inputs):
    """Negative control: a plate cluster spanning the official train/test split.

    A cluster straddling the OFFICIAL split is an inherited-data property
    (PR41's split is by dish); the reader reports it with full member detail
    instead of failing the load -- the study cannot fix PR41's assignment,
    only quarantine it downstream. (A dev dish in the cluster would be a
    different, harder failure: see test_split_provenance_leak_check_direct.)
    """
    rows = base_rows()
    rows[2][5] = "cafe1_c00003"  # my-train dish d3 joins the scored test cluster
    targets_p, estimates_p, frozen_p = make_inputs(targets_rows=rows)
    report = reader.validate(targets_p, estimates_p, frozen_p)  # no raise
    straddles = report["cluster_straddles"]
    assert len(straddles) == 1
    assert straddles[0]["plate_cluster"] == "cafe1_c00003"
    assert straddles[0]["official_rgb_splits"] == ["test", "train"]
    assert straddles[0]["test_dishes"] == ["d4", "d5"]
    assert {m["dish_id"] for m in straddles[0]["members"]} == {"d3", "d4", "d5"}


def test_split_provenance_leak_check_direct():
    """Second leak layer: split_provenance rejects dev/scored-test cluster
    overlap even when rows arrive pre-parsed (the loader would normally fire
    the straddle check first; this exercises the leakage check itself)."""
    targets = [
        {"dish_id": "d1", "plate_cluster": "c1", "my_split": "dev", "official_rgb_split": "train"},
        {"dish_id": "d2", "plate_cluster": "c2", "my_split": "test", "official_rgb_split": "test"},
    ]
    estimates = [
        {"dish_id": "d2", "plate_cluster": "c2", "population": "rgb_test", "arm": "rgb", "target": "mass_g", "y_true": 80.0, "y_pred": 95.0},
        # d1's dev cluster scored as a test prediction:
        {"dish_id": "d1", "plate_cluster": "c1", "population": "rgb_test", "arm": "rgb", "target": "mass_g", "y_true": 100.0, "y_pred": 95.0},
    ]
    with pytest.raises(ContractError, match="leakage"):
        reader.split_provenance(targets, estimates)


def test_swapped_units_header_swap_rejected(make_inputs):
    """Swapped gram/kcal control #1: target-table columns swapped.

    Value magnitudes alone cannot catch this (g and kcal overlap in range),
    but the cross-file y_true anchor does: estimates' mass y_true no longer
    matches the swapped mass column.
    """
    targets_p, estimates_p, frozen_p = make_inputs(swap_target_columns=True)
    with pytest.raises(ContractError, match="unit or provenance error"):
        reader.validate(targets_p, estimates_p, frozen_p)


def test_swapped_units_ytrue_swap_rejected(make_inputs):
    """Swapped gram/kcal control #2: estimates' y_true carries the kcal value
    on a mass_g row (the classic unit-swap data bug)."""
    estimates = [
        ["d4", "cafe1_c00003", "rgb_test", "rgb", "mass_g", "220.0", "95.0"],  # y_true = kcal
    ]
    targets_p, estimates_p, frozen_p = make_inputs(estimates_rows=estimates)
    with pytest.raises(ContractError, match="unit or provenance error"):
        reader.validate(targets_p, estimates_p, frozen_p)


def test_scale_tripwire_rejects_gross_unit_error(make_inputs):
    """A column stored 100x too large (e.g. milligrams as grams) trips the
    implausible-fraction tripwire."""
    rows = base_rows()[:3]
    for r in rows:
        r[7] = str(float(r[7]) * 100.0)  # grams -> milligrams
    targets_p, _, _ = make_inputs(targets_rows=rows)
    with pytest.raises(ContractError, match="unit tripwire"):
        reader.unit_flags(reader.load_targets(targets_p))


def test_implausible_targets_flagged_and_kept(make_inputs):
    """Locked policy: implausible values are counted, never deleted."""
    rows = base_rows()
    rows[0][7] = "2500.0"  # mass above the 2000 g cap: implausible, kept
    rows[1][8] = "0.0"  # zero calories: kept, excluded from coverage by policy
    targets_p, _, _ = make_inputs(targets_rows=rows)
    targets = reader.load_targets(targets_p)
    flags = reader.unit_flags(targets)
    assert flags["mass_g"]["implausible_outside_range"] == 1
    assert flags["energy_kcal"]["n_leq_zero"] == 1
    assert len(targets) == 5  # nothing deleted


def test_estimate_for_non_test_dish_rejected(make_inputs):
    estimates = [["d3", "cafe1_c00002", "rgb_test", "rgb", "mass_g", "150.0", "95.0"]]
    targets_p, estimates_p, _ = make_inputs(estimates_rows=estimates)
    targets = reader.load_targets(targets_p)
    with pytest.raises(ContractError, match="split provenance"):
        reader.load_estimates(estimates_p, targets)


def test_plate_group_mismatch_rejected(make_inputs):
    estimates = [["d4", "cafe1_c00009", "rgb_test", "rgb", "mass_g", "120.0", "95.0"]]
    targets_p, estimates_p, _ = make_inputs(estimates_rows=estimates)
    targets = reader.load_targets(targets_p)
    with pytest.raises(ContractError, match="plate group mismatch"):
        reader.load_estimates(estimates_p, targets)


def test_unknown_dish_rejected(make_inputs):
    estimates = [["dX", "cafe1_c00003", "rgb_test", "rgb", "mass_g", "120.0", "95.0"]]
    targets_p, estimates_p, _ = make_inputs(estimates_rows=estimates)
    targets = reader.load_targets(targets_p)
    with pytest.raises(ContractError, match="not in dish_targets"):
        reader.load_estimates(estimates_p, targets)


def test_rgbd_outside_depth_population_rejected(make_inputs):
    estimates = [["d4", "cafe1_c00003", "rgb_test", "rgbd", "mass_g", "120.0", "95.0"]]
    targets_p, estimates_p, _ = make_inputs(estimates_rows=estimates)
    targets = reader.load_targets(targets_p)
    with pytest.raises(ContractError, match="not part of population"):
        reader.load_estimates(estimates_p, targets)


def test_nonfinite_prediction_rejected(make_inputs):
    estimates = [["d4", "cafe1_c00003", "rgb_test", "rgb", "mass_g", "120.0", "nan"]]
    targets_p, estimates_p, _ = make_inputs(estimates_rows=estimates)
    targets = reader.load_targets(targets_p)
    with pytest.raises(ContractError, match="finite"):
        reader.load_estimates(estimates_p, targets)


def test_broken_my_split_provenance_rejected(make_inputs):
    rows = base_rows()
    rows[3][3], rows[3][4] = "train", "none"  # my_split=test requires official=test
    targets_p, _, _ = make_inputs(targets_rows=rows)
    with pytest.raises(ContractError, match="split provenance"):
        reader.load_targets(targets_p)


def test_missing_column_rejected(make_inputs):
    targets_p, _, _ = make_inputs()
    with open(targets_p, newline="") as fh:
        rows = list(csv_mod.reader(fh))
    col = rows[0].index("cafe")
    del rows[0][col]
    for row in rows[1:]:
        del row[col]
    with open(targets_p, "w", newline="") as fh:
        w = csv_mod.writer(fh, quoting=csv_mod.QUOTE_ALL, lineterminator="\r\n")
        w.writerows(rows)
    with pytest.raises(ContractError, match="column contract"):
        reader.load_targets(targets_p)
