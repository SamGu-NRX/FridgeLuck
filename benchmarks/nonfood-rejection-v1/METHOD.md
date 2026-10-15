# nonfood-rejection-v1

A frozen, CC-BY-2.0-licensed 1,200-image benchmark measuring a specific
failure of FridgeLuck's photo scan: **declaring a fridge or cupboard empty
when it is not** — the one wrong "add nothing" outcome that erodes trust in
the inventory, because the app then silently omits containers the user knows
are full.

## What it measures

The scan pipeline proposes inventory items from a photo. Two things can go
wrong after recognition: the pipeline *adds something that isn't there*
(false addition), or it *sees an occupied space and proposes nothing*
(missed food). Both fail quietly; neither shows up in accuracy numbers on
food-only datasets. This benchmark measures both, plus the grey zone in
between, with three strata:

| Stratum | n | Role | Ground truth |
|---|---|---|---|
| `empty_visible` | 300 | negative | No food present, interior visible — a correct pipeline can be certain |
| `opaque_unknown` | 300 | negative | Food possibly present behind a closed box, sealed jar, or opaque container — certainty is never warranted |
| `food_control` | 600 | control | Visible food present — an occupied space the pipeline should register |

Images come from Open Images (validation subset), image-level labeled, with
photographer and series metadata. Every negative is paired with a
`food_control` from the same context class where the pool allows
(`pair_id`); pair quality is recorded honestly — only 19 of 600 pairs share
the exact context (`exact_context`), 296 share a context class
(`any_context`), and 285 have no matched context (`none`). The manifest
reports this distribution rather than implying matched pairs.

## Design decisions, and why

**Opaque containers are never "certainly empty."** The scorer's verdict
policy (`policy.py`) can only emit `empty` for `empty_visible` images with a
food-evidence score at or below a learned low threshold. An `opaque_unknown`
image is `unknown` at any score below the admit bar — the model cannot see
behind the box, so "empty" would be a claim nothing supports. This is the
central epistemic rule of the benchmark.

**Produced food is never folded into "empty."** If the pipeline produced any
food label on an image below the admit bar, the verdict is `unknown`, not
`empty`, and the scorer counts the group as a false addition. A verdict of
"empty" is only available when nothing was produced and the score says
nothing is visible.

**Dev/test splits are leak-safe.** 50/50 within each stratum. Photographer
groups (`group_id`) and near-duplicate series (`series_id`) are each bound
to a single split by the manifest checker — the same kitchen or the same
shoot cannot appear in both splits. Thresholds are selected on dev only;
test is reported once.

**Metrics are group-level.** False additions count *groups* (a photographer
group or near-duplicate series counts once if any member triggers), which
matches how a user experiences the failure: one wrong photo convinces them
the scan is unreliable, not one wrong frame in a burst.

**Reports pin their inputs.** `run.py` writes the manifest sha256 into every
raw report; `score.py --verify` recomputes verdicts and metrics from the raw
report plus manifest and refuses a scored file whose contents no longer
reproduce. The suite includes a planted-mutation test that must be caught.

## Files

- `taxonomy.py` — curated Open Images label set for kitchen contexts, occluders, and food
- `sample.py`, `select_plan.py` — deterministic 1,680-image acquisition plan (420/480/780 across strata, drawn down to the frozen 1,200)
- `acquire.py` — fetcher with logged hashes; all 1,680 fetched, 0 hash mismatches
- `build_manifest.py` — binds cached bytes to logged hashes, builds groups/pairs/splits, writes `manifest.json` + `build_stats.json`
- `check_manifest.py` — independent structural, count, licensing, pair, group-binding, and cached-hash validation (`manifest OK`)
- `run.py` — arm adapter runner; reports pin the manifest hash
- `arms/food101_mobilenet.py` — the pinned model arm (below)
- `policy.py` — the three-verdict rule
- `score.py` — dev threshold selection, group metrics, `--verify` recomputation
- `tests/` — 40 tests: policy semantics (measured + oracle), truth-mutation blindness (predictions invariant under truth relabeling), checker defect detection (each check has a planted-defect test), and scorer tests

## The two verdict policies

`policy.py` ships two named policies (see also `results/summary.md`):

- **`measured`** (default, headline) — stratum-blind: verdicts are a
  function of arm output and dev-selected thresholds only.
  `tests/test_policy_blindness.py` mutation-tests this end-to-end through
  the scorer: permuting the manifest's ground truth with arm outputs held
  byte-identical changes no measured prediction, while the metrics do
  move (and the oracle's predictions move too, pinning its privilege).
- **`oracle`** (privileged upper bound) — additionally reads the frozen
  stratum so it can protect opaque-unknown images from certain-empty.
  That is target information the production pipeline does not have at
  prediction time; oracle numbers are reported separately and never mixed
  with measured ones. The production mapper is unchanged by this
  benchmark either way.

Threshold selection uses dev ground truth only (selection, not
prediction) and is identical under both policies.

## The measured arms

Two real arms plus two non-model baselines, all deterministic on CPU
with fixed eval mode. They map every photo to a food-evidence score in
[0, 1] and optionally produced labels.

- **`food101-mobilenet`** — MobileNetV2 fine-tuned on Food-101, pinned to
  `rajkr/mobilenet-v2-food101@0dea82e70d00f786f2029d8487d845a5cfc2d64a`.
  Proxy for the production scan resolver: `food_score` = max softmax
  probability over the 101 food classes; `produced_food` = always true (a
  food-only classifier's argmax always resolves to a food class — the
  same semantics as a base resolver that accepts any predicted food
  label); `food_labels` = the predicted class.
- **`clip-zeroshot`** — OpenCLIP ViT-B-32-quickgelu (laion2b_s34b_b79k),
  checkpoint pinned by sha256 in the arm file. Two-prompt food/empty
  probe with temperature-1 cosine softmax (the native logit-scale softmax
  saturates; documented in the arm). `produced_food` = score >= 0.5.
- **`constant-0.5`**, **`reject-everything`** — non-model baselines
  bounding the policy: a signal with no information, and an arm that
  never adds anything.

Thresholds are learned from dev: `tau_high` is the smallest grid point
(0.01–0.99) where every dev control group is admitted while the dev
false-addition rate stays within cap; `tau_low` is the worst max-score among
clean dev visible-empty groups.

## Results

`results/summary.md` records scored run 2026-10-10 (r2) over four arms
under both policies (eight scored outputs, all re-verified with
`score.py --verify`).

## Known limitations

- **No Swift replay.** The production `LearningService`/scan pipeline could not run here (no Swift toolchain); all numbers measure the pinned Python arm, not the shipped app.
- **Proxy classifier.** Food-101 is dish-centric (prime rib, waffles); raw-ingredient coverage is thinner than production recognition, so absolute scores are not directly comparable to the pipeline.
- **Pair matching is imperfect by construction** — recorded, not hidden (see build stats).
- **Image-level labels.** Small or occluded food in a control image can be under-labeled; controls were drawn from explicit food labels, which mitigates but does not eliminate this.
- iOS-side integration of the benchmark runner is out of scope; CI exercises the Python suite only.

## Reproduce

```sh
cd benchmarks/nonfood-rejection-v1
python3 -m pytest tests/ -q
python3 check_manifest.py --cache-dir /home/user/work/bench/nonfood-cache
python3 run.py --arm arms/food101_mobilenet.py --cache-dir /home/user/work/bench/nonfood-cache
python3 score.py reports/raw/food101-mobilenet.json --verify
```
