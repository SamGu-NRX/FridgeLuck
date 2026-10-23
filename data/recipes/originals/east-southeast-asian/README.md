# East & Southeast Asian Originals — Part Notes

Part of the original-recipe corpus (`data/recipes/originals/`). Read
`AUTHORING.md` at the corpus root before editing anything here. This
README records the catalog traps, mapping decisions, and known soft spots
for this part so the next writer does not rediscover them.

## What's in this part

Nine authored recipes plus the larb exemplar that shipped with the corpus:

| id | minutes | tags of note |
|---|---|---|
| ea-chicken-larb-lettuce-cups (exemplar) | 25 | weeknight, high-protein, use-it-up |
| ea-tomato-egg-stir-fry-rice | 20 | weeknight, budget, use-it-up:tomatoes, vegetarian |
| ea-chicken-adobo-rice | 35 | one-pot, high-protein, make-ahead |
| ea-ginger-pork-rice-bowl | 25 | weeknight, budget, high-protein |
| ea-thai-basil-chicken-egg | 25 | weeknight, high-protein |
| ea-vietnamese-caramel-pork-eggs | 55 | one-pot, make-ahead, high-protein |
| ea-korean-spicy-tuna-rice-bowl | 15 | weeknight, budget, high-protein, use-it-up:rice |
| ea-weeknight-japanese-curry | 45 | one-pot, high-protein, make-ahead, freezer-friendly |
| ea-chilled-rice-noodles-herbs-egg | 25 | weeknight, use-it-up:mint, gluten-free |
| ea-kimchi-tofu-stew | 30 | weeknight, one-pot |

Cuisines: Filipino, Chinese, Thai, Vietnamese, Korean, Japanese.
All recipes are original writing (provenance "authored") — no bundled
recipes or external sources were copied. Every line carries quantity
evidence (suite conversions, part-shard refs with a cited basis, weighed
package grams, or source_grams), and every flesh/egg step carries an FSIS
safety object at the class's exact temperature.

## Catalog traps (don't repeat these)

- **fdc 2646171 "Chicken, thigh, raw"** computes 0 kcal per 100 g despite
  nonzero macros — the zero-kcal Foundation-Foods bug. We map chicken
  thighs to **fdc 171067** (dark-meat row as a like-for-like raw
  stand-in, disclosed here); it prices macros honestly. Same family of
  bug: **fdc 2684441 (salmon)** also shows 0 kcal — fish dishes in this
  part use the canned-tuna row (171986) or stay unmapped instead.
- **fdc 168883 "White Rice (Cooked)"** carries dry-rice macros (~360
  kcal/100 g). Never point "cooked rice" at it. We measure rice dry
  (`dry_rice_cup` → fdc 168879) and use the app's bundled cooked-rice row
  (data.json core ingredient, 130 kcal/100 g) when a dish starts from
  leftover cooked rice.
- **No liquid broth/stock row** exists in the catalog — chicken stock is
  intentionally unmapped; the `incomplete-salty-unmapped` sodium flag
  covers the under-reporting.
- **No sugar, vinegar, or plain-egg-100 g row** — eggs map to the app's
  bundled core row (1 large = 50 g), sugars/vinegars stay unmapped; all
  are either negligible or carry the caveat in the block.
- **No whole shrimp or lean white-fish fillet row** — that's why this
  part has no shrimp/fish-fillet dish; canned tuna (171986) is the one
  clean seafood row and it anchors the Korean tuna rice bowl.

## Mapping decisions worth knowing

- **"all-purpose flour" → fdc 168896** (bread-flour row): closest
  committed row; ~10 g protein/100 g vs AP's ~11.7 g — a small,
  disclosed approximation used only in the curry roux.
- **"uncooked white rice" → fdc 168879** (medium-grain, 360 kcal/100 g):
  closest row to Japanese short grain; long-grain rows run ~365.
- **Onions → fdc 170000** (raw, 40 kcal/100 g); green onions → 170005.
- **Curry powder → fdc 170924.** Ginger is 172232 (fresh, 80 kcal/100 g).
- **Fish sauce is never mapped to soy sauce** — 2 tbsp of fish sauce is
  meaningfully saltier than the same soy sauce, and the validator's
  salty-unmapped flag exists precisely for this. Same policy for
  gochujang and oyster sauce.
- Fresh mint/thai basil have no catalog row and stay unmapped; their
  conversions live in the part shard (`mint_tbsp` is also provided by the
  suite at 2 g/tbsp — consistent).

## Coverage ratio notes

`nutrition_per_serving.coverage` is mapped grams ÷ total grams. All
recipes sit ≥ 0.689 except:

- **ea-kimchi-tofu-stew (0.539):** soup recipes are structurally heavy on
  unmapped liquid (2.5 cups stock) plus gochujang, which has no catalog
  row. Every solid ingredient is mapped. The sodium flag
  (`incomplete-salty-unmapped`) reports the honest underestimate.

## Cost assumptions

Budget-tagged dishes carry `cost_per_serving_usd` with
`assumptions_ref: "tables/cost-assumptions.json"` (US mid-cost
supermarket, October 2026, shelf prices; each line in that file shows its
own arithmetic):

- ea-tomato-egg-stir-fry-rice: **$1.27** (eggs + tomatoes + rice)
- ea-ginger-pork-rice-bowl: **$1.48** (pork shoulder grind + rice)
- ea-korean-spicy-tuna-rice-bowl: **$2.36** (canned tuna dominates)

## Validation status

Last full run on this part (10 recipes incl. exemplar):
`validate --part east-southeast-asian` → hard=0, soft=0,
resolved-lines=100.0%; `nutrition.py --check` → 10 blocks, 0 mismatches;
dedupe → no exact or near-duplicate warnings. `test_status` stays
"untested" on all authored recipes until someone cooks them.
