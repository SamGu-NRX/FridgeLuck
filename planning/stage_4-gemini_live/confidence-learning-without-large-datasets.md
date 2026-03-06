# Confidence Learning Without Large Labeled Datasets

Last updated: 2026-03-04 (America/Chicago)

## Direct answer

You do **not** need to train a big model for this project.

A production-credible alternative is:

1. Keep Gemini Live as planner/tool-caller.
2. Build a lightweight **confidence inference layer** (math + priors + online updates).
3. Learn reliability online from user interactions you already collect.

This is realistic for hackathon scope and much safer than pretending to have a fully trained confidence model.

## What you already have in repo

Existing continual-learning hooks are real and useful:

1. `LearningService` already records corrections and suggestion acceptance:
   - `FridgeLuck.swiftpm/Capability/Core/Recognition/LearningService.swift`
2. Current confidence router explicitly says scores are routing-only (not calibrated):
   - `FridgeLuck.swiftpm/Capability/Core/Recognition/ConfidenceRouter.swift`
3. Vision pipeline already provides per-detection source and confidence:
   - `FridgeLuck.swiftpm/Capability/Core/Recognition/VisionService.swift`

So the missing piece is not data collection from scratch; it's confidence inference and policy.

## Recommended approach: Bayesian trust vector + rule gates

### 1) Dynamic trust vector (your original idea) as Beta posteriors

Track trust per component/context as `Beta(alpha, beta)`.

Examples of keys:

1. `vision:ingredient_id`
2. `ocr_exact:ingredient_id`
3. `ocr_fuzzy:ingredient_id`
4. `gemini_recipe_rerank`
5. `portion_estimator:food_class`

Posterior mean and uncertainty:

```text
mean = alpha / (alpha + beta)
uncertainty = sqrt(mean*(1-mean)/(alpha+beta+1))
```

This gives confidence + how sure you are about confidence.

### 2) No big labels needed: online reward from user actions

Convert existing behavior into fractional outcomes `r in [0,1]`.

1. Detection accepted unchanged: `r = 1.0`
2. Detection corrected to another ingredient: original gets `r = 0`, corrected mapping gets `r = 1`
3. Candidate recipe selected but with edits: `r = 0.4~0.8` based on edit distance
4. Portion heavily adjusted: lower portion estimator reward
5. Suggestion accepted (already tracked): `r = 1`; ignored/replaced: `r = 0`

Update rule:

```text
alpha <- decay(alpha) + r
beta  <- decay(beta)  + (1-r)
```

Use decay so old behavior does not dominate forever.

### 3) Instance confidence = raw signal x trust quality

For each signal:

```text
q_i = raw_i * trust_mean_i - k * trust_uncertainty_i
```

Then combine signals conservatively (geometric/product style), not by naive averaging.

### 4) Portion uncertainty without training a new model

Portion confidence should be interval-based, not point-guess confidence.

1. Produce `[g_low, g_mid, g_high]` via priors + visual cues.
2. Compute interval-width penalty:

```text
width_ratio = (g_high - g_low) / max(g_mid, eps)
portion_conf = clamp(1 - width_ratio)
```

3. If no scale/depth cues, force lower ceiling (e.g., max 0.65).

### 5) Macro confidence from provenance, not only model score

Compute a macro provenance score:

1. Ingredient coverage in nutrition DB.
2. Percent of grams from confirmed vs inferred ingredients.
3. Portion confidence.

If any of these weak, block "exact" claim.

## Policy modes (no trained classifier required)

Use hard safety gates + soft score.

### Hard-fail gates (immediate review/estimate)

1. Unknown ingredients > 20% of total mass.
2. Portion interval width > 60% of median.
3. Top-2 recipe candidates too close (ambiguous match).

### Mode decision

1. `exact`: only if hard gates pass and fused score high.
2. `review_required`: moderate score or one warning.
3. `estimate_only`: low score or hard fail.

This is robust and easy to explain to judges.

## How this integrates with Gemini Live

Gemini Live provides candidate outputs, but confidence layer owns the final claim level.

Runtime pipeline:

1. Gemini/tool outputs candidate detections/recipe/portion.
2. Confidence layer computes `assessment`.
3. Response formatter enforces policy:
   - may present exact macros,
   - or force review UI,
   - or show estimate with uncertainty.
4. User actions feed trust-vector updates.

So LLM helps generate hypotheses; confidence engine decides what is trusted.

## Why this is better for hackathon scope

1. No offline training pipeline required.
2. Uses real user-in-the-loop signal (credible technical story).
3. Demonstrates grounded, safety-aware agent architecture (judging advantage).
4. Can still evolve into learned calibrators later without architecture rewrite.

## Minimal implementation steps (next)

1. Add `confidence_signal_events` table (source, context_key, raw_score, outcome_reward, timestamp).
2. Add `trust_vector_state` table (key, alpha, beta, updated_at).
3. Implement `ConfidenceLearningService` with:
   - `assess(...)`
   - `recordOutcome(...)`
   - `mode(...)`
4. Wire into:
   - `ReverseScanService`
   - `RecommendationEngine`
5. Add UX labels:
   - Exact
   - Needs Review
   - Estimate

## Practical caveat

This still needs good UX instrumentation. If user edits are not captured at high-signal moments, trust updates will be noisy.

So the critical product move is: force clear confirmation/edit checkpoints where outcomes can be measured.
