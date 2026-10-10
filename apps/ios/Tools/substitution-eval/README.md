# substitution-eval — evidence harness for FridgeLuck ingredient substitutions

Offline, deterministic evaluation of the substitution pairs shipped in
`apps/ios/Platform/Persistence/Services/SubstitutionService.swift` against
published food-science evidence, per ingredient-pair and per recipe-context.

No network access, no APIs, no Swift toolchain needed. Python 3.11+ and
`pytest` are the only requirements.

## Layout

```
evidence/
  pairs.snapshot.json   frozen copy of the production pairs, extracted from
                        SubstitutionService.swift (region hash included)
  sources.csv           source registry: every source cited anywhere, with
                        what it supports and what it does not
  pair_evidence.csv     one row per production pair: supported/unsuitable
                        functional roles, ratio status, cited sources,
                        assessment prose
  context_cases.csv     one row per (pair, bundled recipe) context: the role
                        the original ingredient plays, the verdict for the
                        substitute
reports/
  evidence_report.json  deterministic rollup; verified by score.py
tools/
  extract_production_map.py  re-parses SubstitutionService.swift
  build_cases.py             regenerates context_cases.csv from bundled data
  render_swift_fixture.py    renders the generated Swift replay fixture
check_evidence.py         validator: schema, references, drift, controls
score.py                  report writer / verifier
tests/                    pytest suite (validator controls, ratio math)
Tests/SubstitutionEvidenceReplayTests.swift   Swift production replay
Tests/SubstitutionEvidencePairs+Generated.swift  generated fixture
```

## Commands

Run from the repository root:

```bash
# regenerate context cases (writes evidence/context_cases.csv)
python3 apps/ios/Tools/substitution-eval/tools/build_cases.py

# validate everything; exit 1 on any error; prints coverage counts
python3 apps/ios/Tools/substitution-eval/check_evidence.py

# write reports/evidence_report.json (deterministic)
python3 apps/ios/Tools/substitution-eval/score.py

# verify a stored report recomputes exactly (tamper check)
python3 apps/ios/Tools/substitution-eval/score.py --verify-report \
  apps/ios/Tools/substitution-eval/reports/evidence_report.json

# tests
python3 -m pytest apps/ios/Tools/substitution-eval/tests -q
```

## Verdict model

A (pair, context) case gets one of four verdicts, computed from the pair
evidence:

- **verified** — the substitute covers the ingredient's function in this
  recipe, and a published source states both the swap and a matching amount
  (function evidence sourced, ratio evidence sourced).
- **partial** — the function is supported but the shipped amount rests on
  convention or a conflicting source.
- **unverified** — no evidence either way for this function (this includes
  every case where the ingredient's role could not be determined from the
  recipe steps; those contexts are labeled `unknown` and left unverified).
- **unsupported** — the pair's own evidence marks the function unsuitable
  (e.g. butter → olive oil cannot bind a batter).

## Negative controls

`check_evidence.py` runs two built-in controls every time:

1. **missing-reference** — synthetic cases citing a pair not in production
   and a recipe not in the bundled data are rejected by the row validator.
2. **incompatible-function** — a case whose context function the pair
   evidence marks unsuitable computes `unsupported`, and a `verified` claim
   for it is rejected.

## Current coverage (see reports/evidence_report.json for the live numbers)

- 27 production pairs, 227 recipe contexts, every required function class
  (binding, fat, liquid, thickening, garnish) represented.
- 35/227 contexts fully verified from sourced ratio + function evidence
  (35/227 ≈ 15.4%); 88/227 have at least partial function support.
- Honest gaps retained: 130 unverified and 9 unsupported contexts stay in the
  set rather than being dropped.

## Scope and caveats

- Sources prove that a swap is *recognized in published guidance* — not that
  it tastes good, and nothing here addresses allergen cross-contact safety.
- Function labels come from keyword classification of the bundled recipe
  steps; contexts that cannot be classified stay `unknown`.
- USDA FoodData Central household-mass tables are referenced, not duplicated.
- Some bundled USDA FDC identity matches are poor; they are not treated as
  composition evidence without further checking (flagged in pair assessments).
- Swift replay (SwiftReplay): `SubstitutionEvidenceReplayTests` instantiates
  the real `SubstitutionService` on an in-memory GRDB queue and runs actual
  production suggestions over all 27 frozen pairs and all 227 context cases,
  including a dietary-restrictions pass, asserting substitute, ratio, and
  reasons against the fixtures. A source-region SHA-256 test guards against
  silent edits to `SubstitutionService.swift`; the hashed region excludes the
  `private static func buildMap()` marker on both the Python and Swift sides
  so they hash an identical byte range. The tests are portable XCTests in the
  existing `AppModuleTests` target; they were not compiled in this
  environment (no Swift toolchain) and run on hosted macOS CI. See
  `HANDOFF.md` for the full state.
