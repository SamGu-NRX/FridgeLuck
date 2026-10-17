# experiments/nutrition5k-portion

Portion-estimation experiment on the public [Nutrition5k](https://research.google/pubs/nutrition5k-towards-automatic-nutritional-understanding-of-generic-food/)
dataset, answering one question for FridgeLuck's scan-a-plate flow: **how far do
milliseconds-per-image handcrafted features (RGB alone, RGB + raw depth) get on per-plate
mass (g) and energy (kcal), measured with the dataset's own protocol and metrics?**

Read **[REPORT.md](REPORT.md)** for the full write-up (results, CIs, what was and wasn't
measured) and **[ATTRIBUTION.md](ATTRIBUTION.md)** for the dataset citation and license.

## Layout

```
src/download_nutrition5k.py   selective GCS fetch (public bucket, sha256 manifest, no archive download)
src/build_dataset.py          joins official metadata + splits, audits targets, carves a plate-clustered dev split
src/extract_features.py       134 RGB + 12 depth features per dish (deterministic, CPU, ~55 ms/image)
src/features.py               feature implementations (frozen: NEAREST depth resize to the 320x240 RGB grid)
src/fit_models.py             dev-only estimator selection (RidgeCV vs HistGradientBoostingRegressor); writes FROZEN_CONFIG.json
src/scorer.py                 MAE / nMAE (= official MAE_%/100) / bias / quantiles / coverage + plate-cluster bootstrap CIs
src/evaluate.py               one-shot test evaluation + official compute_eval_statistics.py cross-check
src/test_pipeline.py          portable synthetic tests (no dataset required); official-script parity test included
data/                         derived tables + audit (no dataset redistribution - see ATTRIBUTION.md)
outputs/                      dev/test metrics, per-dish test estimates, bootstrap draws, official cross-check
```

## Run

```bash
pip install -r requirements.txt
python3 -m pytest src -q
python3 src/download_nutrition5k.py
python3 src/build_dataset.py
python3 src/extract_features.py
python3 src/fit_models.py
python3 src/evaluate.py
```

Protocol: model fitting and estimator selection see only the official RGB-train data
(carved 2,360 train / 395 dev by plate cluster); the official RGB test set (507 dishes with
overhead imagery) is touched once by `evaluate.py`. Zero-target policy and all metric
definitions are frozen in `src/scorer.py` and documented in the report.

Headline (official test, n=507; 95% plate-cluster bootstrap CIs in REPORT.md):

| Arm | Mass MAE | Energy MAE |
|---|---|---|
| median baseline | 115.3 g | 167.4 kcal |
| ingredient list (privileged) | 70.0 g | 101.7 kcal |
| RGB only | 53.2 g | 88.4 kcal |
| RGB + depth | **43.5 g** | **82.5 kcal** |

The vision-LLM endpoint harness (`src/vision_endpoint.py`) is optional and refused to run
without `GEMINI_API_KEY`; it is budget-gated (e.g. `--max-images=250 --spend-ceiling-usd=2.0`)
and was not executed for the reported results.
