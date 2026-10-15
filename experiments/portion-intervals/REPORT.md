# Portion-interval study over PR41's frozen portion-estimation outputs

Scope: quantify how much structure is needed for calibrated nutrition-portion
intervals given FridgeLuck's current Nutrition5k evidence, WITHOUT refitting
or modifying PR41's frozen artifacts (experiments/nutrition5k-portion is
read-only for this study). The protocol was declared in NOMINAL_LEVELS.json
and committed BEFORE any test scoring.

## Declared protocol

- Nominal levels: 0.5, 0.8, 0.9
- Fixed absolute half-width grid (mass_g): 25.0, 50.0, 100.0 g
- Fixed absolute half-width grid (energy_kcal): 100.0, 250.0, 500.0 kcal
- Split-conformal calibration fraction (of dev plate clusters): 0.5
- Split-conformal random seed: 20261010
- Grouped split conformal: cluster score = mean |residual| within plate cluster;
  (n+1) finite-sample correction counts calibration CLUSTERS. Calibration uses
  development rows only; test rows are never touched by any width computation.

## Data accounting

| Quantity | Value |
|---|---|
| Committed target rows (validated) | 5006 |
| Committed estimate rows (validated) | 10134 |
| Cross-checks against PR41 aggregates | 35/35 passed |
| my_split: train / dev / test / no_rgb_split | 3452 / 607 / 709 / 238 |
| Official RGB split: train / test / no_rgb_split | 4059 / 709 / 238 |
| Scored test dishes (with committed predictions) | 507 of 709 |
| Test dishes WITHOUT committed predictions (coverage unknown) | 202 |
| Dev dishes committed (imagery membership unknown) | 607 (212) |
| Plate clusters on the scored test set (all multi-dish) | 494 |
| Scored-set cluster sizes | {"120": 1, "14": 1, "20": 484, "40": 8} |
| Singleton-plate stratum on the scored set | 0 dishes (every scored dish shares a plate cluster) |
| Inherited official-split-straddling plate clusters | cafe1_c01732, cafe1_c02052 |
| Implausible/zero targets flagged and kept (mass / energy) | 6 outside range / 240 <= 0, 243 outside range |
| Median anchors (mass / energy) | 177.0 g / 206.37 kcal, both ok |

The 202 unscored test dishes mean every
coverage number below is a LOWER bound on true test coverage: dishes PR41 could
not score are absent from its estimates file and from this study. The
2 inherited straddle clusters (cafe1_c01732, cafe1_c02052; test dishes
dish_1558641200, dish_1559844490) are upstream split properties, reported rather
than repaired; a sensitivity population excludes their test dishes.

## Arms that CANNOT run (unavailable, not zero)

- `dev_residual[foodlist]`: PR41 commits no per-record development predictions for the foodlist estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.
- `dev_residual[rgb]`: PR41 commits no per-record development predictions for the rgb estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.
- `dev_residual[rgbd]`: PR41 commits no per-record development predictions for the rgbd estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.
- `split_conformal[foodlist]`: PR41 commits no per-record development predictions for the foodlist estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.
- `split_conformal[rgb]`: PR41 commits no per-record development predictions for the rgb estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.
- `split_conformal[rgbd]`: PR41 commits no per-record development predictions for the rgbd estimator (test-only estimates, aggregate dev metrics, and no fitted model artifact), so calibration scores cannot be derived without re-fitting the owned model, which this study refuses to do.

Per-record development predictions for the image estimators were never
committed by PR41 (test-only estimates, aggregate dev metrics, no fitted model
artifact), and this study refuses to re-fit the owned models. Calibrated
intervals therefore exist only for the median estimator, whose dev
predictions ARE the frozen constants.

## Point-error context (absolute error of the frozen estimators)

| population | estimator | target | n | MAE | RMSE | median AE |
|---|---|---|---|---|---|---|
| depth_test | foodlist | energy_kcal | 507 | 101.738 | 153.245 | 62.660 |
| depth_test | foodlist | mass_g | 507 | 69.972 | 99.021 | 49.284 |
| depth_test | median | energy_kcal | 507 | 167.412 | 217.642 | 141.756 |
| depth_test | median | mass_g | 507 | 115.308 | 153.022 | 98.000 |
| depth_test | rgbd | energy_kcal | 507 | 82.521 | 119.446 | 57.931 |
| depth_test | rgbd | mass_g | 507 | 43.500 | 65.399 | 28.844 |
| depth_test | rgb | energy_kcal | 507 | 88.420 | 127.647 | 57.376 |
| depth_test | rgb | mass_g | 507 | 53.188 | 76.597 | 34.566 |
| rgb_test_plausible | foodlist | energy_kcal | 506 | 101.806 | 153.368 | 62.447 |
| rgb_test_plausible | foodlist | mass_g | 506 | 69.965 | 99.066 | 49.279 |
| rgb_test_plausible | median | energy_kcal | 506 | 167.335 | 217.664 | 141.603 |
| rgb_test_plausible | median | mass_g | 506 | 115.188 | 152.973 | 98.000 |
| rgb_test_plausible | rgb | energy_kcal | 506 | 88.548 | 127.769 | 57.491 |
| rgb_test_plausible | rgb | mass_g | 506 | 53.233 | 76.661 | 34.844 |
| rgb_test | foodlist | energy_kcal | 507 | 101.738 | 153.245 | 62.660 |
| rgb_test | foodlist | mass_g | 507 | 69.972 | 99.021 | 49.284 |
| rgb_test | median | energy_kcal | 507 | 167.412 | 217.642 | 141.756 |
| rgb_test | median | mass_g | 507 | 115.308 | 153.022 | 98.000 |
| rgb_test | rgb | energy_kcal | 507 | 88.420 | 127.647 | 57.376 |
| rgb_test | rgb | mass_g | 507 | 53.188 | 76.597 | 34.566 |

## Calibrated intervals (median estimator, rgb_test population)

| method | target | nominal | n | coverage | undercoverage | mean width | median width |
|---|---|---|---|---|---|---|---|
| dev_residual | mass_g | 0.5 | 507 | 0.521 | -0.021 | 202.0 | 202.0 |
| dev_residual | mass_g | 0.8 | 507 | 0.787 | 0.013 | 298.0 | 298.0 |
| dev_residual | mass_g | 0.9 | 507 | 0.892 | 0.008 | 415.0 | 415.0 |
| dev_residual | energy_kcal | 0.5 | 506 | 0.464 | 0.036 | 266.9 | 266.9 |
| dev_residual | energy_kcal | 0.8 | 506 | 0.739 | 0.061 | 385.3 | 385.3 |
| dev_residual | energy_kcal | 0.9 | 506 | 0.866 | 0.034 | 554.3 | 554.3 |
| split_conformal | mass_g | 0.5 | 507 | 0.503 | -0.003 | 196.0 | 196.0 |
| split_conformal | mass_g | 0.8 | 507 | 0.763 | 0.037 | 286.0 | 286.0 |
| split_conformal | mass_g | 0.9 | 507 | 0.874 | 0.026 | 378.0 | 378.0 |
| split_conformal | energy_kcal | 0.5 | 506 | 0.472 | 0.028 | 270.1 | 270.1 |
| split_conformal | energy_kcal | 0.8 | 506 | 0.727 | 0.073 | 379.2 | 379.2 |
| split_conformal | energy_kcal | 0.9 | 506 | 0.858 | 0.042 | 518.8 | 518.8 |

Reading: BOTH calibrated methods under-cover at every level on energy, and
split conformal under-covers even with the finite-sample correction. Two
mechanisms, both visible in the data: EVERY scored test dish shares its plate
cluster with 13-119 other dishes, so cluster-mean calibration scores are
smaller than individual residuals; and the test meals differ from the dev
meals. The dev-residual arm (per-record widths, no correction) covers
slightly MORE than split conformal here - an honest negative result for
naive cluster-level conformal on this data, at slightly wider mean widths.

## Fixed-width intervals (all estimators, by population)

### rgb_test / mass_g

| estimator | half-width | n | coverage | mean width |
|---|---|---|---|---|
| foodlist | 25.0 g | 507 | 0.276 | 50.0 |
| foodlist | 50.0 g | 507 | 0.505 | 100.0 |
| foodlist | 100.0 g | 507 | 0.771 | 200.0 |
| median | 25.0 g | 507 | 0.122 | 50.0 |
| median | 50.0 g | 507 | 0.250 | 100.0 |
| median | 100.0 g | 507 | 0.519 | 200.0 |
| rgb | 25.0 g | 507 | 0.363 | 50.0 |
| rgb | 50.0 g | 507 | 0.629 | 100.0 |
| rgb | 100.0 g | 507 | 0.848 | 200.0 |

### rgb_test / energy_kcal

| estimator | half-width | n | coverage | mean width |
|---|---|---|---|---|
| foodlist | 100.0 kcal | 506 | 0.650 | 200.0 |
| foodlist | 250.0 kcal | 506 | 0.911 | 500.0 |
| foodlist | 500.0 kcal | 506 | 0.988 | 1000.0 |
| median | 100.0 kcal | 506 | 0.328 | 200.0 |
| median | 250.0 kcal | 506 | 0.846 | 500.0 |
| median | 500.0 kcal | 506 | 0.953 | 1000.0 |
| rgb | 100.0 kcal | 506 | 0.666 | 200.0 |
| rgb | 250.0 kcal | 506 | 0.935 | 500.0 |
| rgb | 500.0 kcal | 506 | 0.994 | 1000.0 |

Note: the estimators PR41 scored on the rgb_test population are: foodlist, median, rgb.

### depth_test / mass_g

| estimator | half-width | n | coverage | mean width |
|---|---|---|---|---|
| foodlist | 25.0 g | 507 | 0.276 | 50.0 |
| foodlist | 50.0 g | 507 | 0.505 | 100.0 |
| foodlist | 100.0 g | 507 | 0.771 | 200.0 |
| median | 25.0 g | 507 | 0.122 | 50.0 |
| median | 50.0 g | 507 | 0.250 | 100.0 |
| median | 100.0 g | 507 | 0.519 | 200.0 |
| rgb | 25.0 g | 507 | 0.363 | 50.0 |
| rgb | 50.0 g | 507 | 0.629 | 100.0 |
| rgb | 100.0 g | 507 | 0.848 | 200.0 |
| rgbd | 25.0 g | 507 | 0.448 | 50.0 |
| rgbd | 50.0 g | 507 | 0.720 | 100.0 |
| rgbd | 100.0 g | 507 | 0.901 | 200.0 |

### depth_test / energy_kcal

| estimator | half-width | n | coverage | mean width |
|---|---|---|---|---|
| foodlist | 100.0 kcal | 506 | 0.650 | 200.0 |
| foodlist | 250.0 kcal | 506 | 0.911 | 500.0 |
| foodlist | 500.0 kcal | 506 | 0.988 | 1000.0 |
| median | 100.0 kcal | 506 | 0.328 | 200.0 |
| median | 250.0 kcal | 506 | 0.846 | 500.0 |
| median | 500.0 kcal | 506 | 0.953 | 1000.0 |
| rgb | 100.0 kcal | 506 | 0.666 | 200.0 |
| rgb | 250.0 kcal | 506 | 0.935 | 500.0 |
| rgb | 500.0 kcal | 506 | 0.994 | 1000.0 |
| rgbd | 100.0 kcal | 506 | 0.717 | 200.0 |
| rgbd | 250.0 kcal | 506 | 0.943 | 500.0 |
| rgbd | 500.0 kcal | 506 | 0.996 | 1000.0 |

Note: the estimators PR41 scored on the depth_test population are: foodlist, median, rgb, rgbd.

## Strata: singleton vs multi-dish plates (rgb_test, nominal 80%)

| method | target | n (1-dish) | coverage (1-dish) | n (2+ dishes) | coverage (2+ dishes) |
|---|---|---|---|---|---|
| dev_residual | mass_g | 0 | — | 507 | 0.787 |
| dev_residual | energy_kcal | 0 | — | 506 | 0.739 |
| split_conformal | mass_g | 0 | — | 507 | 0.763 |
| split_conformal | energy_kcal | 0 | — | 506 | 0.727 |

## Sensitivity: excluding the inherited straddle test dishes

| method | target | coverage (rgb_test) | coverage (straddle-excluded) | |delta| |
|---|---|---|---|---|
| dev_residual | mass_g | 0.787 | 0.788 | 0.001 |
| dev_residual | energy_kcal | 0.739 | 0.740 | 0.001 |
| split_conformal | mass_g | 0.763 | 0.764 | 0.001 |
| split_conformal | energy_kcal | 0.727 | 0.728 | 0.001 |

The inherited leak moves coverage by at most 0.1 percentage point(s) on
this population: it is a real upstream defect but immaterial to these interval
results.

## Limitations

1. Coverage is descriptive; no confidence intervals are attached to the
   interval-coverage numbers (the study measures, it does not test).
2. rgb/foodlist/rgbd calibrated arms are unavailable (see above); only
   fixed-width intervals exist for the image estimators.
3. The 202 unscored official-test dishes make all coverage a lower bound.
4. Zero-truth dishes (no consumption) are excluded from coverage
   denominators and counted per cell (n_zero_excluded).
5. One fixed conformal seed; seed sensitivity was not explored (declared).

## Reproduce

```bash
python3 experiments/portion-intervals/check_inputs.py            # input contract
python3 experiments/portion-intervals/evaluate.py --seed 20261010 # re-score
python3 experiments/portion-intervals/score.py --verify-report    # byte-verify this file
python3 -m pytest experiments/portion-intervals/tests -q          # test suite
```

## Handoff

- Done: contract reader, declared protocol, negative-control tests (M1);
  interval evaluation with unavailable arms made explicit (M2); this report,
  regenerable and byte-verifiable (M3).
- Left: nothing in scope; optional follow-ups (out of scope here): seed
  sensitivity, per-dish intervals per estimator if PR41 ever commits dev
  predictions, integrating interval width into product decisions.
- Continue: check out obv/fl-l3-portion-intervals; run the four commands
  above; REPORT.md must byte-verify against the committed results.
