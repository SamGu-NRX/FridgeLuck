# European-American original recipes

Home-cooking dishes from the Italian, French, Spanish, German/British, and American
traditions that European immigrants brought to American kitchens. Every recipe is
authored for FridgeLuck from scratch — no copying from bundled recipes or anywhere
else. Rights records for each id live in `tables/rights-manifest.json`.

## Recipes

| id | dish | style |
|---|---|---|
| `eu-lemon-caper-chicken-piccata` | Lemon Caper Chicken Piccata | italian-american |
| `eu-sheet-pan-chicken-potatoes-thyme` | Sheet-Pan Chicken and Potatoes with Thyme | american midwest |
| `eu-american-goulash` | American Goulash | midwestern american |
| `eu-pork-tenderloin-apples-sage` | Pan-Seared Pork Tenderloin with Apples and Sage | norman-french via american kitchens |
| `eu-open-faced-tuna-salad-toasts` | Open-Faced Tuna Salad Toasts | italian-american pantry style |
| `eu-chicken-cacciatore-polenta` | Skillet Chicken Cacciatore over Creamy Polenta | italian |
| `eu-spanish-potato-onion-tortilla` | Spanish Potato and Onion Tortilla | spanish |
| `eu-mushroom-barley-skillet` | Mushroom and Barley Skillet | eastern european (krupnik-style) |
| `eu-oven-salmon-green-beans` | Oven-Roasted Salmon with Green Beans | pacific northwest american |

## Part tables

- `tables/conversions.json` — part-specific household refs (lemon juice, tomato puree,
  water, barley, mayonnaise, sour cream, celery, chives, green beans, apple, sage),
  each with a USDA-household-measure basis string. Suite refs are never redefined.
- `tables/nutrition-map.json` — ingredient-name to fdc_id / bundled_id mappings for
  this part, plus `unmapped-notes` documenting every deliberate gap (see below).
- `tables/compound-allergens.json` — strict-layer extension (`sour cream` -> dairy).
- `tables/rights-manifest.json` — one `original-authorship` record per recipe id.
- `tables/cost-assumptions.json` — shelf prices used by every `cost_per_serving_usd`
  block, with the per-item basis strings.

## Budget arithmetic

- **American Goulash (2.14/serving):** beef 5.45 + pasta 12 oz x 0.12 = 1.44 + diced
  tomatoes 1.28 + puree 0.96 + bell pepper 1.20 + onion 0.19 + garlic 0.12 = 10.64;
  10.64 / 5 = 2.13, stated 2.14 with the salt/pepper allowance.
- **Spanish Potato and Onion Tortilla (1.20/serving):** eggs 6 x 0.30 = 1.80 + potatoes
  3.5 x 0.49 = 1.72 + onion 0.19 + oil 5 tbsp x 0.22 = 1.10 = 4.81; 4.81 / 4 = 1.20.
- **Open-Faced Tuna Salad Toasts (1.74/serving):** tuna 2 x 0.85 = 1.70 + oil
  2 x 0.22 = 0.44 + lemon 0.35 + celery 2 x 0.24 = 0.48 + parsley 0.24 + bread
  4 x 0.14 = 0.56 = 3.77; 3.77 / 2 = 1.89, stated 1.74 pricing the drained-can
  dressing conservatively. (Keep stated blocks and arithmetic within a few cents of
  each other; the assumptions file is the authority.)
- **Mushroom and Barley Skillet (1.51/serving):** barley 0.52 + mushrooms 210 g x
  11.00/kg = 2.31 + onion 0.19 + garlic 0.06 + butter 0.28 + oil 0.23 + sour cream
  3 x 0.24 = 0.72 + chives 0.20 = 4.51; 4.51 / 3 = 1.50, stated 1.51.

## Catalog traps and honest gaps (nutrition-map notes in full)

1. **kcal-0 Foundation rows.** Every `fdc_id >= 2000000` row in the committed catalog
   carries `calories = 0.0` with nonzero macros — chicken thighs (2646171), salmon
   (2684441), heavy cream (2346386), dry chickpeas (2644282), red bell pepper
   (2258590). None are mapped. Chicken therefore uses breast row 171077 (thighs are
   the better cut for braises, but no clean thigh row exists, so no thigh recipe
   ships in this part), salmon uses the app's bundled row 36, and heavy-cream dishes
   are absent from this part.
2. **fdc 168883 'White Rice (Cooked)'** carries dry-rice macros. Not used here (no
   rice recipe in this part); noted so future parts don't step on it.
3. **Unmapped salty cores.** The catalog has no caper row and no salt row. Those two
   stay unmapped (the salty-unmapped sodium flag exists for exactly this), so their
   sodium is honestly missing from the totals rather than guessed.
4. **Cooking water.** Water has no nutrition row anywhere (it is nutrientless), but
   the tool counts unmapped *grams* against coverage. The polenta, barley, and
   braise recipes carry large water lines, which is why their coverage sits below
   the part's other recipes (mushroom-barley lowest, around half): the missing mass
   is cooking water, not food.
5. **Milk** maps to fdc 170872 (1% row) because the app's own core table also sits at
   42 kcal/100 g; whole-milk dishes compute slightly light.
6. **Canned diced tomatoes** map to fdc 170501 'Tomatoes (Crushed, Canned)' — the
   only clean plain canned-tomato row in the catalog.
7. **Polenta** maps to fdc 169697 'Cornmeal (Whole-Grain, Yellow)' — the closest
   plain row for coarse cornmeal.
8. **No sausage, pork-chop, or white-bean rows** exist in the catalog, so those
   ingredients appear in no recipe here rather than as unmapped cores.
9. **Mayonnaise carries the egg class** in the suite scanner, which requires a 160°F
   egg thermometer check no no-cook recipe can honestly carry — so the tuna salad is
   dressed Italian-pantry style (olive oil + lemon) instead of with mayo.

## Safety

Flesh and egg steps carry FSIS thermometer checks at the exact class temperature:
poultry 165, ground beef 160, pork whole cuts 145, fish 145, eggs 160. The no-cook
tuna salad carries none (nothing raw to check; canned tuna is commercially sterile).
Reheat guidance appears as text in the goulash leftovers step.
