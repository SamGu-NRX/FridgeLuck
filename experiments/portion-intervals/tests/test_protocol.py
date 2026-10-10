"""Protocol tests: hand-computed quantiles, conformal correction, strata, coverage.

Every expected value here is computed by hand in the comment.
"""

from __future__ import annotations

import math

import pytest

import protocol


def test_empirical_quantile_hand_cases():
    # [1,2,3,4], q=0.5: pos=0.5*3=1.5 -> 2 + 0.5*(3-2) = 2.5
    assert protocol.empirical_quantile([1, 2, 3, 4], 0.5) == 2.5
    # [1,2,3,4], q=0.8: pos=0.8*3=2.4 -> 3 + 0.4*(4-3) = 3.4
    assert protocol.empirical_quantile([1, 2, 3, 4], 0.8) == pytest.approx(3.4)
    # single point: quantile is the point
    assert protocol.empirical_quantile([5.0], 0.9) == 5.0
    # q=0 and q=1 are the extremes
    assert protocol.empirical_quantile([2.0, 7.0], 0.0) == 2.0
    assert protocol.empirical_quantile([2.0, 7.0], 1.0) == 7.0


def test_conformal_quantile_hand_cases():
    scores = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
    # level 0.8, n=10: k=ceil(11*0.8)=ceil(8.8)=9 -> 9th smallest = 9.0
    assert protocol.conformal_quantile(scores, 0.8) == 9.0
    # level 0.9, n=10: k=ceil(9.9)=10 -> 10.0
    assert protocol.conformal_quantile(scores, 0.9) == 10.0
    # level 0.5, n=10: k=ceil(5.5)=6 -> 6.0
    assert protocol.conformal_quantile(scores, 0.5) == 6.0
    # n=9, level 0.9: k=ceil(10*0.9)=9 -> the maximum 9.0
    assert protocol.conformal_quantile([1.0, 2, 3, 4, 5, 6, 7, 8, 9], 0.9) == 9.0
    # unachievable level: n=5, level 0.95 -> k=ceil(6*0.95)=ceil(5.7)=6 > 5 -> inf
    assert protocol.conformal_quantile([1.0, 2, 3, 4, 5], 0.95) == math.inf


def test_conformal_correction_is_honest():
    """The (n+1) correction must be >= the raw empirical quantile (wider or
    equal), and the gap must shrink as n grows."""
    scores = [float(i) for i in range(1, 21)]  # 1..20
    for level in (0.5, 0.8, 0.9):
        raw = protocol.empirical_quantile(sorted(scores), level)
        conf = protocol.conformal_quantile(sorted(scores), level)
        assert conf >= raw
    # at n=100 the correction moves at most one order statistic:
    # raw 90th pct = 90.1 (pos=89.1 interpolation), conformal k=91 -> 91.0
    big = [float(i) for i in range(1, 101)]
    raw90 = protocol.empirical_quantile(big, 0.9)
    conf90 = protocol.conformal_quantile(big, 0.9)
    assert conf90 - raw90 == pytest.approx(0.9)


def test_eligibility_mirrors_locked_policy():
    spec = {"lo_exclusive": 0.0, "hi_inclusive": 2000.0, "targets_column": "y"}
    rows = [
        {"y": "100.0", "plate_cluster": "c1"},  # eligible
        {"y": "0.0", "plate_cluster": "c1"},  # zero -> excluded, counted
        {"y": "-5.0", "plate_cluster": "c1"},  # negative -> zero bucket, counted
        {"y": "2500.0", "plate_cluster": "c2"},  # implausible -> excluded, counted
        {"y": "2000.0", "plate_cluster": "c2"},  # boundary is inside (inclusive)
    ]
    eligible, counts = protocol.eligible_calibration_rows(rows, spec)
    assert [r["y"] for r in eligible] == ["100.0", "2000.0"]
    assert counts == {
        "n_dev_rows": 5,
        "n_zero_excluded": 2,
        "n_implausible_excluded": 1,
        "n_eligible": 2,
    }


def test_dev_residual_widths_hand_case():
    spec = {"lo_exclusive": 0.0, "hi_inclusive": 5000.0, "targets_column": "y"}
    dev = [
        {"y": str(177.0 + d), "plate_cluster": f"c{i}"}
        for i, d in enumerate([10, -20, 30, -40, 50])
    ]
    widths, counts = protocol.dev_residual_widths(dev, spec, 177.0, [0.5])
    # residuals {10,20,30,40,50}; q50: pos = 0.5*4 = 2 -> 30.0
    assert widths[0.5] == pytest.approx(30.0)
    assert counts["calibration_records"] == 5
    assert counts["calibration_clusters"] == 5


def test_split_cluster_calibration_grouping_and_counts():
    spec = {"lo_exclusive": 0.0, "hi_inclusive": 5000.0, "targets_column": "y"}
    dev = [
        {"y": "100.0", "plate_cluster": "c1"},  # residual 0   -> cluster mean 5
        {"y": "110.0", "plate_cluster": "c1"},  # residual 10
        {"y": "200.0", "plate_cluster": "c2"},  # residual 100 -> cluster mean 100
        {"y": "150.0", "plate_cluster": "c3"},  # residual 50  -> cluster mean 50
    ]
    scores, counts = protocol.split_cluster_calibration(
        dev, spec, lambda r: 100.0, calibration_fraction=2 / 3, seed=20261010
    )
    # 3 clusters, fraction 2/3 -> round(2.0) = 2 calibration clusters, 1 holdout
    assert counts["calibration_clusters"] == 2
    assert counts["holdout_clusters"] == 1
    assert counts["n_dev_rows"] == 4
    assert counts["calibration_records"] + counts["holdout_records"] == 4
    assert len(scores) == 2
    assert set(scores) <= {"c1", "c2", "c3"}
    # cluster scores are mean |residual| per cluster
    expected_means = {"c1": 5.0, "c2": 100.0, "c3": 50.0}
    for cid, sc in scores.items():
        assert sc == pytest.approx(expected_means[cid])
    # determinism: same seed -> same calibration split
    scores2, counts2 = protocol.split_cluster_calibration(
        dev, spec, lambda r: 100.0, calibration_fraction=2 / 3, seed=20261010
    )
    assert set(scores) == set(scores2)
    assert counts2["calibration_records"] == counts["calibration_records"]
    # grouping integrity: calibration and holdout sets are disjoint by cluster
    assert counts["calibration_clusters"] + counts["holdout_clusters"] == 3


def test_conformal_width_uses_cluster_scores():
    scores = {"a": 10.0, "b": 20.0, "c": 30.0, "d": 40.0, "e": 50.0}
    # level 0.8, n=5: k=ceil(6*0.8)=ceil(4.8)=5 -> max 50
    assert protocol.conformal_width(scores, 0.8) == 50.0
    # level 0.5: k=ceil(3)=3 -> 30
    assert protocol.conformal_width(scores, 0.5) == 30.0


def test_stratum_label():
    assert protocol.stratum_label(1) == "size1"
    assert protocol.stratum_label(2) == "size_ge2"
    assert protocol.stratum_label(6) == "size_ge2"


def test_coverage_stats_hand_case():
    records = [
        {"covered": True, "width": 2.0},
        {"covered": False, "width": 4.0},
        {"covered": True, "width": 6.0},
        {"covered": True, "width": 8.0},
    ]
    stats = protocol.coverage_stats(records, level=0.8)
    assert stats["n_eval"] == 4
    assert stats["coverage"] == pytest.approx(0.75)
    assert stats["mean_width"] == pytest.approx(5.0)
    assert stats["median_width"] == pytest.approx(5.0)  # sorted [2,4,6,8]: pos=1.5 -> 5.0
    assert stats["undercoverage"] == pytest.approx(0.05)  # 0.8 - 0.75, positive = too narrow

    fixed = protocol.coverage_stats(records, level=None)
    assert fixed["undercoverage"] is None
    assert protocol.coverage_stats([], level=0.9)["n_eval"] == 0


def test_load_nominal_levels_enforces_declaration(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text(
        '{"nominal_levels": [0.5], "fixed_widths": {"mass_g": [1.0]},'
        ' "conformal_calibration_fraction": 0.5}'
    )
    with pytest.raises(ValueError, match="declared_before_test_scoring"):
        protocol.load_nominal_levels(bad)
    dup = tmp_path / "dup.json"
    dup.write_text(
        '{"declared_before_test_scoring": true, "nominal_levels": [0.5, 0.5],'
        ' "fixed_widths": {"mass_g": [1.0]}, "conformal_calibration_fraction": 0.5}'
    )
    with pytest.raises(ValueError, match="distinct"):
        protocol.load_nominal_levels(dup)
