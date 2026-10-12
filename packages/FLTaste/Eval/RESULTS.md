# Suite B evaluation campaign — RESULTS

Suite: `fl-learning-lab-f1` (suite B) · Branch `eval/fltaste-suite-b` · Producing commit: see `PROVENANCE.json` in the committed campaign artifacts (`evaluation/suites/learning/campaign/`).

**Scale honesty up front.** The preregistered campaign (5,000 households × 20 seeds × 12 arms × 13 weeks) measures on the order of thousands of CPU-hours on this 2-core sandbox and **was not run** (`preregistered_scale: fail` is mechanical in the suite wiring — the suite computes it from the run manifest, fail-closed). The executed reduced grid exercises every arm, metric, and statistic end-to-end, but it is not the full activation decision.

## Status: post-seam metrics-v4 rerun (this document's numbers land when it completes)

The tables below are **skeletons at the post-seam baseline**; they are filled from the committed checkpoints when the current run finishes. Every earlier committed grid is superseded and is not shown as a baseline:

1. **Seam supersession.** The sealed `RankerCandidate` seam (`feat/fltaste-sim` @ `11f9119`, merged as `91fb900`) changed ranker-visible inputs (observable projections only, schema v2, `latentRegime` field, rule-blind regime). Numbers produced before the seam must not be compared to post-seam numbers.
2. **Metrics-v4 supersession.** The independent restriction evaluator's never-suggest clock previously ran ahead of the simulator's enforcement granularity: Sim snapshots never-suggest into its week-start `FeasibilityFilter`, so a mid-week mute cannot reach the ranker-visible candidate set until the next week boundary regardless of arm behavior (`RankInput` carries no mute surface). Metrics ≤ v3 flagged same-week slates no arm could have prevented (observed: 5 hits in a 7-household probe — 2 random, 3 rule-port, all two-eater-regime). **v4** (commit `7ea5386`): a mute emitted in week *w* counts against slates in weeks > *w*; from that boundary Sim's own filter excludes the ingredient, so any hit is a real enforcement failure and still fails the zero bar. Walk-level regression: `testNeverSuggestAppliesAtSimEnforcementGranularity`.

Current run (the one this document will report): 70 households × 6 seeds × 12 arms × 13 weeks, 7-regime wheel (baseline, sparse-feedback, slow-drift, two-eater, abrupt-shift, exposure-bias, **rule-blind**), release build, tmux-checkpointed per (seed, arm), resumable under hash-bound fingerprints (config + corpus + code + metrics version).

Reproduction (from repo root, after `swift build -c release` in `packages/FLTaste/Eval`):

```
cd packages/FLTaste/Eval
.build/out/Products/Release-linux-x86_64/fltaste-eval --config custom --households 70 --seeds 6 \
  --weeks 13 --out <out-dir>   # resumable: per-(seed, arm) checkpoints under <out-dir>/checkpoints/
python3 ../../evaluation/suites/learning/suite.py --out <abs-out-dir>   # fail-closed gate verdict
```

Machine provenance: `manifest.json` (hostname, Swift version, corpus path/count, seeds) and `PROVENANCE.json` (producing SHA, dirty-file hashes, `produced_at`) in the committed campaign artifacts. Linux x86_64, Swift 6.4, 2 cores, foundation-only.

## Disclosure 1 — the staged-replay inversion hypothesis (why the engine may be under-measured)

Week-granular **staged replay** is the harness's core compromise: Sim's `Ranker` protocol has no per-event feedback hook (`rank` + week-boundary `make` only — recorded as an API gap), so learner arms are re-staged once per week on the full event history instead of learning per decision. Thompson-style arms draw one posterior sample per **stage**, not per **session**: exploration that a per-event loop would spread across a week's sessions is collapsed into a single ranking at the week boundary. The engine arm (family 2) is the heaviest consumer of per-event exploration, so this harness artifact plausibly deflates exactly the arm the activation gate scores.

**Confirm/reject criteria (preregistered here, before the hook exists):**

- **CONFIRM** — a per-event feedback-hook rerun (Sim adds the hook; arms replay per event) lifts the engine arm materially toward or above the trust-vector arm: the paired engine-vs-trust-vector NDCG@10 difference moves from clearly negative to within its 95% interval of zero (or positive), AND the engine's lift vs the rule ranker improves by more than the interval width. Material = outside the paired interval, not a point-estimate wiggle.
- **REJECT** — the engine-vs-trust-vector gap is unchanged (intervals overlap the old difference) and the engine's lift vs rule does not improve materially: the deficit is attributable to data quantity and regime structure, not feedback granularity.

**Status: untested.** The hook is a Sim-surface change (outside this PR's scope); this document records the hypothesis and the criteria so the follow-up is a designed experiment, not a post-hoc excuse. Until then, every engine deficit in this suite carries this caveat.

## Disclosure 2 — the trust-vector arm (Beta trust vector per source and feature)

On the last complete grid (pre-seam inputs, superseded for absolute numbers), the trust-vector arm ranked **second overall and first among learned arms**, −2.0 NDCG points behind the rule-port and +7.8 ahead of the engine. The mechanism is structural, not an artifact of that grid: Beta posteriors per feedback source and recipe feature converge from few sessions, need no staged-history refold, and degrade gracefully under sparse feedback — the exact conditions the reduced grid stresses. The post-seam tables below confirm or revise its position; the arm list and its design (Sam's trust-vector design applied to taste) are unchanged.

## Headline: activation gate (scorecard B)

The gate is evaluated by `python3 evaluation/suites/learning/suite.py --out <abs>` from the raw per-checkpoint data: the suite computes run identity, executed scale, per-seed lifts with paired bootstrap CIs (B recorded in the results), and the zero-violation field **itself**, fail-closed to `not-run` on any missing or mismatched input. `gate.json` carries the exact verdict.

| Quantity | Value |
| --- | --- |
| Engine vs rule ranker (port), NDCG@10 rel. lift (95% CI) | *to fill from post-seam run* |
| Engine vs explicit-profile-only, NDCG@10 rel. lift (95% CI) | *to fill from post-seam run* |
| Hard-restriction violations (all arms, all seeds, independent evaluator) | *to fill — bar: 0* |
| Median cooks-to-recovery after the week-8 shift | *to fill — bar: ≤ 6* |
| Preregistered scale (5,000 × 20) | **not-run** (reduced grid executed) |
| **Gate verdict at reduced scale** | *to fill* |

## Headline table (post-seam, metrics v4)

Per-arm means over seeds; 95% CI from the paired bootstrap over seeds. `viol` = independent restriction violations summed over seeds (bar: 0). `recov` = mean over seeds of per-seed median cooks-to-recovery. `hit@10` = best-in-slate rate. `tau` = Kendall calibration against the hidden true preference order.

| arm | family | NDCG@10 [CI] | viol | recov (med) | regret | exp-regret | tau | hit@10 |
|---|---|---|---|---|---|---|---|---|
| rule-port | baseline | — | — | — | — | — | — | — |
| profile-only | baseline | — | — | — | — | — | — | — |
| popularity | baseline | — | — | — | — | — | — | — |
| random | baseline | — | — | — | — | — | — | — |
| trust-vector | family-1 | — | — | — | — | — | — | — |
| logistic-l2 | family-3 | — | — | — | — | — | — | — |
| pairwise-ltr | family-4 | — | — | — | — | — | — | — |
| embedding | family-5 | — | — | — | — | — | — | — |
| engine | family-2 | — | — | — | — | — | — | — |
| engine-no-exploration | ablation | — | — | — | — | — | — | — |
| engine-no-exposure | ablation | — | — | — | — | — | — | — |
| engine-no-recency | ablation | — | — | — | — | — | — | — |

## Per-regime breakdown (post-seam, with intervals)

Mean NDCG@10 per regime with per-regime bootstrap CIs (paired seeds; B recorded in the results). The **rule-blind** regime (latent preferences driven by features the rule ranker cannot see — hidden ingredient affinities, technique keys, spice affinity) is where a learned ranker has structural room to win; per SIM-ASSUMPTIONS §12 the paired-seed regime comparison is the designed read: same seed → same household, standard vs rule-blind latent regime, rule-port vs learners side by side.

| arm | baseline | sparse-feedback | slow-drift | two-eater | abrupt-shift | exposure-bias | rule-blind |
|---|---|---|---|---|---|---|---|
| rule-port | — | — | — | — | — | — | — |
| profile-only | — | — | — | — | — | — | — |
| popularity | — | — | — | — | — | — | — |
| random | — | — | — | — | — | — | — |
| trust-vector | — | — | — | — | — | — | — |
| logistic-l2 | — | — | — | — | — | — | — |
| pairwise-ltr | — | — | — | — | — | — | — |
| embedding | — | — | — | — | — | — | — |
| engine | — | — | — | — | — | — | — |
| engine-no-exploration | — | — | — | — | — | — | — |
| engine-no-exposure | — | — | — | — | — | — | — |
| engine-no-recency | — | — | — | — | — | — | — |

Paired-seed rule-blind comparison (per seed: rule-port − learner NDCG in rule-blind minus the same difference in the standard regime, with interval): *to fill from post-seam run — this difference isolates the rule ranker's blind-spot advantage, which learning should shrink.*

## Recovery, volume, calibration

*To fill from the post-seam run:* per-arm recovery distributions (median, p75, p90, censored count — with the standing caveat that a week-8 shift in a 13-week horizon leaves little recovery room, so the ≤6 bar is weakly identified at reduced scale), volume and secondary diagnostics (ranked/cooked sessions, mean choice rank, repeat rate, two-eater fairness gap), and calibration (`tau`).

## Compute profile and the speed objective (resolved: dropped)

Profiling instrument: `EVAL_PROFILE=1` PhaseTimer (commit `099fd80`), opt-in, metrics-neutral. Measured on a 2-household × 1-seed × 13-week fixture: simulation dominates — ≈0.9–1.1 s/household for stateless arms and ≈8–11 s/household for staged learner arms — while scoring is negligible and `make` costs concentrate in engine arms (full `TasteEngine` refold per stage). The refold is FLTaste-owned; the staged replay is Sim-owned; both are outside this PR's scope (`packages/FLTaste/Eval/**` only).

**Decision: the optimization is dropped.** The brief's criterion is a proven ≥2× speedup with byte-identical outputs, else ship nothing. No Eval-owned hot path can plausibly reach 2× — the dominant costs are Sim's week-granular replay and FLTaste's per-stage refold, and Eval-side caching cannot restructure either without changing what is measured. The campaign therefore runs on unoptimized code with honest wall-time accounting (this file and `manifest.json`), and any real speedup requires Sim/FLTaste surface changes (the same per-event hook of Disclosure 1 would also restructure the staged replay).

## API gaps for the record

1. Sim `Ranker` exposes no per-event feedback hook → week-granular staged replay (Disclosure 1); a per-event rerun is the designed test of the inversion hypothesis.
2. `RankInput` carries no mute surface → same-week never-suggest enforcement is not expressible by any arm; metrics v4 encodes the week-boundary contract the system actually enforces. A per-session mute surface would tighten the safety metric's resolution.
3. The rule-port omits alpha seams the simulator cannot express (documented in the arm's source header); it is a faithful port of the ranker's scoring behavior, not of its IO context.

## Honest read

*To finalize from the post-seam run.* The last complete grid (pre-seam, superseded inputs) had the gate **not met, and not narrowly**: the engine trailed the rule-port by −11.2% relative NDCG@10 (interval entirely below zero on every seed) and beat profile-only by +4.8% with the interval low far under +10%; zero violations held; the trust-vector arm was the best learner. That grid's direction is the working hypothesis for the post-seam tables above — the sealed seam removed information from every ranker and added the rule-blind regime where the rule-port cannot see its usual signal, so the gap may narrow; Disclosure 1 bounds how much of any remaining gap the harness itself may be causing. The parent owns the activation recommendation; this suite only reports.
