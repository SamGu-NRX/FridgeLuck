# Health-ranking sensitivity to nutrient and portion uncertainty (production replay, base 8c9c88f)

Question: which health rankings are unstable under plausible label uncertainty?
Method: the production scoring code, unchanged and vendored byte-identically, replayed
over a frozen recipe/profile matrix with locked perturbation bounds applied ONLY to
nutrition/portion inputs.

**Load-bearing assumption.** This study assumes that the uncertainty ranges in
`inputs/uncertainty_assumptions.json` (Nutrition5k and restaurant-calorie estimation
error; portion-scale bridge to per-serving labels) are a fair description of the
error between what a photo/receipt pipeline would produce and a true per-serving
label. If real upstream estimates are materially better or worse, the headline
instability numbers move with them — check that file's citations before acting on
the numbers below. Adjacent explanations not tested here: errors correlated across
recipes (e.g. a systematically lenient estimator) and errors in the ranking inputs
themselves (matched ingredients, times), which this study holds fixed.

## How to reproduce

```bash
cd apps/ios/Tools/health-ranking-sensitivity
python3 check_inputs.py                                   # schema + bounds lock
python3 -m pytest tests -q                                # python gates
swift test --package-path SwiftReplay                     # parity + engine tests
SwiftReplay/.build/out/Products/Debug-linux-x86_64/ExperimentRunner \
  --inputs inputs --outputs outputs/20261010-swift        # deterministic rerun (seed 20261010)
python3 score.py --verify-report                          # this report's checks
```

Full-run aggregates in `outputs/20261010-swift/run_meta.json` were reproduced
identically across independent runs (only wall-clock timings differ). Window
aggregates are recomputed from the committed raw samples by `score.py` and compared
exactly against the engine's summaries.

<!-- BEGIN GENERATED TABLES -->
Profiles: P1 | P2 | P3 | P4 | P5 · recipes: 62 · seed: 20261010 · base: 8c9c88f

## Full-run aggregates (engine-recorded, verified where windowed)

Plausible arms (within the locked uncertainty bounds):

| arm | profile | rank-moving draws | rank moves | rating flips | reasoning changes | interval overlaps |
|---|---|---|---|---|---|---|
| plausible_macros | P1 | 400/400 | 21594 | 6272 | 11901 | 1556/1891 |
| plausible_macros | P2 | 400/400 | 22486 | 6665 | 11824 | 1571/1891 |
| plausible_macros | P3 | 400/400 | 21419 | 4288 | 11838 | 1220/1891 |
| plausible_macros | P4 | 400/400 | 21834 | 6514 | 11882 | 1649/1891 |
| plausible_macros | P5 | 400/400 | 14628 | 595 | 11965 | 1350/1891 |
| plausible_portion | P1 | 400/400 | 19249 | 4426 | 4843 | 1251/1891 |
| plausible_portion | P2 | 400/400 | 19626 | 2984 | 4817 | 1128/1891 |
| plausible_portion | P3 | 400/400 | 19472 | 2420 | 4786 | 611/1891 |
| plausible_portion | P4 | 400/400 | 18979 | 2755 | 4725 | 1235/1891 |
| plausible_portion | P5 | 394/400 | 12787 | 514 | 4770 | 1233/1891 |
| plausible_both | P1 | 400/400 | 21986 | 7083 | 12065 | 1694/1891 |
| plausible_both | P2 | 400/400 | 22881 | 7585 | 12143 | 1782/1891 |
| plausible_both | P3 | 400/400 | 21643 | 5265 | 12228 | 1622/1891 |
| plausible_both | P4 | 400/400 | 22257 | 6894 | 12208 | 1730/1891 |
| plausible_both | P5 | 400/400 | 15754 | 639 | 12067 | 1493/1891 |

Stress arms (adversarial, OUTSIDE plausible uncertainty — separately labeled, never mixed):

| arm | profile | rank-moving draws | rank moves | rating flips | reasoning changes | interval overlaps |
|---|---|---|---|---|---|---|
| stress_macros | P1 | 200/200 | 11717 | 6363 | 7496 | 1800/1891 |
| stress_macros | P2 | 200/200 | 11676 | 6748 | 7506 | 1813/1891 |
| stress_macros | P3 | 200/200 | 11626 | 5495 | 7459 | 1781/1891 |
| stress_macros | P4 | 200/200 | 11824 | 5911 | 7457 | 1810/1891 |
| stress_macros | P5 | 200/200 | 10973 | 984 | 7495 | 1710/1891 |
| stress_portion | P1 | 200/200 | 11671 | 6075 | 5236 | 1765/1891 |
| stress_portion | P2 | 200/200 | 11680 | 6523 | 5184 | 1826/1891 |
| stress_portion | P3 | 200/200 | 11587 | 4473 | 5225 | 1727/1891 |
| stress_portion | P4 | 200/200 | 11798 | 4408 | 5170 | 1762/1891 |
| stress_portion | P5 | 200/200 | 10838 | 571 | 5221 | 1566/1891 |
| stress_both | P1 | 200/200 | 11658 | 7984 | 8787 | 1828/1891 |
| stress_both | P2 | 200/200 | 11697 | 7886 | 8849 | 1830/1891 |
| stress_both | P3 | 200/200 | 11709 | 6549 | 8730 | 1829/1891 |
| stress_both | P4 | 200/200 | 11631 | 7086 | 8814 | 1829/1891 |
| stress_both | P5 | 200/200 | 11511 | 1801 | 8866 | 1776/1891 |

## Headline instability numbers (plausible arms)

- Rank moved in 394-400 of 400 draws for every plausible arm-profile cell — at least one recipe changes position in essentially every plausible draw.
- Joint plausible arm: 1493-1782 of 1891 recipe pairs have overlapping plausible score intervals (rank order between them is not determined by the data).
- Window recomputation from committed raw samples: PASS (exact equality with engine summaries)
- Control bit-exactness: 310 records re-derived from the frozen matrix reproduce the committed control output exactly.

## Hand-verified rank swap (production formulas)

- Pair: R06 (control rank 33, score 113.5) vs R38 (control rank 34, score 112.5), profile P1.
- Under the committed plausible perturbation of draw 0, R38 gains +4.0 points by crossing the 24 g protein ranking threshold (23.9 g -> 27.40 g) and its order flips. Hand arithmetic in hand_swap.md; machine-verified by score.py.
- The same pair flips in raw-sample draws: 0, 2, 5, 8, 9.

## Label-service defect reproducer (documented, NOT fixed)

Ranking grants the high-protein bonus on absolute grams (protein >= 24 g or the `high_protein` tag) while reasoning strings use calorie-share bands (protein kcal share > 30%/25%). The two disagree on the same input:

| profile | bonus w/o reasoning note | reasoning note w/o bonus |
|---|---|---|
| P1 | 45/62 | 1/62 |
| P2 | 45/62 | 1/62 |
| P3 | 45/62 | 1/62 |
| P4 | 45/62 | 1/62 |
| P5 | 45/62 | 1/62 |

Failing-input example R07 (P1 control): ranking_reasons includes 'High protein', reasoning is 'Hearty portion' with no protein note. Reproduce: re-derive the P1 control and inspect R07, or run `python3 score.py --verify-report` which asserts this example.

## Boundary flips with point impact (plausible_both, full run)

| indicator | profile | flips | points per flip |
|---|---|---|---|
| reasoning_protein_band none->good | P1 | 5532 | no ranking points |
| calorie_bucket 30->20 | P1 | 3134 | -10 |
| reasoning_protein_band good->high | P1 | 2532 | no ranking points |
| calorie_bucket 30->15 | P1 | 1001 | -15 |
| sugar_bonus on->off | P1 | 998 | -10 |
| ranking_high_protein on->off | P1 | 997 | -4 |
| reasoning_cal_band hearty->mid | P1 | 984 | no ranking points |
| reasoning_protein_band high->good | P1 | 890 | no ranking points |
| reasoning_cal_band mid->hearty | P1 | 792 | no ranking points |
| calorie_bucket 15->30 | P1 | 788 | +15 |
| calorie_bucket 20->5 | P1 | 692 | -15 |
| calorie_bucket 20->30 | P1 | 670 | +10 |
| calorie_bucket 15->5 | P1 | 640 | -10 |
| reasoning_cal_band light->mid | P1 | 622 | no ranking points |
| ranking_high_protein off->on | P1 | 555 | +4 |
| reasoning_protein_band good->none | P1 | 475 | no ranking points |
| reasoning_protein_band none->high | P1 | 474 | no ranking points |
| calorie_bucket 5->15 | P1 | 393 | +10 |
| fiber_bonus on->off | P1 | 369 | -10 |
| sodium_bonus on->off | P1 | 358 | -10 |
| reasoning_cal_band mid->light | P1 | 267 | no ranking points |
| sugar_bonus off->on | P1 | 255 | +10 |
| sodium_bonus off->on | P1 | 202 | +10 |
| fiber_bonus off->on | P1 | 190 | +10 |
| calorie_bucket 5->20 | P1 | 176 | +15 |
| reasoning_protein_band high->none | P1 | 52 | no ranking points |
| calorie_bucket 5->30 | P1 | 7 | +25 |
| reasoning_protein_band none->good | P2 | 5547 | no ranking points |
| goal_band on->off | P2 | 3159 | goal-dependent |
| reasoning_protein_band good->high | P2 | 2585 | no ranking points |
| calorie_bucket 30->15 | P2 | 1537 | -15 |
| calorie_bucket 15->30 | P2 | 1206 | +15 |
| reasoning_cal_band hearty->mid | P2 | 1022 | no ranking points |
| calorie_bucket 15->5 | P2 | 1003 | -10 |
| ranking_high_protein on->off | P2 | 990 | -4 |
| sugar_bonus on->off | P2 | 981 | -10 |
| reasoning_protein_band high->good | P2 | 881 | no ranking points |
| goal_band off->on | P2 | 838 | goal-dependent |
| reasoning_cal_band mid->hearty | P2 | 775 | no ranking points |
| calorie_bucket 5->15 | P2 | 689 | +10 |
| reasoning_cal_band light->mid | P2 | 593 | no ranking points |
| ranking_high_protein off->on | P2 | 573 | +4 |
| reasoning_protein_band good->none | P2 | 475 | no ranking points |
| reasoning_protein_band none->high | P2 | 470 | no ranking points |
| calorie_bucket 20->30 | P2 | 428 | +10 |
| sodium_bonus on->off | P2 | 381 | -10 |
| fiber_bonus on->off | P2 | 373 | -10 |
| reasoning_cal_band mid->light | P2 | 260 | no ranking points |
| sugar_bonus off->on | P2 | 230 | +10 |
| calorie_bucket 30->20 | P2 | 222 | -10 |
| sodium_bonus off->on | P2 | 194 | +10 |
| fiber_bonus off->on | P2 | 182 | +10 |
| reasoning_protein_band high->none | P2 | 46 | no ranking points |
| calorie_bucket 20->5 | P2 | 41 | -15 |
| calorie_bucket 5->30 | P2 | 14 | +25 |
| reasoning_protein_band none->good | P3 | 5566 | no ranking points |
| reasoning_protein_band good->high | P3 | 2526 | no ranking points |
| calorie_bucket 20->30 | P3 | 1621 | +10 |
| calorie_bucket 30->20 | P3 | 1184 | -10 |
| calorie_bucket 20->5 | P3 | 1155 | -15 |
| reasoning_cal_band hearty->mid | P3 | 1058 | no ranking points |
| ranking_high_protein on->off | P3 | 994 | -4 |
| sugar_bonus on->off | P3 | 987 | -10 |
| reasoning_protein_band high->good | P3 | 915 | no ranking points |
| reasoning_cal_band mid->hearty | P3 | 765 | no ranking points |
| reasoning_cal_band light->mid | P3 | 591 | no ranking points |
| ranking_high_protein off->on | P3 | 585 | +4 |
| calorie_bucket 15->30 | P3 | 570 | +15 |
| calorie_bucket 30->15 | P3 | 557 | -15 |
| reasoning_protein_band good->none | P3 | 518 | no ranking points |
| reasoning_protein_band none->high | P3 | 482 | no ranking points |
| fiber_bonus on->off | P3 | 392 | -10 |
| sodium_bonus on->off | P3 | 384 | -10 |
| reasoning_cal_band mid->light | P3 | 281 | no ranking points |
| sugar_bonus off->on | P3 | 234 | +10 |
| calorie_bucket 5->20 | P3 | 197 | +15 |
| sodium_bonus off->on | P3 | 192 | +10 |
| fiber_bonus off->on | P3 | 172 | +10 |
| reasoning_protein_band high->none | P3 | 43 | no ranking points |
| calorie_bucket 15->5 | P3 | 10 | -10 |
| reasoning_protein_band none->good | P4 | 5618 | no ranking points |
| goal_band on->off | P4 | 4021 | goal-dependent |
| calorie_bucket 20->30 | P4 | 3392 | +10 |
| reasoning_protein_band good->high | P4 | 2537 | no ranking points |
| calorie_bucket 30->20 | P4 | 1729 | -10 |
| ranking_high_protein on->off | P4 | 1052 | -4 |
| reasoning_cal_band hearty->mid | P4 | 1052 | no ranking points |
| sugar_bonus on->off | P4 | 1001 | -10 |
| reasoning_protein_band high->good | P4 | 900 | no ranking points |
| reasoning_cal_band mid->hearty | P4 | 780 | no ranking points |
| calorie_bucket 30->15 | P4 | 708 | -15 |
| ranking_high_protein off->on | P4 | 597 | +4 |
| reasoning_cal_band light->mid | P4 | 594 | no ranking points |
| goal_band off->on | P4 | 551 | goal-dependent |
| reasoning_protein_band good->none | P4 | 521 | no ranking points |
| calorie_bucket 5->20 | P4 | 504 | +15 |
| reasoning_protein_band none->high | P4 | 489 | no ranking points |
| calorie_bucket 15->30 | P4 | 391 | +15 |
| calorie_bucket 15->5 | P4 | 388 | -10 |
| fiber_bonus on->off | P4 | 376 | -10 |
| sodium_bonus on->off | P4 | 359 | -10 |
| reasoning_cal_band mid->light | P4 | 274 | no ranking points |
| sugar_bonus off->on | P4 | 242 | +10 |
| fiber_bonus off->on | P4 | 186 | +10 |
| calorie_bucket 20->5 | P4 | 173 | -15 |
| sodium_bonus off->on | P4 | 170 | +10 |
| reasoning_protein_band high->none | P4 | 37 | no ranking points |
| reasoning_protein_band none->good | P5 | 5536 | no ranking points |
| reasoning_protein_band good->high | P5 | 2529 | no ranking points |
| sugar_bonus on->off | P5 | 1015 | -10 |
| reasoning_cal_band hearty->mid | P5 | 1004 | no ranking points |
| ranking_high_protein on->off | P5 | 934 | -4 |
| reasoning_protein_band high->good | P5 | 899 | no ranking points |
| reasoning_cal_band mid->hearty | P5 | 799 | no ranking points |
| reasoning_cal_band light->mid | P5 | 586 | no ranking points |
| ranking_high_protein off->on | P5 | 584 | +4 |
| reasoning_protein_band good->none | P5 | 493 | no ranking points |
| reasoning_protein_band none->high | P5 | 455 | no ranking points |
| sodium_bonus on->off | P5 | 381 | -10 |
| fiber_bonus on->off | P5 | 380 | -10 |
| reasoning_cal_band mid->light | P5 | 277 | no ranking points |
| sugar_bonus off->on | P5 | 229 | +10 |
| sodium_bonus off->on | P5 | 198 | +10 |
| fiber_bonus off->on | P5 | 173 | +10 |
| reasoning_protein_band high->none | P5 | 55 | no ranking points |


<!-- END GENERATED TABLES -->

## What the numbers mean

- **Rank-moving draws** — draws in which at least one recipe changed position in the
  per-profile ranking (62 recipes sorted by `sharedRankingScore`).
- **Rating flips / reasoning changes** — star ratings (1–5, from
  `HealthScoringService.computeScore`) and the user-facing reasoning string
  changing relative to the unchanged control on the same draw.
- **Interval overlaps** — recipe pairs whose Monte-Carlo plausible score intervals
  (min/max over the arm's draws) intersect: for these pairs the data does not
  determine an order. With 62 recipes there are 1,891 pairs.
- **Boundary flips** — which replay-side threshold indicator flipped
  (`calorie_bucket`, `fiber/sugar/sodium_bonus`, `ranking_high_protein`,
  `goal_band`, reasoning bands), with the production point delta each carries.

## Findings

1. **Rank order is genuinely unstable under plausible uncertainty on this matrix.**
   In every plausible arm-profile cell, ranks moved in at least 394 of 400 draws
   (macros and joint arms: 400/400). Instability is not driven by deep-pair
   noise alone: the joint arm's score-interval overlaps cover 1,493–1,782 of the
   1,891 recipe pairs — for ~79–94% of pairs, plausible error can reorder them.
2. **Discrete production thresholds are the mechanism.** Full-run boundary-flip
   counts (joint arm) and their point values are in the generated tables. The
   hand-verified swap below shows the smallest concrete case: a 1.0-point control
   margin reversed by a single 24 g-protein bonus crossing.
3. **Ratings are steadier than ranks** — rating flips are rarer than rank moves
   (595–7,585 flips per 24,800 recipe-draws in the plausible macros arm vs
   14,628–22,886 rank moves), because rating changes need a 20-point band crossing
   while ranks need any score reorder.
4. **Reasoning strings churn with macro-split bands** (11,824–12,228 changes per
   24,800 recipe-draws in the macros arm): the calorie-share protein/calorie bands
   are sensitive to compositional error even when the star rating does not move.
5. **Stress arms behave like amplified plausibility, not a different regime** —
   rank-moving 200/200 draws, overlaps 1,710–1,830/1,891. They are reported
   separately and are NOT plausible-case evidence.

## Hand-verified rank swap

`hand_swap.md` carries the full hand calculation through the production formulas;
`hand_swap.json` carries the exact inputs (copied from the committed raw draw) and
expected values. Summary: on profile P1, R38 (112.5, rank 34) sits 1.0 point below
R06 (113.5, rank 33). Under the committed plausible draw-0 perturbation R38's
protein crosses 24 g (23.9 g → 27.40 g, inside the ±20.2% protein / ±10.6% portion
envelope), gains the production +4.0 bonus, and lands 3.0 points ABOVE R06 — their
order is reversed by plausible label error alone. `score.py --verify-report`
re-derives every number bit-exactly and confirms the pair also swaps in the
committed raw-sample draws.

## Scope fences

- **Measured outcomes cover ONLY rank, rating, and explanation stability** of the
  production scorer on the frozen matrix, under the locked uncertainty envelope.
- **Explicitly OUT of scope:** clinical benefit, weight-loss effectiveness, real
  user preference, realism of the recipe sample, and any claim about the app's
  actual behavior on-device. Nothing here says the rankings are bad or good —
  only how much of their order is determined by the data.
- **Generalization fence:** the matrix deliberately OVERSAMPLES threshold
  neighborhoods (calorie-bucket flanks, bonus boundaries, tie pairs). These are
  designed stability probes, not a natural recipe distribution; absolute
  percentages should not be read as field rates.
- **Stress fence:** stress arms are adversarial illustrations, labeled separately
  everywhere (flag `stress: true` in `run_meta.json`, separate tables). They never
  count toward plausible-uncertainty claims.

## Label-service defect — documented reproducer (NOT fixed, NOT a failing test)

The ranking layer grants the high-protein bonus on **absolute grams** (protein
≥ 24 g or the `high_protein` tag, +4 ranking points and a "High protein" ranking
reason), while the reasoning string uses **calorie-share bands** (protein kcal
share > 30% → "High protein", > 25% → "Good protein"). On identical inputs the two
disagree: in the P1 control, 45 of 62 recipes carry the ranking bonus without any
protein note in their reasoning (1 recipe the other way; counts for all profiles in
the generated tables). Concrete failing input: **R07** on P1 — protein 45.375 g and
no `high_protein` tag, so ranking grants the bonus and emits the "High protein"
ranking reason, but its protein kcal share is exactly 0.25 (not > 0.25), so the
reasoning string is "Hearty portion" with no protein note — a user sees
contradictory protein claims on one card. Per scope, this is recorded as a
reproducer for the label service owner; production code is untouched and no CI
test intentionally fails. `score.py --verify-report` asserts the R07 example stays
reproducible from the committed control.

## Failures visibility

The experiment recorded **0 failures** across all 30 arm-profile cells
(`failure_count: 0` in `run_meta.json`); had any draw produced a non-finite score
or missing control entry, it would appear in that cell's `failures` array — the
engine never drops failures silently, and `score.py` surfaces them.

## What was NOT checked

- **No Xcode/iOS build:** this environment has no macOS; nothing here compiles the
  iOS app. The vendored regions are byte-identical to the production source at
  `8c9c88f` (enforced by `VendoredRegionParityTests`), but the app's own build and
  its hosted macOS CI were not run from this branch.
- **No live-model arm:** the study is fully offline; no paid API or live model
  endpoint was called. Nothing was NOT RUN because of that — no step in this study
  requires a live service.
- **Beyond the 10-draw verification window**, full-run aggregates are engine-recorded
  and reproduced across runs, but not recomputed draw-by-draw from committed data
  (a full-draw ledger was dropped for repo size; the windowed recomputation covers
  the same code path and the determinism tests cover the rest).
- **Only P1's hand swap** was hand-verified in full arithmetic; other profiles rely
  on the same code path.

## Assumptions

1. Uncertainty ranges (±16.5% calories, ±20.2% protein, ±20.7% carbs, ±22.6% fat,
   ±20% fiber/sugar/sodium, ±10.6% portion scale; stress bounds separate) are
   judgment calls anchored to the sources in `inputs/uncertainty_assumptions.json`
   — labeled there as sourced vs assumed, with the USDA FDC variability caveat.
2. Perturbation draws are independent per field and per recipe; real label errors
   may be correlated (stated above; out of scope).
3. Zeros are measured zeros (preserved exactly); missing/unknown nutrients were
   handled deterministically and loudly by `check_inputs.py` at freeze time.
4. The replay-side sort tiebreak (input order on full ties) is a determinism guard;
   production leaves full ties to Swift's unstable sort, so tie-pair behavior is
   reported as tie-adjacent, not as production-defined order.
5. The frozen matrix's ranking inputs (matched ingredients, times, personal score)
   are held fixed — only nutrition/portion inputs are perturbed.

## Committed coverage counts (observed this session)

- Python: `check_inputs.py` exit 0; **pytest: 37 passed** (unknown/zero handling,
  bound-lock verification, matrix completeness vs 31 claimed coverage cases).
- Swift: **swift test: 9 tests, 0 failures** (2 control-parity incl. bit-exact
  fixture, 2 vendored-region byte parity over 8 production regions, 5 engine tests).
- Control: **310 records** (5 profiles × 62 recipes) re-derived and compared
  bit-exactly (score bits, rank, rating, label, reasoning, ranking reasons).
- Window recomputation: **30 arm-profile cells** recomputed from raw samples,
  exact equality with engine summaries.
- Experiment: **400 draws** per plausible arm, **200** per stress arm, × 5 profiles
  × 6 arms; **0 failures**.

## Handoff

- **State:** complete through the planned scope: frozen inputs, locked bounds,
  byte-parity Swift replay, deterministic experiment, verified report. Draft PR is
  the source of truth for follow-ups.
- **Reproduce every number:** the command block above; `score.py --verify-report`
  is the one-command check of this report against committed raw outputs.
- **Open questions for reviewers:** (1) are the assumption ranges acceptable as a
  product-level envelope, or should the sources be re-derived before acting?
  (2) is the R07 label mismatch worth a fix ticket for the label service?
  (3) should a full-draw ledger ship for byte-level recomputation of all aggregates
  (repo-size tradeoff)?
- **If picking this up:** rerun `score.py --verify-report` after any input change;
  bounds are checksum-locked — regenerate outputs and tables together
  (`--update-report`) or the verifier will fail loudly.
