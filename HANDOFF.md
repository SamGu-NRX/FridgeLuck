# Recipe amount export — handoff (L5)

Branch `obv/fl-l5-recipe-amount-export`, base `feat/minimal-product-20261007`.

## Objective
The recipe preview drawer gains "Export amounts": the user chooses an explicit positive serving count and a weight presentation, sees a prepared **immutable** UTF-8 text document of ingredient amounts (scaled once, substitution ratios applied once), then can share it natively or save it as a text file. Amount list only — cooking instructions are excluded (separate licensing question).

## Owned surfaces
- `apps/ios/FeatureLogic/RecipeExport/` — pure logic: intake validation, preparation, rendering, filename, drift, session state machine.
- `apps/ios/Feature/RecipeExport/` — SwiftUI sheet: serving/presentation controls, prepared preview, native share, file export, cancel/retry/reprepare.
- `apps/ios/Tools/recipe-amount-export-check/` — offline Linux test package (`swift test --package-path apps/ios/Tools/recipe-amount-export-check`).
- `apps/ios/Feature/Recipe/RecipePreviewDrawer.swift` — minimal entry/state wiring only.
- `apps/ios/DesignSystem/AppTheme.swift` / `AppMotion.swift` — additive tokens.

## Privacy / payload boundaries (enforced, sentinel-tested)
Never exported: journal photos/paths, profile or Health values, ratings, database IDs, OCR, tokens, private history. Attribution (HTTP/HTTPS via the existing parser interface) is shown when available; attribution is not a license grant. No upload, remote publisher, or account. Plain UTF-8 text only.

## Status
- Implemented and joined on this branch (tip e873744): logic + offline check package + sheet UI + drawer wiring + additive design tokens.
- `swift test --package-path apps/ios/Tools/recipe-amount-export-check`: **11 tests, 0 failures** (Linux Swift 6.4), independently re-run by the joining thread on the merged tree.
- Hosted iOS CI (no CI changes): `build-and-test` **pass** (7m03s) on the joined implementation; `dead-code-advisory` advisory-only.
- Unrun (no Apple host in this environment; no web mocks substituted): 390×844 / 1440×900 native fixture captures, on-device share/save trace, VoiceOver / large-type / keyboard-focus interaction evidence.
- The named design skills (`frontend-design`, `emil-design-eng`, `holistic-ux`, `animate`, `prep-for-prod`) are not present in this workspace's skill catalog; the intent was applied as additive `AppTheme`/`AppMotion` tokens with Reduce Motion honored.

## Left / how to continue
See the PR description's Handoff section (kept current on every push).
