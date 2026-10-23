# FLFoodSafety

Foundation-only SwiftPM package implementing FridgeLuck's reviewed food-safety
knowledge base (SPEC 3.1). Builds and tests on Linux; no UIKit/SwiftUI/GRDB.

- `Rulebook` — strict decoder for `data/food-safety/rules.json`. Fails loudly
  on schema violations: unknown keys, unknown topics or food classes, missing
  citations, inconsistent temperatures.
- `DonenessLookup` — maps an ingredient name or recipe step to the applicable
  thermometer check (food class, safe minimum in °F/°C, placement, rest time).
- `StepLinter` — flags unsafe phrasing in recipe steps and proposes safe
  rewrites. Forbidden phrases mirror `rs.py`'s `_COLOUR_OR_TIME_DONENESS`
  (golden, no longer pink, cooked through, no longer translucent, opaque,
  browned through, firm to the touch) plus "juices run clear" and "no pink".
- `BundledRecipeAudit` — parses the bundled positional `data.json` and renders
  the deterministic audit report.

## Regenerate the bundled-recipe audit

From the repository root:

```sh
swift build -c release --package-path packages/FLFoodSafety
packages/FLFoodSafety/.build/release/flfoodsafety-audit --repo-root . > data/food-safety/BUNDLED-RECIPE-AUDIT.md
```

The report is byte-identical for the same rulebook and corpus (no timestamps,
no locale dependence); a test asserts the renderer is deterministic.

## Test

```sh
swift test --package-path packages/FLFoodSafety
```
