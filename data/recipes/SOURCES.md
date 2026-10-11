# Recipe sources for the FridgeLuck corpus

Research date: 2026-10-11. This document inventories candidate recipe-text sources for the catalog corpus task (SPEC 3.5) and records, per source: the exact terms governing reuse of recipe text and images (quoted, linked, with the retrieval date), whether commercial redistribution inside a paid app is permitted, attribution and share-alike obligations, a plausible usable-recipe yield, and a verdict: **usable** or **quarantine**.

Evidence rules for this document:

- Every terms quote was verified against the primary page this session (2026-10-11). The route is recorded (direct fetch, or web research synthesis where the site blocked direct fetches).
- Unknown rights means quarantine. Absence of a forbidden-use clause is not permission.
- No bulk downloads were performed. Spot-checks were single-page fetches; `robots.txt` was checked before each (see "Method notes").
- Sam makes the final legal call; this document supplies the evidence.

## Already-settled conclusions (carried forward, not re-litigated)

From `docs/spec/overhaul-20261011/inputs/food-data-licensing.md` and its check document on branch `docs/spec-overhaul-20261011` (lead-verified 2026-10-11):

- **USDA FoodData Central** is public domain published under CC0 1.0 - usable for nutrition values, **not** a source of recipe text.
- **Recipe1M / Recipe1M+** is research-only ("Access to the dataset is granted only for research purposes to universities and research institutions") - excluded from a paid app.
- **RecipeDB** is CC BY-NC-SA 3.0 - NonCommercial and ShareAlike, doubly disqualified.
- **Open Food Facts** is ODbL - a packaged-product database, not a recipe source.

The check document's own conclusion stands: **no large open dataset of recipe text is cleared for a paid app.** Original recipes are therefore expected to be a large share of the corpus.

## Usable sources

### 1. Original recipes (in-house authorship) - usable, the backbone

Dishes written in our own words with our own structured steps, authored for FridgeLuck. The 25 seed recipes (`RIGHTS-AUDIT.md`) are the existing example of this class.

- Terms: none apply - we hold the rights to what we write.
- Commercial redistribution: permitted (our own work).
- Attribution: none owed.
- Share-alike: none.
- Yield: unbounded; constrained by writing and test-cooking effort, not rights. A dish concept (name plus ingredient list) is not copyrightable, so existing dishes can be *reinterpreted*; what must never be copied is another site's expressive method text.

### 2. NHS website recipes - usable under the Open Government Licence v3.0

The NHS website is owned by the Department of Health and Social Care. Its terms release NHS Website Content under the OGL. From `https://www.nhs.uk/our-policies/terms-and-conditions/` (retrieved 2026-10-11, direct fetch), verbatim:

> Copyright and database rights in NHS Website Content are released free-of-charge under the current version of the Open Government Licence ("OGL"), except where specified, either in these terms and conditions, elsewhere on this website or in the OGL terms.

> This means that you can use NHS Website Content, except where specified, including copying it, adapting it, and using it for any purpose, including commercially, provided you follow these terms and conditions and the terms of the OGL.

- **Commercial redistribution inside a paid app:** permitted explicitly ("including commercially").
- **Attribution obligations** (same page, verbatim):
  - Unmodified copies: attribute as `"Information from the NHS website"` plus `"as at DDMMYY"` when not refreshing the copy, and "publish, in a prominent and noticeable location within your site or service the statement that 'Information from the NHS website is licensed under the Open Government Licence v3.0'".
  - Adapted content (rewriting wording counts - "Any change to wording that serves to change its meaning or impact" is an adaptation): include `"Contains public sector information licensed under the Open Government Licence v3.0."` and **do not** attribute the adapted content to the NHS website.
- **Share-alike:** none beyond the OGL's own terms (OGL v3 is not copyleft).
- **Exclusions to respect** (same page, verbatim): "any logos, visuals, image rights, trademarks, trade names and design styles", and "information owned by third parties which we are not authorised to licence on to you... Many images on the NHS website are included as these are licensed by stock sites." **Ship no NHS photographs**; recipe text only.
- **Yield (spot-check):** the Healthier Families recipe index (`https://www.nhs.uk/healthier-families/recipes/`, retrieved 2026-10-11) lists **202 distinct recipe pages** (counted programmatically from the index HTML). Recipes are nutritionist-developed, under 600 calories per portion - a natural fit for the catalog.
- **Verdict: usable**, with the OGL attribution implemented in the app's source-credits surface and per-recipe source URLs kept in the rights record.

### 3. NHLBI Healthy Eating Recipes - usable for NHLBI-authored recipes, checked per recipe

The National Heart, Lung, and Blood Institute is a US federal agency. Works authored by federal employees as part of official duties are not subject to US copyright (17 U.S.C. § 105). The NHLBI site notice states (retrieved 2026-10-11 via web-research synthesis; nhlbi.nih.gov blocks direct fetches): "The information on this site is in the public domain and may be used or reproduced without permission."

- **Commercial redistribution inside a paid app:** permitted for federal works; the collection's own PDFs describe recipes "specially developed by the National Heart, Lung, and Blood Institute" (`https://www.nhlbi.nih.gov/sites/default/files/publications/15-5227.pdf`, retrieved 2026-10-11).
- **Attribution:** credit NHLBI as source; none of it burdens the app (requested, not a license condition, mirroring USDA practice).
- **The trap:** some NHLBI pages credit an external "Recipe Source" - for example the "Pinto Beans" page credits *Honoring the Gift of Heart Health Manual for American Indians and Native Alaskans*. Those recipes are not NHLBI works. Record each recipe's stated source; skip or individually clear the externally credited ones.
- **Yield (spot-check):** "More than 50 delicious heart-healthy recipes" (collection landing page, `https://www.nhlbi.nih.gov/health/heart-healthy-living/healthy-foods/healthy-eating-recipes`, retrieved 2026-10-11).
- **Verdict: usable** for NHLBI-authored recipes after a per-recipe contributor check; externally credited ones go to the unknown-rights path (quarantine until shown otherwise).

### 4. USDA MyPlate Kitchen - conditional; per-recipe contributor record required

Known findings, carried forward from the checked licensing research and confirmed this session: **MyPlate Kitchen is not blanket public domain.** Only works written by federal employees as part of official duties are US-government works; recipes contributed by MyPlate National Strategic Partners, universities, and extension offices are not federal works.

From the About page (`https://myplate-prd.kwaps.platform.usda.gov/about-us`, retrieved 2026-10-11 via web-research synthesis; the page blocked direct fetch), verbatim:

> Direct use of recipes, formatting, artwork, or compilation thereof from the MyPlate Kitchen are required to include proper attribution and do not serve as an endorsement by USDA of products or publications.

USDA's stated citation format (same page, retrieved 2026-10-11):

> U.S. Department of Agriculture. MyPlate Kitchen Website. *Title of recipe.* Recipe source (if listed). Available at MyPlate.gov/MyPlateKitchen. Access date: [month, day, year].

On partner-developed resources (`https://myplate-prd.kwaps.platform.usda.gov/partner-resources`, retrieved 2026-10-11 via web-research synthesis), verbatim:

> MyPlate National Strategic Partner resources are provided voluntarily by the MyPlate National Strategic Partners and can be used without permission.

That sentence is USDA speaking about its partners' resources; USDA cannot speak for the partners' copyrights. A National Strategic Partner's recipe is still not a federal work, and "can be used without permission" does not name commercial app redistribution explicitly. Per the checked research: **treat each partner or extension recipe as unknown rights until its contributor and terms are shown otherwise.** Record the contributor of every recipe considered.

- **Site status:** myplate.gov's consumer site was retired in January 2026 per an unofficial mirror (`https://myplate.food/`, which claims the retirement date 2026-01-07); the legacy `myplate-prd.kwaps.platform.usda.gov` platform still serves the recipe pages. The retirement claim is unverified against a USDA primary source - do not rely on the mirror; use the USDA-hosted pages.
- **Yield:** the unofficial mirror claims 1,072 MyPlate Kitchen recipes preserved; unverified count from a non-USDA host. The usable subset (USDA-authored, or partner recipes with cleared rights) is unknown until per-recipe contributor records exist.
- **Verdict: conditional** - USDA-authored recipes are usable with the citation format above; partner/extension recipes are quarantined as unknown rights until their contributors' terms say otherwise. This is the per-recipe rights-record work SPEC 3.5 requires.

## Quarantine list

Sources that fail the evidence bar, with the reason. Quarantined sources do not enter the corpus.

| Source | Terms (quote or citation) | Why quarantined |
|---|---|---|
| BBC Good Food | Immediate Media T&Cs: "you agree that you will only access its contents for your own personal and non-commercial use"; "You will need our prior written permission if you want to use any content on our Services for any other reason" (`https://www.immediate.co.uk/terms-and-conditions/`, retrieved 2026-10-11); "Content may only be downloaded or used for personal use" (`https://www.bbcgoodfood.com/good-food-app-terms-and-conditions`, retrieved 2026-10-11) | Personal-use-only terms; paid-app bundling is commercial redistribution; no permission evidence exists in the repo. The 141 bundled BBC recipes are rewrite targets (`RIGHTS-AUDIT.md`). |
| Recipe1M / Recipe1M+ | "Access to the dataset is granted only for research purposes to universities and research institutions" (checked doc, 2026-10-11) | Research-only permission gate; no commercial license. |
| RecipeDB | CC BY-NC-SA 3.0 (checked doc, 2026-10-11) | NonCommercial bars a paid app; ShareAlike bars a closed derived corpus. |
| RecipeNLG | Poznań University of Technology permission terms: use "only for non-commercial research and educational purposes" (Hugging Face dataset card `https://huggingface.co/datasets/mbien/recipe_nlg`, license metadata "unknown", retrieved 2026-10-11 via web-research synthesis) | Non-commercial research permission, not a license; underlying recipe text was scraped from commercial recipe sites, so no rights chain exists even before the permission gate. |
| Wikibooks Cookbook | Text is dual-licensed CC BY-SA 4.0 and GFDL (`https://en.wikibooks.org/wiki/Wikibooks:Copyrights`, retrieved 2026-10-11 via web-research synthesis) | Copyleft: a corpus derived from Wikibooks text would carry share-alike obligations over our catalog. Project rule: copyleft sources go to quarantine, not the corpus. |
| MyPlate partner and extension-office recipes | Attribution clause quoted above; contributors are the rights holders | Unknown rights until each recipe's contributor and terms are recorded. |
| Open Food Facts | ODbL (checked doc, 2026-10-11) | Not a recipe source (packaged-product database); listed to prevent category error. |
| Kaggle recipe dumps (e.g. scraped Food.com copies) | Category-level assessment, not a single verified dataset | Personal uploads of scraped commercial-site content; no rights chain. Avoid this category. |

## Yield summary

| Source | Verdict | Plausible usable yield (this session's evidence) |
|---|---|---|
| Original recipes | usable | Unbounded; expected large share of the corpus |
| NHS website recipes | usable | 202 recipe pages on the Healthier Families index (counted 2026-10-11) |
| NHLBI recipes | usable (NHLBI-authored only) | "More than 50" per the collection page; minus externally credited entries |
| MyPlate Kitchen (USDA-authored) | conditional | Unknown; mirror claims 1,072 total, contributor split unrecorded |
| Everything on the quarantine list | quarantine | 0 |

Path to SPEC 3.5's first-release target of about 400 reviewed recipes: the 25 seed originals, the NHS collection (202), the NHLBI-authored subset (50+), MyPlate's USDA-authored subset once contributor records exist, and new original recipes to fill the remainder.

## Method notes

- Retrieval routes: direct page fetches for immediate.co.uk, bbcgoodfood.com, nhs.uk, and nhlbi.nih.gov robots.txt; web-research synthesis (Perplexity Sonar, 2026-10-11) where sites blocked direct fetches (myplate-prd.kwaps.platform.usda.gov, nhlbi.nih.gov pages); primary-page verification of every quote is recorded above per source.
- `robots.txt` was checked before spot-checks: nhs.uk's wildcard section disallows specific service pages, not the recipe index; the single-page fetches performed were spot-checks, not crawls.
- No bulk download of any site was performed, and no site with terms forbidding reuse was crawled.
- Live-execution scope: none of this research spent money or called paid APIs.
