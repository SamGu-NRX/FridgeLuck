# Grocery label OCR benchmark — method

Evaluates FridgeLuck's production packaged-food recognition pipeline over a
reproducible, stratified sample of Open Food Facts (OFF) product images, entirely
on Linux, with the iOS Vision recognition arm replayed from pre-extracted OCR
lines. Licensing: OFF data is ODbL (attribution + share-alike for the database);
this experiment derives metrics and code only — no OFF content is committed.

## What is evaluated

The OCR arm of `VisionService.scan` on branch `obv/fl-next-grocery-ocr`:
per OCR line, `IngredientLexicon.resolveFromTextDetailed` (exact synonym phrase or
fuzzy token, 0.90 / 0.60), then `IngredientCatalogResolver` sliding-window
matching (fuzzy, 0.55), per-ingredient deduplication by confidence and source
priority, and `ConfidenceRouter` buckets (auto ≥0.70, confirm ≥0.50 for exact /
≥0.55 for fuzzy, else possible). The classification arm and barcode detection are
NOT replayed — this benchmark measures text recognition against the USDA catalog.

The harness compiles the production sources directly (symlinks):
`IngredientLexicon.swift`, `IngredientCatalogResolver.swift`, `ConfidenceRouter.swift`,
`ScanContracts.swift` — all on this branch, plus `FeatureLogic/Benchmark/*` for
`ScanRequestFailure`. On Linux, `CoreGraphics` geometry comes from Foundation
(Swift 6.4); the shim provides only the opaque `CGImage`. `@testable import
FridgeLuck` exposes internal production types to the executable, so the harness
must be built in debug (default `swift build`), not `-c release`.

## Data

Deterministic sampler (`acquisition/sample_products.py`, DuckDB over the OFF
product-database parquet, snapshot 2026-06, `main` branch of the HF dataset —
pinned by content hash of the manifest + image hashes at first successful run):

- Universe: 13-digit EAN codes, non-obsolete, front image present, modified since
  2017, product name available in `main` or `en`.
- Schema note (probed 2026-10-09): `product_name`/`generic_name`/`ingredients_text`
  are LIST of STRUCT(lang, text); `nutriments` and `images` are struct lists;
  tag columns are LIST(VARCHAR). Name extraction prefers `en` for ingredient
  text and `main` for names.
- Strata (evaluated in order; specialized take precedence), targets sum to 29 500
  with MAX_PER_STRATUM=800 cap:
  trace_warning 1500 · parenth_subing 2000 · percent_subing 2000 ·
  short_simple 4000 · short_parenth 3000 · mid_comma 8000 · long_comma 5000 ·
  name_only 3000 · nonfood_control 250 (from the beauty.parquet universe).
- Split: within each stratum, salted-shuffle then first 15% → `dev`, rest `test`.
  Dev may be used while iterating; test totals are the reported numbers. The
  nonfood controls are dev-only by design.
- Selection is blind: the salted hash orders candidates before any fetch; the
  manifest is written once and frozen.

Images are fetched at role-specific size preference (front: 1000/full/400;
ingredients: full/1000/400; nutrition: 1000/full/400), highest revision per key,
and pinned by SHA-256 in `image_hashes.csv`.

## Arms

1. **ocr_front / ocr_ingredients / ocr_nutrition** — Tesseract 5.5.0 line boxes
   (`acquisition/ocr_baseline.py`) → harness OCR replay. Tesseract is a stand-in
   for Apple Vision OCR: same input contract (lines + pixel geometry + image
   dims), weaker recognizer. Cross-engine deltas are attributed to the OCR
   engine, not the recognition pipeline; production deltas require device Vision
   traces (out of scope here).
2. **reference** — OFF `ingredients_text` split into items and fed through the
   same recognition pipeline (no OCR). Upper-bounds the recognition layer and
   shows what OCR quality costs.

## Targets and scoring

Target tiers are derived per product by the harness itself
(`acquisition/prepare_inputs.py` emits, harness `--mode targets` resolves):

- **primary** (the packaged item): product name, brand-stripped product name,
  generic name.
- **context** (never the packaged item): last `categories_tags` leaf
  (e.g. `en:tomato-ketchups`).
- Ingredient-list text is never a target.

Metrics per arm × split × stratum (`acquisition/score.py`):

- **item_hit_rate** — share of products with ≥1 primary target whose detections
  include a primary id. The headline number.
- **false_foods_per_case** — mean detections per product that resolve to neither
  primary nor context ids.
- **nonfood_trigger** — share of nonfood controls producing any detection.
- **buckets** — auto/confirm/possible distribution of detections.
- **outside_curated** — detections with ids outside the 50-id curated lexicon
  space (catalog-only territory; seeds lexicon growth).
- **no_target_cases** — products whose name variants resolve to nothing (target
  derivation ceiling, not pipeline failure; item_hit_rate excludes them).

**CER/WER: null by design.** No defensible transcription gold exists in this
run — scoring OCR output against OFF's own `ingredients_text` would measure
Tesseract-vs-crowd-transcription agreement, not recognition accuracy. CER/WER
requires device Vision traces or manual transcription; the harness accepts them
as input when available.

## Assumptions (provisional, documented)

- A product's identity for inventory purposes is its primary-target set; the
  category leaf is context only. Misparsed multi-pack names (e.g. "6 pack
  yogurts x4") may weaken primary targets; the no_target_cases counter exposes
  the ceiling.
- `main`-language ingredient text is acceptable when no `en` entry exists;
  `split_items` line-splitting approximates the intake parser's fragmenting.
- Nonfood controls (beauty products) approximate non-food packaging: any
  detection counts as a trigger, regardless of id.
- Tesseract line geometry from its TSV is close enough to Vision's line boxes
  for bounding-box normalization checks; no pixel metrics are reported.

## Reproduce

```
bash experiments/grocery-ocr/acquisition/run_experiment.sh
```

Steps: sample → fetch images (resumable) → tesseract → prepare inputs →
`swift test` (equivalence vectors) → harness (targets/ocr/reference) → score.
All outputs land in `experiments/grocery-ocr/data/` (not committed except the
manifest, universe counts, and image hashes, which are the pinned record).
