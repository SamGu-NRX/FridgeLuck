## build_sqlite

All `path:line` references below are **final line numbers on the p05 branch head**
(branch `obv/gend-fridgeluck-scripts-data-usda-core--p05`; the exact commit sha is
recorded in the p05 final report — `build_sqlite.py` reached its final content in
that commit, so the numbers are stable for the whole branch).

### What this module is

`scripts/data/usda_core/build_sqlite.py` is the **last build stage of the USDA
ingredient pipeline**: it turns the canonical catalog JSON into the single SQLite
file that the iOS app bundles and reads. Why it exists as its own module: the
catalog is a human-edited JSON document (800 rows at the base commit), while the
app needs a queryable database with two denormalized schemas inside; keeping the
JSON→SQLite materialization separate lets `usda validate` gate the JSON and this
module own the physical layout.

### Data flow

```
catalog/usda_curated_ingredients.json          (input, maintained by promote.py)
  │  load_canonical() -> CanonicalCatalog      (usda_core/schema.py)
  ▼
usda build-sqlite  =  usda.py cmd_build_sqlite (scripts/data/usda.py:153-161)
  ▼
build_sqlite()                                 (usda_core/build_sqlite.py:53)
  │  FileLock + temp file + os.replace         (build_sqlite.py:121-130)
  ▼
_build_sqlite_file()                           (build_sqlite.py:139)
  │  per row, sorted by fdc_id                 (build_sqlite.py:255)
  │  helpers: schema.row_to_search_text, sprite_rules.infer_sprite_group
  ▼
apps/ios/Resources/usda_ingredient_catalog.sqlite   (output, bundled by the app)
```

The CLI is the only importer of this module (`from usda_core.build_sqlite import
build_sqlite`, scripts/data/usda.py:12).

### Main functions

**`build_sqlite(catalog, out_path)` — `scripts/data/usda_core/build_sqlite.py:53`** (public)
The entry point. Creates `out_path`'s parent directories, takes an exclusive
`filelock.FileLock` on `str(out_path) + ".lock"` (line 121), builds the whole
database in a `NamedTemporaryFile` in the same directory (line 124), and moves it
into place with `os.replace` (line 128) — readers never see a half-written file.
On failure the temp file is removed and the existing output is untouched. The
lock file is unlinked after release (lines 132-137, see gotchas). Raises
`sqlite3.Error` (e.g. duplicate `fdc_id`) and `OSError` (filesystem). Deterministic:
the same catalog builds a byte-identical file (verified by sha256; asserted in
`tests/p05_test_build-sqlite.py::test_build_is_byte_deterministic`).

**`_build_sqlite_file(catalog, out_path)` — `scripts/data/usda_core/build_sqlite.py:139`** (private)
Creates all three tables and indexes from scratch (`CREATE TABLE` without
`IF NOT EXISTS`, so a second call on a populated file raises
`OperationalError`), then walks `catalog.records` sorted by ascending `fdc_id`
(line 255) and inserts every row into BOTH schemas. Tables:

| Table | Created | Key columns | Read by Swift? |
|---|---|---|---|
| `ingredient_catalog` (v2) | :189 | `id` = surrogate 1..N in fdc_id order; `fdc_id` UNIQUE; `normalized_name`, `search_text`, `alt_names_json`, provenance | **No** (see below) |
| `ingredients` (legacy) | :221 | `id` = the row's `fdc_id` itself; `name` = raw display_name | Yes |
| `ingredient_aliases` (legacy) | :245 | `ingredient_id` → `ingredients.id`; `alias` lowercased | Yes |

Indexes: `idx_catalog_display_name`/`idx_catalog_category`/`idx_catalog_search`
(lines 215-217) and `idx_ingredient_aliases_alias` (line 253).

Per-row details (lines 255-327):
- `normalized_name` = `display_name.strip().lower()` (line 256) — see gotchas.
- Sprite backfill (lines 258-260): if `sprite_group` is empty or `"other"` and
  `category_label` is not `"other"`, substitute
  `sprite_rules.infer_sprite_group(category_label)` — applied to a **local
  variable** used by both inserts; the in-memory catalog is never mutated.
- `ingredients.notes` (line 261) is synthesized as
  `"source=<data_type>; food_category=<food_category>; verified=<verified_at_utc>; source_system=<verification_source>"`;
  `typical_unit`/`storage_tip`/`pairs_with` stay `NULL`.
- `alt_names` → `ingredient_aliases` rows (line 326) with `.lower()` and
  `INSERT OR IGNORE`; the v2 table stores the same list as `alt_names_json`
  (line 283, `json.dumps(..., ensure_ascii=True)`).

### Consumers (verified at base commit 1151588)

**Known limitation — the v2 table is written today, read tomorrow.** No Swift
code reads the `ingredient_catalog` *table*. The only grep hits for
`ingredient_catalog` in `apps/ios` are the resource *filename*
(`usda_ingredient_catalog.sqlite`) in
`apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift:188` and
`apps/ios/Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift:8`.
The table exists so a future app migration can adopt the v2 schema without
another pipeline format change.

The tables the app actually consumes:
- `BundledDataLoaderUSDACatalog.swift:8-70` opens the bundled file **read-only**
  and `SELECT`s from `ingredients` (with a fallback query when
  description/category columns are missing); lines 103-119 copy rows and
  `INSERT OR IGNORE INTO ingredient_aliases` into the app's runtime database.
- `BundledDataLoader.swift:188-216` locates the resource and counts
  `ingredients`/`ingredient_aliases` rows.
- `IngredientCatalogResolver.swift:72-131` queries `ingredients` and
  `ingredient_aliases` at recognition time — but in the **runtime** database
  (the imported copy), not the bundled file.
- `AppDatabase.swift:47-48` counts rows in the runtime DB (DEBUG diagnostics) —
  not the bundled file.

### Gotchas, traps, limitations

1. **Two normalizers coexist.** `normalized_name` (build_sqlite.py:256) is
   `display_name.strip().lower()` — underscores and punctuation survive
   (`"Fuji_Apple"` → `"fuji_apple"`). The rest of the package normalizes with
   `utils.canonical()` (utils.py:23-26), which also maps `_`→space, deletes
   non-`[a-z0-9% -]` characters, and collapses whitespace (`"Fuji_Apple"` →
   `"fuji apple"`; `"Crème"` → `"cr me"`). Matching `normalized_name` against
   `canonical()`-derived queries will miss. FLAGGED — changing it would alter
   the generated database (not safe to fix under docs-only rules).
2. **Sprite backfill is duplicated with promote.py.** promote.py:26-27 applies
   the same rule when a row enters the canonical JSON; build_sqlite.py:258-260
   re-derives it at build time as a safety net. Tiny semantic difference:
   promote backfills an *empty* sprite_group regardless of category, while
   build_sqlite skips when `category_label == "other"` — unreachable in
   practice because the `CuratedIngredientRow` validator maps empty to
   `"other"`. Harmless but easy to trip over when changing either side.
3. **Lock-file unlink race (build_sqlite.py:132-137).** After the `with lock:`
   block releases, another process may have just acquired the (still existing)
   lock file; unlinking it leaves that holder locking a deleted inode, and a
   third process creates a fresh lock file and runs concurrently — the mutual
   exclusion gap the unlink was meant to avoid is reintroduced under
   contention. The `except OSError: pass` also swallows cleanup errors.
   FLAGGED, not fixed — locking policy is behavior, out of scope here.
4. **A bare `SELECT id FROM ingredients` has no guaranteed order.** SQLite may
   satisfy it from the `UNIQUE(name)` covering index instead of a table scan —
   observed ordering `[170211, 500, 900123]` for fdc_id-ordered inserts. Use
   `ORDER BY rowid` (rowid order = physical insert order = fdc_id ascending).
5. **Aliases are canonicalized before this module runs.** The
   `CuratedIngredientRow` validator (schema.py, via
   `utils.dedupe_keep_order`, utils.py:36) lowercases, strips punctuation,
   and dedupes `alt_names`. The insert-side `.lower()` and `INSERT OR IGNORE`
   (line 326) are defensive no-ops for validated catalogs — do not rely on
   them to preserve original casing.
6. **Rebuilds replace, not merge.** Pointing `--out` at an existing database
   discards it wholesale (fresh tables + `os.replace`); rows dropped from the
   canonical JSON disappear from the app on the next build.
7. **`ingredients.id` is the `fdc_id`** while `ingredient_catalog.id` is a
   1..N surrogate — joins/aliases always key on `fdc_id`, never on the v2 `id`.
8. No Python CI exists in this repo (only `.github/workflows/ios-ci.yml`);
   the verification commands in the fragment owner's report are the de-facto
   check suite for this module.

### Tests

`tests/p05_test_build-sqlite.py` (11 offline, deterministic tests: both schemas
populated, fdc_id ordering, alias lowercasing/dedupe, sprite backfill in both
tables, `normalized_name` behavior, byte-determinism, lock/temp cleanup, notes
provenance string, `search_text`/`alt_names_json`, rebuild-raises,
existing-output replacement). Run from `scripts/data`:

```
uv run --with pytest python -m pytest usda_core/tests/p05_test_build-sqlite.py -q
```

Note: the directory scan `pytest usda_core/tests` collects nothing because the
prescribed filename `p05_test_build-sqlite.py` matches neither default pattern
(`test_*.py`, `*_test.py`); pass the explicit file path. The in-docstring
doctest is run with
`uv run python -c "import doctest; import usda_core.build_sqlite as m; print(doctest.testmod(m))"`
— `python -m doctest usda_core/build_sqlite.py` cannot work for any module in
this package (the doctest CLI imports the file as a top-level module and every
module here uses relative imports).
