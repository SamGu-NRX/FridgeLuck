# multiplate-v1 — which dish is where?

Frozen benchmark slice answering one question: **can a detector say which
dish is where on a multi-food table, while whole-image classification — the
shape of FridgeLuck's on-device pipeline — cannot?**

Whole-image labels break exactly here: they can tell you the photo contains
pizza and cake, but not which slice is which. This benchmark measures that
gap with box-level ground truth, then measures it again with the
deterministic crops an app could realistically compute, so the comparison is
anchored to what the product could actually run.

## Provenance and licensing

- Open Images V4 (2018_04) **validation** split. Official annotation files
  (`annotations-human-bbox.csv`, `class-descriptions.csv`,
  `class hierarchy/bbox_classes_2018_04.zip`) from the openimages GCS bucket;
  images from the official unsigned S3 mirror (downloader bucket). All CC BY 2.0.
- The originally specified authoritative source (UECFOOD256) returned 404 on
  2026-10-10 (checked this session), so the documented fallback applies:
  official Open Images food-subtree classes with >= 60 eligible boxes.
- No image bytes are committed. `acquire.py` fetches and SHA-256-verifies
  them locally; `manifest.json` pins exact content hashes.

## Frozen manifest

`manifest.json` (868 KB) records, per image: `image_id`, `role`
(`multi` | `control`), `series_group`, normalized canonical GT boxes
(`label_name`, `xmin/ymin/xmax/ymax`, `is_group`), image sha256, and
license-record sha256. Image-level dHashes exclude near-duplicates.

- **668 images** = 508 multi-category + 160 single-category controls
- **29 classes**, **2,361 canonical GT boxes**
- Canonicalization: same-class boxes with IoU > 0.98 collapsed; a
  parent-class box with IoU >= 0.8 over a deeper-class box dropped.

Verify any checkout with:

```sh
python3 benchmarks/multiplate-v1/acquire.py --manifest benchmarks/multiplate-v1/manifest.json --out /home/user/work/bench/multiplate-images
python3 benchmarks/multiplate-v1/check_manifest.py --manifest benchmarks/multiplate-v1/manifest.json
```

## Runner arms (`run.py`) — all offline CPU, deterministic, pinned

| arm | model | sees |
|---|---|---|
| `detector` | DETR-ResNet-50, `facebook/detr-resnet-50@1d5f47bd3bdd2c4bbfa585418ffe6da5028b4c0b`, score >= 0.30, COCO-to-eval-class table (10 classes) | boxes |
| `proposals` | pinned CLIP ViT-B-32 (`laion2b_s34b_b79k`, same checkpoint as `experiments/ingredient-recognition`) zero-shot over 29 classes + 5 absorber prompts, on **automatic** proposals (Felzenszwalb segments + multi-scale grid, <= 120/image, per-class NMS 0.5 / cross-class 0.7) | pixels only |
| `oracle-crops` | same classifier on the **ground-truth boxes** | target boxes — **separately labelled upper bound, never compared head-to-head with automatic predictions as if fair** |

Library versions at run time are recorded in `results/run_config.json`
alongside every pin. `results/host_timing.json` holds host wall-clock timing
— not product latency; different host and no app-overhead accounting.

```sh
python3 benchmarks/multiplate-v1/run.py --manifest benchmarks/multiplate-v1/manifest.json --out benchmarks/multiplate-v1/results
python3 benchmarks/multiplate-v1/score.py --manifest benchmarks/multiplate-v1/manifest.json --results benchmarks/multiplate-v1/results
```

## Metrics (`score.py`, IoU 0.5, count-first optimal same-category assignment)

- Matching objective: maximize the **number of valid same-category
  matches** (IoU >= 0.5) first; total IoU only breaks ties. Maximizing
  summed IoU alone can undercount valid matches (see `matching.py` and
  the `test_count_first_beats_max_sum_iou` regression). If the exact
  solver (scipy) is unavailable, scoring refuses rather than emit a
  summary claiming optimal-mode matching it did not run.
- Precision / recall per arm, overall and by role
- **Missed small regions**: fraction of GT boxes < 4% of image area unmatched
- **Duplicates on matched GT**: second detections on an already-covered region
- **Category confusion**: cross-class overlaps (pred to GT, IoU >= 0.5)
- **Region-count error**: mean |n_pred - n_gt| per image
- Oracle arm: crop accuracy + coverage (classified GT boxes / all GT boxes)

The machine report (`results/summary.json`) records the matcher mode and
solver alongside the arms.

## Report integrity

Regenerate the machine report from the committed predictions and
byte-compare it with the committed file:

```sh
python3 benchmarks/multiplate-v1/score.py --manifest benchmarks/multiplate-v1/manifest.json \
    --results benchmarks/multiplate-v1/results --verify-report
```

Exits 0 on an exact match, 1 on drift (predictions, thresholds, or
matching code changed since the summary was written).

## Region result schema

`schema/region-result.schema.json` (JSON Schema 2020-12) describes one
JSONL row of `results/predictions_{arm}.jsonl`. Two tests validate every
committed row against it and check name compatibility with the
production scan contracts — read-only:
`tests/test_schema.py` reads `apps/ios/Capability/Core/Recognition/ScanContracts.swift`
and asserts the schema's optional `provenance` enum equals the
production `ScanProvenance` cases and that `ScanInputSource` keeps its
`benchmark` case. The Swift file is never written or compiled here; the
production types stay untouched.

## Scope limits (stated, not hidden)

- **GT boxes count food categories, not servings or plates.** No plate or
  serving ground truth exists in Open Images; none is claimed. Region-count
  error measures agreement with category boxes only.
- The detector arm covers only the 10 mapped COCO classes; recall over the
  other 19 eval classes is reported as 0 by construction.
- Zero-shot CLIP probabilities are not calibrated; thresholds (0.20 +
  absorber margin) are pinned, not tuned.
- GT boxes come from crowd-sourced annotation; a wrong box costs both arms
  symmetrically but is not verifiable from here.

## Tests

```sh
python3 -m pytest benchmarks/multiplate-v1 -c benchmarks/multiplate-v1/pytest.ini
```

covers exact IoU, greedy-vs-optimal matching counterexamples, duplicate
detections, manifest invariants, and scoring metric units.
