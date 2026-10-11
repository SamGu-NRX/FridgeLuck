# Bundled-data input contract

What a new bundle must satisfy so `BundledDataRefresher` can install it on
existing installs. This is the path the expanded recipe corpus ships through.
The refresh runs at every launch, inside one transaction, and refuses the whole
payload when anything is wrong: a bundle that half-validates never reaches
installed rows.

## Files

| File | Role |
|---|---|
| `apps/ios/Resources/data.json` | The current payload: ingredients, recipes, tags. |
| `apps/ios/Resources/usda_ingredient_catalog.sqlite` | The current USDA catalog rows (read-only at refresh time). |
| `apps/ios/Resources/LegacyBundles/manifest.json` | Pins: the exact payloads past public releases hydrated from. |
| `apps/ios/Resources/LegacyBundles/v*_*.json` | Pinned payload and catalog-export files the manifest names. |

`Scripts/data/check_legacy_bundle_pins.py` must pass on every change to these
files: it recomputes the SHA-256 digests the manifest records and the catalog
row count it promises. Pins are **adoption evidence only** — they tell the
refresher what an old install's rows look like so those rows can be adopted.
They are never re-applied as current content; a pinned catalog never overwrites
the shipped catalog.

## data.json schema

Positional arrays, decoded by `BundledDataLoader` (`BundledData`,
`IngredientArray`, `RecipeArray`). Field order is the contract.

```json
{
  "tags": ["breakfast", "dinner"],
  "ingredients": {
    "1": ["egg", 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14,
          "piece", "keep cold", "salt", null]
  },
  "recipes": [[7, "Egg Bowl", 15, 1, [[1, 100.0], [2, 200.0]], [[3, 5.0]],
               "Cook it.", 3]]
}
```

- Ingredient entry, in order: `[name, calories, protein, carbs, fat, fiber,
  sugar, sodium, typicalUnit, storageTip, pairsWith?, notes?]`. The last two
  may be `null` or omitted; everything before them is required.
- Recipe entry, in order: `[id, title, timeMinutes, servings,
  requiredPairs, optionalPairs, instructions, tagBitmask]`, where each pair is
  `[ingredientId, grams]`. `tagBitmask` indexes into the top-level `tags`.
- `ingredients` keys are decimal strings of integer ids.

## Validation (all-or-nothing)

`BundledDataValidator` runs before any write and collects every problem:

- Ingredient ids are integers; names are non-blank; the seven nutrition
  doubles are finite and non-negative; normalized names (case- and
  whitespace-insensitive) are unique.
- Recipe titles are non-blank and uniquely normalized; `timeMinutes >= 1`;
  `servings >= 1`; `tagBitmask >= 0`; instructions non-blank.
- Every required and optional pair references an ingredient id present in the
  same payload, with finite positive grams.

Any failure throws `BundledDataValidationError` listing all problems; the
launch path logs the refusal and retries on the next launch. Fix everything it
names, not just the first line.

## ID stability rules

The ownership key (`fridgeluck.bundle.ingredient/<id>`,
`fridgeluck.bundle.recipe/<id>`, `usda.fdc/<fdcId>`) is the identity a row is
adopted and updated under. `BundleOwnership` defines them; they are stable
across bundle content versions by design — the id, not the name, is what an
installed row answers to.

- **Never reuse an id for a different dish.** A reused id updates the same
  owned row in place: every meal in the cooking journal that points at that
  row now describes the new dish (the row id, and therefore the reference,
  survives). To replace a dish, ship it under a fresh id and drop the old id
  from the payload. `testReusingABundleIdRewritesTheDishInPlaceAndTheJournalFollowsIt`
  pins this behavior.
- **New entries get ids never used before** in any shipped payload. A fresh id
  inserts a new owned row; a retired id kept retired costs nothing.
- **Removing an entry** (id absent from `data.json`, catalog absent from the
  shipped sqlite) never deletes the row. The pass writes a
  `bundle_refresh_diagnostics` row with code `removed_from_bundle` ("the
  current bundle no longer ships this entry; row kept") and the row keeps its
  last owned content. Because `cookingJournal` joins `cooking_history` to
  `recipes`, and the recipe row survives, meals that reference a removed
  recipe stay readable, with their macros coming from the frozen v20 snapshot.
  `testMealReferencingARemovedRecipeStaysInTheJournalAfterTheRefresh` and
  `testEntriesRemovedFromTheBundleAreRecordedAndKept` pin this.
- **Renaming is safe**; identity follows the id, so a renamed ingredient or
  recipe updates in place and history keeps its subject.

## What the refresh may not disturb

Adoption and updates distinguish bundle-written columns from user edits:
`bundle_content_hash` captures what the bundle last wrote, so a row the user
edited (any column in the row-hash projection differs without a matching
diagnostic) wins over the payload (`testOwnedRowTracksPayloadChangesButUserEditsWin`).
Historical outputs — the cooking journal, daily macro totals, and Apple Health
record values — read the v20 frozen snapshots, so a changed bundle leaves them
bit-identical (`testChangedBundleRefreshKeepsJournalDailyAndHealthOutputsBitIdentical`).

## USDA catalog sqlite

The shipped file carries one `ingredients` table:
`id` (= FDC id, the ownership identity), `name`, `calories`, `protein`,
`carbs`, `fat`, `fiber`, `sugar`, `sodium`, `notes`, `description`,
`category_label`, `sprite_group`, `sprite_key` (the last four may be NULL and
are read as empty strings). FDC ids follow the same stability rules as bundle
ids; `usda.fdc/<fdcId>` never names two different foods across releases.

## Shipping a corpus bump

1. Regenerate `data.json` and `usda_ingredient_catalog.sqlite` from the corpus
   pipeline (rights-cleared per SPEC 3.5).
2. Pin the PREVIOUS release's exact payload in `LegacyBundles/` (or confirm it
   is already pinned) and add its manifest entry, so installs of that release
   can adopt their rows.
3. Run `python3 scripts/data/check_legacy_bundle_pins.py` — it must pass.
4. Run the Linux checks (see `Tools/bundled-refresh-check/README.md`) — the
   launch-path tests exercise the real resources end to end.
5. Xcode-side: confirm the app target ships `data.json`,
   `usda_ingredient_catalog.sqlite`, and the `LegacyBundles` folder (resource
   bundling is UNVERIFIED-NATIVE in this environment).
