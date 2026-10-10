# Attribution and source limits

## Source

All groups and probes derive from the app's own bundled catalog:

- `apps/ios/Resources/usda_ingredient_catalog.sqlite` (800 records, sha256 pinned
  in `manifest.json`). Names are SR Legacy-style USDA descriptions; the
  parenthetical descriptors (e.g. "(Dried)", "(Raw, Lean)", "(Canned, Heavy
  Syrup, Drained)") are the only source of preparation-state labels.

## What the source establishes and what it does not

- Canonical states (`raw`, `cooked`, `dried`, `frozen`, `canned`) are mapped
  only from descriptor tokens the source spells out; canonical state is always
  coarser than or equal to the source wording ("Smoked, Cooked" -> `cooked`).
- Cooking method, fat-trim level, added salt/syrup, and variety are NOT part of
  a probe's state; probes never contain those words (enforced by
  `check_manifest.py`).
- The catalog is the app's curated 800-record slice, not all of FDC. Record ids
  are the app's own catalog ids (FDC-derived), not live FDC ids.
- Nutrient values are per 100 g for 7 fields (calories, protein, carbs, fat,
  fiber, sugar, sodium) as pinned in the SQLite file. The manifest does not
  copy nutrient values; analyses read the pinned file at run time.

## Synthetic labels

Probe texts are synthetic constructions (`<surface word> <group base>`), not
observations. Labels point at pinned record ids or abstain; `check_manifest.py`
verifies labels stay within their group and that unknown-state probes name a
state no group member establishes.
