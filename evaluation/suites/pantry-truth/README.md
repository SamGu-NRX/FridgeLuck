# Suite A: pantry-truth

Measures the pantry fit-line truth bar (SPEC 3.2) on the CURRENT app code
(baseline). Three metrics, each derived by the shared runner contract
(`evaluation/suite_contract.py`) from the suite's `results.json`:

| id | what it counts | bar |
|---|---|---|
| `stock_counted_twice` | plan scenarios where production calls every dinner makeable while the shared stock cannot cover them | `== 0` |
| `sufficient_claimed_without_quantity_evidence` | line-instances across the 200 audited pairs where production counts a line as matched with no quantity evidence behind it (short stock, scan-only presence, recognition-estimated amounts, stale evidence, bare assumptions) | `== 0` |
| `fit_line_text_correct_200` | pairs whose rendered fit surface states exactly the ledger's sufficiency count, never overclaims a complete match, and never shows a percentage | `== 200` |

## Grounding

- **Corpus of record:** `apps/ios/Resources/data.json` — the production
  bundled corpus the app loads (`BundledDataLoader`). The original brief
  named `assets/recipes.json`; that file does not exist on any branch of
  this repository, so the suite grounds on the production corpus instead
  (166 recipes, 50 ingredients) and records the substitution plus the
  corpus SHA256 in `results.json`.
- **USDA catalog:** `scripts/data/catalog/usda_curated_ingredients.json`
  is loaded when present and used to record name-based grounding coverage
  of corpus ingredients (auxiliary; recorded in results, not used to
  alter quantities).
- **Pantry scenarios:** synthetic, seeded (`SEED` in `manifest_builder.py`),
  coherent with real corpus recipe quantities. No personal data, no
  network, no credentials. Eight pair classes (see `PAIR_CLASSES`):
  full coverage, swap-covered coverage, short stock, scan-only presence,
  recognition-estimated amounts, stale evidence, bare staple assumptions,
  empty pantry — plus curated edge pairs.

## How production code is exercised

The production pure-logic fit subset (see `fitprobe/production_files.json`
— RecipeRepository, scoring, services, domain models, RecommendationPolicy)
is staged **byte-verbatim** from the repo and compiled with SwiftPM against
the same GRDB the app vendors. The probe
(`fitprobe/Sources/FLFitProbe/main.swift`) then replays audit jobs through
the real production calls:

- composition per pair mirrors `RecommendationEngine.findRecipes`:
  `RecommendationPolicy.effectiveIngredientIDs` →
  `RecipeRepository.findMakeable(limit: 20)` →
  `findNearMatch(maxMissingRequired: 1, limit: …)` → widening to
  `maxMissingRequired: 2` when both come back empty;
- the suite passes exactly the ingredient IDs that have physical inventory
  lots, replicating the production boundary at `AppDependencies.swift:137-139`
  (`Set(inventoryRepository.fetchAllActiveItems().map(\.ingredientId))` —
  quantities are dropped there; assumptions never join the fit);
- the probe imports the production module with `@testable`, so it builds in
  the SwiftPM **debug** configuration (testability is only enabled there);
  production sources are untouched either way.

If Swift or the build is unavailable on the host, the affected metrics
report `not-run` with the precise reason — never skipped silently, never
faked. Every staged production file's SHA256 is recorded in `results.json`.

**Known Linux shim:** the vendored GRDB references `sqlite3_snapshot_*`
symbols the host SQLite lacks. The probe package ships abort-on-call shims
(`Sources/SnapshotStubs`) that are link-only and unreachable from the
`DatabaseQueue` code path the production subset uses.

**No LLM arm:** the programme plan's suite A is property tests plus the
200-pair deterministic audit; no LLM arm is designed, so none is
implemented or left unexecuted.

## Findings semantics

- **double-count finding** — production says both dinners are makeable
  while the ledger shows the shared lot cannot cover both combined.
- **anomaly** — production did not render a dinner the ledger fully
  covers. Verified cause in the baseline: exact matches are ranked and
  only 20 surface (`findMakeable(limit: 20)`), so fully-covered dinners
  can miss the ranked window (a coverage-visibility gap, not a double
  count). Recorded, never silently dropped.
- **pair verdict (metric 3)** — correct iff the rendered fit surface
  states the ledger's sufficiency count exactly (swap-covered lines
  count), no complete-match claim while any line lacks quantity evidence,
  and no percentage. Unrendered pairs are incorrect (the fit truth is owed
  on every card).

## Files

- `suite.json` — manifest (id `pantry-truth`, letter A) per SCORECARD.md;
  the `letter`/`title` emitted into results.json come from here, so the
  scorecard renders `A. Pantry truth` (not `?. pantry-truth`).
- `suite.py` — orchestrator: grounding → probe stage/build/run → audits →
  `results.json` + evidence files. results.json carries the PLAN.md identity
  and a `plan_battery_rows_present` completeness row: every metric row
  PLAN.md line 49 requires of suite A must be emitted — a row the battery
  does not produce is emitted as not-run with a reason naming it, and the
  completeness row derives fail (`enforce_battery_completeness`).
  `--self-test` plants seven corruptions (lying emitter, lying probe row,
  tampered ledger, inconsistent probe output, missing corpus, empty corpus,
  missing battery row) and asserts the scoring catches each; prints
  `caught k/k planted failures` and exits 0 only when all are caught.
- `test_battery_completeness.py` — planted-failure self-test for the two
  review defects: identity (letter A, title "Pantry truth" in a real run's
  results.json) and battery completeness (a required row removed from the
  emission comes back as not-run with the row named, and the completeness
  row derives fail). Drives the real suite CLI on a synthetic mini corpus;
  exits 0 only when all checks are caught.
- `manifest_builder.py` — corpus loading, USDA grounding, seeded pantry
  and plan scenario generation.
- `fit_oracle.py` — SPEC 3.2 ledger derivation, corpus tripwire
  (every ledger line re-checks its demand against the corpus it claims to
  derive from), probe-output invariants, pair verdicts, Wilson interval.
- `fitprobe/` — the SwiftPM probe package and the list of production
  files to stage verbatim.

## Usage

```bash
# from the repository root
python3 evaluation/run.py --suite pantry-truth     # runner-invoked
python3 evaluation/run.py --self-test              # runner + all suite self-tests

# direct
python3 evaluation/suites/pantry-truth/suite.py --out evaluation/out/pantry-truth --repo-root .
python3 evaluation/suites/pantry-truth/suite.py --self-test
```

Probe builds are cached under `/tmp/fl-fitprobe-cache/<content-hash>`
(override with `FL_FITPROBE_CACHE_DIR`); the cache key covers every staged
byte, so any production-source change rebuilds.

Baseline results (first measured 2026-10-11, Swift 6.4, corpus
`apps/ios/Resources/data.json`): all three bars fail — production
double-counts shared stock in 37 of 62 plan scenarios, claims sufficiency
without quantity evidence on 209 audited line-instances, and states the
fit truth correctly on 55 of 200 pairs. Evidence: `evaluation/out/pantry-truth/`.
