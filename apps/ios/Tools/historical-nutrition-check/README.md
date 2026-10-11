# historical-nutrition-check

Linux-safe checks for the historical nutrition snapshot feature, compiled
against the REAL production persistence sources (`apps/ios/Platform/Persistence`)
and GRDB on Linux — no Xcode required.

## Run

```sh
bash Scripts/refresh.sh
swift test --package-path apps/ios/Tools/historical-nutrition-check
```

`Scripts/refresh.sh` copies the real sources into `Sources/NutritionCheck/Real/`
(gitignored — never edit those copies; edit the originals in `Platform/`).

## What is covered

- v20 migration backfill: row counts, provenance labels, frozen servings,
  line order (recipe_ingredients rowid), swap-ratio COALESCE, orphaned
  histories skipped, empty recipes completed with zero lines.
- Capture writer: fractional grams, substitute-applied effective values,
  unswapped ratio frozen as 1.0, all seven nutrients, stable line order.
- Rollback: an injected capture failure inside the composed logging
  transaction (history, swaps, streak, inventory lot/event/item) leaves no
  partial writes behind.
- Guards: NULL timestamps/consumed servings, unsupported snapshot versions.
