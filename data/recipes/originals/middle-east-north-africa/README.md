# middle-east-north-africa — original recipes

Part of the `originals` corpus. See `../AUTHORING.md` for corpus law. Exemplars for
file shape: `../east-southeast-asian/ea-chicken-larb-lettuce-cups.json`,
`../part1-rewrite/rw-ginger-egg-fried-rice.json`.

## Recipes

| id | serves | minutes | tags |
|---|---|---|---|
| me-harissa-shakshuka | 4 | 25 | weeknight, one-pot, use-it-up:bell peppers |
| me-turkish-red-lentil-soup | 4 | 35 | budget, one-pot, make-ahead, freezer-friendly, use-it-up:carrots |
| me-beef-kofte-rice-pilaf | 4 | 30 | weeknight, high-protein |
| me-sheet-pan-chicken-shawarma | 4 | 35 | sheet-pan, high-protein, make-ahead |
| me-kuku-sabzi-herb-frittata | 3 | 40 | make-ahead, use-it-up:parsley |
| me-weeknight-koshari | 4 | 50 | budget, make-ahead, use-it-up:rice |
| me-tomato-bulgur-pilaf | 3 | 20 | weeknight, budget, make-ahead, one-pot |
| me-cilbir-yogurt-eggs | 2 | 20 | weeknight |
| me-moroccan-chicken-lemon-olives | 4 | 30 | weeknight, one-pot, use-it-up:chickpeas |

All recipes are original authorship for FridgeLuck (Levantine, Turkish, Moroccan,
Egyptian, and Persian home-cooking traditions), rights-clear, `test_status: untested`.

## Conventions and decisions

- **Water is never an ingredient line.** The bundled catalog (`data.json`, 50 core
  ingredients) has no water ingredient, so no recipe in the corpus references one;
  cooking liquid is named in step text instead (e.g. the soup's "5 cups of water",
  the koshari's rice and lentil water). This matches the exemplar convention and
  keeps coverage math about food.
- **Salty unmapped lines stay unmapped.** Feta, chicken stock, and salt have no
  clean committed source (see `tables/nutrition-map.json` `unmapped-notes`), so they
  are left unmapped and the `sodium_basis` flag stands, exactly as in the exemplars.
- **Red lentils are unmapped** — no lentil row exists in the USDA catalog (only
  `Lentil Sprouts (Raw)` 168427, wrong form) or in `data.json`. The soup and koshari
  therefore report lower `nutrition_coverage` (≈0.72–0.84); the gap is the lentils
  themselves plus small paste/spice lines.
- **Kalamata olives** map to fdc 169096 `Green Olives (Pickled)` — the closest
  committed plain form (brine-cured olives); kalamata sodium may run somewhat
  higher per gram.
- **`cumin`** maps to fdc 170923 `Cumin Seed` — the seed row is used for ground
  cumin (same macros per gram in the source data).
- **`lemon`** maps to fdc 167746 `Lemons (Without Peel, Raw)`; recipes weigh juice
  (22 g/half), slightly understating kcal per gram versus juice alone (22 vs 29).
- **Dry-grain discipline:** rice, bulgur, and pasta are weighed or referenced dry,
  never "cooked" — fdc 168883 `White Rice (Cooked)` carries dry-rice macros and is
  not used; pasta maps to fdc 169736 `Pasta (Dry, Enriched)`.

## Budget arithmetic

Costs use US mid-cost supermarket shelf prices (October 2026) itemized in
`tables/cost-assumptions.json`.

**me-turkish-red-lentil-soup (4 servings → $0.70/serving):**
lentils 190 g × $2.20/lb = $0.92; crushed tomatoes 360 g of a $1.30 28-oz can =
$0.59; onion $0.17; carrots 2 × $0.12 = $0.24; tomato paste 16 g = $0.11; olive oil
28 g ≈ $0.25; garlic, spices, lemon juice, parsley ≈ $0.30. Total ≈ $2.58 → $0.70
per serving (rounded up to the nearest $0.10).

**me-weeknight-koshari (4 servings → $1.20/serving):**
rice 231 g × $2.20/kg = $0.51; lentils 190 g = $0.92; pasta 3.5 oz × $1.60/lb =
$0.35; canned chickpeas = $1.00; crushed tomatoes 480 g = $0.79; onions 220 g =
$0.34; vegetable oil 42 g ≈ $0.36; tomato paste 32 g = $0.22; vinegar ≈ $0.09;
spices ≈ $0.20. Total ≈ $4.78 → $1.20 per serving.

**me-tomato-bulgur-pilaf (3 servings → $0.90/serving):**
bulgur 200 g × $2.80/kg = $0.56; crushed tomatoes 240 g = $0.39; green pepper =
$0.80; onion $0.17; tomato paste 16 g = $0.11; olive oil 28 g ≈ $0.25; lemon, mint,
spices ≈ $0.30. Total ≈ $2.58 → $0.90 per serving (rounded up to the nearest $0.10).

## Protein arithmetic (high-protein tags)

- **me-beef-kofte-rice-pilaf:** beef 600 g × 17.2 g/100 g = 103 g; bread 30 g ≈ 3 g;
  rice 277 g dry ≈ 20 g; vegetables ≈ 4 g → ≈ 130 g / 4 servings ≈ 32 g per serving.
- **me-sheet-pan-chicken-shawarma:** chicken 680 g × 22.5 g/100 g = 153 g; yogurt
  184 g ≈ 18 g → ≈ 174 g / 4 ≈ 43 g per serving.
