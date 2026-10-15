"""Evaluation tests: hand-computed coverage, straddle exclusion, arm availability."""

from __future__ import annotations

import evaluate
import pytest


@pytest.fixture(autouse=True)
def _reset_cluster_size():
    evaluate.CLUSTER_SIZE.clear()
    yield
    evaluate.CLUSTER_SIZE.clear()


def _rows():
    """Median-arm mass rows: r1 exact (resid 0), r2 resid 8, r3 zero-truth."""
    return [
        {"dish_id": "d1", "plate_cluster": "c1", "population": "rgb_test", "arm": "median", "target": "mass_g", "y_true": 100.0, "y_pred": 100.0},
        {"dish_id": "d2", "plate_cluster": "c1", "population": "rgb_test", "arm": "median", "target": "mass_g", "y_true": 118.0, "y_pred": 110.0},
        {"dish_id": "d3", "plate_cluster": "c1", "population": "rgb_test", "arm": "median", "target": "mass_g", "y_true": 0.0, "y_pred": 100.0},
    ]


def _arms():
    return {
        "fixed_width": {"mass_g": {"10.0": 10.0}},
        "dev_residual": {"mass_g": {"0.5": 5.0}},
        "split_conformal": {"mass_g": {"0.5": 7.0}},
    }


def test_point_metrics_hand_case():
    rows = [
        {"population": "rgb_test", "arm": "rgb", "target": "mass_g", "y_true": 10.0, "y_pred": 11.0},
        {"population": "rgb_test", "arm": "rgb", "target": "mass_g", "y_true": 10.0, "y_pred": 7.0},
    ]
    pm = evaluate.point_metrics(rows)
    m = pm["rgb_test|rgb|mass_g"]
    assert m["n"] == 2
    assert m["mae"] == pytest.approx(2.0)  # (1 + 3) / 2
    assert m["rmse"] == pytest.approx((5.0) ** 0.5)  # sqrt((1 + 9)/2)
    assert m["median_abs_error"] == pytest.approx(2.0)


def test_score_intervals_hand_computed():
    rows = _rows()
    for r in rows:
        evaluate.CLUSTER_SIZE[r["plate_cluster"]] = evaluate.CLUSTER_SIZE.get(r["plate_cluster"], 0) + 1
    results = evaluate.score_intervals(rows, _arms(), [0.5])
    by_key = {(r["method"], r["width_label"]): r for r in results}
    # dev_residual half-width 5: d1 covered, d2 not, d3 zero-excluded
    dr = by_key[("dev_residual", "0.5")]
    assert dr["n_eval"] == 2
    assert dr["n_zero_excluded"] == 1
    assert dr["coverage"] == pytest.approx(0.5)
    assert dr["mean_width"] == pytest.approx(10.0)  # 2 * 5
    assert dr["undercoverage"] == pytest.approx(0.0)  # 0.5 - 0.5
    # fixed 10: both d1 and d2 covered
    fw = by_key[("fixed_width", "10.0")]
    assert fw["coverage"] == pytest.approx(1.0)
    assert fw["undercoverage"] is None
    # conformal half-width 7: d1 covered (|0|<=7), d2 not (8 > 7)
    sc = by_key[("split_conformal", "0.5")]
    assert sc["coverage"] == pytest.approx(0.5)
    assert sc["half_width"] == 7.0
    # both scored dishes share cluster c1 (size 2) -> size_ge2 stratum
    assert dr["by_stratum"]["size_ge2"]["n_eval"] == 2
    assert dr["by_stratum"]["size1"]["n_eval"] == 0


def test_straddle_dish_excluded_only_in_sensitivity_population():
    rows = _rows()
    rows.append(
        {"dish_id": "dish_1558641200", "plate_cluster": "c9", "population": "rgb_test",
         "arm": "median", "target": "mass_g", "y_true": 100.0, "y_pred": 100.0}
    )
    for r in rows:
        evaluate.CLUSTER_SIZE[r["plate_cluster"]] = evaluate.CLUSTER_SIZE.get(r["plate_cluster"], 0) + 1
    results = evaluate.score_intervals(rows, _arms(), [0.5])
    by_pop = {}
    for r in results:
        if r["method"] == "fixed_width":
            by_pop[r["population"]] = r
    assert by_pop["rgb_test"]["n_eval"] == 3  # includes the straddle dish
    assert by_pop["rgb_test_straddle_excluded"]["n_eval"] == 2  # removed


def test_non_median_estimators_score_fixed_width_only():
    rows = [
        {"dish_id": "d1", "plate_cluster": "c1", "population": "rgb_test", "arm": "rgb", "target": "mass_g", "y_true": 100.0, "y_pred": 110.0},
    ]
    evaluate.CLUSTER_SIZE["c1"] = 1
    results = evaluate.score_intervals(rows, _arms(), [0.5])
    assert {r["method"] for r in results} == {"fixed_width"}
    assert results[0]["population"] == "rgb_test"


def test_build_widths_marks_image_estimators_unavailable():
    frozen = {"arms": {"median": {"train_medians": {"mass_g": 177.0, "energy_kcal": 206.369995}}}}
    targets = [
        {"dish_id": "d1", "plate_cluster": "c1", "my_split": "dev", "total_mass_g": "100.0", "total_calories_kcal": "200.0"},
        {"dish_id": "d2", "plate_cluster": "c2", "my_split": "dev", "total_mass_g": "300.0", "total_calories_kcal": "400.0"},
    ]
    cfg = {
        "nominal_levels": [0.5, 0.8],
        "conformal_calibration_fraction": 0.5,
        "fixed_widths": {"mass_g": [10.0], "energy_kcal": [25.0]},
    }
    arms, status = evaluate.build_widths(targets, frozen, cfg, seed=20261010)
    assert status["dev_residual"]["status"] == "ok"
    assert status["dev_residual"]["dev_counts"]["mass_g"]["n_eligible"] == 2
    assert status["split_conformal"]["status"] == "ok"
    for arm in ("rgb", "foodlist", "rgbd"):
        assert status[f"dev_residual[{arm}]"]["status"] == "unavailable"
        assert status[f"split_conformal[{arm}]"]["status"] == "unavailable"
        assert "no per-record development predictions" in status[f"split_conformal[{arm}]"]["reason"]
    assert arms["fixed_width"]["mass_g"] == {"10.0": 10.0}
