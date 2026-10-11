# Check of `food-data-licensing.md` against primary sources (2026-10-11)

`food-data-licensing.md` is a research document written on the coco17 Obvious account on 2026-10-10 (sha256 99390e2f…). The lead re-checked the licence claims a recipe or nutrition task would rely on. Checked by fetching the primary pages on 2026-10-11:

| Claim in the document | Primary source | Result |
| --- | --- | --- |
| USDA FoodData Central data are public domain, published under CC0 1.0; attribution is requested, not required (§1.5) | [FDC API Guide, Licensing](https://fdc.nal.usda.gov/api-guide/) | Confirmed verbatim. The suggested citation on the page includes a year ("FoodData Central, 2019") that the document omits; cite the release actually used. |
| Recipe1M/Recipe1M+: "Access to the dataset is granted only for research purposes to universities and research institutions" (§6.5) | [im2recipe-Pytorch README](https://github.com/torralba-lab/im2recipe-Pytorch) | Confirmed verbatim. The repo's MIT licence covers the code, not the dataset. Excluded. |
| RecipeDB is CC BY-NC-SA 3.0 (§7.4) | [RecipeDB](https://cosylab.iiitd.edu.in/recipedb/) and its paper's Availability section | Confirmed. The paper itself is CC BY 4.0, which covers only the article text, not the data. Excluded. |
| Open Food Facts: database ODbL, contents DbCL, images CC BY-SA (§2.5) | [OFF data page](https://world.openfoodfacts.org/data) | Confirmed verbatim. The page also warns that images "may contain graphical elements subject to copyright or other rights". |

Not covered by the document, and found during the check:

- **MyPlate Kitchen is not blanket public domain.** Its [About page](https://myplate-prd.kwaps.platform.usda.gov/about-us) says some recipes were developed by MyPlate National Strategic Partners, and that direct use of recipes, formatting, artwork or compilations requires attribution in a stated citation format. Only works written by federal employees are US-government public domain; recipes contributed by universities, extension offices or partners are not automatically. An unofficial mirror ([myplate.food](https://myplate.food/recipes)) claims the official site was retired on 2026-01-07; that claim is unverified. Treat each MyPlate recipe's contributor as part of its rights record.
- The document is about nutrition and food-image datasets. It does not evaluate recipe-text sources beyond Recipe1M and RecipeDB, so it does not answer where licensable recipe text comes from. Its conclusion still stands for recipes: no large open dataset of recipe text is cleared for a paid app, which supports writing original recipes (SPEC 3.5).

Usable for FridgeLuck without licence friction: USDA FDC (CC0) for nutrition. OFF only through per-scan lookup with an ODbL notice, not as a bundled derived store (document §9.3). The image-dataset conclusions concern recognition training, not the recipe corpus.

Image datasets: the source document's recommendation to use FoodSeg103 (§9.1) is not adopted. FoodSeg103's images come from Recipe1M, which is research-only, and the Apache 2.0 licence on the repository does not clearly clear rights in those photographs. FoodSeg103 stays excluded until those image rights are resolved with counsel. The same applies to any model trained on it that ships in the app.
