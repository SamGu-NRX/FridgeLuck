# Original recipe corpus — data/recipes/originals

Original RS-format recipes authored for FridgeLuck (overhaul SPEC: "many more
and better recipes"). Status: **scaffold + smoke tests**; corpus authoring runs
in six parallel writer threads, one branch/PR each, landing on
`fleet/fl-recipe-originals`.

- **Format:** RS — `evaluation/suites/recipes/rs.py` (suite C, PR #88) is the
  grammar and linter. The food-safety rulebook (PR #97, SCHEMA.md) aligns the
  corpus to this format. Open question recorded in the PR: whether ingestion
  also wants an RS→RecipeRevision (PR #90 fixture) converter here or in the
  ingestion task.
- **Format status note:** no `data/recipes/SCHEMA.md` exists on alpha yet
  (PR #97 lands `data/food-safety/SCHEMA.md`, a different document). When a
  corpus schema lands, reconcile; RS is authoritative until then.
- **Conventions:** `AUTHORING.md` (binding).
- **Validation gate:** `python3 data/recipes/originals/tools/validate.py --all`
  (suite linter + rights + craft layer), nutrition via
  `tools/nutrition.py` (bundled USDA catalog only), counts via
  `tools/counts.py --write-report`, dedupe via `tools/dedupe_check.py --all`.
- **Pin:** suite C `26c7004e`, rulebook `fd0b75f3`, alpha `2e779381` —
  `tools/SUITE-PIN.json`.

## Layout

| Dir | prefix | scope |
|---|---|---|
| `part1-rewrite/` | `rw-` | rewrite of each bundled recipe (all 166), fixing the audit findings (safety steps, sodium, budget/time-tag data) |
| `east-southeast-asian/` | `ea-` | originals, suite cuisine `asian` |
| `south-asian/` | `sa-` | originals, suite cuisine `indian` |
| `middle-east-north-africa/` | `me-` | originals, suite cuisine `mediterranean` |
| `latin-american/` | `la-` | originals, suite cuisine `mexican` |
| `european-american/` | `eu-` | originals, suite cuisine `american`/`italian` |

`tables/` shards (conversions, nutrition-map, compound-allergens extensions,
rights-manifest, cost-assumptions) live inside each part so writer threads
never edit a shared file. `tools/compound-allergens.json` is the shared seed.

## Untested status

Every recipe ships `"test_status": "untested"`. Claims are machine-verified
(allergen recompute + compound table) and quantities evidence-backed, but no
recipe here has been cooked or platform-audited. That is the corpus's declared
state, not a hidden gap.

<!-- COUNTS:BEGIN -->
<!-- COUNTS:END -->
