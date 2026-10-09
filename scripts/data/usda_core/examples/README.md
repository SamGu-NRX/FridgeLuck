# usda_core examples

`pipeline_demo.py` is a self-contained, offline tour of the entire USDA
ingredient pipeline. It builds a tiny 3-row synthetic canonical catalog in a
throwaway temporary directory and walks it through every stage the real
pipeline uses — validate, batch export, human review, promote, SQLite build,
report — without touching the network, the real catalog under
`scripts/data/catalog/`, or anything outside its temp directory. It is the
fastest way to see how `usda_core` fits together end to end.

## Run it

```bash
cd scripts/data
uv run python usda_core/examples/pipeline_demo.py
```

Exit code is 0 on success. Every step prints a `step N:` line; the run is
asserted by `usda_core/tests/p11_test_examples.py`.

## What each step shows

1. Build a synthetic canonical catalog (3 rows, fixed fdc_ids 171001–171003,
   full USDA provenance) and round-trip it through disk with
   `io.save_canonical` / `io.load_canonical` — the same load path the CLI uses
   for the real catalog.
2. `validate.validate_catalog` — strictly increasing fdc_ids, unique display
   names, USDA provenance, and required search terms; prints the stats dict.
   (A demo-sized `required_terms` list is passed; see the code comment for why
   an empty list would silently fall back to the 14 app-default terms.)
3. `batches.export_batch` — one fresh candidate row plus the lowest-quality
   catalog rows become a review batch; prints the review-notes distribution.
4. Simulate the human step: edit the batch JSON (add an alias to the
   green-onion row), then `promote.promote_batch` merges it back — row count
   goes 3 → 4, and promotion infers the missing `sprite_key` values,
   surfacing the green-onion quirk (`green onion` text resolves to the plain
   `onion` sprite key, not `green_onion`).
5. The macro-freeze guard: promoting a batch that edits an existing row's
   macros raises `promote.PromoteError`; the demo catches and prints it.
6. `build_sqlite.build_sqlite` — builds the app database and prints every
   table with its row count (`ingredient_catalog`, `ingredients`,
   `ingredient_aliases`, plus SQLite's internal `sqlite_sequence`).
7. `report.build_report` — prints the head of the markdown pipeline report.

## Expected output (sketch)

The `Generated at UTC` line varies with the wall clock; everything else is
deterministic.

```text
step 1: build a 3-row synthetic canonical catalog and round-trip it through disk
step 1: 3 rows written to canonical.json and loaded back
step 2: validate the catalog
step 2: stats {'record_count': 3, 'unique_alias_count': 7, 'required_terms': 4}
step 3: export a review batch (one new candidate + lowest-quality catalog rows)
step 3: batch_id=1 rows=4 review-notes={'review metadata quality': 3, 'new candidate from USDA': 1}
step 4: simulate a human edit, then promote the batch back into the catalog
step 4: row count 3 -> 4 after promoting the edited batch manual_batch_1.json
step 4: quirk — the green-onion row got sprite_key='onion', not 'green_onion' (DISTINCT_SPRITE_KEYS tests 'onion' before 'green onion')
step 5: macros are frozen — promoting a changed macro value must fail
step 5: caught expected PromoteError: Macro freeze violation for existing fdc_id=171001; USDA-verified macro values are immutable
step 6: build the app SQLite database in the temp dir
step 6: table ingredient_aliases: 10 rows
step 6: table ingredient_catalog: 4 rows
step 6: table ingredients: 4 rows
step 6: table sqlite_sequence: 2 rows
step 7: build a markdown pipeline report
    # USDA Pipeline Report
    ...
done: temp directory removed; nothing was written outside it
```

## Run the tests

```bash
cd scripts/data
uv run --with pytest python -m pytest usda_core/tests/p11_test_examples.py -q
```

(Both tests live in a `p11_test_examples.py` file whose name does not match
pytest's default `test_*.py` / `*_test.py` discovery globs, so pass the file
path directly — see the fragment in `usda_core/.parts/` for details.)

## Where to read more

- `scripts/data/usda_core/README.md` — the module-by-module guide to
  `usda_core` (assembled by the pipeline documentation fleet from the
  fragments under `scripts/data/usda_core/.parts/`).
- `scripts/data/README.md` — how the data pipeline fits into the repo, and the
  CLI commands (`validate`, `build-sqlite`, …) it drives.
- `scripts/data/usda.py` — the typer CLI that is the only production caller
  of `usda_core`; the demo mirrors its `validate` and `build-sqlite` paths.
