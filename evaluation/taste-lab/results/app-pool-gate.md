# Taste-residual re-gate over the app recommendation pool

Decision: **the shipped residual-ranker default stays OFF** (`TasteResidualSettings.builtInDefault = false`).
Re-gated on the pool the app actually ranks (exact matches plus the one/two-missing near-match
tier over a product-shaped pantry), no arm — shipped residual, churn-bounded, or exposure-shrunk —
clears the pass rule on the held-out seeds. No Swift changed in this burst.

## Re-gate after the two setup fixes (2026-10-16)

PR #184's gate was measured with two setup defects found in review; both are fixed in this burst
and the gate was re-run end to end. No Swift changed.

1. **Assumed staples competed in the pantry draw** (`taste_lab/sim.py`, Greptile P1): the app-mode
   pantry took its stable set from `Catalog.staple_ids()`, which on recipes-v2.json is empty (no
   blocking required ingredient reaches the 25% frequency threshold), so all 30 assumed-staple keys
   landed in the random 15-40 draw and the +2.5 sharedRankingScore staple bonus depended on the
   draw. App mode now guarantees every assumed staple before the draw and draws only from the
   remaining keys; legacy mode keeps the committed setup.
2. **churn_bounded chained adjacent gaps** (`taste_lab/engine.py`, Greptile P2): the run split
   compared each ADJACENT rule-score gap, so 60, 58.5, 57 chained into one band-2.0 run whose ends
   sit 3.0 apart and the last entry could pass the first across a gap wider than the band. A run is
   now bounded by its full rule-score spread (head minus tail at most the band).

### Paired results, per arm and seed: #184 before -> re-gate after

| arm | seed | #184 delta NDCG@10 (95% CI) | #184 churn | re-gate delta NDCG@10 (95% CI) | re-gate churn |
|---|---|---|---|---|---|
| residual | 7 (tune) | +0.0012 [-0.0014, +0.0041] | 0.025 | +0.0009 [-0.0009, +0.0029] | 0.035 |
| residual | 11 (tune) | +0.0007 [-0.0005, +0.0021] | 0.040 | +0.0022 [+0.0004, +0.0045] | 0.035 |
| residual | 13 (held out) | +0.0004 [-0.0010, +0.0017] | 0.030 | -0.0002 [-0.0023, +0.0019] | 0.040 |
| residual | 17 (held out) | +0.0005 [-0.0010, +0.0022] | 0.030 | +0.0006 [-0.0014, +0.0027] | 0.035 |
| residual | 19 (held out) | +0.0006 [-0.0018, +0.0030] | 0.040 | +0.0006 [-0.0020, +0.0027] | 0.020 |
| churn_bounded | 7 (tune) | +0.0012 [-0.0014, +0.0041] | 0.025 | +0.0009 [-0.0009, +0.0029] | 0.035 |
| churn_bounded | 11 (tune) | +0.0007 [-0.0005, +0.0021] | 0.040 | +0.0022 [+0.0004, +0.0045] | 0.035 |
| churn_bounded | 13 (held out) | +0.0004 [-0.0010, +0.0017] | 0.030 | -0.0002 [-0.0023, +0.0019] | 0.040 |
| churn_bounded | 17 (held out) | +0.0005 [-0.0010, +0.0022] | 0.030 | +0.0006 [-0.0014, +0.0027] | 0.035 |
| churn_bounded | 19 (held out) | +0.0006 [-0.0018, +0.0030] | 0.040 | +0.0009 [-0.0014, +0.0028] | 0.020 |
| shrunk | 7 (tune) | +0.0009 [-0.0017, +0.0037] | 0.030 | +0.0010 [-0.0001, +0.0027] | 0.025 |
| shrunk | 11 (tune) | +0.0008 [-0.0005, +0.0022] | 0.040 | +0.0023 [+0.0004, +0.0046] | 0.025 |
| shrunk | 13 (held out) | +0.0003 [-0.0006, +0.0011] | 0.020 | +0.0006 [-0.0014, +0.0024] | 0.030 |
| shrunk | 17 (held out) | -0.0000 [-0.0016, +0.0013] | 0.025 | +0.0009 [-0.0010, +0.0029] | 0.025 |
| shrunk | 19 (held out) | +0.0009 [-0.0016, +0.0034] | 0.025 | +0.0012 [+0.0002, +0.0025] | 0.015 |

Verdict: **no arm passes; the pre-registered rule keeps the default OFF**
(`TasteResidualSettings.builtInDefault = false`).

- **residual: fails.** Held-out CI lower bounds -0.0023 (seed 13), -0.0014 (17), -0.0020 (19).
- **residual_churn_bounded: fails.** Held-out CI lower bounds -0.0023, -0.0014, -0.0014. The spread
  fix makes the band real for the first time: #184's tuning found every band value identical
  ("never binds"); the re-gate's tuning separates them (band 3.0 reads +0.0013 mean delta vs
  +0.0015 for the others) and the tie-break takes the most conservative value, so the chosen band
  moves 1.0 -> 6.0. It still does not lift a held-out CI above zero.
- **residual_shrunk: fails.** Held-out CI lower bounds -0.0014 (seed 13), -0.0010 (17); it clears
  seed 19 (+0.0002) for the first time, but the rule requires every held-out seed. Chosen k stays
  16.0.

Churn passes everywhere (1.5-4.0% vs the 5% limit) - the CI rule is again the binding constraint.
Tuning deltas rose on seed 11 (+0.0022 vs #184's +0.0007) because guaranteed assumed staples make
the +2.5 rule bonus deterministic instead of draw-dependent. Porting any passing arm would mean
reproducing its lab math in `FLFeatureLogic` plus fixture replay in `TasteRankerTests`; since none
passes, nothing was ported and Sam's threshold switch is untouched.

Note: #184's tuning table below lists shrunk chosen k 2.0; the committed `app-pool-gate.json` of
that run records k 16.0 (the max mean delta of its own grid). The re-gate also chose k 16.0.

---

The sections below are #184's original report, kept as the historical record. Its per-seed JSONs
(`app-pool-seed*.json`, `app-pool-gate.json`) were superseded in place by the re-gate run.

## Load-bearing assumption

The premise of this re-gate is that the lab should simulate the pool the app ranks rather than a
synthetic wide-pantry setup. The committed v2 gate drew 160–260 of 299 non-staple keys, which makes
`RecipeRepositoryCatalogRecommend`'s feasibility tier enormous and rule gaps narrow; this gate draws
15–40 non-staple keys plus the assumed staples (matching the documented intake flow) and ranks the
exact-plus-near-match pool (at most two blocking lines missing — the tier Home falls back to and the
successor dedupe bound). Evidence that confirms the premise: pool sizes land at 75–181 recipes
(median 108, mean 111; zero households skipped across 80 draws). What would break it: if the product
pantry is materially denser than 15–40 non-staple keys in practice, the wide-pool setup returns and
the committed gate's numbers are the relevant ones again.

## Setup

- Catalog: `apps/ios/Resources/RecipeCatalog/recipes-v2.json` — 763 recipes.
- Pool modes (new): `app` — pantry = 15–40 non-staple keys + assumed staples; candidate pool =
  exact-feasible ∪ {recipes missing 1–2 blocking required lines} (mirrors
  `RecipeRepositoryCatalogRecommend`'s near-match tier with `maxMissing: 2`); assumed-staple lines
  never block feasibility and count like optional matches (+2.5) when present, per the app's
  `sharedRankingScore`. `legacy` — the committed gate's setup (160–260 keys, exact-only pool),
  retained for reproducibility of the earlier results.
- Arms: rule (production scoring port), residual (shipped learned layer, default contribution
  bounds), residual_churn_bounded (reorders confined to runs of consecutive pool entries whose rule
  scores lie within `band` points), residual_shrunk (contributions scaled by
  n/(n + k) on exposure count). Tuning grid: band ∈ {1, 2, 3, 6}, k ∈ {2, 4, 8, 16}.
- Tuning seeds 7 and 11 (objective: highest mean delta among grid values whose churn stays ≤ 5%);
  held-out seeds 13, 17, 19; every seed also reported. Campaign 40 households × 30 days.
- Pass rule: on EACH held-out seed, paired delta-vs-rule bootstrap CI lower bound > 0 AND top-10
  churn vs the rule order ≤ 0.05.

## Tuning (seeds 7 and 11 only)

| variant | grid outcomes (mean delta / mean churn) | chosen |
|---|---|---|
| churn_bounded | every band ∈ {1, 2, 3, 6} identical: +0.00098 / 0.0325 | band 1.0 |
| shrunk | k=2: +0.0008 / 0.0325 · k=4: +0.0007 / 0.0350 · k=8: +0.0007 / 0.0350 · k=16: +0.0008 / 0.0350 | k 2.0 |

The band never binds: on the app pool, every learned reorder happens inside ≤ 1.0-point rule-score
runs, so churn_bounded reproduces the shipped residual exactly (per-seed metrics identical to four
decimals). It is retained as an arm for completeness and fixture support.

## Results (40 households × 30 days per seed)

| seed | residual Δ NDCG@10 | 95% CI | churn | churn_bounded | shrunk Δ | shrunk CI | shrunk churn |
|---|---|---|---|---|---|---|---|
| 7 (tune) | +0.0012 | [-0.0014, +0.0041] | 0.025 | same as residual | +0.0009 | [-0.0017, +0.0037] | 0.030 |
| 11 (tune) | +0.0007 | [-0.0005, +0.0021] | 0.040 | same | +0.0008 | [-0.0005, +0.0022] | 0.040 |
| 13 (held out) | +0.0004 | [-0.0010, +0.0017] | 0.030 | same | +0.0003 | [-0.0006, +0.0011] | 0.020 |
| 17 (held out) | +0.0005 | [-0.0010, +0.0022] | 0.030 | same | -0.0000 | [-0.0016, +0.0013] | 0.025 |
| 19 (held out) | +0.0006 | [-0.0018, +0.0030] | 0.040 | same | +0.0009 | [-0.0016, +0.0034] | 0.025 |

Verdict lines from the gate run: every arm fails (CI lower bound ≤ 0 on at least one held-out seed).
NDCG@10 for the residual sits at 0.470–0.476 across seeds. Pool sizes per household-day: 75–181,
median 108.

Reports: `app-pool-seed{7,11,13,17,19}.json`, summary `app-pool-gate.json` (includes the full tuning
grid and the per-seed arms). Fixture set regenerated in `app` mode
(`fixtures/golden-hh00|hh01|hh23.json`, seeds 7/11/13) — all fixtures replay exactly against the
shipped math.

## Why the default stays off

1. **The benefit does not survive the app-shaped pool.** On the committed gate's wide-pantry setup
   the residual delta read +0.0022 / +0.0111 / +0.0059 with two of three seeds clearing zero. On the
   pool the app ranks, the same layer reads +0.0004 to +0.0012 — roughly ten times smaller — and no
   seed's CI clears zero. The wide-pantry setup manufactured rule-near-ties for the learned layer to
   exploit; the near-match pool's coverage tiers keep consecutive rule scores well separated, so the
   layer's ≤ 8-point clamped contributions rarely move anything that matters.
2. **Churn was never the binding constraint here.** Top-10 churn reads 2.5–4% on every seed — well
   under the 5% limit, and five to eight times lower than the committed gate's 13.5–22.5%. The
   learned layer is already quiet on this pool; neither churn_bounded nor shrunk can rescue a delta
   that is statistically indistinguishable from zero.
3. **shrunk trades delta for nothing.** Exposure-count shrinkage matches or lowers churn on held-out
   seeds but also zeroes the (tiny) positive delta on seed 17. With the churn headroom available, the
   shipped bounds were never the problem.

## What was and wasn't checked

- Checked: 17 lab tests pass (pool-mode behavior, pantry shape, band never crossing a wide rule gap,
  shrunk scaling by exposure count, variant validation, fixture pinning, determinism, bounds,
  replay); `docs/spec/taste/contracts/check.py` all examples valid; fixtures replay exactly; gate
  reproducible via `python3 -m taste_lab gate --catalog <recipes-v2.json> --households 40 --days 30
  --out-prefix results/app-pool` (about 45 s).
- Not checked: any Swift behavior — the gate failed, so per the pre-registered rule nothing was
  ported and `TasteResidualSettings.builtInDefault` stays `false`; no iOS build or XCTest ran. The
  Swift ranker is untouched, so the existing taste-store-check parity relationship to the shipped
  math is unchanged; the churn-bounded/shrunk variants remain lab-only.
- Assumed: the 15–40 non-staple pantry draw approximates the product's intake flow (the documented
  intake paths do not pin a pantry size); exposure share floor 0.15 and personal-score=0 carried over
  from the committed setup unchanged.
