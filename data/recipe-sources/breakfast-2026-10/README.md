# Breakfast Recipe Originals — breakfast-2026-10

An authored packet of **30 original breakfast recipes** for FridgeLuck's
recipe catalog, spread across 15 world regions. All recipe text and
quantities are original work written for this packet
(`evidence/originals-rights-manifest.json` maps every `source_ref` to its
rights entry; there is no third-party recipe text).

## Layout

```
originals.jsonl              30 RS v1 records (build output, checked in)
build-report.json            line/vegetarian/fast15/known-composition counts
reach-report.json            pantry-reach analysis over the ten named fixtures
src/
  build_batch.py             compiles src/recipes_breakfast.py -> originals.jsonl
  recipes_breakfast.py       30 entries across 15 regions
  fndds_registry.py          ingredient+unit -> pinned FNDDS row map
                             (34 direct + 8 derived conversions)
  check_batch.py             packet checker (rights, quantities, lint, gates)
  test_check_batch.py        19 planted-failure tests for the checker
  reach_report.py            pantry-reach analysis (see below)
evidence/
  originals-rights-manifest.json  30 rights entries
  fndds-portions.json             36 pinned FNDDS portion rows cited by the registry
  allergen-classes-extension.json classification table extension (see below)
```

The build and the checker depend on the pinned FNDDS household-measure table
from PR #50's MassConversionKit evidence (7,288 portion rows; pinned download
URL and archive hashes live with that PR; `/tmp/mck.json` when validating —
see README "Verifying" and VALIDATION.md for the restore commands). The
checker also reads the pinned recipes-suite at `$RS_SUITE_DIR` (default
`/tmp/fl-suite/evaluation/suites/recipes`) for `rs.py`, `bands.py`,
`allergens.json`, and the pinned `canon/rules.json` snapshot
(overhaul/food-safety-canon @ 2e03467d).

## Quantity evidence

Three quantity kinds, in priority order:

1. **Record-carried FNDDS conversion.** For ingredient+unit pairs with a
   matching pinned FNDDS row, the record carries `grams`, a
   `conversion_ref` (`fndds:<fdcId>`), and the row's grams-per-unit.
   `src/fndds_registry.py` maps the packet's ingredient/unit pairs to
   those rows.
2. **Recipe-stated metric mass** (`source_grams`), used where a recipe is
   conventionally written in grams.
3. **Unknown**, for genuinely unquantified amounts ("to taste", garnish);
   every unknown line carries a note.

The checker recomputes every carried grams value from the pinned table —
it verifies the conversion, it does not trust the record's copy.

## Food-safety checks

Raw-animal ingredients carry FSIS-sourced doneness checks: a class-specific
metadata block, a canon-resolving FSIS source, a cook-visible Fahrenheit
thermometer reading, and the required rest stated in the same step. The
compiler attaches the per-class check text from the pinned suite and the
pinned canon validates it. The packet's egg dishes all carry the 160 °F
egg check; the shrimp in the Vietnamese crepe carries the 145 °F shellfish
check. No step tells the user to judge doneness by color or texture alone.

## Classification extension

The pinned suite ships an allergen-classification fixture; breakfast
ingredients outside it are resolved by
`evidence/allergen-classes-extension.json` (35 ingredient rows, 36
aliases), a conservative extension the compiler and checker merge over the
fixture. It is a subset of the world-2026-10 packet's extension (same
pinned source) plus breakfast-specific rows such as `glutinous_rice`
(empty classes — no meat/flesh class to assign, and the row prevents
canon-keyword false positives). The checker fails if any class-bearing row
loses its FSIS-citing note.

## Cuisine vocabulary mapping (lossy, documented)

RS v1 and bundle-v2 restrict `cuisine` to six values (asian, mediterranean,
indian, american, mexican, italian), while this packet documents real world
regions. Records keep the allowed `cuisine` value and carry the specific
region in the extension field `world_cuisine` (american, british,
caribbean, chinese, eastern_european, indian, japanese, korean,
latin_american, mediterranean, middle_eastern, north_african, thai,
vietnamese, west_african). The mapping is lossy and deterministic:

| world_cuisine | cuisine |
|---|---|
| chinese, japanese, korean, thai, vietnamese | asian |
| mediterranean, middle_eastern, north_african | mediterranean |
| indian, west_african | indian |
| american, british, caribbean | american |
| latin_american | mexican |
| eastern_european | italian |

This is a compatibility workaround pending a spec revision that widens the
cuisine vocabulary; the checker enforces that the mapping stays consistent.
The `british → american` fold is the lossiest one in the packet.

## Breakfast gates (brief requirements)

The checker enforces the brief's three breakfast-specific gates:

1. **Fast pool:** at least 12 recipes are 15 minutes or less — the packet
   ships 19.
2. **Known-composition pool:** more than 10 recipes intended vegan or
   gluten-free have fully known ingredient composition — the packet ships
   22. The count derives from the app's own `vocabulary.json` classes;
   ingredients with unknown diet classes fail the recipe for the pool
   (fail closed).
3. **No title collisions:** normalized titles may not collide inside the
   batch or with any title already in `data/recipes/corpus.jsonl`.

## Vegetarian coverage

**28/30 records (93.3%)** are vegetarian under a conservative classifier:
a record is non-vegetarian if any ingredient resolves (via the merged
classification table or canon keywords) to a meat, poultry, fish, or
shellfish class, or is a named animal product. The two non-vegetarian
recipes carry the fish (smoked salmon) and shrimp shellfish classes.
Well above the one-third release gate.

## Meal-slot coverage

All 30 records are `breakfast`-slot. Several (rice porridge, congee,
breakfast tacos) would honestly serve lunch or dinner too, but the packet
claims only the slot it was authored and checked for.

## Pantry reach (disclosed)

`reach-report.json` runs the packet over the ten named pantry fixtures from
`evaluation/catalog-reach/pantries-v2.json` with the project's exact
resolution semantics (compile_bundle staple keys, reach-v2 exact written-name
transforms, app `name-mappings.json` identities; no similarity guessing).
Result: **0–1 recipes cookable now and 3–5 near-cookable (≤2 missing lines)
per pantry.** That low number is a property of the fixture set, not the
packet: those ten pantries were authored for the lunch/dinner packet
(pantry-2026-10) and carry almost no breakfast-specific ingredients (only
one fixture has eggs; none carry tofu, besan, miso, or smoked salmon). The
report's per-pantry `top_missing_ingredients` lists what a
breakfast-oriented fixture set would need. This analysis is informational;
it is not a release gate for the packet.

## Suite-runner integration gap (disclosed)

PR #113's corpus validator hardcodes `fl-original-NNNN` record IDs and the
`overhaul/original-recipes` provenance form; this packet uses `fl-bfast-NNNN`
IDs and its own rights manifest, so that validator cannot run against this
packet without falsifying provenance or editing suite code (both out of
scope). `src/check_batch.py` is the packet's equivalent validator: same
pinned suite linter and canon, packet-local rights and evidence paths.

## Verifying

```bash
# one-time: restore the pinned inputs (see VALIDATION.md "Environment")
mkdir -p /tmp/fl-suite/evaluation/suites
cp -r data/recipes/suite /tmp/fl-suite/evaluation/suites/recipes
# note: the suite's rs.py/bands.py/allergens.json must be the pinned copies
# from data/recipe-sources/world-2026-10/src/ (this checkout's copy predates
# the pinned snapshot) and canon/rules.json from overhaul/food-safety-canon
# @ 2e03467d:data/food-safety/rules.json
git show origin/obv/fl-l2-mass-evidence:scripts/data/reference/household_measures/mass_conversion_table.json > /tmp/mck.json

# rebuild (optional; originals.jsonl is checked in and deterministic)
python3 src/build_batch.py

# packet checker: rights, recomputed quantities, pinned lint, gates
python3 src/check_batch.py

# 19 planted failures must each be caught
python3 src/test_check_batch.py

# pantry-reach analysis (informational)
python3 src/reach_report.py
```

Expected: checker prints `checked 30 records … PASS`; tests print
`19/19 planted failures caught`. Exact recorded outputs are in
`VALIDATION.md`.
