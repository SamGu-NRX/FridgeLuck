# World Cuisine Recipe Originals — world-2026-10

An authored packet of **179 original recipes** for FridgeLuck's recipe catalog:
East Asian (57), Southeast Asian (34), MENA (34), and Americas/Europe (54)
entries. All recipe text and quantities are original work written for this
packet (`evidence/originals-rights-manifest.json` maps every `source_ref` to
its rights entry; there is no third-party recipe text).

## Layout

```
originals.jsonl              179 RS v1 records (build output, checked in)
build-report.json            slot/vegetarian counts from the last build
src/
  build_corpus.py            compiles src/recipes_*.py -> originals.jsonl
  recipes_east_asia.py       57 entries (korean, japanese, chinese)
  recipes_south_east_asia.py 33 entries (thai, vietnamese)
  recipes_mena.py            31 entries (middle_eastern, north_african)
  recipes_americas_europe.py 58 entries (west_african, caribbean,
                             latin_american, eastern_european)
  safety_lines.py            FSIS endpoint/rest/thermometer sentence constants
  fndds_registry.py          ingredient+unit -> pinned FNDDS row map
  check_packet.py            packet checker (rights, quantities, lint, gates)
  test_check_packet.py       14 planted-failure tests for the checker
evidence/
  originals-rights-manifest.json  179 rights entries
  allergen-classes-extension.json  classification table extension (see below)
```

The build and the checker depend on the pinned FNDDS household-measure table
from PR #50's MassConversionKit evidence (7,288 portion rows; pinned download
URL and archive hashes live with that PR). The checker also reads the pinned
recipes-suite at `$RS_SUITE_DIR` (default
`/tmp/fl-suite/evaluation/suites/recipes`) for `rs.py`, `bands.py`,
`allergens.json`, and the pinned `canon/rules.json` snapshot.

## Quantity evidence

Three quantity kinds, in priority order:

1. **Record-carried FNDDS conversion.** For ingredient+unit pairs with a
   matching pinned FNDDS row, the record carries `grams`, a
   `conversion_ref` (`fndds:<fdcId>`), and the row's grams-per-unit.
   `src/fndds_registry.py` maps 130+ ingredient/unit pairs to those rows,
   including arithmetically derived juice conversions (tbsp from floz).
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
compiler attaches the per-class check text (`src/safety_lines.py`) and the
pinned canon validates it. Camera framing stays out of the checks; no step
tells the user to judge doneness by color or texture alone.

## Classification extension

The pinned suite ships an allergen-classification fixture; world ingredients
outside it (gochujang, nuoc mam, hoisin, millet flour, fava beans, …) are
resolved by `evidence/allergen-classes-extension.json`, a conservative
extension the compiler and checker merge over the fixture. Every row that
assigns a meat/flesh safety class carries a note citing FSIS guidance (e.g.
`goat meat` is classified whole-cut-red per FSIS "Goat From Farm to Table":
145 °F plus a three-minute rest). The checker fails if any class-bearing row
loses its FSIS-citing note. Rows that only add a name exist to prevent
canon-keyword false positives: broad keywords misclassify condiments and
stocks (fish sauce, oyster sauce, broth) as raw flesh, so the packet uses
the specific condiment names with empty classes and a recorded rationale.

## Cuisine vocabulary mapping (lossy, documented)

RS v1 and bundle-v2 restrict `cuisine` to six values (asian, mediterranean,
indian, american, mexican, italian), while this packet documents real world
cuisines. Records keep the allowed `cuisine` value and carry the specific
region in the extension field `world_cuisine` (korean, japanese, chinese,
thai, vietnamese, middle_eastern, north_african, west_african, caribbean,
latin_american, eastern_european). The mapping is lossy and deterministic:

| world_cuisine | cuisine |
|---|---|
| korean, japanese, chinese, thai, vietnamese | asian |
| middle_eastern, north_african | mediterranean |
| west_african | indian |
| caribbean | american |
| latin_american | mexican |
| eastern_european | italian |

This is a compatibility workaround pending a spec revision that widens the
cuisine vocabulary; the checker enforces that the mapping stays consistent.

## Meal-slot coverage (disclosed)

179 records cover 205 slot assignments: **dinner 112, lunch 58, breakfast
35**. Lunch and dinner deliberately overlap — most rice, noodle, and soup
dishes are genuinely both. Breakfast is the thinnest slot (19.6% of
records) because world breakfast traditions are disproportionately
porridge, egg, and bread dishes, which the packet covers (congee and juk
variants, cháo gà, haus koko, ful medames, bissara, kai jiao, bánh mì ớp
la, huevos rancheros, cornmeal porridge, koose); it covers the slot without
pretending every cuisine maps cleanly onto three Western meal slots.

## Vegetarian coverage (disclosed)

**98/179 records (54.7%)** are vegetarian under a conservative classifier:
a record is non-vegetarian if any ingredient resolves (via the merged
classification table or canon keywords) to a meat, poultry, fish, or
shellfish class, or is a named animal product the class tables miss (nuoc
mam, dashi, chicharrones, salted duck egg, …). Well above the one-third
release gate.

## Suite-runner integration gap (disclosed)

PR #113's corpus validator hardcodes `fl-original-NNNN` record IDs and the
`overhaul/original-recipes` provenance form; this packet uses `fl-world-NNNN`
IDs and its own rights manifest, so that validator cannot run against this
packet without falsifying provenance or editing suite code (both out of
scope). `src/check_packet.py` is the packet's equivalent validator: same
pinned suite linter and canon, packet-local rights and evidence paths.

## Verifying

```bash
# rebuild (optional; originals.jsonl is checked in)
python3 src/build_corpus.py

# packet checker: rights, recomputed quantities, pinned lint, gates
python3 src/check_packet.py

# 14 planted failures must each be caught
python3 src/test_check_packet.py
```

Expected: checker prints `checked 179 records … PASS`; tests print
`14/14 planted failures caught`. Exact recorded outputs are in
`VALIDATION.md`.
