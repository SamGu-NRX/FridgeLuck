# USDA Data Pipeline v2

This pipeline is JSON-canonical and non-circular:

1. Curate ingredients in a tracked canonical JSON file.
2. Build app SQLite deterministically from that canonical file.
3. Keep USDA fetch/cache artifacts in `.cache` only.

## Canonical Files

- Canonical catalog: `scripts/data/catalog/usda_curated_ingredients.json`
- Review batches: `scripts/data/review_batches/manual_batch_*.json`
- Generated SQLite: `FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite`
- HTTP cache DB: `scripts/data/.cache/usda_http_cache.sqlite`

## Setup (uv)

```bash
cd scripts/data
uv sync
```

## Commands

### 1) Bootstrap canonical from existing clean JSON (one-time)

```bash
uv run usda bootstrap-canonical \
  --from-clean .cache/usda_cooking_ingredient_catalog_clean.json \
  --canonical catalog/usda_curated_ingredients.json
```

### 2) Fetch USDA candidates (async + bounded concurrency)

```bash
set -a; source ../../.env; set +a
uv run usda fetch-candidates \
  --query-file .cache/missing_terms.txt \
  --out .cache/candidates/run_001.json
```

### 3) Export 50-row editable batch

```bash
uv run usda export-batch \
  --batch-id 1 \
  --batch-size 50 \
  --candidates .cache/candidates/run_001.json \
  --out review_batches/manual_batch_001.json
```

### 4) Promote edited batch into canonical JSON

```bash
uv run usda promote-batch \
  --in review_batches/manual_batch_001.json \
  --canonical catalog/usda_curated_ingredients.json
```

### 5) Validate canonical data

```bash
uv run usda validate --canonical catalog/usda_curated_ingredients.json
```

### 6) Build app SQLite

```bash
uv run usda build-sqlite \
  --canonical catalog/usda_curated_ingredients.json \
  --out ../../FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite
```

### 7) Generate report

```bash
uv run usda report \
  --canonical catalog/usda_curated_ingredients.json \
  --out .cache/usda_pipeline_report.md
```

## Macro Freeze Policy

- Macro fields (`calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sodium_g`) are immutable for existing `fdc_id` rows.
- New rows must include USDA provenance in `source_meta.verification_source`.
- Aliases, category labels, sprite metadata, and descriptions are editable via review batches.

Use `uv run usda ...` directly for all USDA data workflow steps.
