# HANDOFF — substitution-evidence

State of the harness, what is verified where, and what to do next. Written
for the next session; everything here was re-verified against the tree at
commit time.

## What this is

An offline evidence harness for the 27 substitution pairs shipped in
`apps/ios/Platform/Persistence/Services/SubstitutionService.swift`, plus an
isolated Swift package (`Package.swift` in this directory) that compiles the
real production sources and replays actual production suggestions over every
frozen pair and every generated (pair, bundled recipe) context case,
including a dietary-restrictions pass.

## Verified where

- **Python harness** — verified on Linux (Python 3.13): `check_evidence.py`
  exit 0 with both negative controls passing; 8/8 pytest;
  `score.py --verify-report` byte-exact. All commands in README.md.
- **Swift replay** — verified by running the package test suite on Linux
  (Swift 6.1.2, GRDB 7.x, `-Xswiftc -DSQLITE_DISABLE_SNAPSHOT`). The app
  test target no longer contains these tests: they moved into this package,
  so a green app `build-and-test` CI run does NOT exercise them. Run them
  with the two commands under "Swift replay" in README.md.

## Strict checks (all retained)

- Production drift: `pairs.snapshot.json` is re-extracted from the live
  `SubstitutionService.swift` and compared pair-for-pair.
- Source-region SHA-256: the Python extractor and the Swift replay slice the
  identical byte range (everything after the `private static func
  buildMap()` marker, up to `return map`) and both compare against the
  fixture value.
- Stale-fixture detection: both generated Swift fixtures
  (`SubstitutionEvidencePairs+Generated.swift`,
  `SubstitutionEvidenceContexts+Generated.swift`) are re-rendered and
  byte-compared by `check_evidence.py`.
- Real/-mirror drift: the Swift tests assert the `Real/` copies are
  byte-identical to the production files; the Python validator repeats the
  check when `Real/` exists. A stale mirror fails loudly instead of passing
  green — check this before trusting any cached test result.
- Report tamper check: `score.py --verify-report` recomputes the report
  exactly.

## Regenerating after an intentional production change

```
python3 apps/ios/Tools/substitution-evidence/tools/extract_production_map.py
python3 apps/ios/Tools/substitution-evidence/tools/build_cases.py
python3 apps/ios/Tools/substitution-evidence/tools/render_swift_fixture.py
python3 apps/ios/Tools/substitution-evidence/score.py
python3 apps/ios/Tools/substitution-evidence/check_evidence.py
bash apps/ios/Tools/substitution-evidence/Scripts/refresh.sh
swift test --package-path apps/ios/Tools/substitution-evidence \
  -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
```

## Known evidence conflicts (recorded, not resolved)

- egg → banana: extension guidance supports ~¼ cup mashed banana per egg
  (~1.2 by weight); production ships 0.6.
- honey → banana: at the shipped 1.5 ratio the swap delivers about one fifth
  of the sugar; sweetness equivalence is unsupported.
- Several vegetable/protein/texture swaps are convention-only.

Production behavior is untouched; conflicts are documented in
`evidence/pair_evidence.csv` and surfaced in `reports/evidence_report.json`.

## Open follow-ups

- Wire the package's `swift test` into CI if hosted macOS runners should
  enforce the replay (this PR deliberately does not touch CI configuration).
- Decide what to do about the two ratio conflicts above (change production
  ratios deliberately, or keep the documented conflicts).
- Per-class thresholds / better evidence coverage for the 130 unverified
  contexts.
