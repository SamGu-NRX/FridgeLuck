# FLTaste

FridgeLuck's continual preference-learning engine: it ingests typed cooking
events, learns a Bayesian taste model over recipe features, ranks candidate
recipes with hard safety filters and faithful explanations, and renders an
editable human-readable taste profile.

Standalone SwiftPM research package (Part 1 of the learning overhaul). The
proven model later moves into the app's core package (SPEC §7). Builds and
tests on Linux x86_64 with the Swift 6 toolchain; **Foundation only** — no
GRDB, no UIKit/SwiftUI.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/FLTaste/Core/` | IDs, UTC instants, seeded RNG, canonical JSON |
| `Sources/FLTaste/Events/` | Typed event model, fold, canonical codec |
| `Sources/FLTaste/Features/` | Catalog input types, `taste-features-v1` space + extractor |
| `Sources/FLTaste/Serialization/` | Config, versioned snapshots, forward-only migrations |
| `Sources/FLTaste/TasteEngine.swift` | Public engine surface (ingest / snapshot / restore) |
| `Tests/FLTasteTests/` | Behaviour tests + golden fixtures |
| `FEATURES.md` | Written feature spec (every feature, rule, version string) |
| `DESIGN.md` | Model choice, weighting math, expiry, exploration policy, API contract |

Planned in later tasks, not here: `Sim/` (simulator), `Eval/` (evaluation
runner), `EVAL.md`.

## Build and test (Linux x86_64, Swift 6.4 toolchain)

```sh
cd packages/FLTaste
swift build
swift test
```

Determinism contract: the same seed and the same events produce identical
state and byte-identical snapshots. Snapshots are canonical JSON with sorted
keys, fixed field order, and `%.17g` doubles; round-trip byte equality is
tested, and the committed golden fixture
(`Tests/FLTasteTests/Fixtures/golden-v1.json`) pins the exact bytes.
Regenerate deliberately and review the diff:

```sh
FLTASTE_REGENERATE_GOLDEN=1 swift test --filter SerializationTests.testGoldenFixture
```

Restore fails closed on unknown format/config versions or a feature-space
mismatch; forward-only migrations are registered in `SnapshotMigrations`.

## Verification gates (maintained per milestone)

- `swift build && swift test` green on Linux before every push
- determinism: same fixture events twice ⇒ byte-identical serialized state
- idempotency: duplicate event-ID replay leaves state and counts unchanged
- hard filters: restricted recipes can never surface in `rank()` output
- explanation faithfulness: ablating a cited feature moves the score
- tests assert observable behaviour, not internals

Status: M1 in progress (events, features, serialization, engine surface).
M2 adds the model + rank + explanations + hard filters; M3 the profile
sentences, edits, expiry, and complete docs.
