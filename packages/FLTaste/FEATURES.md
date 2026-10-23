# Recipe feature specification — `taste-features-v1`

The feature space turns catalog recipes into the vector the taste model
learns over. Every change to a feature, an extraction rule, or the
catalog-driven key set bumps the version string (`tasteFeaturesVersion`) and
is described here; snapshots record the version and refuse to restore across
a mismatch (fail closed).

The extractor is built from a `RecipeCatalog` (ingredients + recipes) and is
a pure function of `(recipe, catalog)`. All features are categorical with
one-hot (or value-weighted) encodings — on this data size, buckets beat raw
numeric values because a linear model on raw values must learn its own
non-linearity per feature, while buckets make every rule a single weight.

One feature is always present: `bias.one` (+1.0).

## Ingredient features (`ingredient.*`)

For each ingredient the recipe uses:

- required use → `ingredient.<id>` = **+1.0**
- optional use → `ingredient.<id>` = **+0.5**

Presence is the taste signal; an optional ingredient is half-evidence (the
user could have left it out). There is no separate `.opt` key. Vocabulary:
one key per catalog ingredient (the app ships 50 core ingredients).

## Cuisine features (`cuisine.*`)

The schema has no free-text cuisine field; cuisines are positional tags.
For each cuisine tag the recipe carries → `+1.0`:
`asian`, `mediterranean`, `mexican` (the catalog's entire cuisine vocabulary).

## Style features (`style.*`)

For each non-cuisine tag the recipe carries → `+1.0`:
`quick`, `vegetarian`, `vegan`, `breakfast`, `budget`, `comfort`,
`high_protein`, `low_carb`, `one_pot`.

## Time bucket (`time.*`)

`timeMinutes` (the recipe's total time) → exactly one of `le15`, `le30`,
`le60`, `gt60`.

## Effort bucket (`effort.*`)

Effort proxy: the number of **distinct ingredient kinds** (required ∪
optional ids). ≤6 → `simple`, ≤10 → `moderate`, else `involved`. The schema
has no effort field; distinct kinds is the documented v1 proxy.

## Servings bucket (`servings.*`)

Base servings: 1 → `one`, 2 → `two`, 3–4 → `threeToFour`, else `fivePlus`.

## Nutrition buckets (`nutrition.*`)

Per-serving macros, computed exactly the way the app computes them:
`(per-100g / 100) × grams` summed over used ingredients (required and
optional), divided by base servings.

- `nutrition.calorie`: ≤400 → `le400`, ≤650 → `400to650`, ≤900 → `651to900`,
  else `gt900`
- `nutrition.protein`: <15 g → `lt15`, ≤30 g → `15to30`, else `gt30`
- `nutrition.fiber`: <6 g → `lt6`, else `ge6`

## Spice level (`spice.*`)

The schema carries no heat value, so v1 derives it from fixed ingredient
lists: any ingredient in the **hot** list (`red_pepper_flakes`) → `hot`;
otherwise any **mild** ingredient (`ginger`, `cumin`) → `mild`; otherwise
`none`. Documented limitation: binary-ish, ingredient-derived, not a true
heat scale. A future version may add curated heat levels and bump the
version string.

## Cost proxy (`cost.*`)

The catalog has no price data in v1: recipes with the `budget` tag →
`budget`, all others → `standard`. Documented limitation.

## Technique features (`technique.*`)

The schema has no technique field. v1 derives techniques from instruction
text: case-insensitive substring search over the lowercased instructions,
every match recorded (a recipe can use several). Vocabulary and needles:

| Key | Needles |
| --- | --- |
| `technique.stirfry` | `stir-fry`, `stir fry`, `fry`, `wok` |
| `technique.boil` | `boil` |
| `technique.simmer` | `simmer` |
| `technique.bake` | `bake` |
| `technique.roast` | `roast` |
| `technique.grill` | `grill` |
| `technique.steam` | `steam` |
| `technique.marinate` | `marinate`, `marinade` |
| `technique.saute` | `sauté`, `saute` |
| `technique.toast` | `toast` |
| `technique.blend` | `blend` |
| `technique.mash` | `mash` |

Note: the `fry` needle inside `stirfry` means pan-fry text also matches
`stirfry` — a crude but deterministic and documented rule of v1.

## Complexity bucket (`complexity.*`)

Count of non-empty instruction lines (steps): ≤5 → `le5`, ≤8 → `6to8`,
else `gt8`.

## Vocabulary and restore semantics

`FeatureSpace(catalog:).keys` is the complete, sorted key list; indices are
positions in that array and are never serialized (the string form
`namespace.value` is the stable identity). Ingredient keys come from the
catalog, so a catalog change (e.g. a new core ingredient) changes the space;
that requires a feature-version bump per the rule above. When restoring a
snapshot whose log references recipes missing from the current catalog,
those recipes simply extract only `bias.one` (they are rankable but carry no
taste signal) — restore never fails on catalog content, only on a version
mismatch.

## Known limitations (accepted for v1)

1. Spice is ingredient-list-derived, not a true heat scale.
2. Cost is the `budget` tag, not a price model.
3. Techniques come from instruction substring matches, not a curated
   taxonomy; `fry` matches `stirfry` too.
4. Effort is distinct-ingredient count, not measured work.

None of these breaks determinism or the hard-filter guarantees. They bound
what taste can learn; the version string makes the limit explicit.
