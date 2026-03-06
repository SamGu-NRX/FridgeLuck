# Confidence Engine Spec for Gemini Live Smart Fridge

Last updated: 2026-03-04 (America/Chicago)

## Direct answer: model vs prompt vs hybrid

This should be a **hybrid confidence system**:

1. **Not prompt-only**: prompt instructions cannot guarantee calibration or error control.
2. **Not one monolithic model**: one score from one model is too brittle across tasks.
3. **Hybrid** = calibrated task-level estimators + deterministic policy gates + runtime abstention.

Gemini Live remains the planner/tool caller, but confidence is computed by a dedicated module that can overrule agent output claims.

## Problem decomposition

You need confidence for four different uncertainty types:

1. **Ingredient detection confidence** (is ingredient X actually present?).
2. **Ingredient amount/portion confidence** (how many grams?).
3. **Recipe-match confidence** (does meal correspond to recipe R?).
4. **Macro confidence** (how reliable are macro totals, especially when ingredient nutrition is missing or substituted?).

Treat each as a separate estimator, then fuse.

## Core data contract

```ts
export type ConfidenceMode = "exact" | "review_required" | "estimate_only";

export interface TaskConfidence {
  score: number;                 // calibrated probability-like score [0,1]
  interval?: [number, number];   // uncertainty interval if applicable
  reasons: string[];             // machine-readable reasons
}

export interface ConfidenceAssessment {
  detection: TaskConfidence;
  portion: TaskConfidence;
  recipeMatch: TaskConfidence;
  macro: TaskConfidence;
  overallScore: number;
  mode: ConfidenceMode;
  deterministicReady: boolean;
}
```

## How to build each confidence estimator

### 1) Detection confidence (ingredient-level)

Inputs:

1. Vision model confidence (local detector).
2. OCR match confidence + exact/fuzzy flag.
3. Gemini extraction agreement (ingredient set overlap).
4. Temporal agreement across adjacent frames (for live stream).

Implementation:

1. Build correctness labels from user confirmation logs.
2. Fit a post-hoc calibrator per source (`vision`, `ocr_exact`, `ocr_fuzzy`) using temperature scaling or isotonic regression.
3. Fuse source probabilities with agreement features in a lightweight meta-model (logistic regression/GBDT).

Output:

- `p_detect_correct(ingredient_i)`

## 2) Portion confidence (grams)

This is the hardest part and should not be faked.

Inputs:

1. Segmentation quality score.
2. Depth availability/quality (if ARKit LiDAR or RGB-D available).
3. Plate/bowl scale estimate quality.
4. Food density prior variance for ingredient class.
5. User-provided portion adjustments.

Implementation:

1. Predict grams with a regressor and quantile bounds (P10/P50/P90).
2. If no depth/scale signal, widen interval and lower confidence hard.
3. Confidence score derived from normalized interval width and data quality features.

Output:

- `portion.interval = [g_low, g_high]`
- `portion.score = 1 - normalized_interval_width` (after calibration)

## 3) Recipe-match confidence

Inputs:

1. Required-ingredient coverage ratio.
2. Missing-required count.
3. Optional coverage.
4. Similarity between observed ingredient set and recipe ingredient set.
5. Gemini reranker score (as a feature, not final authority).

Implementation:

1. Train binary classifier: "selected recipe was accepted by user without major edits".
2. Calibrate classifier probability.
3. Use top-1/top-2 margin as ambiguity penalty.

Output:

- `p_recipe_match_correct`

## 4) Macro confidence

Two branches:

1. **Deterministic branch**: all ingredients mapped to known nutrition rows + confirmed grams.
2. **Fallback branch**: any unknown ingredient requires substitution/imputation.

Implementation:

1. Deterministic branch score near 1.0, penalized by portion uncertainty.
2. Fallback branch uses substitution uncertainty from nearest-category nutrition stats.
3. Track and calibrate residual error from historical corrected logs.

Output:

- `p_macro_within_tolerance` (for tolerance, e.g., +/-10%)

## Fusion and gating

Use a conservative fusion (geometric mean + penalty terms):

```text
overall = exp(
  w_d*log(max(eps, detection.score)) +
  w_p*log(max(eps, portion.score)) +
  w_r*log(max(eps, recipeMatch.score)) +
  w_m*log(max(eps, macro.score))
) - oodPenalty - contradictionPenalty
```

Default weights (start):

1. `w_p = 0.35` (portion dominates macro reliability)
2. `w_m = 0.30`
3. `w_d = 0.20`
4. `w_r = 0.15`

Mode policy:

1. `exact` if `overall >= tau_exact` and portion interval narrow enough.
2. `review_required` if `tau_review <= overall < tau_exact`.
3. `estimate_only` if below `tau_review`.

## Conformal wrapper (optional but strong)

After base scoring, add conformal risk control on a held-out calibration set from real user-confirmed events.

Goal:

1. Bound error rate for `exact` mode (distribution-free finite-sample style guarantee).
2. Dynamically adapt thresholds as data drifts.

Practical usage:

1. Keep rolling calibration window (latest N confirmed events).
2. Compute nonconformity on prediction errors.
3. Set `tau_exact` from target risk (e.g., <=5% high-confidence mistakes).

## Gemini Live integration pattern

Gemini Live should call tools; tool outputs include uncertainty; confidence module decides what can be claimed.

```ts
// Tool output from reverse scan
{
  candidateRecipes: [...],
  ingredientMassEstimates: [...],
  uncertaintySignals: {
    detector: {...},
    portion: {...},
    retrieval: {...},
    macroFallback: {...}
  }
}
```

Runtime guard:

1. Agent drafts response.
2. `confidenceAccessor.assess(...)` runs.
3. Response is rewritten/blocked if it violates confidence policy.
4. Only confidence-safe output is sent to user.

This is where "confidence wrapper" actually lives: **outside the prompt**, in executable policy code.

## Why prompt-only confidence is insufficient

1. LLM self-reported confidence is often miscalibrated under distribution shift.
2. Research shows softmax/probability-like scores alone are overconfident OOD.
3. You need a learned/calibrated abstention policy and user-confirmation loop.

## Calibration and evaluation metrics

Track these continuously:

1. ECE (Expected Calibration Error) for detection and recipe-match classifiers.
2. Brier score for probabilistic correctness estimates.
3. Coverage-at-risk for abstention policy ("what fraction auto-approved at <=X error").
4. Portion MAE and macro MAE against corrected/ground-truth entries.
5. Edit distance from auto result to user-confirmed final result.

## Incremental implementation plan

### Phase 1 (fast)

1. Add structured uncertainty signals to every tool output.
2. Add rule-based conservative gating with existing heuristics.
3. Log outcomes + user edits for training data.

### Phase 2 (real confidence)

1. Train per-task calibrators (isotonic/temperature scaling).
2. Add meta-classifier for overall correctness likelihood.
3. Start using calibrated probabilities in gates.

### Phase 3 (strong reliability)

1. Add conformal thresholding for `exact` mode.
2. Add drift monitoring and threshold auto-tuning.

## Source references

1. On calibration and temperature scaling:
   - https://proceedings.mlr.press/v70/guo17a.html
2. Selective abstention under domain shift (softmax overconfidence issue):
   - https://aclanthology.org/2020.acl-main.503/
3. Hallucination uncertainty via semantic entropy:
   - https://www.nature.com/articles/s41586-024-07421-0
   - https://arxiv.org/abs/2303.08774
4. Conformal prediction intro:
   - https://arxiv.org/abs/2107.07511
5. Conformal language modeling:
   - https://research.google/pubs/conformal-language-modeling/
6. Nutrition5k (portion/nutrition with RGB-D + mass labels):
   - https://arxiv.org/abs/2103.03375
   - https://github.com/google-research-datasets/Nutrition5k
7. Gemini logprobs support fields (`responseLogprobs`, `logprobsResult`):
   - https://ai.google.dev/api/generate-content
8. Gemini Live tool-calling loop requirements:
   - https://ai.google.dev/gemini-api/docs/live-tools
