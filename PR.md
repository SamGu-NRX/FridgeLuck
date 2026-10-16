## What changed and why

PR #192 re-pinned catalog ingredient rows to different USDA FDC rows so typed pantry text resolves (reach v3). Eleven of those re-pins also re-sourced the vocabulary's per-100 g nutrition from the new row, and for four keys that row describes a **different preparation form** than the recipes measure — cooked thigh applied to raw thigh pieces, cooked rice applied to dry cups, "canned, cooked" applied to as-sold crushed/chopped tomatoes — so per-serving calories moved with no recorded reason. On alpha, `test_kcal_drift.py` fails (16 recipes over the 40 percent drift gate with no recorded reason) and `validate_bundle.py --real-bundles` reports the same 16 drift problems.

This PR is the **calorie audit** the held rebuild packet must apply:

- **Nutrient-row re-choices, grounded in USDA FoodData Central bulk CSVs** (Survey 2024-10-31, SR Legacy 2018-04, CC0 — exact per-100 g values read from `food.csv` + `food_nutrient.csv`, not the web UI):
  - `chicken_thighs` and `chicken_thigh` -> nutrient row **fdc 173627** "Chicken, broilers or fryers, dark meat, thigh, meat only, raw" (121 kcal/100 g). All corpus lines measure raw thigh (23 lines "boneless chicken thighs" pieces of 110 g; 41 lines with purchase weights 400-700 g or pieces). Identity pins stay 2706027; the catalog gains row 173627 (canonical now 960 records; `uv run usda validate` passes; shipped sqlite rebuilt).
  - `white_rice` -> nutrient row **fdc 168877** "Rice, white, long-grain, regular, raw, enriched" (365 kcal/100 g). 59 of 60 corpus lines measure dry rice by cup (185 g). The 14 lines reading "cooked white rice" are listed exceptions (majority-form rule).
  - `canned_tomatoes` -> nutrient row **fdc 170501** "Tomatoes, crushed, canned" (32 kcal/100 g, fat 0.28 g). The FNDDS "canned, cooked" row carries 3.04 g fat/100 g from cooking — wrong for the as-sold product.
  - **Kept** (verified honest): lentils 172420 (352; lines are dry cups, old row was lentil sprouts), sugar 169655 (387; old row was Sugar Apple), banana 173944 (89; old row was Banana Pepper), cinnamon 171320 (247; old row was cinnamon buns), almonds 170567 (579), bacon 2705885 (484; lines ship no grams), heavy cream 2346386 (343.31), pork chop 2705866 (183; kept as closest cited row, documented approximation).
- **evaluation/kcal-audit/**: `kcal-audit.md` (decisions + full record table), `kcal_audit.py` (recompiles the bundle in memory with the real compiler at three vocabulary states: prev `9e4a3af5`, alpha, fixed), `test_kcal_audit.py` (pytest gate), `kcal_prev_9e4a3af5.json` (published-bundle reference).
- **Identity pins are untouched** — the reach gain from #192 is preserved by construction; this PR re-chooses nutrient rows only.

**Fidelity anchor:** corpus, rights, name mappings, and the compiler are unchanged `9e4a3af5..alpha` (verified with `git diff --stat`), so the in-memory prev state reproduces the published bundle exactly: max |delta| **0.0000 kcal over all 762 recipes**.

## Reach: #192's gain was NOT holding on alpha — this rebuild restores it

`reach_report_v3.py` (before = alpha-shipped sqlite, after = this branch's rebuilt sqlite):

| | exact medians (omn/veg/vegan/gf/df) | near medians | wrong-ID lost lines |
|---|---|---|---|
| alpha-shipped sqlite | 1.5 / 0.5 / 0 / 0 / 0 | 108.5 / 58.5 / 23.5 / 47.5 / 49.5 | 2044 |
| this branch | **4.5 / 1.5 / 0 / 2.5 / 2.0** | **162.5 / 93.5 / 29 / 76 / 78** | **0** |
| PR #192's claimed after-state | 4.5 / 1.5 / 0 / 2.5 / 2.0 | 162.5 / 93.5 / 29 / 76 / 78 | 0 |

The sqlite shipped on alpha was stale against the canonical catalog (content-identical rows, byte-identical alias bindings; the physical build state differed) and had silently regressed part of #192's reach. Rebuilding from canonical restores the published numbers exactly, on top of the one added audited row.

## Exact nutrition-change records for the rebuild packet

The rebuild must write changes-file entries (recipe id, old kcal, new kcal, reason) for every recipe the fixed state moves more than 40 percent versus the published bundle — **55 records** (16 pre-existing drifts plus honest corrections the audit surfaces). Full reasons per record are in `evaluation/kcal-audit/kcal-audit.md`; the records:

| recipe | prev kcal | fixed kcal | swing | deciding keys |
|---|---|---|---|---|
| `rcp-000213` | 363.1 | 614.1 | +69% | chicken_thighs, white_rice |
| `rcp-000221` | 441.5 | 699.7 | +58% | canned_tomatoes, chicken_thighs, white_rice |
| `rcp-000260` | 548.2 | 785.1 | +43% | pork_chop, white_rice |
| `rcp-000266` | 472.3 | 721.1 | +53% | white_rice |
| `rcp-000267` | 441.8 | 690.7 | +56% | white_rice |
| `rcp-000270` | 296.6 | 545.4 | +84% | white_rice |
| `rcp-000279` | 360.1 | 546.8 | +52% | white_rice |
| `rcp-000293` | 412.4 | 663.4 | +61% | chicken_thighs, white_rice |
| `rcp-000298` | 482.4 | 793.4 | +64% | white_rice |
| `rcp-000304` | 413.1 | 661.9 | +60% | white_rice |
| `rcp-000305` | 626.5 | 999.7 | +60% | bacon, white_rice |
| `rcp-000322` | 568.8 | 817.7 | +44% | white_rice |
| `rcp-000352` | 353.7 | 602.5 | +70% | white_rice |
| `rcp-000373` | 348.4 | 721.7 | +107% | white_rice |
| `rcp-000378` | 320.6 | 693.9 | +116% | white_rice |
| `rcp-000386` | 568.0 | 941.2 | +66% | canned_tomatoes, white_rice |
| `rcp-000402` | 289.8 | 173.2 | -40% | chicken_thigh |
| `rcp-000410` | 317.7 | 568.7 | +79% | chicken_thighs, white_rice |
| `rcp-000411` | 232.2 | 408.0 | +76% | heavy_cream, lentils |
| `rcp-000428` | 222.5 | 346.9 | +56% | white_rice |
| `rcp-000429` | 144.9 | 269.3 | +86% | white_rice |
| `rcp-000461` | 278.2 | 161.6 | -42% | chicken_thigh |
| `rcp-000465` | 365.2 | 551.9 | +51% | white_rice |
| `rcp-000482` | 230.7 | 417.4 | +81% | white_rice |
| `rcp-000486` | 213.4 | 400.1 | +87% | white_rice |
| `rcp-000487` | 234.2 | 483.0 | +106% | white_rice |
| `rcp-000488` | 382.6 | 569.3 | +49% | white_rice |
| `rcp-000504` | 442.3 | 691.1 | +56% | white_rice |
| `rcp-000511` | 205.8 | 469.0 | +128% | canned_tomatoes, white_rice |
| `rcp-000512` | 181.7 | 444.9 | +145% | canned_tomatoes, white_rice |
| `rcp-000516` | 350.8 | 599.6 | +71% | white_rice |
| `rcp-000518` | 392.5 | 579.2 | +48% | white_rice |
| `rcp-000524` | 176.6 | 370.5 | +110% | canned_tomatoes, white_rice |
| `rcp-000525` | 441.2 | 690.0 | +56% | white_rice |
| `rcp-000546` | 192.6 | 379.3 | +97% | white_rice |
| `rcp-000548` | 262.4 | 451.3 | +72% | chicken_thighs, white_rice |
| `rcp-000564` | 150.0 | 383.7 | +156% | lentils |
| `rcp-000567` | 206.5 | 393.2 | +90% | white_rice |
| `rcp-000569` | 309.1 | 495.8 | +60% | white_rice |
| `rcp-000573` | 389.2 | 1026.7 | +164% | white_rice |
| `rcp-000580` | 208.0 | 526.7 | +153% | white_rice |
| `rcp-000586` | 338.1 | 663.0 | +96% | sugar, white_rice |
| `rcp-000597` | 39.0 | 63.6 | +63% | sugar |
| `rcp-000599` | 560.7 | 852.6 | +52% | chicken_thigh, sugar, white_rice |
| `rcp-000605` | 300.8 | 640.8 | +113% | white_rice |
| `rcp-000610` | 292.0 | 717.0 | +146% | white_rice |
| `rcp-000631` | 407.7 | 840.9 | +106% | sugar, white_rice |
| `rcp-000634` | 420.0 | 853.3 | +103% | sugar, white_rice |
| `rcp-000645` | 352.8 | 699.2 | +98% | sugar, white_rice |
| `rcp-000649` | 420.0 | 853.3 | +103% | sugar, white_rice |
| `rcp-000652` | 456.3 | 802.7 | +76% | sugar, white_rice |
| `rcp-000666` | 143.7 | 276.5 | +92% | lentils |
| `rcp-000686` | 585.7 | 904.4 | +54% | white_rice |
| `rcp-000702` | 356.8 | 208.4 | -42% | chicken_thigh |
| `rcp-000728` | 160.4 | 293.3 | +83% | lentils |

Reasons group as: dry-rice row correction (fdc 168877) for white-rice recipes — with the 14 cooked-rice-line exceptions (rcp-000573, 580, 586, 589, 599, 605, 610, 631, 634, 645, 649, 652, 686, 722) carrying their own exception reason; raw thigh row (fdc 173627) for thigh recipes; dry-lentil row (fdc 172420) for lentil recipes; granulated-sugar row (fdc 169655) for sugar recipes; crushed-canned row (fdc 170501) for canned-tomato recipes. The rebuild must also re-source the four keys' `per_100g` + `nutrition_source` citations exactly as `evaluation/kcal-audit/kcal-audit.md` specifies, regenerate both bundles, and record these entries so `test_kcal_drift.py` passes.

## How I checked it (commands and results)

- `python3 evaluation/kcal-audit/kcal_audit.py` — fidelity max |delta| 0.0000 kcal vs published 9e4a3af5 bundle (762 recipes); 55 recipes above the gate at the fixed state, all tabulated with reasons; 16 above the gate at alpha before the rebuild.
- `python3 -m pytest evaluation/kcal-audit/test_kcal_audit.py -q` — **4 passed** (fidelity anchor; every gate recipe documented and nothing else; audit rows exist in canonical catalog with cited macros; idempotence over the rebuilt vocabulary).
- `cd scripts/data && uv run usda validate --canonical catalog/usda_curated_ingredients.json` — **Validation OK** (960 records, 3942 unique aliases, 14 required terms); `uv run usda build-sqlite ...` — **960 rows**.
- `python3 -m pytest data/recipes/tools/tests -q` — **37 passed, 1 failed, 1 skipped**: the failure is the known pre-rebuild `test_kcal_drift.py` changes-file consistency assert (changes entries vs shipped bundle), unchanged by this PR and resolved by the held rebuild.
- `python3 evaluation/catalog-reach/reach_report_v3.py --before-sqlite ... --before-bundle ...` — table above; alias bindings and catalog content diffed directly between the shipped and rebuilt sqlite (0 changed shared rows, 0 alias-pair diffs, +1 audited row).
- USDA rows verified from the bulk CSVs; e.g. 173627 = 121.0 kcal, P 19.66, C 0.0, F 4.12, Na 95 mg per 100 g.

## What I could not check

- No Xcode here: no iOS build/simulator run (no Swift files changed; hosted macOS CI covers the repo build).
- The held rebuild packet's own outputs (re-sourced vocabulary, regenerated bundles, changes-file entries, `test_kcal_drift.py` going green) are not in this PR — this PR ships the audit they must apply.
- Reach replay is the report's Python model of `IngredientRepository.search`, not the app binary.

## Assumptions

- Majority measurement form decides single-form nutrient rows (the repo gate's own rule); minority-form lines are listed exceptions with their over/under-count disclosed, not silently accepted.
- "Boneless chicken thighs" pieces are raw, skinless; generic "chicken thighs" purchase weights include bone+skin — the raw meat-only row is the closer approximation on both (documented residual error in the audit).
- Pork chops keep the pinned FNDDS as-consumed row as closest cited row (raw twins within ~7 percent); no pork recipe approaches the gate.

Human author: Sam Gu (sgu07966@gmail.com)

🔗 [Obvious Project](https://app.obvious.ai/p/fridgeluck-GmL1ONwZ) · 🧵 [Obvious Thread](https://app.obvious.ai/p/fridgeluck-GmL1ONwZ?thread=th_FQclziNL) · 🔀 [Obvious PR Artifact](https://app.obvious.ai/link/pr-artifact/fridgeluck-correct-calorie-rows-behind-192s-ingred-task:todo_N5kwicQh)
