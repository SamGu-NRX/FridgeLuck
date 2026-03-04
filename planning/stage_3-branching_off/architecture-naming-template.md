# FridgeLuck Architecture + Naming Template

## Taxonomy (locked)
- `App/`: composition root and navigation shell only.
- `Feature/*`: user journeys and screen flows.
- `Capability/Core/*`: reusable business engines (recognition/intelligence/orchestration).
- `Platform/Persistence/*`: storage, migrations, repositories, file IO, platform services.
- `Domain/Models` and `Domain/Ports`: shared model contracts and protocol seams.
- `DesignSystem/`: shared visual language (theme, motion, components).

## Naming conventions
- Use feature-first folders: `Feature/Scan`, `Feature/Home`, `Feature/Ingredients`, etc.
- Use feature-prefixed type names in shared module scope:
  - `ScanView`, `ScanAnalyzingView`, `HomeInsightSection`, `IngredientReviewSummarySection`.
- Avoid namespace wrapper enums as type containers.
- Avoid ambiguous buckets (`Helpers`, `Manager`, `Utils`) unless narrowly scoped and justified.

## Feature folder template
- Always start flat for small features.
- Add subfolders only when a feature grows enough to justify them (guideline: 5+ files).
- Suggested subfolders as needed:
  - `Sections/` for large screen composition parts
  - `Components/` for reusable local UI pieces
  - `State/` for extracted screen-local state types
  - `ViewModel/` when presentation logic gets non-trivial

## Cohesion guidance (not hard LOC limits)
- LOC is a signal, not a strict rule.
- Split when a file has multiple reasons to change.
- Keep root screens orchestration-focused; push rendering-heavy chunks into sections/components.
- Prefer extraction over behavior rewrites.

## Dependency guidance
- Feature code should prefer seams/ports when crossing volatile boundaries.
- Add abstractions only when there is real need:
  - multiple implementations now,
  - imminent second implementation,
  - test seam needed,
  - or repeated coupling across consumers.
