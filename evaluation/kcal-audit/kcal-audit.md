# kcal audit — shipped state of the nutrient-row corrections and the cooked-rice routing decision

State audited: branch `obv/burst14-fridgeluck-kcal-pins` (on top of `alpha` at
`af856008`, the published 822-recipe bundle), after the lead review of PR
#221. Companion to `data/recipe-bundle/nutrition-changes-2026-10.json` and the
gate `data/recipes/tools/tests/test_kcal_drift.py`, which now passes.

## What this is

PR #192 re-pinned catalog ingredient rows to different USDA FDC rows so typed
pantry text resolves (reach v3). Some of those re-pins re-sourced the
vocabulary's per-100 g nutrition from a row describing a different
**preparation form** than the recipes measure. An earlier revision of this
audit (basis `9e4a3af5`) chose honest nutrient rows for four keys; the
#210 corpus rebuild then changed the corpus between `9e4a3af5` and
`af856008` (189 amount fixes + 60 new recipes), so the old basis is no longer
reproducible from the committed corpus and this audit was rebased onto
`af856008` — the bundle this branch moves, the same basis
`validate_bundle.py --previous` enforces against.

**This branch ships the correction**, in `data/ingredients/vocabulary.json` and
`data/ingredients/name-mappings.json`:

- the four nutrient-row re-choices (raw thigh, dry rice, as-sold canned
  tomatoes) from the original audit;
- plus the cooked-rice decision from the lead review of PR #221. The first
  revision of this branch had pinned `cooked_rice` (the old identity was fdc
  2705411 **'Rice milk'**, a different food) and routed the cooked-rice names
  to it — which left a rice-stocked kitchen unable to cook a cooked-rice
  recipe (the iOS walked-kitchen test read "missing Cooked rice" and the Rice
  shortfall disappeared). The shipped decision instead keeps cooked-rice lines
  on the `rice` key and stores their corpus-pinned cooked-form grams as
  **dry-equivalent weights** on the dry long-grain row, using one cited factor
  in the `rice` entry's `dry_equivalent` block: 2.8295 = 365/129, the energy
  ratio of fdc 168877 (dry) and fdc 2708403 (cooked); USDA puts the
  cooked:white dry-weight ratio at about 2.8x. Matching and pantry deduction
  keep working against the user's rice stock, the calories come out right on
  the dry row, the `cooked_rice` key is removed from the shipped vocabulary,
  and the step and ingredient display text stays as the recipe wrote it.

Identity pins elsewhere stay exactly as #192 set them; the reach gain is kept.

## Method

- The real compiler (`data/recipes/tools/compile_bundle.py`) is imported, never
  copied, and the bundle is compiled in memory at two states: **prev** (the
  `af856008` rows for the re-sourced keys, the `af856008` cooked-rice name
  mappings, and the removed `cooked_rice` entry, all pinned in
  `kcal_prev_af856008.json`; no `dry_equivalent` declarations, which this
  branch introduces) and **fixed** (this branch's committed vocabulary and
  name mappings — exactly what ships).
- Fidelity: the in-memory prev state reproduces the published `af856008`
  bundle exactly — max |delta| **0.0000 kcal** over all 822 recipes (corpus,
  rights and compiler are unchanged `af856008..this branch`; the three
  rerouted name mappings are pinned in the snapshot's `name_overrides`).
- USDA rows were verified against the FoodData Central bulk CSVs
  (Survey `2024-10-31`, SR Legacy `2018-04`, CC0) and against the curated
  catalog (`test_audit_nutrient_rows_exist_in_catalog_with_cited_values`).
- Gate: `validate_bundle.KCAL_DRIFT_THRESHOLD` (40 percent), same semantics
  (`kcal_swing`).

## The re-sourced keys and the decisions

| key | af856008 row (fdc, kcal/100g) | this branch (fdc, kcal/100g) | decision |
|---|---|---|---|
| chicken_thighs / chicken_thigh | 2706027 FNDDS thigh cooked skin eaten, 226 | 173627 SR raw thigh meat only, 121 | **re-source nutrient row** — corpus lines measure raw boneless skinless thigh (pieces of 110 g, purchase weights); the FNDDS row is cooked, skin eaten. |
| white_rice | 2708403 FNDDS rice cooked NS fat, 129 | 168877 SR long-grain raw enriched, 365 | **re-source nutrient row** — 62 of 64 corpus lines measure dry rice by cup (`dry_rice_cup`, 185 g). The cooked-rice lines resolve to the `rice` key with dry-equivalent grams (next row), so no cooked-rice line is priced here. |
| canned_tomatoes | 2709722 FNDDS tomatoes canned cooked, 43 | 170501 SR crushed canned, 32 | **re-source nutrient row** — lines use the as-sold crushed/chopped product; the FNDDS row carries 3 g fat/100 g from cooking. |
| cooked_rice (key removed) | 2705411 **'Rice milk'**, 47 | — | **routing decision, lead review of PR #221** — the old pin was a different food; instead of re-pinning a separate cooked-rice key, 'cooked rice' / 'cooked white rice' / 'cooked basmati rice' resolve to the `rice` key and the compiler stores their cooked-form grams as dry-equivalent weights (factor 2.8295 = 365/129, cited in the `rice` entry). The `cooked_rice` vocabulary entry is removed. |
| lentils | 172420 Lentils, raw, 352 | same | **keep** — all 5 lines measure dry lentils and simmer them; the pre-#192 row was lentil sprouts. |
| sugar | 169655 Sugars, granulated, 387 | same | **keep** — the pre-#192 row was Sugar Apple, a fruit. |
| banana | 173944 Bananas, raw, 89 | same | **keep** — the pre-#192 row was Banana Pepper. |
| cinnamon | 171320 ground cinnamon, 247 | same | **keep** — the pre-#192 row was frosted cinnamon buns. |
| almonds | 170567 Nuts, almonds, 579 | same | **keep** — ~2 percent variant correction. |
| bacon | 2705885 Bacon cooked, 484 | same | **keep** — both lines ship no grams. |
| heavy_cream | 2346386 Foundation Heavy Cream, 343.31 | same | **keep** — ~1 percent row correction. |
| pork_chop | 2705866 FNDDS pork chop NS fat, 183 | same | **keep** (documented approximation) — lines measure raw pieces; the raw loin twin is within ~7 percent and no recipe approaches the gate. |

Enriched vs unenriched long-grain rice have identical macros (365); enriched is
the US retail default, chosen as 168877.

## Recipes above the 40 percent gate at the fixed state (vs af856008)

68 recipes. Every one carries an exemption in
`data/recipe-bundle/nutrition-changes-2026-10.json` naming the re-sourced keys
on its lines or the cooked-rice dry-equivalent conversion (the recorder
computes causes from the vocabulary diff, the committed fix packets, and the
`dry_equivalent` declarations, and fails closed on an untraceable move); the
exemption values are byte-checked against this table by `test_kcal_audit.py`.

| recipe | prev kcal | fixed kcal | swing | deciding keys |
|---|---|---|---|---|
| rcp-000190 | 838.6 | 425.5 | -49% | cooked-rice routing |
| rcp-000252 | 965.5 | 552.5 | -43% | cooked-rice routing |
| rcp-000261 | 866.1 | 453.1 | -48% | cooked-rice routing |
| rcp-000263 | 816.1 | 403.1 | -51% | sugar, cooked-rice routing |
| rcp-000265 | 945.9 | 533.0 | -44% | cooked-rice routing |
| rcp-000266 | 502.8 | 721.1 | +43% | white_rice |
| rcp-000267 | 472.4 | 690.7 | +46% | white_rice |
| rcp-000270 | 327.1 | 545.4 | +67% | white_rice |
| rcp-000279 | 383.0 | 546.8 | +43% | white_rice |
| rcp-000298 | 513.4 | 786.2 | +53% | white_rice |
| rcp-000304 | 443.6 | 661.9 | +49% | white_rice |
| rcp-000352 | 384.2 | 602.5 | +57% | white_rice |
| rcp-000373 | 394.2 | 721.7 | +83% | white_rice |
| rcp-000378 | 347.2 | 674.7 | +94% | white_rice |
| rcp-000386 | 665.4 | 979.6 | +47% | canned_tomatoes, white_rice |
| rcp-000426 | 287.1 | 171.6 | -40% | chicken_thighs |
| rcp-000428 | 237.7 | 346.9 | +46% | white_rice |
| rcp-000429 | 160.2 | 269.3 | +68% | white_rice |
| rcp-000436 | 476.1 | 269.5 | -43% | cooked-rice routing |
| rcp-000461 | 277.1 | 161.6 | -42% | chicken_thigh |
| rcp-000465 | 388.1 | 551.9 | +42% | white_rice |
| rcp-000466 | 281.9 | 166.4 | -41% | chicken_thighs |
| rcp-000482 | 253.6 | 417.4 | +65% | white_rice |
| rcp-000486 | 236.3 | 400.1 | +69% | white_rice |
| rcp-000487 | 264.7 | 483.0 | +82% | white_rice |
| rcp-000488 | 405.5 | 569.3 | +40% | white_rice |
| rcp-000504 | 472.8 | 691.1 | +46% | white_rice |
| rcp-000511 | 263.9 | 469.0 | +78% | canned_tomatoes, white_rice |
| rcp-000512 | 239.8 | 444.9 | +86% | canned_tomatoes, white_rice |
| rcp-000516 | 381.3 | 599.6 | +57% | white_rice |
| rcp-000524 | 213.3 | 370.5 | +74% | canned_tomatoes, white_rice |
| rcp-000525 | 471.7 | 690.0 | +46% | white_rice |
| rcp-000546 | 363.0 | 526.8 | +45% | white_rice |
| rcp-000567 | 229.4 | 393.2 | +71% | white_rice |
| rcp-000569 | 332.0 | 495.8 | +49% | white_rice |
| rcp-000702 | 355.4 | 208.4 | -41% | chicken_thigh |
| rcp-000752 | 486.4 | 279.8 | -42% | cooked-rice routing |
| rcp-000757 | 761.2 | 451.5 | -41% | cooked-rice routing |
| rcp-000763 | 844.3 | 415.0 | -51% | chicken_thigh, cooked-rice routing |
| rcp-000793 | 702.6 | 348.6 | -50% | cooked-rice routing |
| rcp-000794 | 811.5 | 433.9 | -47% | cooked-rice routing |
| rcp-000799 | 796.0 | 418.4 | -47% | cooked-rice routing |
| rcp-000800 | 835.6 | 458.0 | -45% | cooked-rice routing |
| rcp-000804 | 647.9 | 270.3 | -58% | cooked-rice routing |
| rcp-000805 | 469.9 | 233.9 | -50% | cooked-rice routing |
| rcp-000806 | 808.5 | 431.0 | -47% | cooked-rice routing |
| rcp-000809 | 833.3 | 455.7 | -45% | cooked-rice routing |
| rcp-000810 | 684.2 | 306.6 | -55% | cooked-rice routing |
| rcp-000811 | 927.7 | 550.1 | -41% | cooked-rice routing |
| rcp-000812 | 717.6 | 340.0 | -53% | cooked-rice routing |
| rcp-000823 | 688.8 | 311.2 | -55% | cooked-rice routing |
| rcp-000838 | 796.5 | 418.9 | -47% | cooked-rice routing |
| rcp-000842 | 927.1 | 549.5 | -41% | cooked-rice routing |
| rcp-000848 | 788.4 | 410.8 | -48% | cooked-rice routing |
| rcp-000864 | 853.9 | 476.3 | -44% | cooked-rice routing |
| rcp-000868 | 691.3 | 337.2 | -51% | cooked-rice routing |
| rcp-000872 | 578.6 | 295.4 | -49% | cooked-rice routing |
| rcp-000874 | 378.9 | 190.0 | -50% | cooked-rice routing |
| rcp-000875 | 396.9 | 208.1 | -48% | cooked-rice routing |
| rcp-000898 | 903.7 | 526.1 | -42% | cooked-rice routing |
| rcp-000903 | 672.1 | 294.6 | -56% | cooked-rice routing |
| rcp-000905 | 567.7 | 315.9 | -44% | cooked-rice routing |
| rcp-000915 | 715.5 | 337.9 | -53% | cooked-rice routing |
| rcp-000917 | 661.5 | 307.5 | -54% | cooked-rice routing |
| rcp-000918 | 568.4 | 316.7 | -44% | cooked-rice routing |
| rcp-000920 | 786.9 | 409.3 | -48% | cooked-rice routing |
| rcp-000927 | 821.7 | 444.1 | -46% | cooked-rice routing |
| rcp-000931 | 913.5 | 535.9 | -41% | cooked-rice routing |

Every move is a **correction toward honest values**: the af856008 bundle
under-counted cooked rice (priced at rice milk 47 kcal/100g on the
`cooked_rice`-mapped lines, or over-counted at the dry row on the
`rice`/`white_rice`-mapped ones), under-counted dry staples (rice 129 on dry
grams), and over-counted raw thigh through a cooked row (226/227 on raw piece
grams). The shipped decision prices cooked-rice lines at their true energy on
the dry-rice row. The gates see the moves because the repo tracks every move
over 40 percent against the published bundle; the recorded causes are the
documentation.

## Verification on this branch (measured)

- `python3 evaluation/kcal-audit/kcal_audit.py` — fidelity 0.0000 kcal over
  822 recipes; 68 recipes above the gate, matching the changes file.
- `python3 data/recipes/tools/validate_bundle.py` — PASS, 0 errors.
- `python3 data/recipes/tools/validate_bundle.py data/recipes/build/recipes-v2.json
  --previous <af856008 bundle> --changes data/recipe-bundle/nutrition-changes-2026-10.json`
  — PASS, 0 unrecorded/exempted problems.
- `python3 -m pytest data/recipes/tools data/recipes/fixes evaluation/kcal-audit -q` —
  `test_kcal_drift.py` and `test_kcal_audit.py` pass (the two failures this
  branch owned). The remaining failures
  (`test_safety_invariants.py` shipped-pin tests, `test_amounts_b.py`
  base-sha tests) fail identically on the `alpha` head `af856008` and are
  outside this branch's paths — see the PR body.
- `python3 data/recipes/tools/compile_bundle.py` three times — byte-identical
  (MD5 recorded in the PR body); committed bundle sha256 matches the manifest.
- `python3 -m taste_lab validate-fixtures` — the committed taste-lab golden
  fixtures replay exactly against the rebuilt bundle.
- No iOS/Xcode build: no Swift files changed (the app resource copy is
  byte-identical to the build output; hosted macOS CI covers Swift changes —
  there are none).
