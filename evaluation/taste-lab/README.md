# taste-lab — the taste-residual-v1 reference implementation and offline evaluation

A standard-library Python package (`taste_lab`) plus a seeded household
simulator and a four-arm offline evaluation, for the learning model defined in
`docs/spec/taste/SPEC.md` (PR #146). Everything here is deterministic:
fixed seed, fixed start date, no RNG anywhere in the engine, canonical
6-decimal floats — the same inputs always produce the same outputs.

## Layout

```
taste_lab/
  constants.py   the spec's numeric dials (half-lives, strengths, caps, priors,
                 thresholds) — transcribed from SPEC.md sections 2 and 4
  features.py    data.json catalog loader + taste-feature extractor (the
                 documented deterministic proxy for the app's
                 taste-features-v1 pipeline), NutritionService /
                 HealthScoringService ports
  rules.py       faithful port of today's ranking: PersonalizationService
                 .personalScore + RecipeScoring.sharedRankingScore
  engine.py      taste-residual-v1: lazy-decay Beta posteriors per feature key,
                 exposure-share weighting, cook-transaction windows, profile
                 statements
  baselines.py   evaluation arms (residual, rule anchor, explicit-profile-only,
                 household-habit "popularity")
  sim.py         seeded households with latent preferences over feature keys;
                 they cook, rate, skip, save, substitute, and send LeChef
                 feedback; golden-fixture writer
  metrics.py     NDCG@10, pairwise accuracy on rule-flippable pairs, top-10
                 churn, deterministic bootstrap CIs (paired for arm deltas)
  evalcli.py     the CLI
fixtures/        committed golden fixtures (replay-verified)
results/         committed evaluation reports
tests/           pytest suite
```

## Parity with the machine-checked contracts

`tests/test_parity.py` replays the contracts checker's committed
`coriander-v1` golden fixture (`docs/spec/taste/contracts/examples/
golden-fixture/`) through this engine and compares, at canonical 6-decimal
precision:

- the full ranking order and every per-feature contribution,
- every recipe's `learnedContribution` and `totalScore`,
- the decayed posterior state (alpha, beta, lastEvidenceAt) for every
  feature key,
- the rendered profile statement text, byte for byte, and the hidden-reason
  set.

That is the lab's claim to correctness for the rated-cook reference math: it
is the same math as `docs/spec/taste/contracts/check.py:recompute()`, not a
reimplementation of it. Where the lab generalizes beyond the checker's
cook-only reference — the other eleven event kinds of SPEC section 2.3 — the
decision is documented at the code site in `engine.py` (rated-merge into the
cook's transaction window, unsave as a reversed save, substitution
motivations, LeChef spice tags, skip/view/open requiring a resolving
exposure, `never_suggest` pinned statements, corrections suppressing
regeneration).

## Usage

```bash
cd evaluation/taste-lab

# offline campaign (writes stdout; --out also saves the JSON)
python3 -m taste_lab eval --catalog ../../apps/ios/Resources/RecipeCatalog/recipes-v2.json \
    --households 40 --days 30 --seed 7

# verify the committed golden fixtures replay exactly
python3 -m taste_lab validate-fixtures \
    --catalog ../../apps/ios/Resources/RecipeCatalog/recipes-v2.json --fixtures fixtures

# regenerate them (byte-identical for the same seed)
python3 -m taste_lab regenerate-fixtures \
    --catalog ../../apps/ios/Resources/RecipeCatalog/recipes-v2.json --out fixtures --seed 7

python3 -m pytest tests -q
```

## Committed result (40 households x 30 days, seed 7)

`results/eval-40x30-seed7.json`. Headline numbers (NDCG@10 against the
households' latent utilities, 95% percentile-bootstrap CIs, household-level
paired resampling for the delta):

| arm | NDCG@10 mean | 95% CI | top-10 churn vs rule |
|---|---|---|---|
| rule (production port) | 0.4496 | [0.3708, 0.5334] | 0 |
| **residual (spec model)** | **0.4555** | [0.3816, 0.5364] | 0.04 |
| profile-only (#115 family) | 0.4603 | [0.3608, 0.5623] | 0.38 |
| household-habit "popularity" | 0.5700 | [0.4884, 0.6584] | 0.84 |

- **Residual vs rule: +0.0059 NDCG@10, 95% CI [+0.0002, +0.0139]** — a small,
  reliably positive lift, with only 4% of top-10 slots changing. That is the
  spec's "small evidence nudges but never overturns" behaviour doing exactly
  what it says: the residual flips near-ties (pairs with rule-score gaps
  within the 2.5-point guardrail; 575 flippable pairs observed) and never
  spans a larger gap (tested in `tests/test_lab.py`).
- **The popularity arm's high NDCG is a simulator artifact, not a
  recommendation.** Slate exposure is generated from the household's latent
  utilities, so its own repeat-cook frequency is a leaked proxy of the very
  ground truth the metrics read. It also churns 84% of the top 10 and ignores
  the pantry-feasible rule anchor's guarantees. On-device it does not even
  exist as designed here — a phone cannot see other households' cooking.
  Read it as an upper bound on what any taste signal could recover, not as a
  candidate.
- Profile-only matches the rule anchor's NDCG while churning 38% —
  re-learning today's behaviour with a different score shape buys nothing.

## What this is for

1. The Swift port of taste-residual-v1 must reproduce this engine's outputs —
   the committed golden fixtures are the acceptance harness, and the CLI's
   `validate-fixtures` is the one-command check.
2. The simulator is the only place with ground truth (latent preferences);
   any future scoring change can be re-evaluated with one deterministic
   command before touching on-device code.

## Known seams (all deliberate, all documented at the code site)

- The feature extractor is a proxy for the app's taste-features-v1 tagging;
  fixtures pin features as inputs, so the residual contract does not depend
  on extractor refinements.
- Final lazy decay uses the half-life of a feature's last update class; the
  checker's cook-only reference hard-codes the cook_rating half-life. The two
  agree on all committed fixtures (verified by the parity test).
- The simulator's exposure surface is a noisy latent-utility browser, not the
  residual arm itself — arms are always re-ranked from the same logs, never
  from latent state.
