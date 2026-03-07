# Confidence Calibration Data Plan (Bayesian Trust Vectors)

## Objective
Calibrate confidence for reverse scan, recipe generation, and macro estimation so deterministic mode is only used when evidence is strong.

## What to Collect Per Scan Event
- `event_id`, `user_id_hash`, `timestamp`, `device_model`, `app_version`
- Input metadata: photo count, image size, lighting estimate, blur estimate
- Detection outputs:
  - top ingredient predictions with raw model scores
  - OCR tokens and OCR confidence
  - portion estimate and confidence
  - macro estimate and confidence
- Candidate recipe outputs:
  - top-k recipe ids, ranking scores, explanation
  - whether cloud re-ranker was used
- Confidence engine outputs:
  - per-signal raw/adjusted score
  - trust mean/uncertainty for each signal
  - final mode (`exact`, `review_required`, `estimate_only`)

## Outcome Labels (No Large Pre-Labeled Dataset Required)
Use product interactions as weak labels:
- Ingredient accepted without edit: positive signal outcome
- Ingredient corrected/deleted: negative signal outcome
- Recipe accepted/cooked: positive recipe-match outcome
- User overrides portion/macros heavily: negative portion/macro outcome
- Logged meal + no correction after review window: delayed positive outcome

## Bayesian Trust Vector Signals to Track
- `reverse_scan.vision_detection`
- `reverse_scan.recipe_match`
- `reverse_scan.margin_separation`
- `reverse_scan.portion_estimation`
- `reverse_scan.macro_alignment`
- `reverse_scan.gemini_rerank`

For each signal maintain Beta posterior (`alpha`, `beta`):
- `mean = alpha / (alpha + beta)`
- uncertainty penalty from posterior variance
- decay old evidence slowly (already implemented) so model can adapt

## Data Sources to Scrape / Ingest
### Nutrition Ground Truth
- USDA FoodData Central API for authoritative nutrient values and serving references.
- Open Food Facts for packaged products, barcode-linked metadata, and ingredient strings.

### Shelf Life / Storage Rules
- USDA FSIS refrigerator/freezer storage guidance (for spoilage confidence priors).

### Vision / Portion Benchmarking Datasets
- Nutrition5k (food + portion contexts)
- Recipe1M+ (ingredient-recipe relationships)
- Food segmentation/classification datasets (for robustness checks)

## Calibration Procedure
1. Log confidence snapshots daily by signal (`event_count`, avg score, avg reward, avg abs error).
2. Compute calibration buckets (0.0-0.1, 0.1-0.2, ... 0.9-1.0): compare predicted confidence vs empirical success.
3. If overconfident, increase uncertainty penalty and/or lower deterministic threshold.
4. If underconfident with high agreement outcomes, relax thresholds slightly.
5. Re-run synthetic replay tests before shipping threshold changes.

## Minimum Offline Evaluation Set You Should Build
- 1,000 fridge/pantry photos across lighting/device conditions
- 300 plated-meal reverse-scan photos with known recipes
- 200 packaged-food OCR/barcode examples
- 300 portion-heavy examples (small/medium/large serving variance)

## Metrics to Track
- Ingredient top-1 / top-3 accuracy
- OCR token precision/recall for food entities
- Recipe recommendation acceptance@k
- Macro absolute error per meal (kcal/protein/carbs/fat)
- Calibration error (ECE) by signal and globally
- Deterministic mode precision (must stay very high)

## Deployment Rules
- Deterministic mode only when:
  - no hard fail reasons
  - min signal adjusted score above threshold
  - trust uncertainty below threshold
- Fallback to review mode when uncertainty is high.
- Use local-only path only when confidence is very high or network unavailable.

## References
- USDA FoodData Central: https://fdc.nal.usda.gov/api-guide
- Open Food Facts API: https://openfoodfacts.github.io/openfoodfacts-server/api/
- USDA FSIS Storage Charts: https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/refrigeration-and-food-safety
- Google GenAI JS SDK (`@google/genai`): https://github.com/googleapis/js-genai
