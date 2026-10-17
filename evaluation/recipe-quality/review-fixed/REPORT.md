# A cook's review of the 189 agent-fixed catalog recipes

Packet `burst14-fridgeluck-review-fixed` · base `alpha` @ af856008 · branch
`obv/burst14-fridgeluck-review-fixed-recipes`

## Scope and method

The three existing fix packets (`rubric.json`, `amounts-a.json`, `amounts-b.json`)
rewrote 189 catalog recipes (`rcp-000167` … `rcp-000994` span; 189 distinct ids).
This review audited all 189 the way a cook would read them, with the real
compiler doing the arithmetic:

1. **Compiler audit** — every packet record was recompiled through
   `compile_bundle.compile_recipe` with the rights label context, and screened
   by the rubric audit (kcal/sodium bands, title/step ingredient coverage,
   protein food per serving, timer-vs-minutes promise, taste axes, FSIS
   placement). `review.py` writes the full result to `findings.json`; every
   recipe carries `red_flags` or a clean bill.
2. **Hand read** — all 189 recipe digests (ingredients, quantities, steps,
   timers, servings) read end to end, with extra detail on every recipe the
   audit flagged. The audit's substring matching is noisy in both directions
   (it misses pan-lining oil and staple water/salt, and it flags "unused" lines
   that steps do use under different names), so every flag was judged by hand
   before becoming a finding.

## What the review found

The packets are in good shape: 175 of 189 recipes read as cookable, honestly
portioned, and internally consistent. The recurring real defects were:

- **Quantity conversion errors** — a unit misread through a conversions row
  (the almond bowl shipping 435 g of nuts, 1,564 kcal a serving).
- **Servings that don't match the pot** — ten braise-style mains written for
  "2 servings" while carrying 500-600 g of raw meat food, i.e. 250-350 g of
  raw protein per serving against the 110-225 g main-course band.
- **Lines a step names but no ingredient carries** — garlic in the birria
  blend, butter in the bhurji pan, the bread the bhurji is served on, the rice
  the kadhi is eaten over. Each pushes the recipe toward a floor or makes the
  step un-cookable as written.
- **A minutes promise the recipe's own timers break** — chicken and rice soup
  promising 25 minutes with 32 minutes of timers.

## The fix file

`data/recipes/fixes/review-fixed.json` carries the 14 one-correct-answer fixes.
Post-fix numbers are from the repository compiler; before numbers from the
pre-fix audit (findings.json):

| recipe | change | kcal/serving before → after | sodium after |
|---|---|---|---|
| rcp-000247 Almond and Honey Yogurt Bowl | almonds 435 g → 27 g (3 tbsp) | 1564.3 → 383.2 | 84.5 |
| rcp-000391 Sunday Pot Roast | servings 2 → 3 (200 g beef/serving) | 1150.7 → 775.9 | 913.7 |
| rcp-000397 Slow Beef Ragu | servings 2 → 3 (167 g) | 821.4 → 560.8 | 1020.4 |
| rcp-000401 Greek Lamb Baked with Orzo | servings 2 → 3 (167 g) | 1001.0 → 680.5 | 1215.8 |
| rcp-000405 Citrus-Braised Pork Carnitas | servings 2 → 3 (200 g) | 857.6 → 571.7 | 631.8 |
| rcp-000406 Pork Chili Verde | servings 2 → 3 (200 g) | 696.0 → 464.0 | 332.3 |
| rcp-000413 Rendang-Style Beef | servings 2 → 3 (200 g) | 1117.1 → 744.7 | 779.6 |
| rcp-000442 Barbecue Pulled Pork | servings 2 → 3 (200 g) | 770.6 → 548.6 | 432.4 |
| rcp-000443 Red Wine Beef Daube | servings 2 → 3 (167 g) | 898.2 → 598.8 | 681.2 |
| rcp-000444 Hominy and Pork Pozole | servings 2 → 3 (200 g) | 718.1 → 487.5 | 977.6 |
| rcp-000450 Birria-Style Braised Beef Tacos | servings 2 → 3 (167 g) + garlic line (rights pin) | 965.1 → 656.7 | 832.9 |
| rcp-000463 Egg Bhurji | + 1 tbsp butter, + 2 slices bread 60 g (rights pin) | 141.9 → 274.0 | 284.2 |
| rcp-000478 Chicken and Rice Soup | minutes 25 → 35 | 473.0 (unchanged) | 938.1 |
| rcp-000561 Kadhi-Style Spiced Yogurt Soup | + 1 cup rice 185 g (rights pin) | 144.3 → 263.6 | 277.1 |

Every recompiled recipe sits inside the 150-1300 kcal band, at or under
2300 mg sodium, and the ten rescaled mains land at 167-200 g raw protein food
per serving. The three `changes_rights_pin` fixes (garlic, butter + bread,
rice) add ingredient lines the steps already name; after this packet is
applied, `pin_rights_evidence.py` regenerates `data/recipes/evidence/rights.json`
from the packet so the rights gate covers the revised FridgeLuck-original text.

## Findings left open (reviewed, deliberately not fixed)

- **Bone-in and cured weights** — a few recipes flag 250-350 g protein/serving
  where the line is a bone-in cut (chops, drumsticks) or the dish is explicitly
  a shared pot; the audit counts bone. Real portion is in band; no change.
- **Documented sodium exceedances** — pozole (hominy) and taco recipes land
  1,000-1,600 mg/serving on canned hominy, stock, and chipotle; real and
  typical for the dishes. Cutting sodium means reformulating the dish, not a
  one-correct-answer fix. Worth a salt-reduction pass later.
- **Deliberately light soups and sides** — several low-kcal soups/sides sit
  near or just under the floor by design (clear broths, cucumber salads);
  padding them would fight the recipe. The two below 150 kcal with a named
  missing food (bhurji, kadhi) were fixed above; the rest are intentional.
- **Audit false positives** — "unused line" and "missing food" flags cleared by
  hand (pan-lining oil, staple water/salt, name variants like "chili flakes"
  vs "red pepper flakes"). No corpus change; noted so future audit readers
  trust the tool but verify the text.
- **Title tokens** — proper nouns and style names ("bhurji", "rendang",
  "pozole-style") are not coverage defects.

## Verification

- `python3 -I evaluation/recipe-quality/review_fixed.py` — writes
  `data/recipes/fixes/review-fixed.json` (14 fixes) and prints the post-fix
  table; all values in band.
- `python3 -m pytest data/recipes/fixes/test_review_fixed.py -q` — 14 passed:
  packet header/base pin, sha256 match against the base corpus lines,
  shape/title/step-text preservation, household grams = value × canon row
  mass, compiled vocabulary/claims/Atwater/timer/thermometer gates,
  food-safety + allergen screening, kcal/sodium/protein bands, and the
  repository validator over the patched corpus (pre-apply, it must report
  exactly the three expected rights-pin refusals and nothing else).
- Base corpus untouched; all fixes travel as a fix packet in
  `fridgeluck/corpus-fixes/v1` shape, per the repo's fix-file convention.

## What was not verified

- No Xcode here: nothing built the iOS side. These changes are data-only and
  exercised by the portable Python tests and the repository's hosted macOS CI.
- The three rights-pin fixes cannot clear the rights gate until the packet is
  applied to the corpus and `pin_rights_evidence.py` regenerates the evidence;
  the validator test pins that expected pre-apply state exactly.

## Assumptions

- Household masses come from the repo's own conversion rows (butter_tbsp 14 g,
  bread_slice 30 g, garlic_clove 3 g, dry_rice_cup 185 g, almonds_cup 145 g);
  where my kitchen instinct differed from the canon, the canon won.
- "Servings 2 → 3" is the honest fix for the over-portioned braises: the pot
  is unchanged, the label was wrong. Cutting the meat would be the other
  answer but the recipes were written for the quantity they carry.
- The three embedded-conversion additions (garlic, butter + bread, rice) use
  the canon rows and stay at quantities a home cook would actually use.
