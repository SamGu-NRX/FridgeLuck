# Taste-residual gate rerun over the shipped bundle-v2 catalog

Decision: **the shipped residual-ranker default stays OFF** (`TasteResidualSettings.builtInDefault = false`).
The ranker ships behind the stored preference; the offline evidence does not meet the bar the
legacy-catalog gate set.

## Setup

- Catalog: `apps/ios/Resources/RecipeCatalog/recipes-v2.json` — 763 recipes, canonical ingredient
  keys, bundled per-serving nutrition (163 computed / 345 estimated / 255 partial), no equipment.
- Campaign: 40 simulated households × 30 days, seeds 7 / 11 / 13 (same shape as the legacy gate).
- Arms: rule (production `sharedRankingScore` port), residual (learned layer over the rule),
  profile-only, popularity. Every arm ranks the same feasible set per household-day.
- v2 specifics (documented deviations, all mirroring the app's catalog path):
  - Personalization term held at 0 for catalog entries (`RecipeRepositoryCatalogRecommend` passes
    `personalScore: 0`), so the rule arm is pure pantry/health/time scoring.
  - Macros are the bundle's `nutrition_per_serving`, never recomputed.
  - Feasibility ignores `assumed_staple` required lines; features still include them.
  - Simulated pantries draw 160–260 of the 299 non-staple keys (the legacy 6–14 draw yields
    feasible sets of 0–2 recipes on this catalog — no dominant staples once assumed staples are
    excluded). All arms share the same pantries.

## Results

| seed | Δ NDCG@10 (residual − rule) | 95% CI | top-10 churn vs rule | residual | rule |
|---|---|---|---|---|---|
| 7  | +0.0022 | [-0.0034, +0.0078] | 0.135 | 0.4711 | 0.4690 |
| 11 | +0.0111 | [+0.0027, +0.0198] | 0.225 | 0.4719 | 0.4609 |
| 13 | +0.0059 | [+0.0008, +0.0110] | 0.175 | 0.4835 | 0.4776 |
| legacy seed 7 (prior gate) | +0.0059 | [+0.0002, +0.0139] | 0.040 | — | — |

Reports: `catalog-v2-eval-40x30-seed{7,11,13}.json`. Fixtures regenerated over the same catalog
(`fixtures/golden-hh00|hh01|hh23.json`, seeds 7/11/13); all lab tests pass (8/8) and the fixtures
replay exactly.

## Why the default stays off

1. **Not consistently significant.** The legacy gate confirmed the learned layer with a
   delta CI lower bound above zero on seed 7. Over the v2 catalog, seed 7's CI spans zero
   ([-0.0034, +0.0078]); two of three seeds clear zero, one does not.
2. **Churn is 3–5× the legacy rate** (13.5–22.5% of top-10 slots vs 4.0% legacy). The learned
   layer reorders far more of the slate on the big catalog — the 763-recipe pool spreads 30 days
   of cooking thinly, so near-ties dominate and the residual moves many of them.

## What would flip it

The pattern across seeds points at signal growing with per-household exposure volume (seed 11:
most churn AND the largest, clearly significant delta). A rerun with denser history — longer
campaigns, or live exposure data once the ranker has been enabled voluntarily for a cohort —
should be re-gated with the same decision rule: all-seed CI lower bounds above zero and churn
at or below the legacy band.

## Not covered here

- The simulator's latent-preference model, not real users, supplies the utility signal.
- `nutrition_per_serving` coverage "partial" recipes carry no nutrient features by design.
- The v2 catalog ships no equipment values, so `tool:*` features are produced by neither side.
