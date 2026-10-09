# How usda_core connects to the rest of the repository

(Line numbers refer to this branch's head commit — the commit that adds this
fragment. Its tree is identical to base commit
`1151588d6bc6f5dcc3e848b6115813ff36ffbf0d` for every referenced source file;
this branch only adds content under `scripts/data/usda_core/.parts/` and
`scripts/data/usda_core/tests/`. Every claim below was verified by reading or
executing the code at that commit.)

## usda (CLI) — usda_core's only caller

`scripts/data/usda_core/` is an engine with no CLI of its own. Its **only
importer in the repository is the typer CLI `scripts/data/usda.py`**
(imports at `usda.py:11-23`; verified by grep over all tracked `*.py` outside
`.venv`). The package ships in the `fridgeluck-usda` distribution whose console
script `usda = "usda:main"` is defined at `scripts/data/pyproject.toml:19-20`
(`py-modules = ["usda"]` at :23, `packages.find.include = ["usda_core*"]` at
:26). After `cd scripts/data && uv sync`, the `usda` command and `uv run usda`
are interchangeable.

usda.py's own logic is three small helpers: `_load_queries`
(`usda.py:28-43` — merges `--query` terms with a `--query-file`, skips blanks
and `#` comments, dedupes case-insensitively keeping the first spelling),
`_api_key` (`usda.py:46-50` — `--api-key` flag wins, then the
`USDA_FDC_API_KEY` env var, else `typer.BadParameter`; see
[Environment](#packaging-env-and-cache-locations)), and `main`
(`usda.py:191-192`).

### The seven commands: command → core calls → outputs

| Command (usda.py) | usda_core calls | Output |
|---|---|---|
| `bootstrap-canonical` `usda.py:53-63` | `migrate.migrate_from_clean_json` → `io.save_canonical` | Writes the canonical JSON (default `config.CANONICAL_JSON`, `config.py:12`) from a legacy "clean" JSON |
| `fetch-candidates` `usda.py:66-113` | `cache_store.CacheStore` + `client_async.USDAAsyncClient` + `candidates.fetch_candidates`, then `utils.utc_now_iso` + `io.save_json` | Candidate JSON (default `config.CANDIDATE_DIR/"run_001.json"`, gitignored). Network + SQLite HTTP cache; `resolved_key = _api_key(api_key)` runs before any request (`usda.py:82`) |
| `export-batch` `usda.py:116-134` | `io.load_canonical`; optional `--candidates` file via `schema.CuratedIngredientRow.model_validate` (`usda.py:126-129`); `batches.export_batch` → `io.save_batch` | An editable 50-row batch JSON (default `config.REVIEW_BATCH_DIR/"manual_batch_001.json"`); `review_batches/manual_batch_001..021.json` already exist |
| `promote-batch` `usda.py:137-150` | `io.load_canonical` + `io.load_batch` + `promote.promote_batch` (`PromoteError` → `typer.BadParameter`) → `io.save_canonical` | Rewrites the canonical JSON in place, batch merged, macros frozen per fdc_id |
| `build-sqlite` `usda.py:153-161` | `io.load_canonical` + `build_sqlite.build_sqlite` | `config.DEFAULT_SQLITE_OUT` = `apps/ios/Resources/usda_ingredient_catalog.sqlite` (`config.py:14`) — a **git-tracked** file the iOS app bundles |
| `validate` `usda.py:164-177` | `io.load_canonical` + `validate.validate_catalog` (`ValidationError` → `typer.BadParameter`) | Prints `Validation OK` + stats; writes nothing |
| `report` `usda.py:180-188` | `io.load_canonical` + `report.build_report` + `report.write_report` | Markdown report (default `config.DEFAULT_REPORT_OUT`, gitignored) |

### End-to-end data flow

1. **Source of truth:** `scripts/data/catalog/usda_curated_ingredients.json`
   (800 rows today). Humans edit it only through batches; `promote.py` is the
   only writer besides `bootstrap-canonical`.
2. **Fetch (network):** `candidates.fetch_candidates`
   (`candidates.py:241-280`) expands query variants
   (`normalize_query_variants` `candidates.py:225-238`), ranks search hits per
   query (`_rank_fdc_ids_for_query` `candidates.py:283-305`, top 4 via
   `score_candidate` `:192-207` and `is_disallowed` `:210-222`), then fetches
   full details in chunks of 20 (`client_async.USDAAsyncClient.get_foods`
   `client_async.py:110-141`). `row_from_food` (`candidates.py:308-345`)
   converts FDC payloads to `CuratedIngredientRow`s: macros via
   `extract_macros`/`nutrient_value` (`candidates.py:63-73`, `:39-60`; sodium
   normalized mg→g via `as_grams=True` `candidates.py:72`, verified at runtime
   120 mg → 0.12 g); only `"Foundation"`/`"SR Legacy"` data types survive
   (`candidates.py:314`, `config.py:83`). Responses are cached in
   `scripts/data/.cache/usda_http_cache.sqlite` (`CacheStore`, cache keys are
   sha256 of the sorted request JSON, `client_async.py:44-47`).
3. **Review loop:** `export-batch` puts NEW candidates first (`batches.py:36-42`,
   skipping fdc_ids already in the canonical at `:37-39`), then fills the
   remainder with existing rows ranked by `quality_score` (`batches.py:9-23`,
   worst metadata first). A human edits the batch JSON (rows are full
   `CuratedIngredientRow`s; `action` is `upsert` or `drop`, `schema.py:110-115`)
   and runs `promote-batch`: `promote.py:20-46` re-infers missing sprite fields
   (`:26-29`, via `sprite_rules.py:7-18`), requires USDA provenance
   (`_assert_usda_provenance` `:14-17`), applies `drop`s (`:32-34`), and
   **freezes macros** for existing fdc_ids (`:36-42`, float compare with
   epsilon 1e-6 via `macros_equal` `schema.py:140-149`).
4. **Validate:** `validate.py:16-62` enforces strictly increasing fdc_id
   (`:24-27`), unique display names (`:33-36`), USDA verification_source
   (`:38-39`), non-empty aliases (`:41-45`), all 14 required search terms
   present in the corpus (`config.py:23-38`, matched against
   `row_to_search_text` `schema.py:126-133`), and a JSON round-trip
   determinism check (`:52-56`). Current output: `Validation OK`,
   record_count 800, unique_alias_count 3919, required_terms 14.
5. **Build:** `build_sqlite.py:15-32` renders the canonical to SQLite
   atomically (temp file + `os.replace`). Three tables: v2
   `ingredient_catalog` (`:38-68`), v1-compatible `ingredients` (`:70-92`;
   **`ingredients.id` = fdc_id** at `:159`), `ingredient_aliases` (`:94-104`;
   aliases lowercased at `:175-179`). `normalized_name` is the lowercased
   display name (`:107`), sprite_group fallback is re-inferred (`:110-111`),
   provenance is folded into `notes` (`:112-115`).
6. **iOS runtime:** see next section.

### iOS consumer side (which Swift code reads which tables)

- The bundle `apps/ios/Resources/usda_ingredient_catalog.sqlite` is
  **committed to git** (`git ls-files` confirms; ~1.8 MB at the base commit).
- **Hydration:** `BundledDataLoader.ensureUSDACatalogHydrated`
  (`apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift:185-226`)
  locates the bundle by resource name (`:188`), computes a size+mtime marker
  (`catalogMarker`, `BundledDataLoaderUSDACatalog.swift:127-132`), and
  re-imports when the marker changed, when the app DB has fewer than 300
  ingredients (`minimumExpectedCatalogIngredientCount`,
  `BundledDataLoader.swift:103`), or when aliases are empty (`:202-205`).
- **Import:** `BundledDataLoaderUSDACatalog.loadUSDACatalogIngredientsIfAvailable`
  (`BundledDataLoaderUSDACatalog.swift:7-125`) opens the bundle **read-only**
  (`:13-15`), SELECTs from **`ingredients`** (`:20-36`, with a fallback SELECT
  for older bundles lacking display columns `:41-58`), joins
  **`ingredient_aliases`** to ingredients inside the bundle (`:65-69`), then
  `INSERT OR IGNORE`s into the app DB's own tables (`:78-100`, `:117-123`) —
  without the `id` column, so the app assigns fresh rowids and maps by unique
  name (`:101-106`). Aliases are lowercased again on import (`:122`). The
  app-side tables come from migrations `v1_initial`
  (`apps/ios/Platform/Persistence/Database/Migrations.swift:23`) and
  `v4_ingredient_aliases` (`:166-167`); hydration state lives in
  `usda_catalog_state` (`v7_usda_catalog_state`, `Migrations.swift:213-214`).
- **Lookup:** `IngredientCatalogResolver`
  (`apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift`)
  resolves user text against the **app DB**: exact name (`:82-94`) → exact
  alias (`:96-109`) → prefix name (`:111-123`) → prefix alias (`:125-138`),
  each `LIMIT 2` with ambiguity returning nil (`uniqueMatch` `:140`);
  `resolveFromText` (`:48-65`) slides windows of up to 3 tokens,
  longest first.
- **The v2 `ingredient_catalog` table is read by NO Swift code.** Every
  `ingredient_catalog` match in `apps/ios/**/*.swift` is the bundle resource
  *filename* `usda_ingredient_catalog` (`BundledDataLoader.swift:188`,
  `BundledDataLoaderUSDACatalog.swift:8`); greps for
  `FROM|INTO|TABLE ingredient_catalog` return nothing. Runtime reads are
  exclusively `ingredients` and `ingredient_aliases`. The v2 table is forward
  staging (`search_text`, `alt_names_json`, full provenance) that is populated
  on every build; per-table page sizes in the built bundle: `ingredient_catalog`
  716,800 B + `idx_catalog_search` 290,816 B vs `ingredients` 327,680 B —
  i.e. over half the file is the unread table plus its search index.

### Legacy v1 scripts

`scripts/data/fetch_usda_ingredient_nutrition.py` (55 KB) and
`scripts/data/generate_usda_ingredient_swift_static.py` are the pre-v2,
standalone pipeline and **do not import usda_core** (verified by grep and by
AST in `usda_core/tests/p09_test_integration.py`). The former reads
`apps/ios/Resources/data.json`, queries FDC with urllib + ThreadPoolExecutor
and an optional *third-party* `usda_fdc` package (`:29-33` — unrelated to
usda_core), and writes
`apps/ios/Resources/usda_ingredient_nutrition_compact.json`; the latter
(stdlib-only) renders that compact JSON into the generated Swift file
`apps/ios/Platform/Persistence/Static/USDAIngredientNutritionStaticData.swift`
(its `DEFAULT_SWIFT`, `:10`; the file exists and is referenced). They duplicate
the FDC endpoint constants (`fetch_usda_ingredient_nutrition.py:37-40`) and run
outside the uv-managed package — treat them as frozen v1 tooling.

### Packaging, env, and cache locations

- `scripts/data/pyproject.toml` defines the distribution; deps are httpx, typer,
  pydantic, orjson, filelock, tenacity (`:10-16`); Python >= 3.11.
- `USDA_FDC_API_KEY` is documented in the repo-root `.env.example` (line 1) and
  resolved by `usda._api_key` (`usda.py:46-50`).
- `scripts/data/.cache/` is gitignored (repo `.gitignore:53-54`) and holds the
  HTTP cache `usda_http_cache.sqlite` (`config.py:13`; tables `food_cache` /
  `search_cache`, `cache_store.py:28-42`), candidates (`config.py:10`), and the
  report (`config.py:15`).
- Tracked artifacts: canonical JSON, `review_batches/manual_batch_001..021.json`,
  and the built bundle sqlite. `scripts/data/usda_manual_overrides.json` (22 KB,
  tracked) is referenced by **no code** (greps over `*.py`, README, and Swift
  return nothing) — likely consumed manually or orphaned.
- All default paths are anchored at the repo root via
  `ROOT = Path(__file__).resolve().parents[3]` (`config.py:5`), so CLI defaults
  work from any cwd — with one exception, flagged below.

### CI reality

The repository's only workflow is `.github/workflows/ios-ci.yml` (iOS build +
test and an advisory Periphery scan on macos-26); it contains **no Python
steps**. There is no Python CI — the checks below run locally and are the only
automated-style verification of this package. `usda_core/tests/` (added by this
fleet) pins the integration contracts: CLI wiring, config-vs-defaults equality,
the bundle↔Swift reader contract, review-loop invariants, and legacy-script
independence (`usda_core/tests/p09_test_integration.py`).

### Gotchas and traps

1. `bootstrap-canonical --from-clean` defaults to the **cwd-relative** literal
   `Path("scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json")`
   (`usda.py:55-57`), unlike every other default. Run it from the repo root or
   pass the flag explicitly (the README example passes it, e.g.
   `--from-clean .cache/...` from `scripts/data`).
2. Rebuilding the bundle changes its size+mtime marker → every device
   re-imports at next launch (`BundledDataLoaderUSDACatalog.swift:127-132`,
   `BundledDataLoader.swift:202-205`). `INSERT OR IGNORE` keeps that idempotent
   but not free.
3. The bundle's `ingredients.id` is fdc_id (`build_sqlite.py:159`), but the
   **app DB's** `ingredients.id` is a fresh rowid — ids from the two databases
   are different spaces; the unique `name` is the real join key
   (`BundledDataLoaderUSDACatalog.swift:101-106`).
4. The HTTP cache has no TTL or eviction: `updated_at` is stored but never
   consulted (`cache_store.py:46-51`, `:66-84`). Delete the sqlite to force a
   refetch. The API key is still required even for a fully cached run
   (`usda.py:82`).
5. Aliases are lowercased at build (`build_sqlite.py:178`) and again on iOS
   import (`BundledDataLoaderUSDACatalog.swift:122`) — the alias space is
   case-insensitive by construction.
6. The macro freeze is one-way: macros of an existing fdc_id can never change
   through `promote-batch` (`promote.py:36-42`) — the batch fails with
   `PromoteError` → `typer.BadParameter`.
7. `export-batch` silently skips candidate rows whose fdc_id already exists
   (`batches.py:37-39`); "missing" candidates are usually duplicates, not fetch
   failures.
8. `validate` requires *strictly increasing* fdc_id (`validate.py:24-27`) —
   unsorted and duplicate ids fail with the same "strictly sorted" message;
   `promote-batch` and `migrate` sort for you (`promote.py:45`,
   `migrate.py:69`).
9. Macros are rounded to 4 decimals by the schema (`schema.py:36-39`) and sodium
   is stored in **grams** (mg→g at fetch, `candidates.py:53-58`, `:72`) — don't
   compare raw USDA mg values against `sodium_g`.
10. `IngredientCatalogResolver` returns nil on ambiguity on purpose
    (`LIMIT 2` + `uniqueMatch`) — a broad alias matching two rows resolves to
    nothing and falls back to curated data.
11. Only `"Foundation"` and `"SR Legacy"` rows pass `row_from_food`
    (`candidates.py:314`, `config.py:83`); branded FDC hits are also penalized
    in scoring (`candidates.py:205-206`), so candidate JSONs are intentionally
    thin on branded foods.

### Flagged inconsistencies (verified; NOT fixed on this branch)

1. `scripts/data/usda.py:55-57` — the `--from-clean` default is a cwd-relative
   literal while all other defaults are repo-root-anchored (`config.py:5-15`).
   Running `usda bootstrap-canonical` from `scripts/data/` resolves it to the
   nonexistent `scripts/data/scripts/data/.cache/...`. Safe fix would be
   `config.CACHE_DIR / "usda_cooking_ingredient_catalog_clean.json"`, but that
   is a behavior change in a file this part does not own.
2. `scripts/data/usda_core/build_sqlite.py:38-68`, `:116-149` — the v2
   `ingredient_catalog` table is created and fully populated on every build but
   read by no Swift code (see iOS section). It plus `idx_catalog_search` are
   ~1.0 MB of the ~1.8 MB tracked bundle. Dropping it would shrink the app, but
   it is presumably staged for a future reader — a product decision, and
   "changes generated data outputs" is out of bounds for doc parts.
3. `scripts/data/usda_core/validate.py:29-31` — the "Duplicate fdc_id" branch is
   unreachable: any duplicate also violates the strictly-increasing check at
   `:25-27`, which raises first. Harmless belt-and-braces, but don't rely on it
   firing with the "duplicate" message.
4. `scripts/data/usda_core/candidates.py:249-254` — rows fetched via
   `--fdc-id` are stored in `out_by_id` keyed by the *requested* id while the
   row itself carries the payload's `fdcId` (`:309`); `client_async.py:107`
   caches single-food responses under the requested id. If FDC ever returned a
   detail under a different id, keys and row ids would diverge (dedupe-only
   impact today, since the returned list uses values).
5. `scripts/data/usda_core/candidates.py:106` — the herb_spice keyword list
   matches "pepper" before the vegetable list at `:108`, so bell pepper is
   categorized `herb_spice` (verified at runtime) even though
   `DISTINCT_SPRITE_KEYS` gives bell pepper its own sprite (`config.py:64`).
   Heuristic choice, but surprising when curating produce.
6. `scripts/data/usda_manual_overrides.json` — tracked 22 KB JSON referenced by
   no code (see Packaging section). Either consume it, document its process, or
   remove it; as-is it invites confusion with `review_batches/`.

### Verify locally

```bash
cd scripts/data
uv sync
# Note: the fleet's test files are named pXX_test_*.py, which does NOT match
# pytest's default python_files patterns (test_*.py, *_test.py). Pass the file
# explicitly, or add -o python_files='p*_test*.py' / a pytest.ini once the
# orchestrator standardizes this:
uv run --with pytest python -m pytest usda_core/tests/p09_test_integration.py -q
uv run usda validate --canonical catalog/usda_curated_ingredients.json
uv run usda build-sqlite --canonical catalog/usda_curated_ingredients.json --out /tmp/usda_check.sqlite
```
