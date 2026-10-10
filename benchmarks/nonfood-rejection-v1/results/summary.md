# nonfood-rejection-v1 — scored run 2026-10-10 (r1)

Frozen manifest: 1,200 Open Images (CC-BY-2.0) — 300 `empty_visible`,
300 `opaque_unknown`, 600 `food_control`; dev/test 50/50, photographer-
and series-leak-safe. Scoring: dev-selected thresholds, group-level
false-addition metrics, scored outputs reproduce under `score.py --verify`
(all four verified this run).

## Headline

**No measured arm can reject nonfood at the 1% false-addition cap while
keeping any control recall.** The dish-centric classifier unconditionally
hallucinates dishes on empty kitchens; zero-shot CLIP barely separates
food from empty-shelf photos; the only arms that hit the cap do so by
never admitting anything and recall nothing.

## Results (test split; dev in parentheses)

| Arm | False-add rate | Certain-empty (of all neg. groups) | Control recall | Threshold note |
|---|---|---|---|---|
| `food101-mobilenet` (pinned `rajkr/mobilenet-v2-food101@0dea82e…`) | **1.000** (1.000) | 0.000 (0.000) | 1.000 (1.000) | no grid point meets the cap; minimized dev false-add = 1.000 |
| `clip-zeroshot` (OpenCLIP ViT-B-32-quickgelu, laion2b_s34b_b79k, sha256 `ac4f8c4b…`) | **0.901** (0.880) | 0.087 (0.101) | 1.000 (0.987) | `tau_high=0.5` chosen at the cap-violating minimum (0.880 dev) |
| `constant-0.5` baseline | 0.000 | 0.458 | 0.000 | recall-free: never admits |
| `reject-everything` baseline | 0.000 | 0.458 | 0.000 | recall-free: never admits |

Certain-empty rates are against all negative groups; the baselines declare
**every** visibly-empty group certainly empty (127 dev / 116 test groups)
and every opaque-unknown group unknown — the policy behaves as specified
there. Their failure is control recall 0.

## What the numbers say

- **`food101-mobilenet` cannot ever say "empty."** A Food-101 classifier
  produces a dish label on every photo — an empty cupboard comes back
  "prime rib" at 0.5–0.9 confidence (negative-score histogram puts mass in
  0.3–0.6). Under the verdict policy every negative group is a false
  addition (258/258 dev, 253/253 test) and no photo is ever certified
  empty. The benchmark's premise — food-only accuracy hides nonfood
  failure — is confirmed at the extreme.
- **Zero-shot CLIP is not a shortcut.** With a two-prompt food/empty probe
  and temperature-1 cosine calibration, 261 of 300 dev negative images
  land in the 0.5–0.6 bin: the probe separates almost nothing. The
  threshold machinery still does its job — it refuses to claim the 1% cap
  and reports the honest 88–90% false-add rate.
- **The policy never lies about opaque containers.** Across all four arms,
  `opaque_unknown` images are never declared certainly empty, and produced
  food is never silently folded into an "empty" verdict.

## Implication for the scan pipeline

The production resolver should not ask "which dish is this?" of a shelf
photo and trust the argmax. Nonfood rejection needs evidence that is
explicitly absent-vs-present (detector-grounded or multi-probe with
calibration), and the confirm-before-add flow should treat
low-confidence-empty as unknown — exactly the verdict class this
benchmark scores.

## Reproduce

```sh
python3 -m pytest tests/ -q            # 30 tests
python3 check_manifest.py --cache-dir <cache>
python3 run.py --arm arms/food101_mobilenet.py --cache-dir <cache>
python3 run.py --arm arms/clip_zeroshot.py --cache-dir <cache>
python3 run.py --arm arms/constant_baseline.py --cache-dir <cache>
python3 run.py --arm arms/reject_everything.py --cache-dir <cache>
python3 score.py --report reports/raw/<arm>.json --verify results/scored-<arm>.json
```

Raw and scored reports are committed under `reports/` and `results/`;
each pins the manifest sha256 and re-verifies.
