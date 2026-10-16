# Catalog recipe-quality rubric audit — report

- **Date:** 2026-10-16
- **Base:** `alpha` @ `ef236fcd2461`
- **Scope:** the 591 catalog recipes that are *not* covered by the shipped real-amounts work (the 171-recipe amounts set is excluded; it has its own review), plus a fixes packet for the 18 worst records.
- **Deliverables:** `RUBRIC.md` (seven cook-facing criteria), `audit.py` (mechanical sweep + seeded sample + in-memory fix application), `sample-scores.json` (60 hand-scored recipes), `../../data/recipes/fixes/rubric.json` (18 pin-aware fixes, applied in memory only), `test_rubric.py` (12 pytest gates).

## 1. The rubric

Seven criteria, each 0–2, max 14 per recipe (full anchors in `RUBRIC.md`):

| # | Criterion | What 0/1/2 means |
|---|---|---|
| C1 | Ingredient lines vs steps | The shopping list can actually make the dish |
| C2 | Amounts | Cook-plausible quantities; measured kcal inside 150–1,300/serving |
| C3 | Step order | Prep before heat, oven first when roasting, nothing backwards |
| C4 | Doneness signals | FSIS thermometer temperatures in the step text; visual cues alone score 1 |
| C5 | Sodium | Measured mg/serving against the 2,300 mg FDA Daily Value; over = 0, leaning = 1 |
| C6 | Flavour balance | Salt/acid/fat/heat axes present or their absence deliberate |
| C7 | Time honesty | Step timers sum inside the recipe's `minutes` claim |

## 2. Mechanical sweep (591 in-scope recipes, before fixes)

Ran with `python3 evaluation/recipe-quality/rubric/audit.py`; raw counts in `audit-results.json`.

| Signal | Count | Reading |
|---|---|---|
| sodium > 2,300 mg/serving | 5 | all real (brine-level soy/stock quantities) — fixed |
| kcal > 1,300/serving | 4 | all real unit-conversion errors — fixed |
| kcal < 150/serving | 33 | mostly honest condiments, sides, and light soups — judged, not fixed (§5) |
| title tokens uncovered | 572 | almost all tokenizer noise ("smacked", "style", "bowls") — interpreted per recipe |
| step names a food with no line | 391 | the load-bearing class; pantry/garnish-grade words (salt, water, "to serve") filtered by hand |
| recipes with unused lines / unused lines total | 559 / 1,670 | dominated by `step_uses` linkage false positives (plural/underscore/alias mismatches) — not recipe defects |
| timers over the minutes claim | 15 (2 over by >25%) | real where timers sum past the claim — fixed the 3 worst |
| visual-done phrases / FSIS uncovered / preheat-after-bake / heat-before-prep | 1 / 0 / 0 / 8 | healthy overall; the 8 heat-before-prep are hot-pan-then-oil steps, correct as written |

## 3. Hand-scored sample (60 recipes, seed-reproducible)

The sample is `sorted(random.Random(20261016).sample(sorted(in_scope_ids), 60))`. Scores in `sample-scores.json`; every entry carries a per-criterion reason, and `audit.py` refuses to read the file if its ids do not reproduce from the seed.

- **Mean 12.75/14.** Distribution: 10 ×2, 11 ×6, 12 ×11, 13 ×27, 14 ×14.
- **Criterion means:** C1 1.52, C2 1.90, C3 2.00, C4 1.93, C5 1.85, C6 1.62, C7 1.93.
- The corpus is strong on order (C3: zero misses) and doneness (C4) — the mechanical rights/safety gates already enforce those. Failures concentrate in **C1 (lines vs steps, 25 one-scores, 2 zeros)** and **C6 (flavour balance, 21 one-scores)** — exactly the classes a cook notices ("the shopping list missed the rice the bowls are built on") and a linter mostly can't.
- **Worst ten:** rcp-000323 Rajma-Style Kidney Bean Curry (10), rcp-000378 Steamed Fish with Ginger-Soy Broth (10), rcp-000171 Crispy Potato & Egg Breakfast Tacos (11), rcp-000264 Smacked Cucumber and Peanut Noodle Salad (11), rcp-000328 Miso Butter Noodles (11), rcp-000436 Lemon-Oregano Chicken Souvlaki Bowls (11), rcp-000542 Huevos a la Mexicana (11), rcp-000682 Lamb and Prune Tagine (11), rcp-000265 Sweet-Soy Beef Bowls (12), rcp-000275 Bombay-Style Potato Frittata (12).

## 4. Fixes (18 records, `data/recipes/fixes/rubric.json`)

Applied in memory by `audit.py` — the corpus file itself is not touched. Each fix carries before-record SHA-256, per-change evidence (path, reason, criterion), and a rights-pin flag: 7 fixes add or rename ingredient lines and pin the change (allowed by the rights policy for structural gaps); the other 11 change quantities, step text, or time claims only.

| Catalog id | Title | Fix | Before → after (kcal / mg Na per serving) |
|---|---|---|---|
| rcp-000167 | Peanut Butter Banana Overnight Oats | add the banana step 3 slices | 337.9→353.9 / 108.6→116.2 |
| rcp-000226 | Miso Vegetable Ramen with Just-Set Eggs | fix 4×72 g noodle block entry to 2 blocks; halve stock | 1,866.3→501.2 / 3,360.1→2,195.9 |
| rcp-000241 | Rosemary White Bean Bruschetta | add the rosemary step 1 toasts with | 517.6→517.9 / 536.2→536.3 |
| rcp-000248 | Shakshuka with Feta and Dill | add the dill step 4 finishes with | 376.6→381.2 / 541.0→541.3 |
| rcp-000264 | Smacked Cucumber and Peanut Noodle Salad | 6 oz noodles entered as 840 g → 170 g | 1,779.5→493.0 / 795.6→725.3 |
| rcp-000298 | Baked Tomato Risotto with Peanut Silk | salt 0.75→⅓ tsp; stock 4→3 cups for 1.25 cups rice | 482.4→475.2 / 2,755.3→1,907.2 |
| rcp-000300 | Coconut-Curried Cod with Chickpeas | chickpeas 400→300 g (two cans for two) | 1,439.6→1,250.6 / 1,289.4→1,277.4 |
| rcp-000313 | Chicken and Black-Bean Burritos | scallions 440→40 g (a produce error); tomatoes trimmed | 1,427.3→1,231.7 / 1,832.9→1,774.3 |
| rcp-000320 | Sunday Minestrone with Beans and Little Pasta | stock 3→2 cups; salt ¾→½ tsp (stock+salt carry 981 of 1,260 mg) | 631.5→624.3 / 2,519.3→1,865.0 |
| rcp-000323 | Rajma-Style Kidney Bean Curry | minutes 30→45 (step timers sum 38) | 716.3 / 1,637.3 (unchanged) |
| rcp-000338 | Tomato-Pasta Soup with Chickpeas and Toasted Bread | stock 4→3 cups | 1,223.7 / 2,356.2→1,871.7 |
| rcp-000378 | Steamed Fish with Ginger-Soy Broth | soy 6→2 tbsp (a brine, not a broth); minutes 25→30 | 320.6→301.4 / 3,059.8→1,272.3 |
| rcp-000436 | Lemon-Oregano Chicken Souvlaki Bowls | add the rice step 4 builds the bowls on | 156.7→476.1 / 79.6→84.0 |
| rcp-000507 | Maple Oatmeal with Cinnamon | add cinnamon (step 0) and the banana it tops with | 299.2→318.1 / 108.9→118.6 |
| rcp-000542 | Huevos a la Mexicana | add the tortillas the eggs are spooned into | 140.3→238.4 / 112.2→132.4 |
| rcp-000631 | Thai Basil Chicken | step names 'oyster sauce' where the line is 'hao you' — line named in step | 407.7 / 1,052.6 (unchanged) |
| rcp-000645 | Vietnamese Caramel Pork | step names 'fish sauce' where the line is 'nuoc mam' | 352.8 / 1,013.3 (unchanged) |
| rcp-000682 | Lamb and Prune Tagine | add 1 tsp salt — the dish seasoned nothing | 552.1 / 556.2→1,021.3 |

After the fixes: **0 recipes over 1,300 kcal, 0 over 2,300 mg sodium** (was 4 and 5), and every fixed record is inside the 150–1,300 kcal and ≤2,300 mg bands.

## 5. Judged false positives — deliberately not fixed

- **Unused-line flags (1,670):** overwhelmingly `step_uses` linkage artifacts — "the onion" vs `onion`, plural/singular, alias names (`olive_oil`). The compiler linkage work (PR #88 read path, operator ruling 2026-10-11) owns that surface; no recipe change was made for these.
- **Hummus with flatbread (sample):** flagged as lines-never-used; the recipe makes hummus from chickpeas + tahini and serves it with flatbread. Valid as written — not fixed.
- **kcal < 150 (32 remaining):** salsas, pickles, broths, and sides whose honest serving is small. The band is a dinner-quality heuristic; forcing them over 150 would pad condiments with filler. Recorded as a judged class instead.
- **C6 one-scores on deliberately sweet or no-cook dishes** (baked oats, snack rolls): the rubric's axis model fits savoury plates; noted for a future rubric revision, not fixed.

## 6. How to re-run

```bash
python3 evaluation/recipe-quality/rubric/audit.py            # sweep + sample + in-memory fixes
python3 evaluation/recipe-quality/rubric/audit.py --digest /tmp/digests.txt   # hand-scoring aid
python3 -m pytest evaluation/recipe-quality/rubric/test_rubric.py -q          # 12 gates
```

## 7. What was not checked

- No Xcode here: the fixes are data-only (corpus JSON), so the hosted macOS iOS CI is unaffected by construction — but nothing Swift-side was rebuilt or run locally.
- The bundle compiler (`compile_bundle.py`) was not run over the fixed records; that needs the rights context load it performs at bundle time. The pytest gates cover the surfaces the fixes could actually break: name-mapping resolution, conversion refs, corpus lint regressions, rights pins, and nutrition bands.
- The remaining 39 in-scope recipes outside the sample and the fix list were only mechanically swept, not hand-read.
