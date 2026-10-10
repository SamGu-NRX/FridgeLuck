## What changed and why

Adds the **preparation-state-v1 benchmark**: a frozen, source-bound evaluation that separates *ingredient identity* from *preparation state* in the recognition pipeline, and measures whether production resolution abstains when a requested state is unavailable instead of silently returning a wrong-state record.

Two commits:

1. **`6cd97a3` — manifest milestone** (`benchmarks/preparation-state-v1/`)
   - `manifest.json`: 620 preparation-state groups (800 catalog records), deterministic group-level train/dev/test splits, 1,375 synthetic text probes in three families — `identity` (521), `state` (439), `unknown_state` (415: the target state has no catalog record and correct behavior is abstention).
   - `catalog_snapshot.json` (pinned records + sha256) and `check_manifest.py` (validation + mutation tests).
   - `generate_probes.py` and `build_manifest.py` for reproducibility.
   - `tests/`: 9 pytest cases pinning source integrity, splits, label derivation, probe specificity, and unknown-state targets.

2. **`c7e8f7f` — run + results milestone**
   - `run.py`: three arms over the frozen manifest.
     - `pinned_cpu_baseline` — deterministic, state-blind unique-match baseline (production-family normalization: lowercase, de-pluralize, strip leading fresh/raw/cooked/frozen/dried, then unique exact/prefix match, unique-or-abstain).
     - `production_replay` — read-only text replay of the production resolution stack via the existing differential-verified port (`experiments/ingredient-recognition/resolution/app_resolution.py`, mirroring `IngredientLexicon.swift` + `IngredientCatalogResolver.swift` + `IngredientIdentityResolution.swift`); the bundled catalog is opened `mode=ro`. **Nothing in production is imported at runtime, modified, or deleted.**
     - `swift_replay` — a SwiftReplay package (`SwiftReplay/`) that syncs the real `IngredientLexicon.swift` verbatim (gitignored copy, synced by script) and replays probes through it. **Recorded as unrun in `results/report.json`** — no Swift toolchain in this Linux environment; see "What I couldn't check".
   - `results/` — committed `predictions.jsonl` (sha256 recorded in the report) and `report.json` with environment pin (CPU model, Python, SQLite versions, catalog sha256), per-probe timings, abstention counts, identity/state confusion tables.
   - 13 additional pytest cases: classification logic, baseline state-blindness/ambiguity abstention, and hash-integrity checks of the committed results against the manifest.

## Headline results (production replay, 1,375 probes)

- **369/1,375 probes return a wrong-state record of the same food.** Identity is nearly perfect (90.8% exact on identity probes), but state handling is not: on **unknown-state probes, 356/415 (86%) resolve concretely to a wrong-state record instead of abstaining**.
- Dominant confusion: **`cooked → raw` (258 cases)** — the resolver strips leading preparation terms, so "cooked X" resolves to the raw record whenever no cooked variant exists. Other confusions: cooked→dried 28, raw→cooked 26, cooked→canned 26.
- The state-blind baseline shows the same shape (group-level abstention on multi-state groups, concrete resolution on single-record groups), isolating the gap as a missing state-dimension, not a catalog-coverage bug.

## How I checked it

- `python3 check_manifest.py` → `OK: 620 groups, 1375 probes verified`
- `python3 -m pytest benchmarks/preparation-state-v1/tests -q` → **23 passed** (includes hash checks that the committed predictions match `report.json`'s recorded sha256, and that the manifest sha matches)
- `python3 run.py --out benchmarks/preparation-state-v1/results/text_arms` → all three runnable arms completed
- `python3 verify_report.py` → **22/22 checks pass, exit 0** (independent recomputation of outcomes, summaries, confusion tables, image metrics, and file hashes from the committed artifacts alone)
- `git log` / `git push` verified: commits authored as `Sam Gu <127461594+SamGu-NRX@users.noreply.github.com>` with the `Co-authored-by: obvious-autobuild[bot]` trailer, pushed to `origin/obv/fl-l2-preparation`
- Catalog opened read-only in every code path (`mode=ro` URI); no production file touched (`git status` clean outside `benchmarks/preparation-state-v1/`)

## Extension: held-out arm, image inference, nutrient consequences, verifier

Third milestone (`benchmarks/preparation-state-v1/` only; the product mapper is untouched):

1. **`heldout_alternative` arm** (`run.py`) — 22 deterministic test-split probes on groups with ≥2 catalog records, through the production replay path. Identity holds (21/22 group-correct), but exact-record match is only 11/22: all 11 state probes hit their exact record, while on unknown-state targets only 4/11 abstain and 6/11 return a concrete wrong-state record (cooked→frozen 2, cooked→raw 2, raw→cooked 1, dried→raw 1). The state-selection finding generalizes beyond the training-derived confusion table.
2. **Image arm** (`image_inference.py`) — frozen CPU ViT-B/32 baseline over the FoodSeg103 validation split (2,135 images). Identity detection is weak (group recall 0.0736, 37/503 expected groups; 1,720 spurious detections) — reported honestly as a baseline that does not transfer. The production-relevant finding: **69 of 128 detections on multi-alternative groups (53.9%, 15 groups) bound a concrete stateful record with no image evidence for that state**.
3. **Nutrient consequences** (`nutrient_consequences.py` → `results/nutrient_consequences.json`) — for the 13 wrong-state text pairs with a defined target record: `cooked→raw` (n=5) mean kcal +7.96% (worst +108.33%), `frozen→raw` (n=4) mean −16.93% with fat +151.32%, `canned→raw` (n=2) mean −61.44%. For the image side: ungrounded bindings pick members of groups whose kcal spread averages 54.9% of the group mean (52/69 beyond 20%).
4. **Verifier** (`verify_report.py`) — recomputes every recomputable number from the committed files (outcome reclassification, per-arm summaries, confusion tables, image metrics, all sha256 hashes); exit 0.
5. **SwiftReplay** — root-path fix in `sync_production_sources.sh` (`git rev-parse --show-toplevel` instead of a broken relative climb) and an explicit "Full-resolver execution limits" section in its README documenting that the GRDB-backed resolver is not replayable in the package and is covered by the differential-verified Python port.

Committed artifacts: `results/text_arms/` (predictions + report, sha256-pinned), `results/image_inference/` (observations, per-image predictions, report), `results/nutrient_consequences.json`, `HANDOFF.md`.

## What I couldn't check

- **Image preparation-state accuracy is unmeasurable** — FoodSeg103 carries no preparation-state labels, so the image arm reports identity detections and ungrounded-binding rates only; the report states this explicitly rather than scoring state correctness.
- **SwiftReplay never ran** — no Swift toolchain in the Linux sandbox. The package, its XCTest cases (including the state-blindness test `testLexiconIsStateBlindOnCookedModifier`), and the source-sync script are committed for a macOS run (`scripts/sync_production_sources.sh && swift test`). The committed report marks this arm `"ran": false` with an explicit unrun status. The full GRDB-backed resolver is not replayable in the package at all (no GRDB dependency, catalog not bundled); it is covered by the differential-verified Python port (186 cases, 0 divergences).
- iOS compilation is checked only by hosted macOS CI; nothing here exercised Xcode-side behavior.

## Assumptions

- Base branch `obv/fl-next-ingredient-recognition-r1` (benchmark stacks on the ingredient-recognition work already on that branch).
- Synthetic probes are sufficient for a first signal; they are text-only (no image models) and deliberately state-sourced, so `unknown_state` abstention is measured against catalog availability, not model behavior.
- The Python resolution port faithfully mirrors production (it was differential-verified in the ingredient-recognition milestone); the Swift arm exists precisely to re-verify that on macOS.
- Preparation states are derived conservatively from source-name descriptors; ambiguous descriptors produce no state label rather than a guess.
- The image arm uses the already-pinned whole-image ViT-B/32 food classifier as the baseline detector and maps FoodSeg103 classes to catalog groups through the existing frozen taxonomy CSV; a stronger detector can be swapped in without changing the scorer.
- `unknown_state` probes have no target record, so they contribute wrong-state outcome counts but no nutrient-delta rows; the report field names this scope explicitly.

Draft PR — not for merge.
