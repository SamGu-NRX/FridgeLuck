# Hand calculation: R06 vs R38 flips under plausible uncertainty (P1, joint arm)

Production formulas, step by step, at base commit `8c9c88f`
(`RecipeRepository.sharedRankingScore` and `HealthScoringService.computeScore`).
P1 profile: goal `general`, dailyCalories 2000 (meal target 2000/3 = 666.667 kcal),
macro targets 25% protein / 45% carbs / 30% fat. Both recipes have
matchedRequired == totalRequired, matchedOptional 2, missingRequiredCount 0,
personalScore 0.0; R06 time 35 min, R38 time 20 min; no `high_protein` tag on either.
All inputs copied verbatim from the frozen matrix and the committed draw-0 raw
sample (`outputs/20261010-swift/raw/sample__plausible_both__P1.json`).

## Control (unchanged inputs)

### R06 — 113.5 points, rank 33

- Required coverage: 3/3 = 1.0 × 72 = **72.0**
- Optional: 2 × 2.5 = **5.0**
- Health (rating 5 → 5 × 6.5 = **32.5**). Rating check:
  calories 471.333/666.667 = 0.707 → 30-pt bucket;
  split = (29.4583·4) : (53.025·4) : (15.7111·9) = 117.833 : 212.100 : 141.400 →
  shares 0.2500/0.4500/0.3000 → avg diff 0 → alignment max(5, 40·(1−0)) = **40**;
  fiber 3 < 5 → 0; sugar 8 ≤ 10 → +10; sodium 400 ≤ 600 → +10.
  Points = 30 + 40 + 20 = 90 → ceil(90/20) = ceil(4.5) = **5** ✓
- Personal: 0 × 8.0 = **0**
- Time: 35 > 30 → **+0**
- Goal `general`: **+0**
- Protein: 29.4583 ≥ 24 → **+4**
- Missing required: 0 → **−0**

Total: 72 + 5 + 32.5 + 0 + 0 + 0 + 4 = **113.5** ✓

### R38 — 112.5 points, rank 34 (directly below R06)

- Required coverage: 4/4 = 1.0 × 72 = **72.0**
- Optional: 2 × 2.5 = **5.0**
- Health (rating 5 → **32.5**). Rating check:
  calories 600/666.667 = 0.900 → 30-pt bucket;
  split = 95.6 : 300 : 180 → 95.6/575.6 = 0.16609, 300/575.6 = 0.52120, 180/575.6 = 0.31272;
  diffs vs (0.25, 0.45, 0.30) = 0.08391, 0.07120, 0.01272 → avg 0.05594 →
  40·(1 − 0.05594·3) = 40·0.83218 = **33.287**;
  sugar +10, sodium +10, fiber 0.
  Points = 30 + 33.287 + 20 = 83.287 → ceil(4.164) = **5** ✓
- Personal: **0**
- Time: 20 ≤ 30 → **+3.0**
- Goal: **+0**
- Protein: 23.9 < 24 and no tag → **+0** ← below the threshold
- Missing: **−0**

Total: 72 + 5 + 32.5 + 0 + 3 + 0 + 0 = **112.5** ✓

## Perturbed (plausible_both, draw 0 — committed raw sample)

Joint arm: per-nutrient factors (±16.5% calories, ±20.2% protein, ±20.7% carbs,
±22.6% fat, ±20% fiber/sugar/sodium) times a ±10.6% portion scale, all inside the
locked plausible envelope in `inputs/perturbation_bounds.json`.

### R38 — 116.5 points (was 112.5)

Same ranking inputs; only macros move:
calories 611.6207, protein 27.4028 g, carbs 70.1676 g, fat 25.2766 g,
fiber 3.7461 g, sugar 7.6258 g, sodium 393.6505 mg.

- Coverage **72.0**, optional **5.0**, personal **0**
- Health (rating 5 → **32.5**). Rating check:
  calories 611.6207/666.667 = 0.9174 → still the 30-pt bucket;
  split = 109.6113 : 280.6705 : 227.4898 → total 617.7716 →
  shares 0.17742/0.45432/0.36827;
  diffs 0.07258/0.00432/0.06827 → avg 0.04839 →
  40·(1 − 0.04839·3) = 40·0.85484 = **34.193**;
  sugar 7.626 ≤ 10 → +10; sodium 393.65 ≤ 600 → +10; fiber 3.746 < 5 → 0.
  Points = 30 + 34.193 + 20 = 84.193 → ceil(4.2097) = **5** ✓ (unchanged)
- Time 20 → **+3.0**
- Protein: 27.4028 ≥ 24 → **+4.0** ← **the 24 g boundary flips: +4 points**
- Missing: **−0**

Total: 72 + 5 + 32.5 + 3 + 4 = **116.5** ✓ (delta vs control = **+4.0**, exactly the
protein bonus — nothing else crossed a boundary)

### R06 — 113.5 points (unchanged)

Protein 28.9939 g: still ≥ 24, so the bonus was already on. Rating still 5
(calories 509.9036/666.667 = 0.7649 → 30-pt bucket; split shares 0.2461/0.4988/0.2552,
avg diff 0.0201 → 40·0.9397 = 37.588; points = 30 + 37.588 + 10 + 10 = 87.588 →
ceil(4.379) = 5). Score stays **113.5** ✓

## The flip

- Control order: R06 (113.5) above R38 (112.5), gap 1.0.
- Perturbed order: R38 (116.5) above R06 (113.5), gap 3.0.
- Driver: a single threshold discontinuity — R38's protein crossing 24 g grants the
  production `+4` high-protein ranking bonus (its ranking reasons also gain
  "High protein"). A plausible ±20% protein/±10.6% portion error moves an input
  across a 4-point step while the score margin was only 1.0 point, so the pair's
  order is not determined by the measured data.
- Machine check: `python3 score.py --verify-report` re-derives both control and
  perturbed scores with `ref_impl.py` (bit-exact), asserts the flip and the +4.0
  delta, confirms the perturbation sits inside the locked compound envelope, and
  confirms the same pair swaps in the committed raw-sample draws.
