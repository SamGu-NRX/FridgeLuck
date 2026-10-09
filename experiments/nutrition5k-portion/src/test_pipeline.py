"""Portable tests for the Nutrition5k portion-estimation pipeline.

Run: python3 -m pytest experiments/nutrition5k-portion/src -q
These use only numpy/sklearn and synthetic data EXCEPT the official-script
cross-check, which needs the raw compute_eval_statistics.py and skips if absent.
"""

from __future__ import annotations

import csv
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import features  # noqa: E402
import scorer  # noqa: E402

RAW_EVAL = Path("/home/user/work/n5k-data/raw/compute_eval_statistics.py")


# ---------------------------------------------------------------- scorer

def test_mae_nmae_and_bias() -> None:
    y = np.array([100.0, 200.0, 300.0, 400.0])
    p = np.array([150.0, 200.0, 250.0, 300.0])
    c = np.array(["a", "a", "b", "b"])
    m = scorer.full_metrics(y, p, c, mass=True)
    assert m["n"] == 4
    # |50|,|0|,|50|,|100| -> MAE 50
    assert m["mae"] == pytest.approx(50.0)
    # nMAE = sum|err| / sum(y) = 200/1000 (official MAE_% / 100)
    assert m["nmae"] == pytest.approx(0.2)
    assert m["bias"] == pytest.approx(-25.0)


def test_zero_targets_excluded_from_relative_metrics_only() -> None:
    y = np.array([0.0, 100.0])
    p = np.array([50.0, 150.0])
    c = np.array(["a", "a"])
    m = scorer.full_metrics(y, p, c, mass=False)
    # absolute metrics keep the zero row: (|50|+|50|)/2 = 50
    assert m["mae"] == pytest.approx(50.0)
    assert m["n_zero"] == 1
    # rel err: zero row excluded, remaining |150-100|/100 = 0.5
    assert m["rel_err_p50"] == pytest.approx(0.5)
    # coverage: only the non-zero row can be "within"; 0.5 > 0.25 -> 0
    assert m["coverage_rel_25pct"] == pytest.approx(0.0)


def test_nmae_matches_official_mae_pct_definition() -> None:
    rng = np.random.default_rng(11)
    y = rng.uniform(50, 800, 37)
    p = y + rng.normal(0, 40, 37)
    c = np.array([f"cluster{i % 12}" for i in range(37)])
    m = scorer.full_metrics(y, p, c, mass=False)
    official_mae_pct = 100.0 * float(np.abs(p - y).mean()) / float(y.mean())
    assert m["nmae"] * 100 == pytest.approx(official_mae_pct, rel=1e-12)


def test_mass_coverage_bands_present_only_for_mass() -> None:
    y = np.array([100.0, 200.0])
    p = np.array([110.0, 260.0])
    c = np.array(["a", "b"])
    mass_m = scorer.full_metrics(y, p, c, mass=True)
    energy_m = scorer.full_metrics(y, p, c, mass=False)
    assert "coverage_abs_50g" in mass_m
    assert "coverage_abs_50g" not in energy_m
    # errors |10| and |60|: <=50g hit rate 0.5, <=100g hit rate 1.0
    assert mass_m["coverage_abs_50g"] == pytest.approx(0.5)
    assert mass_m["coverage_abs_100g"] == pytest.approx(1.0)


def test_cluster_bootstrap_is_cluster_whole_and_reproducible() -> None:
    clusters = np.array(["c1", "c1", "c2", "c3", "c3", "c3"])
    d1 = scorer.cluster_bootstrap_indices(clusters, B=50, seed=7)
    d2 = scorer.cluster_bootstrap_indices(clusters, B=50, seed=7)
    d3 = scorer.cluster_bootstrap_indices(clusters, B=50, seed=8)
    assert len(d1) == 50
    for idx in d1:
        # every drawn index set has each sampled cluster in full or not at all
        for c in np.unique(clusters):
            rows = np.where(clusters == c)[0]
            drawn = np.isin(rows, idx).all() or not any(np.isin(rows, idx))
            assert drawn, f"cluster {c} partially drawn"
    assert all(np.array_equal(a, b) for a, b in zip(d1, d2))
    assert not all(np.array_equal(a, b) for a, b in zip(d1, d3))


def test_bootstrap_ci_brackets_point_estimate() -> None:
    rng = np.random.default_rng(1)
    clusters = np.repeat([f"c{i}" for i in range(40)], 3)
    y = rng.uniform(50, 500, 120)
    p = y + rng.normal(0, 30, 120)
    m = scorer.full_metrics(y, p, clusters, mass=True)
    assert m["mae_ci95"][0] <= m["mae"] <= m["mae_ci95"][1]


# ---------------------------------------------------------------- features

def test_rgb_features_deterministic_correct_dim() -> None:
    img = (np.random.default_rng(3).uniform(0, 255, (240, 320, 3))).astype(np.uint8)
    f1 = features.rgb_features(Image.fromarray(img))
    f2 = features.rgb_features(Image.fromarray(img))
    assert f1.shape == f2.shape == (len(features.RGB_FEATURE_NAMES),)
    assert len(features.RGB_FEATURE_NAMES) == 134
    assert np.array_equal(f1, f2)
    assert np.isfinite(f1).all()


def _uint16_depth(raw: np.ndarray) -> Image.Image:
    return Image.fromarray(raw.astype(np.uint16))


def test_depth_features_all_sentinel_yields_nan_row() -> None:
    rgb = Image.fromarray(np.full((240, 320, 3), 128, dtype=np.uint8))
    raw = np.full((240, 320), features.DEPTH_SENTINEL)
    f = features.depth_features(_uint16_depth(raw), rgb)
    assert f.shape == (len(features.DEPTH_FEATURE_NAMES),)
    assert np.isnan(f).all()  # imputed downstream / excluded from rgbd fits


def test_depth_features_track_food_height() -> None:
    # Saturated red disk on gray background: the disk is the RGB food mask.
    rgb_arr = np.full((240, 320, 3), 128, dtype=np.uint8)
    yy, xx = np.mgrid[0:240, 0:320]
    disk = (yy - 120) ** 2 + (xx - 160) ** 2 < 60**2
    rgb_arr[disk] = (224, 30, 30)  # s>0.2 and 0.15<v<0.95 -> in food mask
    rgb = Image.fromarray(rgb_arr)

    # Flat table plane 0.70 m from the camera everywhere -> zero food height.
    flat = np.full((240, 320), 7000)
    f_flat = features.depth_features(_uint16_depth(flat), rgb)

    # Food disk 60 mm closer to the camera than the rim -> positive height.
    taller = np.full((240, 320), 7000)
    taller[disk] = 6400
    f_tall = features.depth_features(_uint16_depth(taller), rgb)

    assert np.isfinite(f_flat).all() and np.isfinite(f_tall).all()
    i = features.DEPTH_FEATURE_NAMES.index("height_mean_m")
    p90 = features.DEPTH_FEATURE_NAMES.index("height_p90_m")
    assert f_tall[i] > f_flat[i]
    assert f_flat[i] == pytest.approx(0.0, abs=1e-9)
    # the disk covers ~15% of the frame, so the masked mean is ~0.15 * 0.06 m
    assert f_tall[p90] == pytest.approx(0.06, rel=0.05)
    assert 0.0 < f_tall[i] < 0.06


# ---------------------------------------------------------------- fitting path

def test_ridge_pipeline_imputes_nan_depth_block() -> None:
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import RidgeCV
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import StandardScaler

    rng = np.random.default_rng(6)
    X = rng.normal(size=(80, 10))
    X[:20, -3:] = np.nan  # depth block missing for 25% of rows
    y = X[:, 0] * 10 + rng.normal(scale=0.1, size=80)
    pipe = Pipeline([("imp", SimpleImputer(strategy="median")),
                     ("sc", StandardScaler()),
                     ("m", RidgeCV(alphas=np.logspace(-2, 2, 5), cv=3))])
    pipe.fit(X, y)  # must not raise
    assert pipe.predict(X).shape == (80,)


# ---------------------------------------------------------------- official parity

@pytest.mark.skipif(not RAW_EVAL.exists(), reason="official compute_eval_statistics.py not downloaded")
def test_official_script_agrees_with_own_scorer(tmp_path: Path) -> None:
    n = 60
    rng = np.random.default_rng(9)
    ids = [f"dish_{i:04d}" for i in range(n)]
    y_cal = rng.uniform(200, 1500, n)
    y_mass = rng.uniform(100, 900, n)
    pred_cal = y_cal + rng.normal(0, 100, n)
    pred_mass = y_mass + rng.normal(0, 60, n)

    gt = tmp_path / "gt.csv"
    pr = tmp_path / "pr.csv"
    with gt.open("w", newline="") as fh:
        w = csv.writer(fh)
        for i in range(n):
            # macros are nonzero placeholders: the official script computes MAE_%
            # for every field and divides by the ground-truth mean
            w.writerow([ids[i], y_cal[i], y_mass[i], 20, 20, 20])
    with pr.open("w", newline="") as fh:
        w = csv.writer(fh)
        for i in range(n):
            w.writerow([ids[i], pred_cal[i], pred_mass[i], 20, 20, 20])

    res = subprocess.run(
        [sys.executable, str(RAW_EVAL), str(gt), str(pr), str(tmp_path / "out.json")],
        capture_output=True, text=True,
    )
    assert res.returncode == 0, res.stderr
    official = json.loads((tmp_path / "out.json").read_text())

    ours_cal = float(np.abs(pred_cal - y_cal).mean())
    ours_mass = float(np.abs(pred_mass - y_mass).mean())
    assert official["calories_MAE"] == pytest.approx(ours_cal, rel=1e-6)
    assert official["mass_MAE"] == pytest.approx(ours_mass, rel=1e-6)
    # the official percentage field is nMAE*100 by construction
    assert official["calories_MAE_%"] == pytest.approx(
        100.0 * ours_cal / float(y_cal.mean()), rel=1e-6
    )
