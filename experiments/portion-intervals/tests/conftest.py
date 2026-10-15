"""Shared fixture factory: synthetic PR41-shaped artifacts in a tmp dir."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))  # experiments/portion-intervals

TARGET_HEADER = [
    "dish_id", "cafe", "scan_ts", "official_rgb_split", "official_depth_split",
    "plate_cluster", "my_split", "total_mass_g", "total_calories_kcal",
    "n_ingredients", "ingredient_names",
]
ESTIMATE_HEADER = ["dish_id", "plate_cluster", "population", "arm", "target", "y_true", "y_pred"]

FROZEN = {
    "frozen_before_test_run": True,
    "arms": {"median": {"train_medians": {"mass_g": 177.0, "energy_kcal": 206.369995}}},
}


def base_target_rows():
    """Five dishes, three plate clusters: dev(c1: d1,d2), train(c2: d3), test(c3: d4,d5)."""
    return [
        ["d1", "cafe1", "1550000001", "train", "train", "cafe1_c00001", "dev", "100.0", "200.0", "1", "rice"],
        ["d2", "cafe1", "1550000002", "train", "train", "cafe1_c00001", "dev", "300.0", "400.0", "2", "rice|beans"],
        ["d3", "cafe1", "1550000010", "train", "train", "cafe1_c00002", "train", "150.0", "250.0", "1", "pasta"],
        ["d4", "cafe1", "1550000100", "test", "test", "cafe1_c00003", "test", "120.0", "220.0", "1", "salad"],
        ["d5", "cafe1", "1550000105", "test", "test", "cafe1_c00003", "test", "80.0", "180.0", "1", "soup"],
    ]


def base_estimate_rows():
    """Predictions for the two test dishes: 3 arms x 2 targets (median anchored)."""
    rows = []
    for arm, pred_mass, pred_kcal in (("median", "177.0", "206.369995"), ("rgb", "95.0", "180.0"), ("foodlist", "88.0", "175.0")):
        for did, cluster, mass, kcal in (("d4", "cafe1_c00003", "120.0", "220.0"), ("d5", "cafe1_c00003", "80.0", "180.0")):
            rows.append([did, cluster, "rgb_test", arm, "mass_g", mass, pred_mass])
            rows.append([did, cluster, "rgb_test", arm, "energy_kcal", kcal, pred_kcal])
    return rows


def write_csv(path: Path, header: list[str], rows: list[list[str]]) -> None:
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        w.writerow(header)
        w.writerows(rows)


@pytest.fixture
def make_inputs(tmp_path):
    """Factory: writes targets/estimates/frozen; returns their Paths."""

    def _make(targets_rows=None, estimates_rows=None, frozen=None, swap_target_columns=False):
        targets_rows = base_target_rows() if targets_rows is None else targets_rows
        estimates_rows = base_estimate_rows() if estimates_rows is None else estimates_rows
        frozen = FROZEN if frozen is None else frozen

        t_header, e_header = list(TARGET_HEADER), list(ESTIMATE_HEADER)
        if swap_target_columns:
            # Swapped gram/kcal control: mass column carries kcal values and vice versa.
            i_mass, i_kcal = t_header.index("total_mass_g"), t_header.index("total_calories_kcal")
            t_header[i_mass], t_header[i_kcal] = "total_calories_kcal", "total_mass_g"

        targets_path = tmp_path / "dish_targets.csv"
        estimates_path = tmp_path / "estimates_test.csv"
        frozen_path = tmp_path / "FROZEN_CONFIG.json"
        write_csv(targets_path, t_header, targets_rows)
        write_csv(estimates_path, e_header, estimates_rows)
        frozen_path.write_text(json.dumps(frozen))
        return targets_path, estimates_path, frozen_path

    return _make
