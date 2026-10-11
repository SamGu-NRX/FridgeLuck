# Suite B evaluation campaign — RESULTS

Suite: `fl-learning-lab-f1` (suite B) · Branch `eval/fltaste-suite-b` · Producing commit: see `PROVENANCE.json` in the committed campaign artifacts (`evaluation/suites/learning/campaign/`).

**Scale honesty up front.** The preregistered campaign (5,000 households × 20 seeds × 12 arms × 12 weeks) measures ≈2,600 CPU-hours on this sandbox and **was not run** (`preregistered_scale: fail` is mechanical in the suite wiring). The numbers below are the documented reduced grid. They exercise every arm, metric, and statistic end-to-end, but they are NOT the full activation decision.

**Corpus note.** The campaign replayed the app's bundled 166-recipe catalog (`apps/ios/Resources/data.json`, recorded in `manifest.json` `corpusRecipeCount`), i.e. what the shipping app ranks from — not the 428-recipe corpus deliverable owned by the Part 2 task.

## Executed grid

| Quantity | Value |
| --- | --- |
| Households per seed | 70 (12-week staged replay, shift at week 8) |
| Seeds | 6 (households/regimes derived deterministically per seed) |
| Arms | 12 preregistered (5 families + 4 baselines + 3 engine ablations) |
| Weeks | 12 |
| Workers | 2 (sandbox cores) |
| Build | `swift build -c release`, Linux x86_64, Swift 6.4 |
| Wall time | 15:35:38Z → 21:24:20Z (sandbox idles between polls included); ≈397 CPU-min across both workers |
| Checkpoints | 72/72 (every seed × arm) |

Reproduction (from repo root, after `swift build -c release` in `packages/FLTaste/Eval`):

```
cd packages/FLTaste/Eval
.build/release/fltaste-eval --config custom --households 70 --seeds 6 --weeks 12 \
  --out <out-dir>          # resumable: per-(seed, arm) checkpoints under <out-dir>/checkpoints/
```

Machine provenance: `manifest.json` (hostname, Swift version, corpus path/count, seeds) and `PROVENANCE.json` (producing SHA, dirty-file count, `produced_at`) in the committed campaign artifacts.

## Headline: activation gate (scorecard B)

The gate is evaluated by `python3 evaluation/suites/learning/suite.py --out <abs>` from the committed artifacts; `gate.json` carries the exact verdict. CIs below are the Swift paired bootstrap over seeds (B=10,000, seed recorded in the results).

| Quantity | Value |
| --- | --- |
| Engine vs rule ranker, NDCG@10 relative lift (95% CI) | **−11.15% [−12.18%, −10.08%]** — negative on all 6 seeds |
| Engine vs explicit-profile-only, NDCG@10 relative lift (95% CI) | **+4.83% [+3.76%, +5.88%]** — positive, but CI low < +10% |
| Hard-restriction violations (all arms, all seeds) | **0** (asserted across all 72 checkpoints) |
| Median cooks-to-recovery after the week-8 shift | 3.83 (mean of per-seed medians; see caveat) |
| **Gate verdict at reduced scale** | **NOT MET** (both lift bars fail; scale metric fails by construction) |

## Headline table

Per-arm means over 6 seeds; 95% CI from bootstrap over seeds (B=10,000, numpy PCG64 seed 0). `viol` = hard-restriction violations summed over seeds (bar: 0). `recov` = mean over seeds of the per-seed median cooks-to-recovery. `hit@10` = best-in-slate rate. `tau` = Kendall calibration against the hidden true preference order.

| arm | family | NDCG@10 [CI] | viol | recov (med) | regret | exp-regret | tau | hit@10 |
|---|---|---|---|---|---|---|---|---|
| rule-port | baseline | 0.8797 [0.8737, 0.8850] | 0 | 3.50 | 0.267 | 0.103 | 0.225 | 0.812 |
| profile-only | baseline | 0.7458 [0.7295, 0.7638] | 0 | 3.33 | 1.048 | 0.357 | −0.107 | 0.329 |
| popularity | baseline | 0.7216 [0.7024, 0.7421] | 0 | 3.83 | 1.240 | 0.410 | −0.092 | 0.268 |
| random | baseline | 0.7741 [0.7586, 0.7895] | 0 | 3.67 | 0.663 | 0.237 | 0.005 | 0.455 |
| trust-vector | family-1 | 0.8592 [0.8455, 0.8699] | 0 | 3.67 | 0.385 | 0.147 | 0.169 | 0.697 |
| logistic-l2 | family-3 | 0.8266 [0.8150, 0.8378] | 0 | 3.50 | 0.401 | 0.164 | 0.086 | 0.674 |
| pairwise-ltr | family-4 | 0.7951 [0.7827, 0.8067] | 0 | 3.50 | 0.706 | 0.265 | 0.020 | 0.464 |
| embedding | family-5 | 0.8180 [0.8026, 0.8334] | 0 | 3.17 | 0.473 | 0.181 | 0.104 | 0.619 |
| engine | family-2 | 0.7816 [0.7694, 0.7934] | 0 | 3.83 | 0.688 | 0.252 | −0.013 | 0.463 |
| engine-no-exploration | ablation | 0.7843 [0.7682, 0.8011] | 0 | 3.50 | 0.730 | 0.256 | −0.040 | 0.465 |
| engine-no-exposure | ablation | 0.7849 [0.7733, 0.7991] | 0 | 3.50 | 0.706 | 0.259 | −0.015 | 0.469 |
| engine-no-recency | ablation | 0.7819 [0.7708, 0.7942] | 0 | 3.83 | 0.703 | 0.256 | −0.016 | 0.463 |

### Activation gate detail (Swift paired bootstrap CIs from `gate.json`)

| comparison | baseline arm | mean rel. lift | 95% CI | CI-low >= +10%? |
|---|---|---|---|---|
| engine vs rule ranker (port) | rule-port | −11.15% | [−12.18%, −10.08%] | NO |
| engine vs explicit profile-only | profile-only | +4.83% | [+3.76%, +5.88%] | NO |

- restriction violations: 0 (bar: 0) → PASS
- median recovery: 3.83 cooks (bar: ≤ 6) → PASS
- preregistered scale (5,000 households × 20 seeds): **not-run** (reduced grid 70 × 6 executed)
- **activationGateMet: FALSE**

### Cross-check

Paired lifts recomputed independently (Python, same per-seed NDCG values) match `gate.json` point estimates exactly and its CIs to within bootstrap-RNG rounding: vs rule-port mean −11.15% (per-seed −12.75, −10.67, −12.50, −9.29, −11.91, −9.78); vs profile-only mean +4.83% (per-seed +6.48, +2.92, +5.55, +3.03, +5.77, +5.24).

## Regime breakdown: mean NDCG@10 per regime (mean over seeds)

| arm | baseline | sparse-feedback | slow-drift | abrupt-shift | two-eater | exposure-bias |
|---|---|---|---|---|---|---|
| rule-port | 0.9000 | 0.8987 | 0.8742 | 0.8666 | 0.8889 | 0.8607 |
| profile-only | 0.7669 | 0.7617 | 0.7183 | 0.7363 | 0.7647 | 0.7359 |
| popularity | 0.7444 | 0.7240 | 0.6948 | 0.7337 | 0.7246 | 0.7095 |
| random | 0.7939 | 0.7853 | 0.7433 | 0.7826 | 0.7871 | 0.7617 |
| trust-vector | 0.8815 | 0.8752 | 0.8468 | 0.8479 | 0.8804 | 0.8325 |
| logistic-l2 | 0.8325 | 0.8482 | 0.8012 | 0.8260 | 0.8368 | 0.8322 |
| pairwise-ltr | 0.8173 | 0.7968 | 0.7630 | 0.7938 | 0.8089 | 0.7939 |
| embedding | 0.8325 | 0.8204 | 0.7897 | 0.8212 | 0.8272 | 0.8209 |
| engine | 0.8045 | 0.7926 | 0.7534 | 0.7862 | 0.7939 | 0.7685 |
| engine-no-exploration | 0.8095 | 0.8038 | 0.7646 | 0.7720 | 0.7995 | 0.7694 |
| engine-no-exposure | 0.7988 | 0.8026 | 0.7592 | 0.7827 | 0.7993 | 0.7783 |
| engine-no-recency | 0.7995 | 0.7910 | 0.7623 | 0.7827 | 0.7973 | 0.7629 |

## Recovery (cooks-to-shift-recovery), pooled over seeds

| arm | median | p75 | p90 | censored |
|---|---|---|---|---|
| rule-port | 7.0 | 10.0 | 12.3 | 139 |
| profile-only | 7.0 | 11.0 | 13.2 | 233 |
| popularity | 6.0 | 9.0 | 12.0 | 245 |
| random | 7.0 | 10.0 | 13.0 | 193 |
| trust-vector | 7.0 | 10.0 | 12.3 | 139 |
| logistic-l2 | 7.0 | 11.0 | 13.8 | 157 |
| pairwise-ltr | 7.0 | 11.0 | 13.0 | 213 |
| embedding | 7.0 | 10.0 | 13.0 | 171 |
| engine | 7.0 | 10.0 | 13.0 | 180 |
| engine-no-exploration | 7.0 | 10.0 | 13.0 | 190 |
| engine-no-exposure | 7.0 | 11.0 | 14.0 | 189 |
| engine-no-recency | 8.0 | 11.0 | 14.0 | 202 |

**Recovery caveat, stated plainly.** The gate statistic ("median recovery ≤ 6") is computed as the mean over seeds of per-seed medians (3.83 → PASS). The pooled distribution over all shift events tells a harsher story: pooled median ≈ 7 cooks with 139–245 censored (never-recovered-within-horizon) events per arm. Both views are reported; the PASS under the campaign's preregistered statistic is real, but a 12-week horizon after a week-8 shift leaves little recovery room, so the recovery bar is weakly identified at this scale.

## Volume and secondary diagnostics (sums/means over seeds)

| arm | households | ranked sessions | cooked sessions | mean choice rank | repeat rate | fairness gap |
|---|---|---|---|---|---|---|
| rule-port | 420 | 11207 | 5659 | 3.65 | 0.502 | 0.171 |
| profile-only | 420 | 11173 | 5643 | 5.00 | 0.441 | 0.322 |
| popularity | 420 | 11238 | 5638 | 5.90 | 0.453 | 0.296 |
| random | 420 | 11165 | 5624 | 4.67 | 0.327 | 0.310 |
| trust-vector | 420 | 11238 | 5640 | 3.09 | 0.531 | 0.205 |
| logistic-l2 | 420 | 11255 | 5678 | 3.44 | 0.490 | 0.212 |
| pairwise-ltr | 420 | 11308 | 5722 | 4.03 | 0.392 | 0.287 |
| embedding | 420 | 11179 | 5661 | 3.69 | 0.498 | 0.238 |
| engine | 420 | 11171 | 5636 | 4.22 | 0.367 | 0.367 |
| engine-no-exploration | 420 | 11195 | 5655 | 3.50 | 0.473 | 0.332 |
| engine-no-exposure | 420 | 11110 | 5575 | 4.19 | 0.355 | 0.343 |
| engine-no-recency | 420 | 11174 | 5630 | 4.26 | 0.351 | 0.346 |

## Honest read

At the executed scale the activation gate is **not met, and not narrowly**: the engine arm trails the rule ranker by −11.2% relative NDCG@10 with the entire interval below zero on every seed, and while it beats the explicit-profile-only baseline (+4.8%), the interval low (+3.8%) is far under the required +10%. Zero hard-restriction violations held across all 72 checkpoints, and recovery passes under the preregistered statistic — the safety conditions are fine; the performance condition is not. The ablations sharpen the diagnosis: removing Thompson exploration, exposure weighting, or recency decay moves the engine by at most ~+0.3–0.6 NDCG points, so the gap to the rule ranker is not explained by any single mechanism — at 70 households × 12 weeks the staged replay simply feeds the learners too little data, and the engine (and pairwise LTR) sit near the random arm while the simpler Beta trust-vector converges fastest and comes closest (−2 points). The rule ranker's dominance is also partly structural in this simulator: most of its signal (quick/short/brief appeal, pantry fit, restriction filtering) is available without learning, which is exactly the regime where a learned ranker has the least room to win. The full 5,000 × 20 preregistered campaign — the actual activation decision instrument — remains not-run; the reduced grid's value is that the harness, metrics, and gate mechanics are proven end-to-end and the failure direction is honest. The parent owns the recommendation; this suite only reports.
