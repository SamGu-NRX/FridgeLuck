# Handoff — substitution evidence harness (PR #49)

Status as of commit `HEAD` of `obv/fl-l2-substitution-evidence`
(base `feat/minimal-product-20261007`). Read this before touching the
harness or the production substitution map.

## What exists

- `evidence/` — frozen production pairs (`pairs.snapshot.json`), source
  registry (`sources.csv`), per-pair assessments (`pair_evidence.csv`),
  and 227 generated (pair × bundled recipe) context cases
  (`context_cases.csv`).
- `tools/extract_production_map.py` — re-parses `SubstitutionService.swift`
  into the snapshot. The hashed region is everything after the
  `private static func buildMap()` marker, up to `return map` — the marker is
  **excluded** on both the Python and Swift sides (they hash an identical byte
  range; this convention was the CI failure at 07fd92d and is fixed).
- `tools/build_cases.py` — regenerates the context cases deterministically.
- `tools/render_swift_fixture.py` — renders both generated Swift fixtures:
  `Tests/SubstitutionEvidencePairs+Generated.swift` and
  `Tests/SubstitutionEvidenceContexts+Generated.swift`.
- `check_evidence.py` — validator (schema, references, drift, negative
  controls, and stale-fixture detection for both Swift fixtures).
- `score.py` — deterministic report writer; `--verify-report` recomputes
  exactly.
- `Tests/SubstitutionEvidenceReplayTests.swift` — SwiftReplay: instantiates
  the real `SubstitutionService` on an in-memory GRDB queue and runs actual
  production suggestions over all 27 frozen pairs and all 227 context cases
  (including a dietary-restrictions pass), asserting substitute, ratio, and
  reasons match the frozen evidence.

## Current numbers

- 27 production pairs; 227 context cases; verdicts 35 verified / 53 partial /
  9 unsupported / 130 unverified; 19 contexts with unknown function label.
- Sourced ratio coverage 35/227; function-supported 88/227.

## What is verified where

- Python side: fully verified locally — validator exit 0, both negative
  controls pass, 8/8 pytest, report tamper-check clean.
- Swift side (SwiftReplay): **not compiled or run in this Linux sandbox** (no
  Swift toolchain). Verified only by hosted macOS CI. The prior CI run
  (183 tests, 1 failure) proved the tests compile and execute there.

## Known evidence conflicts (deliberate, not bugs)

- egg → banana: production ratio 0.6; extension guidance supports ~1.2 by
  weight (¼ cup mashed banana per egg). Recorded as a conflict; production is
  untouched.
- honey → banana: production ratio 1.5 does not preserve sugar content; kept
  with an explicit caveat in `pair_evidence.csv`.
- Several bundled USDA FDC identity matches look poor; they are not used as
  composition evidence without further checking.

## How to run everything

```bash
python3 apps/ios/Tools/substitution-eval/tools/extract_production_map.py   # refresh snapshot
python3 apps/ios/Tools/substitution-eval/tools/build_cases.py              # refresh contexts
python3 apps/ios/Tools/substitution-eval/tools/render_swift_fixture.py     # refresh Swift fixtures
python3 apps/ios/Tools/substitution-eval/check_evidence.py                 # validate (exit 1 on error)
python3 apps/ios/Tools/substitution-eval/score.py                          # write report
python3 apps/ios/Tools/substitution-eval/score.py --verify-report \
  apps/ios/Tools/substitution-eval/reports/evidence_report.json
python3 -m pytest apps/ios/Tools/substitution-eval/tests -q
cd apps/ios && swift test --filter SubstitutionEvidenceReplayTests        # macOS CI only
```

## If you change SubstitutionService.swift

1. Rerun `extract_production_map.py`, `render_swift_fixture.py`, `score.py`.
2. `check_evidence.py` must exit 0 (it rejects stale fixtures).
3. Update `pair_evidence.csv` rows for any pair whose ratio, reasons, or note
   changed — the validator checks cited evidence against shipped values.
4. Expect `testSourceRegionHashMatchesTheFixture` and the replay tests to
   fail until the fixtures are regenerated. That is the intended tripwire.

## Open follow-ups

- Hosted macOS CI result for the SwiftReplay rewrite (not yet run at
  handoff time).
- Resolving the two ratio conflicts above requires a product decision plus a
  production change; the evidence set is the input, not the change.
- USDA FDC identity matching for the bundled catalog deserves its own audit.
