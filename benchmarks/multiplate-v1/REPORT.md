# multiplate-v1 run report — which dish is where?

**Run:** 2026-10-10, full frozen slice, all 668 manifest images, all three
arms, 0 decode or inference failures. `run_config.json` pins the DETR
revision (`1d5f47bd3bdd2c4bbfa585418ffe6da5028b4c0b`) and CLIP checkpoint
(`laion2b_s34b_b79k`); library versions are recorded alongside. Metrics:
IoU 0.5, **count-first** optimal same-category assignment — the matcher
maximizes the number of valid same-category matches first and uses total
IoU only as a tie-break (a maximum-total-IoU objective can undercount
valid matches; `summary.json` records the matcher mode). Rescoring the
committed predictions under the corrected matcher reproduced every
committed number exactly, so the findings below are unchanged
(`score.py --verify-report` byte-compares `summary.json` against
regeneration from the committed predictions). Raw rows:
`results/predictions_*.jsonl`; machine summary: `results/summary.json`.

## Headline result

**Nobody solves this task.** On 2,361 ground-truth food regions across 668
multi-food and single-food photos:

| arm | precision | recall | detections | missed small | dups | count err |
|---|---|---|---|---|---|---|
| detector (DETR-R50) | 0.126 | 0.121 | 2,279 | 0.965 | 86 | 3.16 |
| proposals (CLIP zero-shot on automatic regions) | 0.024 | 0.277 | 27,680 | 0.902 | 564 | 37.9 |
| oracle-crops (CLIP on GT boxes — upper bound, not comparable head-to-head) | — | — | — | — | — | crop acc **0.315** |

The structural point stands: whole-image classification — the shape of the
current on-device pipeline — cannot answer "which dish is where" at all.
But box-level models don't answer it usefully yet either.

## What the numbers say

1. **DETR localizes roughly 1 in 8 food regions correctly.** Recall 0.121
   at IoU 0.5. This is partly by construction: only 10 of the 29 eval
   classes have a COCO mapping, so recall over the other 19 is 0 by
   definition. Even within mapped classes, small regions are essentially
   invisible: 598 of 620 GT boxes under 4% of image area went unmatched
   (0.965). Region-count error (mean 3.16 boxes/image) rules out using
   detections as a portion proxy.

2. **The oracle arm is the real finding: 0.315 crop accuracy.** With
   *perfect* ground-truth boxes, zero-shot CLIP on the same checkpoint
   ingredient-recognition uses names the right category only 31.5% of the
   time (2,283 of 2,361 boxes classified, coverage 0.967). Chance is ~3.4%
   (1/29), so the classifier is well above chance but nowhere near usable
   on this label space. The confusion table explains why: the dominant
   errors are parent/grandparent pairs — Sandwich→Baked goods (66),
   Cake→Dessert (64), Cake→Baked goods (61), Dessert→Baked goods (34).
   The 29-class taxonomy (Open Images food subtree) mixes granularity
   levels; much of the error is taxonomy, not perception. Any future
   multi-region classifier needs a flat, level-matched label set.

3. **The proposals arm buys recall with 27,680 detections.** Felzenszwalb
   + grid regions recover more matches (0.277) but at 2.4% precision, 564
   duplicate detections on already-matched regions, and a region-count
   error of ~38/image — it over-fires everywhere. Not a viable arm as
   pinned; it mainly demonstrates that recall is reachable by spraying
   regions and precision is the hard part.

4. **Single-dish controls score *worse* than multi-dish images** for the
   detector (precision 0.034 vs 0.176). On a photo of one dish, DETR fires
   many detections that map to absent classes or fail IoU. Consistent with
   (2): the class taxonomy, not the "multiplate" aspect, is the dominant
   failure mode.

## Host timing (informational only)

Detached-process run; timing reflects only the final segment (~88-89
images per arm) on a shared, disk-pressured host, so it is a rough
indicator, not a measurement: detector mean 1.22 s/image, proposals mean
5.81 s (p90 5.3 s, max 192 s — one pathological image), oracle crops mean
0.23 s. Full details in `results/host_timing.json`. Not comparable to
product latency: different host, CPU-only, no app overhead.

## Run integrity note

The run was interrupted twice by sandbox teardowns and once by disk
exhaustion on the shared host; the runner's resume mode (append +
image/arm dedup) recovered each time. Duplicate rows from a transient
concurrent resume were deduplicated (72/71/72 rows per arm) — the
committed files contain exactly 668 unique rows per arm,
`failures.jsonl` is empty. `check_manifest.py` verified the manifest
before the run.

## What this changes for FridgeLuck

- Do not build "which dish is where" on DETR-style open detectors with
  COCO classes: the class coverage and small-region recall are both
  structurally inadequate.
- The binding constraint is the label space: even oracle boxes yield only
  31.5% zero-shot accuracy on a granularity-mixed 29-class taxonomy.
  Fixing the taxonomy (flat, level-matched, closed-set) is worth more
  than any detector swap.
- Keep whole-image classification for what it can do and treat per-region
  identity as a separate, unsolved problem with a clear upper-bound
  measurement now on file.

## What was not checked

- No macOS/Xcode involvement: this benchmark is Python-only; portable
  tests (`pytest`, 30/30) and scoring ran on Linux.
- GT boxes are crowd-sourced Open Images annotations; spot-checking their
  quality from here was not possible (noted in README scope limits).
- The proposals arm's absorber prompts were pinned before seeing these
  numbers; no threshold tuning was done post hoc.
