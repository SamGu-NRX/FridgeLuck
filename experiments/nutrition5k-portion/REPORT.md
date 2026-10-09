# Report — Cheap portion estimation on Nutrition5k overhead imagery

**Branch** `obv/fl-next-portion-estimates` · **Date** 2026-10-09 · **All numbers below were
retrieved from this run's own artifacts** (`outputs/metrics_test.csv`,
`outputs/official_eval_crosscheck.json`, `data/build_audit.json`, `results/…` under
`experiments/nutrition5k-portion/`).

## Load-bearing assumption

The premise carried into this work: **cheap handcrafted image features fit in FridgeLuck's
on-device budget can estimate portions well enough to beat non-image baselines, and depth
(meters) is the part of the image that carries portion information.** Confirming evidence
from this run: the RGB arm beats both the no-image baseline and the ingredient-list arm, and
depth is decisive for mass (CIs below). What would break it: a learned backbone at
comparable latency doing much better (plausible — see Limitations) — the conclusion
"handcrafted is *enough*" would then be wrong, though the measurement harness itself would
stand.

Adjacent explanations this design skips: learned CNN backbones, per-ingredient detection,
volume-integration approaches with camera calibration, and the side-angle videos. None is
required to answer the question asked (how far do milliseconds-per-image features go?).

## Question

For FridgeLuck's scan-a-plate flow: how accurately can mass (g) and energy (kcal) per plate
be estimated from a single calibrated overhead RGB frame (plus raw depth when present), using
features that cost milliseconds per image on CPU, measured with the dataset's own protocol
and metrics?

## Data

Source: the public Nutrition5k GCS bucket (`gs://nutrition5k/`), fetched selectively on
2026-10-09 — no full archive download. See `ATTRIBUTION.md` for citation and license.

| Item | Value |
|---|---|
| Official RGB split | 4,059 train / 709 test dishes (per official `rgb_train_ids.txt` / `rgb_test_ids.txt`) |
| Dishes with overhead imagery in bucket | 3,490 (each has `rgb.png`; all but one also have a readable `depth_raw.png`) |
| Overhead imagery ∩ official RGB train | 2,755 |
| Overhead imagery ∩ official RGB test | 507 (exactly the official depth-test set — the depth-test population) |
| Official cross-check harness | their `compute_eval_statistics.py`, downloaded unmodified |
| Download manifest | 6,524 files, sha256-verified at fetch time, 0 errors (`imagery_manifest.jsonl`) |
| Known corrupt source file | `dish_1564159636/depth_raw.png` is 0 bytes *in the bucket* (empty-string sha256); counted as depth-unavailable |
| Dishes with features | 3,262 RGB; 3,261 with usable depth (unusable depth → NaN row, excluded from rgbd fits) |

Targets per dish: `total_mass_g` and `total_calories_kcal`, taken from the official per-dish
metadata. **Macros are not modeled or reported.** Target audit (audit thresholds are development heuristics, not data deletion):
6 mass targets and 243 calorie targets flagged implausible (e.g. a 1 g plate in the test
set); all are kept in the official numbers. Two dishes have zero calorie annotations; the
zero policy is: zeros stay in MAE/bias/nMAE, are excluded from relative-error and coverage
denominators, and are counted in `n_zero` (test set: 1 energy zero).

## Method

- **Frozen protocol** (`FROZEN_CONFIG.json`, written before the test run): official RGB
  train → development carve (2,360 train / 395 dev) clustered at the plate level by scan
  timestamp so incremental scans of one physical plate never straddle; official RGB test is
  untouched (507 plates).
- **Features** (`src/features.py`): 134 deterministic handcrafted RGB features (Lab/HSV
  statistics, 96-bin hue-saturation histogram, saturation/value percentiles, color-based food
  mask, Sobel edge density, 5-ring radial occupancy, 4×4 luminance grid) + 12 depth features
  (depth quantiles inside the RGB food mask, rim-reference height above plate, masked height
  statistics, volume proxy). Depth is brought onto the RGB grid with nearest-neighbor resize;
  a fully invalid depth frame yields a NaN row.
- **Arms**: `median` (predict the training-set median — no-image floor), `rgb` (RGB only),
  `rgbd` (RGB+depth, imputed where depth missing), `foodlist` (privileged arm: ingredient
  presence vector from the official ingredient metadata — an oracle a phone app cannot
  expect, included as context).
- **Estimator selection on development only**: `RidgeCV` vs `HistGradientBoostingRegressor`
  per (population, target); HGBR won every arm. No test-set peeking at any hyperparameter.
- **Metrics** (`src/scorer.py`): MAE, nMAE ≡ official `MAE_%`/100 (sum|err|/sum(y)), bias,
  absolute/relative error quantiles, tolerance coverage (|rel|≤10/25/50%, plus ≤25/50/100 g
  for mass), all with 95% plate-cluster bootstrap CIs (2,000 resamples; all rows of a plate
  cluster move together; seed 20261009).
- **Cross-check**: `evaluate.py` also runs the official `compute_eval_statistics.py` on the
  same predictions; its output is quoted verbatim below. (Their script requires nonzero
  ground-truth macros to compute `MAE_%` for every field; macro columns are constant
  placeholders on both sides so the script runs. Only calories and mass are interpreted.)

## Results — official test set (n = 507 plates)

MAE in grams / kcal with 95% plate-cluster bootstrap CIs; nMAE% = official `MAE_%`.

**Mass (g):**

| Arm | MAE | 95% CI | nMAE% | ±25% coverage | ±50% coverage |
|---|---|---|---|---|---|
| median | 115.31 | [106.92, 124.24] | 58.09 | 23.1% | 50.3% |
| foodlist (privileged) | 69.97 | [64.04, 76.21] | 35.25 | 39.6% | 68.8% |
| rgb | 53.19 | [48.78, 58.20] | 26.79 | 51.5% | 80.3% |
| **rgbd** | **43.50** | [39.43, 47.96] | **21.91** | **64.3%** | 83.8% |

**Energy (kcal):**

| Arm | MAE | 95% CI | nMAE% | ±25% coverage | ±50% coverage |
|---|---|---|---|---|---|
| median | 167.41 | [155.89, 180.64] | 65.53 | 16.8% | 40.3% |
| foodlist (privileged) | 101.74 | [91.59, 112.27] | 39.82 | 37.7% | 66.2% |
| rgb | 88.42 | [80.45, 96.26] | 34.61 | 39.5% | 70.6% |
| **rgbd** | **82.52** | [74.97, 90.09] | **32.30** | 39.9% | 71.7% |

Official-script cross-check (their `MAE_%` definition, rgb arm) — verbatim output:
`{"calories_MAE": 88.42, "calories_MAE_%": 34.61, "mass_MAE": 53.19, "mass_MAE_%": 26.79,
"fat_MAE": 0.0, "carb_MAE": 0.0, "protein_MAE": 0.0, …}` — identical to the internal scorer
to the digits shown; the parity test also asserts this on synthetic data at 1e-6.

## Findings

1. **A single overhead photo, no backbone, gets to 53 g / 88 kcal.** The rgb arm cuts MAE
   by 54% (mass) and 47% (energy) against the median floor, with half the test plates
   within ~±25% of true mass. Inference is ~2–4 ms/plate (measured, prediction only);
   feature extraction is ~55 ms/image single-threaded (measured on 8 cores, parallel run
   ~65 s for 3,262 images).
2. **Depth is the portion signal for mass, decisively.** rgbd mass MAE 43.50 g, CI
   [39.43, 47.96], entirely below rgb's CI [48.78, 58.20] — an 18% improvement with no CI
   overlap. For energy the point estimate improves (88.4 → 82.5 kcal) but the CIs overlap;
   the depth gain for energy is directional, not established at n = 507.
3. **The privileged ingredient-list arm loses to the image.** Ingredients alone (69.97 g /
   101.74 kcal) are clearly worse than rgb (53.19 g / 88.42 kcal). For FridgeLuck this says
   the photo carries portion information the recognized ingredient list does not — the
   "ingredients imply portion" prior is weak.
4. **Bias is near zero for mass** (+0.5 g rgb) and mildly negative for energy
   (−26 kcal rgb, −28 rgbd): calories are systematically under-predicted, plausibly because
   energy-dense but visually small items are underweighted. Worth a calibration step before
   product use.
5. **Sensitivity check**: excluding the single zero-calorie test dish (`rgb_test_plausible`,
   n = 506) changes every metric by < 0.3%.

## What was measured, and what was not

- **Measured this run**: everything above, on the machine recorded in
  `outputs/build_stats.json` / `results/env.json` (Python 3.13, numpy 2.5.2, Pillow 12.3,
  scikit-learn, 8-core x86_64 container). The 11-test suite passes
  (`python3 -m pytest src/test_pipeline.py -q` → 11 passed, 1.6 s), including the
  official-script parity test that executes the downloaded Google script.
- **Not built / not measured**: anything GPU or learned-backbone (no CUDA in this
  environment); per-ingredient volumes; the side-angle videos; the vision-LLM endpoint arm
  of the harness (no authorized Gemini credential in this environment — see below); rgbd
  per-plate prediction timing (cell left empty; rgb/foodlist were measured); iOS on-device
  runtime (feature code is portable numpy, not yet Swift).
- **Not interpretable**: the `fat`/`carb`/`protein` zeros in the official cross-check are
  placeholders, not model output.

## First-attempt failures, kept for the record

The first test run failed 7 of 10 tests; three were wrong test expectations (hand-computed
MAE wrong; a nonexistent `sklearn_mape_pct` key; depth "NaN array" fixtures that predated the
16-bit-image API), and running on real data surfaced two genuine bugs the synthetic tests
missed: depth frames are 640×480 while the RGB grid is 320×240 (broadcast crash; fixed by
resizing raw depth with NEAREST), and the official script divides by the ground-truth mean of
*every* field, so zero-filled macro placeholders crashed it (fixed with constant placeholders
on both sides). One bucket file (`dish_1564159636/depth_raw.png`) is 0 bytes at the source;
extraction now counts it as depth-unavailable instead of crashing. All retained in git
history.

## Assumptions made

- The timestamp-clustering development carve (20 s gap threshold, candidates wholly inside
  official train) is a reasonable plate-boundary heuristic; the official test set is used
  exactly once, as downloaded.
- The official split files and metadata were used unmodified; where bucket contents differ
  from documentation (missing imagery for 202 official test dishes, one empty depth file)
  the dish is honestly excluded and counted.
- "Cheap" = milliseconds per image on CPU, so no learned backbone was tuned — that is the
  experiment's design constraint, not a claim that backbones can't do better.

## Reproduce

```bash
pip install -r experiments/nutrition5k-portion/requirements.txt
python3 -m pytest experiments/nutrition5k-portion/src -q
python3 experiments/nutrition5k-portion/src/download_imagery.py   # selective GCS fetch, sha256 manifest
python3 experiments/nutrition5k-portion/src/build_dataset.py
python3 experiments/nutrition5k-portion/src/extract_features.py
python3 experiments/nutrition5k-portion/src/fit_models.py
python3 experiments/nutrition5k-portion/src/evaluate.py
```
