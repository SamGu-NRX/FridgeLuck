# ingredient-facts-check

Offline Swift package that verifies the ingredient facts logic on Linux, without Xcode,
an app target, or a simulator.

## Why the logic target is a symlink

`Sources/IngredientFactsLogic` is a symlink to `../../../FeatureLogic/IngredientFacts`.

The tests compile the same `IngredientFactsModel.swift` file that the app's
`FLFeatureLogic` framework compiles. A change to the production source is picked up by
the next run, so this check cannot drift into testing a stale transcription.

## Running

From the repo root:

```bash
swift test --package-path apps/ios/Tools/ingredient-facts-check
```

The manifest declares `swift-tools-version:5.10`. The suite runs with Swift 6.4 on Linux
and needs no network access.

## Suite layout

One test class, `IngredientFactsCheckTests`, in
`Tests/IngredientFactsCheckTests/IngredientFactsCheckTests.swift`, grouped by what it
verifies about `IngredientFactsModel`:

- Reference values: stored sodium converted from grams to milligrams exactly once, and
  stored energy carried through untouched instead of re-derived from macro factors.
- Portions: preset and fractional weights scale the reference linearly through the same
  text-parsing path the portion field uses.
- Invalid input: empty, non-numeric, non-finite, non-positive, and overflowing weights
  each resolve to their specific error, and every path leaves the reference unchanged.
- Descriptions: supplied text is carried verbatim and no error message claims a source
  for a description-free record.
- Unusable stored nutrition: a non-finite stored value fails portion requests while the
  reference still displays.
- Display formatting for grams, kilocalories, and milligrams, including non-finite
  values.

As of the base commit 32c2178 the suite has 18 tests. Per-group counts are deliberately
omitted so this list does not go stale as tests are added.

## Relation to the hosted CI bridge tests

`.github/workflows/ios-ci.yml` runs on macOS and covers what this package cannot:
compiling the model with the app target, and running
`apps/ios/Tests/IngredientFactsModelTests.swift`, which checks the sheet's mapping from
the stored `Ingredient` record and the preferences weight echo. This package verifies the
pure logic offline on Linux; the hosted workflow verifies the app-facing bridge on macOS.
