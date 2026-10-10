# Ingredient recognition benchmark — milestone 2 report

Open-model baselines for FridgeLuck's ingredient-recognition pipeline, measured on
FoodSeg103 with the app's real resolution path. Everything here was produced by the
committed tooling; every number in the tables below comes from a `scores.json` in
`scoring/` generated this session.

## What this milestone adds

Over milestone 1 (frozen manifest, taxonomy, resolution port) this milestone:

1. **Corrected a real runner bug** — see "Corrections" below. All six-crop numbers
   reported in milestone 1 were deflated by it and are superseded here.
2. Added `--crop-schedule whole` final runs and a development protocol for threshold
   selection (`scoring/threshold_sweep.py`).
3. Extended `scoring/score.py`: mapping-coverage accounting, per-image outcome
   records (`*_per_image.jsonl.gz`), runner-failure integration, and a malformed-record
   guard that refuses to score a partial observation file.
4. Added scorer hand-case and corruption tests
   (`experiments/ingredient-recognition/tests/test_scoring.py`).

## Classifier substitute (documented, deliberate)

There is no Apple silicon in this environment, so the app's Vision classifier is
substituted by **CLIP ViT-B-32 (laion2b_s34b_b79k) zero-shot softmax** over the
curated label set. The app's entire surrounding pipeline is reproduced faithfully:
downscaling, the six-crop schedule from `ScanImagePreprocessor.swift`, the curated
lexicon → catalog resolution (differentially verified against 186 Swift probe cases,
zero differences), best-per-ingredient deduplication, and optional absorber labels.
What this measures is the *pipeline around the classifier*; the classifier itself is
a stand-in. Apple-device and macOS-Vision replay remain unrun (see "Not checked").

## Ground truth and scoring definitions

- **Instance**: (image, FoodSeg103 class) whose taxonomy row has resolution targets.
  `exact` targets one catalog ingredient; `coarse` targets a broader ingredient;
  `ambiguous` targets the union of candidates; `unsupported` has none.
- **Instance recall** (per kind and overall): fraction of instances whose target set
  intersects the image's detections.
- **Detection precision**: correct detections / all detections, counted **only on
  images with at least one mapped GT class**. Detections on unsupported-only images
  are reported separately as no-claim violations.
- **Abstention**: images with mapped GT classes but zero detections.
- **No-claim discipline**: images whose GT classes are all unsupported should get
  zero detections; violations are counted.

Mapping coverage on the validation split: 51 of 103 classes have targets (38 exact,
8 coarse, 5 ambiguous); GT instances 5,563 with targets vs 2,134 unsupported; 100% of
detections carry resolved provenance.

## Corrections

Three defects were found and fixed this milestone; each would have silently skewed
results if left alone.

1. **Cross-crop detection overwrite (invalidate M1 six-crop numbers).**
   `runner/observe.py` rebuilt its best-per-ingredient map per crop and overwrote the
   image's detections each time, so six-crop observations kept only the *last* crop's
   detections. Whole-image runs (one crop) were unaffected, which is why they never
   showed the inconsistency. Diagnostic: image 0 kept `Rice 0.483` from the last crop
   while the recorded crop labels contained `Rice 0.989` and `Chicken Breast 0.727`
   from other crops. Milestone 1's "17.5% recall / 34.5% precision" six-crop numbers
   came from this buggy path; the corrected values are in the table below.
2. **Development slice ordering bias.** `--limit 300` took the shard-ordered head,
   whose ids spanned only 0–99 (correlated images). Replaced with `--sample 300
   --seed 0`, a deterministic uniform sample of manifest train ids.
3. **Threshold-sweep ground truth leakage.** The sweep initially scored the full
   train split's GT against a 300-image development run, deflating recall ~3x and
   pushing threshold selection to the grid edge. The sweep now restricts GT to
   observed images and its grids were extended until the chosen threshold was an
   interior peak (or the boundary was shown to be flat — see below).

## Threshold development (train split, development sample only)

Dev protocol: 300 randomly sampled train images (seed 0), record floor 0.001, zero
observation failures. Chosen threshold maximizes detection F1 on dev.

- **Six-crop**: interior peak at **0.25** (F1 0.4048; neighbors 0.3958 at 0.2 and
  0.3966 at 0.3). Frozen. Full table: `scoring/thresholds_sixcrop_dev.json`.
- **Whole-image**: strict argmax at 0.001, the grid boundary, with F1 flat within
  0.8 points across 0.001–0.01 (0.3052/0.3001/0.2973/0.2968) — within noise for 739
  dev instances. Frozen at **0.005** (F1 0.2973) to avoid boundary-of-grid overfit;
  the flatness means the choice is not load-bearing. Full table:
  `scoring/thresholds_wholecrop_dev.json`.

The frozen six-crop threshold generalizes: dev F1 0.4048 at 0.25 → validation F1
0.396 at 0.25; dev F1 0.370 at 0.1 → validation F1 0.376 at 0.1.

## Final validation results (FoodSeg103 validation, 2,135 images, zero observation failures)

| Run | Threshold | Instance recall (all) | Exact | Coarse | Ambiguous | Detection precision | Detections | Abstain | No-claim violations |
|---|---|---|---|---|---|---|---|---|---|
| Six-crop, dev-tuned, absorbers on | 0.25 | **0.3843** | 0.3731 | 0.6078 | 0.1579 | **0.4078** | 5,253 | 39 | 252 |
| Whole-image, dev-tuned, absorbers on | 0.005 | 0.3095 | 0.2448 | 0.6564 | 0.2051 | 0.2602 | 6,733 | 96 | 254 |
| Six-crop, app constant, absorbers on | 0.1 | 0.4756 | 0.4623 | 0.7146 | 0.2402 | 0.3101 | 8,576 | 9 | 253 |
| Six-crop, app constant, absorbers off | 0.1 | 0.5324 | 0.5114 | 0.8214 | 0.2740 | 0.2688 | 11,118 | 0 | 254 |
| Six-crop, curated+USDA labels, absorbers on | 0.1 | 0.1425 | 0.1667 | 0.1427 | 0.0162 | 0.1058 | 7,479 | 30 | 235 |

Readings:

- **Crops earn their cost.** At the dev-tuned operating point, six crops beat
  whole-image on recall (38.4% vs 31.0%) and precision (40.8% vs 26.0%) — the F1
  comparison (0.396 vs 0.280 on dev) is decisive, not close. The six-crop schedule in
  `ScanImagePreprocessor.swift` is the right call.
- **Absorbers are a recall-for-precision trade, and at the app's threshold they cost
  more than they return.** Absorbers on/off at 0.1: recall 47.6% → 53.2% (+5.7pt),
  precision 31.0% → 26.9% (−4.1pt). The app's intent (fewer false ingredient claims
  from plates/counter backgrounds) is only partially realized: precision still drops
  because the suppressed mass comes back as unjustified food detections. At the
  dev-tuned 0.25 absorbers buy precision (40.8%) at modest recall cost.
- **The USDA label space dilutes the curated one** (14.3% recall, 10.6% precision) —
  consistent with milestone 1's interpretation: adding 100+ USDA names competes for
  softmax mass and floods the resolver with off-catalog labels. Keep the curated
  label set.
- **The app's shipped 0.1 threshold is not tuned for a CLIP-type classifier**; the
  dev-tuned 0.25 buys +9.8pt precision for −9.1pt recall and the better F1. This
  number should *not* be ported into the app — it is specific to the substitute
  classifier — but it shows the pipeline's threshold is a first-class tunable when
  the real Vision model is benchmarked.

## Run cost (CPU, ViT-B-32, cached embeddings where noted)

| Run | Wall | Inference+resolution | Peak RSS |
|---|---|---|---|
| Dev six-crop, 300 imgs (fresh embed, 1,800 crops) | 15.4 s | 1.3 s | 1,547 MB |
| Dev whole-image, 300 imgs (fresh embed, 300 crops) | 30.8 s | 0.2 s | 3,892 MB |
| Validation six-crop (cache hit, 12,810 crops) | 12.5 s | 8.2 s | 1,548 MB |
| Validation whole-image (cache hit, 2,135 crops) | 5.7 s | 1.6 s | 1,548 MB |
| Validation curated+USDA (cache hit) | 85.2 s | 64.8 s | 1,549 MB |

`inference_resolution` covers real image work (embedding, softmax, resolution); the
USDA run's larger share is resolver volume over the bigger label space. Whole-image
dev embeds 300 full-resolution images (hence 3.9 GB RSS vs 1.5 GB for crops).

## Not checked / limitations

- **No Apple inference**: Vision classification, the true on-device model, and
  iOS-side integration were not exercised. There is no Xcode/macOS here; iOS changes
  would be checked by the repo's hosted CI and portable tests only. The genuine
  Apple-observation replay adapter (ingesting observation exports from the device)
  is still not implemented — the observation schema (`crops`/`detections` records)
  is the intended contract for it.
- **CLIP zero-shot is a classifier substitute.** Absolute numbers bound the
  *pipeline*, not the product; the app's Vision model may be materially better or
  worse.
- **FoodSeg103 annotations are segment-oriented.** "Unjustified detections"
  (precision's complement) include real foods the GT omits; per-image records
  (`*_per_image.jsonl.gz`) keep them inspectable rather than calling them errors.
- Unjustified examples are capped at 400 in-memory (60 in `scores.json`) by design;
  the full set is derivable from the per-image records.

## Reproduction (exact commands)

From the repo root (`experiments/ingredient-recognition/`), after
`acquire.py --verify` against the cached shards:

```bash
# development runs (300-image deterministic sample of train, seed 0)
python3 runner/observe.py --split train --sample 300 --crop-schedule six \
  --record-floor 0.001 --threshold 0.2 --out observations/dev_train_smp300_sixcrop.jsonl.gz
python3 runner/observe.py --split train --sample 300 --crop-schedule whole \
  --record-floor 0.001 --threshold 0.005 --out observations/dev_train_smp300_wholecrop.jsonl.gz

# threshold selection (development data only)
python3 scoring/threshold_sweep.py --observations observations/dev_train_smp300_sixcrop.jsonl.gz \
  --split train --thresholds 0.05,0.1,0.15,0.2,0.25,0.3,0.35,0.4,0.5 --out scoring/thresholds_sixcrop_dev.json
python3 scoring/threshold_sweep.py --observations observations/dev_train_smp300_wholecrop.jsonl.gz \
  --split train --thresholds 0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.2 --out scoring/thresholds_wholecrop_dev.json

# final validation runs at the frozen thresholds
python3 runner/observe.py --split validation --crop-schedule six --threshold 0.25 \
  --record-floor 0.001 --out observations/openmodel_validation_curated_absorberson_sixcrop.jsonl.gz
python3 runner/observe.py --split validation --crop-schedule whole --threshold 0.005 \
  --record-floor 0.001 --out observations/openmodel_validation_curated_absorberson_wholecrop.jsonl.gz

# scoring (writes *_scores.json, *_per_class.csv, *_per_image.jsonl.gz)
python3 scoring/score.py --split validation \
  --observations observations/openmodel_validation_curated_absorberson_sixcrop.jsonl.gz
python3 scoring/score.py --split validation \
  --observations observations/openmodel_validation_curated_absorberson_wholecrop.jsonl.gz

# tests (35 pass)
python3 -m pytest experiments/ingredient-recognition/tests -q
```

## License and data notes

Benchmark code and annotations tooling: Apache-2.0, matching FoodSeg103. Dataset
**images are not committed** (Recipe1M+ terms); they live in a local cache under
`/home/user/work/bench/dataset/` and are re-obtainable via `acquire.py` from the
Hugging Face `EduardoPacheco/FoodSeg103` mirror (documented fallback for the
official LARC host, which returned HTTP 502 when accessed). The manifest ships
image hashes only. No secrets in the repo.
