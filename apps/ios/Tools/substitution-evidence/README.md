# substitution-evidence — evidence harness for FridgeLuck ingredient substitutions

Offline evaluation of the 27 production substitution pairs in
`apps/ios/Platform/Persistence/Services/SubstitutionService.swift`, per pair
and per recipe context, with a strict validator and a Swift replay of the
real production service.

## Layout

```
Package.swift            isolated Swift package (Linux-runnable replay)
Scripts/refresh.sh       copies the real production sources into Sources/
                         SubstitutionEvidence/Real/ before swift test
Sources/SubstitutionEvidence/
  Real/                  mirrored SubstitutionService.swift + Ingredient.swift
                         (gitignored; refresh.sh creates it; drift-checked)
evidence/
  pairs.snapshot.json    frozen copy of the 27 production pairs plus a SHA-256
                         of the extracted buildMap() source region (the hashed
                         region excludes the leading
                         `private static func buildMap()` marker on both the
                         Python and Swift sides, so both hash an identical
                         byte range)
  sources.csv            source registry: university extension guidance,
                         peer-reviewed studies, USDA FoodData Central
                         (household-mass tables are referenced, not duplicated)
  pair_evidence.csv      per-pair assessment: supported/unsuitable functional
                         roles, ratio status (sourced / convention / conflict),
                         cited sources, assessment prose
  context_cases.csv      227 (pair x bundled recipe) contexts with functional
                         role and verdict
reports/
  evidence_report.json   deterministic report; verify with score.py
tools/
  extract_production_map.py   re-parses the production source into the snapshot
  build_cases.py              regenerates the context cases
  render_swift_fixture.py     renders the generated Swift fixtures (pairs and
                              contexts) into Tests/SubstitutionEvidenceTests/
check_evidence.py        validator: schema, references, production drift,
                         stale-fixture detection for both fixtures, Real/
                         mirror freshness, built-in negative controls
tests/                   pytest suite (validator controls, ratio math)
Tests/SubstitutionEvidenceTests/
  SubstitutionEvidenceReplayTests.swift      SwiftReplay: production-suggestion
                                             replay over every pair and context
  SubstitutionEvidencePairs+Generated.swift  generated pair fixture
  SubstitutionEvidenceContexts+Generated.swift generated context fixture
HANDOFF.md               state, verified-where, and follow-ups
```

## Commands

Python side (Python 3.13, from the repo root):

```
python3 apps/ios/Tools/substitution-evidence/tools/extract_production_map.py
python3 apps/ios/Tools/substitution-evidence/tools/build_cases.py
python3 apps/ios/Tools/substitution-evidence/tools/render_swift_fixture.py
python3 apps/ios/Tools/substitution-evidence/check_evidence.py
python3 apps/ios/Tools/substitution-evidence/score.py
python3 apps/ios/Tools/substitution-evidence/score.py --verify-report
python3 -m pytest apps/ios/Tools/substitution-evidence/tests -q
```

Swift replay (Linux or macOS; requires a Swift toolchain with GRDB support):

```
bash apps/ios/Tools/substitution-evidence/Scripts/refresh.sh
swift test --package-path apps/ios/Tools/substitution-evidence \
  -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
```

The package compiles the real production `SubstitutionService.swift` and
`Ingredient.swift` (mirrored by `refresh.sh`, never forked) and replays
actual production suggestions over all 27 frozen pairs and all 227 context
cases, including a dietary-restrictions pass. Two strict guards run inside
the replay tests: a source-region SHA-256 comparison against the live
production source (identical slicing to the Python extractor) and a
mirror-drift test asserting the `Real/` copies are byte-identical to the
production files. Editing the snapshot, either generated fixture, a `Real/`
copy, or the production map without regenerating makes the checks fail.

## Verdicts

- `verified` requires both function and ratio evidence sourced (35/227).
- `partial` (53): one of function or ratio is sourced; the rest is
  convention or unverified.
- `unsupported` (9): evidence contradicts the swap for that context (e.g.
  lettuce standing in for bread as a main).
- `unverified` (130): no applicable evidence; contexts whose functional role
  cannot be classified stay `unknown` and are left unverified rather than
  counted as supported.

## Evidence conventions

- Verdicts are grounded in `pair_evidence.csv` function/ratio status and the
  ingredient's role in the specific recipe steps; contexts that cannot be
  classified stay `unknown`.
- USDA FoodData Central household-mass tables are referenced, not duplicated.
- Some bundled USDA FDC identity matches are poor; they are not treated as
  composition evidence without further checking (flagged in pair assessments).
- Swift replay (SwiftReplay): see "Swift replay" above. The tests run in the
  isolated package, not the app test target — a green app CI run does not
  exercise them. See `HANDOFF.md` for the full state.
