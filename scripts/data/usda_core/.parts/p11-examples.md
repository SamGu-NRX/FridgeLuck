## examples

Files (all NEW, added by this part): `scripts/data/usda_core/examples/pipeline_demo.py`,
`scripts/data/usda_core/examples/README.md`, and
`scripts/data/usda_core/tests/p11_test_examples.py` (plus an empty
`scripts/data/usda_core/tests/__init__.py` so pytest can import the test
module as `usda_core.tests.p11_test_examples`).

**Line-number convention:** all `path:line` references below are final line
numbers on this branch's head commit — the single `docs(usda-core)` commit on
top of base `1151588d6bc6f5dcc3e848b6115813ff36ffbf0d`. No pre-existing file
was modified, so line numbers cited for existing modules are identical to the
base commit (verified by reading them at the base commit). The pushed head sha
is in the p11 completion report.

### Why this exists

`usda_core` is only imported by the typer CLI `scripts/data/usda.py` (`usda`
script in `scripts/data/pyproject.toml`), so a new engineer cannot see the
whole pipeline without tracing CLI commands. `examples/pipeline_demo.py` is a
readable, offline, self-contained tour of the same machinery: it replays the
full lifecycle — canonical JSON → validate → review batch → human edit →
promote → app SQLite → report — against a 3-row synthetic catalog inside a
throwaway temp directory. It never touches the network, the real catalog at
`scripts/data/catalog/usda_curated_ingredients.json`, or anything outside its
temp directory, so it is safe to run repeatedly.

### Data flow through the demo

`pipeline_demo.main()` (`pipeline_demo.py:191`) runs seven steps, each printing
a `step N:` marker:

1. `make_demo_catalog()` (`pipeline_demo.py:102`) → `CanonicalCatalog`
   (schema.py:102); `io.save_canonical` (io.py:21) writes `canonical.json`,
   `io.load_canonical` (io.py:16) reads it back — the same on-disk round trip
   the CLI performs on the real catalog.
2. `validate.validate_catalog(catalog, required_terms=[...])` (validate.py:16)
   → stats dict `{'record_count', 'unique_alias_count', 'required_terms'}`.
3. `make_candidate_row()` (`pipeline_demo.py:155`) → one new
   `CuratedIngredientRow`; `batches.export_batch(catalog, batch_id=…,
   batch_size=4, candidates=[…])` (batches.py:26) emits a `BatchPayload`
   (schema.py:118) of one "new candidate from USDA" row plus the three
   lowest-`quality_score` (batches.py:9) catalog rows; the distribution is
   summarized by `note_distribution` (`pipeline_demo.py:179`).
4. `io.save_batch`/`io.load_batch` (io.py:31/26) round-trip the batch JSON;
   the "human" edit appends an alias to the green-onion row and rewrites the
   file; `promote.promote_batch(catalog, batch)` (promote.py:20) merges it —
   row count 3 → 4 — inferring missing `sprite_key`/`sprite_group` via
   `sprite_rules.infer_sprite_key` (sprite_rules.py:12).
5. A batch that edits an existing row's macros hits the macro-freeze guard
   (promote.py:37-42) → `promote.PromoteError` (promote.py:10), caught and
   printed.
6. `build_sqlite.build_sqlite(merged, db_path)` (build_sqlite.py:15) writes
   the app database (tables `ingredient_catalog`, `ingredients`,
   `ingredient_aliases` — the two latter are what the iOS app queries); the
   demo inspects it with the stdlib `sqlite3`.
7. `report.build_report(merged)` (report.py:10) → markdown head printed.

`tests/p11_test_examples.py` guards the demo: `test_pipeline_demo_runs`
(`p11_test_examples.py:37`) runs the demo in a subprocess from
`scripts/data` and asserts exit 0, every `step N:` marker, and the three
table names; `test_doctest_sweep` (`p11_test_examples.py:67`) imports every
top-level `usda_core/*.py` module with `importlib.import_module`, loads
`pipeline_demo.py` by file path (the `examples/` directory is not a package),
and asserts `doctest.testmod` reports zero failures everywhere — this is the
fleet-wide guard that keeps every module's doctests green.

### Main symbols in `pipeline_demo.py`

- `make_demo_catalog` (`pipeline_demo.py:102`) — 3 rows, fdc_ids 171001–171003
  (module constants at `pipeline_demo.py:66-69`), strictly increasing
  (validate_catalog enforces it), `sprite_key` left empty on purpose so
  promotion must infer it. Pure and deterministic (fixed
  `generated_at_utc="2026-01-01T00:00:00Z"`); doctested.
- `make_candidate_row` (`pipeline_demo.py:155`) — the fdc_id-171004
  "Rotisserie Chicken" candidate; doctested.
- `note_distribution` (`pipeline_demo.py:179`) — counts review notes, sorted
  by `(-count, note)` instead of `Counter.most_common` so output is
  byte-stable; doctested.
- `main` (`pipeline_demo.py:191`) — the I/O orchestration; guarded
  `SystemExit` if the macro-freeze guard fails to fire (step 5 cannot pass
  silently). `examples/README.md` documents the run command and the exact
  expected-output sketch.

### Gotchas, traps, limitations

- **Sprite-key quirk (flagged, not fixed):** `config.DISTINCT_SPRITE_KEYS`
  (config.py:55-71) is scanned in insertion order by
  `sprite_rules.infer_sprite_key` (sprite_rules.py:12-17). `"onion"` is tested
  before `"green onion"` and is a substring of it, so green-onion rows get
  `sprite_key="onion"`, never `"green_onion"` (verified empirically:
  `infer_sprite_key('Green Onions (Scallions)', 'Onions, green (scallions), raw')`
  → `'onion'`, while scallion-only text → `'green_onion'`). The demo prints
  this in step 4. Fixing it means reordering the mapping longest-token-first
  in `config.py`/`sprite_rules.py` — both outside this part's file ownership,
  and it would change generated data (`sprite_key` in the app SQLite), so it
  was flagged to the orchestrator instead.
- **`validate_catalog` falsy-`required_terms` trap:** `required_terms or
  list(DEFAULT_REQUIRED_TERMS)` (validate.py:17) means passing `[]` silently
  falls back to the 14 app-default terms (config.py:23), which a tiny demo
  catalog cannot satisfy. The demo passes a non-empty subset. The 14 defaults
  are the terms the shipped app search relies on.
- **Pytest discovery does not match the pinned test filename:** the fleet
  convention `tests/pXX_test_*.py` matches neither of pytest's default
  `python_files` globs (`test_*.py`, `*_test.py`), so
  `uv run --with pytest python -m pytest usda_core/tests -q` collects zero
  tests (exit code 5). Pass the file directly:
  `uv run --with pytest python -m pytest usda_core/tests/p11_test_examples.py -q`
  (2 passed). Renaming the file or adding pytest config was outside this
  part's allowed files — flagged to the orchestrator; the invocation also
  needs a `python_files` override (e.g. `-o python_files="p??_test_*.py"`) or
  renamed test files fleet-wide.
- **`sqlite_sequence` is not a pipeline table:** `build_sqlite` uses
  AUTOINCREMENT, so SQLite adds an internal `sqlite_sequence` table; the
  demo's step 6 listing shows it alongside the three app tables. Do not
  mistake it for part of the schema contract.
- **Wall-clock fields:** `promote_batch` stamps a fresh `generated_at_utc`
  (promote.py:45-46, via `utils.utc_now_iso`) and `build_report` embeds
  `utc_now_iso` (report.py:15), so demo output is not byte-identical across
  runs on those lines. Everything else in the demo is deterministic; the
  pytest assertions avoid the varying lines.
- **Mutation is allowed on these pydantic models:** no `frozen` and no
  `validate_assignment` on `CuratedIngredientRow`/`MacroSet` (schema.py:25-63),
  so the demo's "human edit" (`record.row.alt_names.append(...)`) and the
  tampered macros assignment (`tampered.macros.calories = 950.0`) bypass
  field validators. Harmless in the demo (the freeze guard still fires), but a
  trap if copied into ingestion code: values assigned this way are not
  re-validated or re-rounded (normal validation rounds macros to 4 decimals,
  schema.py:36-39).
- **`export_batch` is keyword-only and `batch_size` is actual, not requested:**
  `batch_id`, `batch_size`, `candidates` are keyword-only (batches.py:26-32),
  and the returned `BatchPayload.batch_size` is the number of records actually
  selected (batches.py:42,49), which can be smaller than requested.
