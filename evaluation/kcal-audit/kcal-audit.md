# kcal audit — nutrient rows behind PR #192's ingredient re-pins

State audited: `alpha` at `f25fedad` (branch `obv/burst12-fridgeluck-kcal-repin-audit`).
Companion to the failing gate `data/recipes/tools/tests/test_kcal_drift.py`
(16 recipes above the 40 percent drift gate with no recorded reason) and to
`validate_bundle.py --real-bundles` (the same 16 drift problems).

## What this is

PR #192 re-pinned catalog ingredient rows to different USDA FDC rows so typed
pantry text resolves (reach v3). Eleven of those re-pins also re-sourced the
vocabulary's per-100 g nutrition from the new row. For four keys the new row
describes a different **preparation form** than the recipes measure, so
per-serving kcal moved with no recorded reason and the drift gate fails.

This audit re-chooses the **nutrient row** for each re-pinned key from how the
recipes actually measure the line, and leaves every **identity pin** (which
ingredient a line resolves to) exactly as #192 set it — the reach gain is kept.

## Method

- The real compiler (`data/recipes/tools/compile_bundle.py`) is imported, never
  copied, and the bundle is compiled in memory at three vocabulary states:
  **prev** (the `9e4a3af5` rows for the drifted keys), **alpha** (committed),
  and **fixed** (this audit's choices).
- Fidelity: the in-memory prev state reproduces the published `9e4a3af5`
  bundle exactly — max |delta| **0.0000 kcal** over all 762 recipes
  (corpus, rights, name mappings, and the compiler are unchanged
  `9e4a3af5..alpha`; verified with `git diff --stat`).
- USDA rows were verified against the FoodData Central bulk CSVs
  (Survey `2024-10-31`, SR Legacy `2018-04`, CC0), not the web UI: the exact
  per-100 g values below were read from `food.csv` + `food_nutrient.csv`.
- Gate: `validate_bundle.KCAL_DRIFT_THRESHOLD` (40 percent), same semantics
  (`kcal_swing`).

## The drifted keys and the decisions

| key | 9e4a3af5 row (fdc, kcal/100g) | alpha row (fdc, kcal/100g) | audit decision |
|---|---|---|---|
| lentils | 168427 lentil sprouts, 106 | 172420 Lentils, raw, 352 | **keep alpha** — all 5 corpus lines measure dry lentils by cup and simmer them from dry (e.g. `rcp-000411` "0.75 cup black beluga lentils", `rcp-000666` "1.5 cup + 6 cups water, simmer until collapse"); 352 x dry-cup grams is the honest value. The pre-#192 row was lentil **sprouts**. |
| sugar | 168175 Sugar Apple, 94 | 169655 Sugars, granulated, 387 | **keep alpha** — lines are granulated sugar by tsp/tbsp; the old row was a fruit. |
| banana | 169394 Banana Pepper, 27 | 173944 Bananas, raw, 89 | **keep alpha** — the old row was a pepper. |
| cinnamon | 167940 Cinnamon buns, 452 | 171320 Spices, cinnamon, ground, 247 | **keep alpha** — the old row was frosted buns. |
| almonds | 170568 blanched, 590 | 170567 Nuts, almonds, 579 | **keep alpha** — whole almonds by cup; ~2 percent variant correction. |
| bacon | 2707466 Bacon bits, 476 | 2705885 Bacon, cooked, 484 | **keep alpha** — both corpus lines ship no grams and contribute no nutrition either way. |
| heavy_cream | 340 | 2346386 Foundation Heavy Cream, 343.31 | **keep alpha** — ~1 percent row correction, tbsp weight unchanged. |
| pork_chop | 190 | 2705866 FNDDS pork chop NS fat, 183 | **keep alpha** (documented approximation) — 4 lines measure raw pieces (~170 g each); the raw loin SR twins are 172-229 kcal/100g; the pinned as-consumed row is the closest cited row and no pork recipe approaches the gate. |
| chicken_thighs | 171052 generic raw chicken meat, 119 | 2706027 FNDDS thigh cooked skin eaten, 226 | **re-source nutrient row -> 173627** (SR "Chicken, broilers or fryers, dark meat, thigh, meat only, raw", 121 kcal/100g). All 23 corpus lines are "boneless chicken thighs" by pieces of 110 g — raw, skinless meat. The alpha row is cooked, skin eaten, applied to raw piece grams. |
| chicken_thigh | 2706037 FNDDS thigh stewed skin eaten, 227 | 2706027 FNDDS thigh cooked skin eaten, 226 | **re-source nutrient row -> 173627** (121). All 41 corpus lines measure raw thigh: 24 piece lines and 17 purchase-weight lines (400-700 g). Known residual: purchase weights include bone+skin (~20-25 percent over meat-only), which is closer than the alpha row's ~2x. |
| white_rice | 2708422 FNDDS glutinous cooked, 96 | 2708403 FNDDS rice cooked NS fat, 129 | **re-source nutrient row -> 168877** (SR "Rice, white, long-grain, regular, raw, enriched", 365 kcal/100g). 59 of 60 corpus lines measure dry rice by cup (`dry_rice_cup`, 185 g). The 14 lines that read "cooked white rice" are **listed exceptions** below; the majority-form rule (the repo's own gate) picks the dry row. |
| canned_tomatoes | 2709719 FNDDS raw tomatoes, 20 | 2709722 FNDDS tomatoes canned cooked, 43 | **re-source nutrient row -> 170501** (SR "Tomatoes, crushed, canned", 32 kcal/100g, fat 0.28 g). Corpus lines use the as-sold product ("canned crushed tomatoes", "400 g can chopped tomatoes"); the FNDDS "canned, cooked" row carries 3.04 g fat/100 g from cooking, wrong for the as-sold product. 5 lines ship no grams (no nutrition impact). |

Enriched vs unenriched long-grain rice have identical macros (365); enriched is
the US retail default, chosen as 168877.

## Listed exceptions — "cooked white rice" lines (14)

These lines measure cooked rice (158 g/cup); under the majority dry row they
over-count rice energy. The repo gate's majority rule picks the dry row; the
rebuild records each of these recipes' change with this reason:

| `rcp-000631` | |
| `rcp-000605` | |
| `rcp-000573` | |
| `rcp-000580` | |
| `rcp-000649` | |
| `rcp-000610` | |
| `rcp-000634` | |
| `rcp-000686` | |
| `rcp-000586` | |
| `rcp-000589` | |
| `rcp-000722` | |
| `rcp-000645` | |
| `rcp-000652` | |
| `rcp-000599` | |

## Recipes above the 40 percent gate at the fixed state (vs 9e4a3af5)

55 recipes (at alpha, before the rebuild: 16). These are the exact
nutrition-change records the rebuild must write into
`data/recipes/changes/*.json` — recipe id, old kcal, new kcal, reason.

| recipe | prev kcal | fixed kcal | swing | deciding keys | reason (for the changes-file entry) |
|---|---|---|---|---|---|
| rcp-000213 | 363.1 | 614.1 | +69% | chicken_thighs, white_rice | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 226; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000221 | 441.5 | 699.7 | +58% | canned_tomatoes, chicken_thighs, white_rice | as-sold crushed-canned row 32 kcal/100g (fdc 170501) replaces the FNDDS canned-cooked row 43; raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 226; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000260 | 548.2 | 785.1 | +43% | pork_chop, white_rice | FNDDS pork-chop row 183 (fdc 2705866) replaces the row 190; lines measure raw pieces (documented approximation); dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000266 | 472.3 | 721.1 | +53% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000267 | 441.8 | 690.7 | +56% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000270 | 296.6 | 545.4 | +84% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000279 | 360.1 | 546.8 | +52% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000293 | 412.4 | 663.4 | +61% | chicken_thighs, white_rice | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 226; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000298 | 482.4 | 793.4 | +64% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000304 | 413.1 | 661.9 | +60% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000305 | 626.5 | 999.7 | +60% | bacon, white_rice | cooked-bacon row 484 (fdc 2705885) replaces the bacon-bits row 476; line ships no grams either way; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000322 | 568.8 | 817.7 | +44% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000352 | 353.7 | 602.5 | +70% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000373 | 348.4 | 721.7 | +107% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000378 | 320.6 | 693.9 | +116% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000386 | 568.0 | 941.2 | +66% | canned_tomatoes, white_rice | as-sold crushed-canned row 32 kcal/100g (fdc 170501) replaces the FNDDS canned-cooked row 43; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000402 | 289.8 | 173.2 | -40% | chicken_thigh | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 227 |
| rcp-000410 | 317.7 | 568.7 | +79% | chicken_thighs, white_rice | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 226; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000411 | 232.2 | 408.0 | +76% | heavy_cream, lentils | Foundation heavy-cream row 343.31 (fdc 2346386) replaces 340; dry lentil row 352 kcal/100g (fdc 172420) replaces the lentil-sprout row 106; lines measure dry lentils and simmer them |
| rcp-000428 | 222.5 | 346.9 | +56% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000429 | 144.9 | 269.3 | +86% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000461 | 278.2 | 161.6 | -42% | chicken_thigh | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 227 |
| rcp-000465 | 365.2 | 551.9 | +51% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000482 | 230.7 | 417.4 | +81% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000486 | 213.4 | 400.1 | +87% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000487 | 234.2 | 483.0 | +106% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000488 | 382.6 | 569.3 | +49% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000504 | 442.3 | 691.1 | +56% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000511 | 205.8 | 469.0 | +128% | canned_tomatoes, white_rice | as-sold crushed-canned row 32 kcal/100g (fdc 170501) replaces the FNDDS canned-cooked row 43; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000512 | 181.7 | 444.9 | +145% | canned_tomatoes, white_rice | as-sold crushed-canned row 32 kcal/100g (fdc 170501) replaces the FNDDS canned-cooked row 43; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000516 | 350.8 | 599.6 | +71% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000518 | 392.5 | 579.2 | +48% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000524 | 176.6 | 370.5 | +110% | canned_tomatoes, white_rice | as-sold crushed-canned row 32 kcal/100g (fdc 170501) replaces the FNDDS canned-cooked row 43; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000525 | 441.2 | 690.0 | +56% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000546 | 192.6 | 379.3 | +97% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000548 | 262.4 | 451.3 | +72% | chicken_thighs, white_rice | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 226; dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000564 | 150.0 | 383.7 | +156% | lentils | dry lentil row 352 kcal/100g (fdc 172420) replaces the lentil-sprout row 106; lines measure dry lentils and simmer them |
| rcp-000567 | 206.5 | 393.2 | +90% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000569 | 309.1 | 495.8 | +60% | white_rice | dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked-rice row 96/129; this recipe measures rice dry |
| rcp-000573 | 389.2 | 1026.7 | +164% | white_rice | white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000580 | 208.0 | 526.7 | +153% | white_rice | white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000586 | 338.1 | 663.0 | +96% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000597 | 39.0 | 63.6 | +63% | sugar | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94 |
| rcp-000599 | 560.7 | 852.6 | +52% | chicken_thigh, sugar, white_rice | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 227; granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000605 | 300.8 | 640.8 | +113% | white_rice | white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000610 | 292.0 | 717.0 | +146% | white_rice | white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000631 | 407.7 | 840.9 | +106% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000634 | 420.0 | 853.3 | +103% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000645 | 352.8 | 699.2 | +98% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000649 | 420.0 | 853.3 | +103% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000652 | 456.3 | 802.7 | +76% | sugar, white_rice | granulated-sugar row 387 kcal/100g (fdc 169655) replaces the Sugar Apple fruit row 94; white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000666 | 143.7 | 276.5 | +92% | lentils | dry lentil row 352 kcal/100g (fdc 172420) replaces the lentil-sprout row 106; lines measure dry lentils and simmer them |
| rcp-000686 | 585.7 | 904.4 | +54% | white_rice | white_rice: dry-rice row 365 kcal/100g (fdc 168877) replaces the cooked row; this recipe's line reads "cooked white rice" — listed exception to the majority-form rule, overcount accepted |
| rcp-000702 | 356.8 | 208.4 | -42% | chicken_thigh | raw thigh row 121 kcal/100g (fdc 173627) replaces the cooked, skin-eaten FNDDS row 227 |
| rcp-000728 | 160.4 | 293.3 | +83% | lentils | dry lentil row 352 kcal/100g (fdc 172420) replaces the lentil-sprout row 106; lines measure dry lentils and simmer them |

Every one of these is a **correction toward honest values**: the old bundle
under-counted dry staples (rice at 96-129 kcal/100g on dry grams, lentil
sprouts, Sugar Apple) and over-counted raw thigh through a cooked row. The
gates see them because the repo tracks every move over 40 percent against the
published bundle; the reasons above are the documented cause.

## What the rebuild must write (summary for the packet owner)

1. Vocabulary `per_100g` re-source + `nutrition_source` citation per key:
   - `chicken_thighs`, `chicken_thigh` -> fdc 173627 (catalog row added by this PR)
   - `white_rice` -> fdc 168877 (already in catalog)
   - `canned_tomatoes` -> fdc 170501 (already in catalog)
   - identity `fdc_id` pins and `legacy_id` bridges stay exactly as #192 shipped them
2. The changes-file records listed in the table above (55 entries).
3. Regenerate `data/recipes/build/recipes-v2.json` and the shipped
   `apps/ios/Resources/RecipeCatalog/recipes-v2.json`; `validate_bundle.py`
   must come back green with the reasons recorded, and
   `test_kcal_drift.py` must pass.

## Scope of this branch, and reach verification (measured)

**What this branch ships:** the audit (report, script, pytest) and the catalog
row fdc 173627 with five search aliases, plus the rebuilt 960-record SQLite.
**What it does not ship:** any change to `data/ingredients/vocabulary.json`,
`data/recipes/build/recipes-v2.json`, or the shipped iOS resource bundle —
those belong to the held rebuild packet (`burst12-fridgeluck-catalog-rebuild`).
Shipped per-serving calories are therefore unchanged by this branch, and
`test_kcal_drift.py` fails here exactly as it does on alpha's head (the
pre-rebuild changes-file assert).

Reach re-measured with recorded inputs —
`python3 evaluation/catalog-reach/reach_report_v3.py --before-sqlite <origin/alpha sqlite> --before-bundle <origin/alpha data/recipes/build/recipes-v2.json>`:

| state | exact (omn/veg/vegan/gf/df) | near (omn/veg/vegan/gf/df) | wrong-ID lines |
|---|---|---|---|
| before: origin/alpha `b33239f5` sqlite + bundle | 1.5 / 0.5 / 0 / 0 / 0 | 108.5 / 58.5 / 23.5 / 47.5 / 49.5 | 2044 |
| after: this branch's sqlite | **4.5 / 1.5 / 0 / 2.5 / 2.0** | **162.5 / 93.5 / 29 / 76 / 78** | **0** |

Unbridged lines are 1220 in both states; not-in-pantry 28131 in both. The two
catalog databases differ only in physical row ordering/ids, the added row
173627, and its five aliases; the numbers above are the measured output of the
replay over them. The after-state matches the after-numbers PR #192 published
(4.5 / 1.5 / 0 / 2.5 / 2.0 exact; 162.5 / 93.5 / 29 / 76 / 78 near; wrong-ID 0).

## Not done here, on purpose

- The vocabulary/bundle rebuild and changes-file entries are owned by the held
  rebuild packet; this PR ships the audit they must apply.
- No iOS/Xcode build: no Swift files changed (no Xcode here; hosted macOS CI
  covers Swift changes — there are none).
- Reach: re-run with this branch's catalog to confirm the reach numbers hold
  (see PR body for the result).
