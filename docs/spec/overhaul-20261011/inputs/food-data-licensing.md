# Public Food Databases & Licenses for an iOS Offline Food App: Inventory, Accuracy Evidence, and a Paid-App Recommendation

**Scope.** This document inventories the public datasets and databases an iOS app doing *offline ingredient recognition* (on-device vision) and *offline nutrition lookup* could realistically build on. For each dataset it records: what it contains, exact published size, how labels/nutrient values were produced, published accuracy evidence (with independent checks where they exist), and the **exact license with verbatim quotes and primary-source URLs**. It closes with a licensing comparison table, one concrete license-compatible recommendation for a **paid** iOS app, remaining accuracy gaps, and an explicit unverified-claims list.

**Load-bearing assumption.** This document assumes the app's architecture is: (1) an on-device ingredient/dish recognition model trained offline by the app developer, and (2) an on-device nutrition database bundled in (or updated for) the app. That assumption is what makes licensing the controlling risk: **research-grade availability is not commercial clearance.** Several of the best-known food-vision datasets are *research-only by explicit terms* and are disqualified for a paid app; training a model on them inside a research lab and shipping it commercially is not something a license audit can wave through, and this document treats those datasets as excluded and says why. Nothing here is legal advice; the verbatim quotes are provided so counsel can verify each claim in one step.

**Verification status.** Licensing quotes were pulled from primary sources (official dataset pages, license texts, official repos) in October 2026. USDA record counts were counted directly from the official full CSV release of April 30, 2026. Accuracy numbers are quoted from the original papers. Claims that could not be confirmed from a primary source are quarantined in the [Unverified claims](#11-unverified-claims) section rather than asserted in the body.

---

## Contents

 1. [USDA FoodData Central](#1-usda-fooddata-central-fdc)
 2. [Open Food Facts](#2-open-food-facts-off)
 3. [Nutrition5k](#3-nutrition5k-google-research-2021)
 4. [Food-101](#4-food-101-eth-zurich-2014) (with Food-101N as evidence)
 5. [UECFood-256](#5-uecfood-256-japan) (with UECFoodPix)
 6. [Recipe1M / Recipe1M+](#6-recipe1m--recipe1m-mit-2017-2019)
 7. [Newer / otherwise relevant datasets](#7-newer--otherwise-relevant-datasets) — FoodSeg103, FooDD, UNIMIB2016, RecipeDB, Open Images (food subset); datasets considered and dropped
 8. [Licensing comparison table](#8-licensing-comparison-table)
 9. [Recommendation for a paid iOS app](#9-recommendation-for-a-paid-ios-app)
10. [Remaining accuracy gaps](#10-remaining-accuracy-gaps)
11. [Unverified claims](#11-unverified-claims)
12. [References](#12-references)

---

## 1. USDA FoodData Central (FDC)

### 1.1 What it contains

FDC is the US Department of Agriculture's integrated nutrition database. It aggregates five sub-databases ("data types"), each with different provenance (see 1.3):

| Data type | What it is | Granularity |
| --- | --- | --- |
| **Foundation Foods** | Lab-analyzed foods and ingredients with extensive underlying metadata | Per food item; per 100 g values; sample-level metadata |
| **SR Legacy** | The legacy "Nutrient Database for Standard Reference" — the classic USDA food table | Per food item; per 100 g; per portion when available |
| **Survey Foods (FNDDS)** | Foods as eaten, for the national dietary survey (What We Eat in America / NHANES) | Per food item; per 100 g **and per survey portion (gram weight)** |
| **Branded Foods** | Nutrients on branded and private-label product labels, submitted by industry data providers | Per product; per label serving or per 100 g |
| **Experimental Foods** | Research datasets contributed by specific studies | Per study |

**Intended use:** nutrition lookup — assign nutrient values to recognized ingredients/dishes or scanned barcodes. It contains no images, no recipes, and no barcodes images; Branded Foods carries barcode (GTIN/UPC) identifiers, which is what makes barcode→nutrition lookup possible.

### 1.2 Size (exact, counted this session)

From the official full CSV release `FoodData_Central_csv_2026-04-30.zip` downloaded from USDA on October 10, 2026 \[4\]; counts below were counted directly from `food.csv` (plus `foundation_food.csv` noted separately):

- **Branded Foods: 1,999,950** foods
- **SR Legacy: 7,793** foods
- **Survey (FNDDS): 5,432** foods
- **Foundation Foods: 469** foods (in `food.csv`); note `foundation_food.csv` itself has **395** rows — see Unverified claims
- **Experimental: 114** foods
- **Total: 2,101,279** entries

Release cycle (official download page \[3\]): Foundation Foods and Branded Foods update on a rolling schedule (current files dated 04/2026); FNDDS "Survey Foods" current release covers the 2021–2023 NHANES cycle (file dated 10/2024); SR Legacy's last release was 04/2018 (see 1.3 — SR Legacy is frozen).

### 1.3 Provenance (how the nutrient values were produced)

This is FDC's core strength: each data type has documented, internally-heterogeneous provenance. From the official FAQ \[2\], verbatim:

- **Foundation Foods:** "includes values derived from analyses for food components, including nutrients on a diverse range of foods and ingredients as well as extensive underlying metadata. These metadata include the number of samples, sampling location, date of collection, analytical approaches used, number of samples, date of analysis, and information about agricultural production, variety, and part of plant or animal analyzed." → **lab measurement**, with sampling metadata.
- **SR Legacy:** "provides a comprehensive list of values for food components, including nutrients derived from analyses, imputations, and the published literature." And critically: "SR Legacy, released in April 2018, is the final release of this data type and will not be updated." → **lab measurement + imputation + literature**, **frozen as of April 2018**.
- **Survey Foods (FNDDS):** "contains data on the nutrient and food component values and weights for foods and beverages reported in the What We Eat in America dietary survey component of the National Health and Nutrition Examination Survey." → values built to describe **foods as consumed in national dietary recall**; portion gram weights are the survey's instrument.
- **Branded Foods:** "are data from a public-private partnership that provides values for nutrients in branded and private label foods that appear on the product label. Information in Branded Foods is received from food industry data providers. USDA supports this data type by standardizing the presentation of the data." → **vendor-submitted label data**, standardized but not independently measured by USDA. FDC also ships derivation codes (e.g., values *calculated* from other label values), which an app can use to filter for measured vs. computed values.

**Practical consequence:** treat Branded Foods as transcription of labels (with the label-error risk in §10) and SR Legacy as a frozen-but-benchmarked reference; Foundation Foods is the highest-quality but smallest source.

### 1.4 Evidence on accuracy

FDC is the reference source other datasets measure against (Nutrition5k, RecipeDB, and FoodData's im2recipe nutrition subset all build their nutrient values from USDA tables), so the question inverts: are *derived* products faithful to FDC? Direct third-party audits of FDC's own Branded values were not found this session (see §11); the US-food-label mismatch literature that exists was not located in a citable primary form during research for this document.

### 1.5 License (verbatim quotes)

**Basis: US government work in the public domain, published under CC0.** From the official FDC API Guide \[1\], verbatim:

> "USDA FoodData Central data are in the public domain and they are not copyrighted. They are published under CC0 1.0 Universal (CC0 1.0)."
>
> "No permission is needed for their use, but we request that users list FoodData Central as the source of the data, and when possible, notify us of the product that uses the data so we may better track how FDC is being used in the public domain."

Suggested citation (same page, verbatim): "U.S. Department of Agriculture, Agricultural Research Service. FoodData Central, fdc.nal.usda.gov."

**Attribution clause:** a *request*, not a license condition — attribution costs nothing legally and should be done anyway. **Commercial use / redistribution / app bundling:** unrestricted under CC0; no share-alike; no field-of-use restriction. Bundling a snapshot in a paid app is permitted with no notice obligation.

**API and download terms** (same API Guide \[1\], verbatim):

> "Anyone may access and use the API. However, a data.gov API key must be incorporated into each API request."
>
> "FoodData Central currently limits the number of API requests to a default rate of 1,000 requests per hour per IP address."

Bulk downloads are full CSV or JSON releases, free, no key needed \[3\] — the mechanism an offline app would use to bundle a snapshot.

### 1.6 Fit for this app

The only large, unambiguously commercial-clean nutrition database in this inventory. Baseline choice for the offline nutrition lookup. Weaknesses: frozen SR Legacy, vendor-quality Branded data, no imagery, US-centric food coverage (see §10).

---

## 2. Open Food Facts (OFF)

### 2.1 What it contains

A global, volunteer-maintained database of packaged-food products: product name, brands, barcode, ingredient lists, nutrient panels as transcribed from packaging, Nutri-Score/NOVA/additives derived fields, and a product photo per entry. Its app SDKs and the public API make it the de-facto open barcode→product lookup. Granularity: per product (not per ingredient-of-a-dish); nutrient values are *label* values (per 100 g as printed), not measurements. Intended use: barcode scanning and packaged-product information display.

### 2.2 Size

**4,805,482 products** as displayed on the OFF homepage on October 10, 2026 (live fetch \[6\]). The count changes continuously — the database accepts contributions daily. For planning: the official full CSV export is roughly 0.9 GB compressed (official data page \[5\]).

### 2.3 Provenance

Almost entirely **crowdsourced**: volunteers photograph packaging and transcribe ingredient lists and nutrient panels, moderated by community review and automated quality checks (e.g., product-completeness scores, generic-name checks). Nutrient values are transcriptions of printed labels, plus derived calculations (e.g., energy computed from macronutrients when absent). No lab measurement, no per-item audit chain.

### 2.4 Evidence on accuracy

**Reported by third parties (the only independent-style audit found):** a 2026 audit by the team behind the Lean calorie app tested **857,655** French OFF products and found **46,757 complete labels (5.5%) internally incoherent** under Atwater-style energy/macronutrient consistency checking; **391,707 (≈45.7%)** products lacked complete labels, and **16,364** had aberrant values (e.g., a "zero-calorie" croissant); protein bars showed the worst coherent-label inconsistency rate (**20.8%**) \[31\]\[38\]. **Caveats, which matter:** this is a *non-peer-reviewed preprint by a company that competes with OFF-based apps*, it measures *internal consistency* (energy vs. macronutrients), not ground-truth accuracy vs. laboratory values, and it covers France only. Treat it as a red flag about label-quality variance, not as a measured error rate. See §11.

**Peer-reviewed context on crowdsourced annotation quality generally:** a controlled study with 2,028 respondents estimating calories from food images found "Average accuracy was 5 out of 20 correct guesses, where 'correct' was defined as a number within 20% of the ground truth. Even a small crowd of 10 individuals achieved an accuracy of 7, exceeding the average individual and expert annotator's accuracy of 5," and "The calorie content of energy-dense foods was overestimated (P=.02)" \[32\] — evidence that *untrained crowd* estimates of nutrition from images are individually poor (this speaks to crowd-built datasets generally, not to OFF's label transcription specifically).

**Reported by the project itself:** OFF's own quality machinery scores product completeness and flags inconsistent entries; no official error-rate figure is published (§11).

### 2.5 License (verbatim quotes)

OFF states on its official data page \[5\], verbatim:

> "The Open Food Facts database is available under the Open Database License (ODbL). The individual contents of the database are available under the Database Contents License (DbCL). Products images are available under the Creative Commons Attribution ShareAlike licence (CC-BY-SA)."

**The operative license is ODbL 1.0.** Key clauses, quoted verbatim from the official license text at opendatacommons.org \[7\]:

**Commercial use — permitted explicitly:**

> "3.1 Subject to the terms and conditions of this License, the Licensor grants to You a worldwide, royalty-free, non-exclusive, terminable (but only under Section 9) license to Use the Database for the duration of any applicable copyright and Database Rights. These rights explicitly include commercial use, and do not exclude any field of endeavour."

**Attribution — required when a produced work publicly uses the data:**

> "4.3 If You Publicly Use a Produced Work, You must include a notice associated with the Produced Work reasonably calculated to make any Person that uses, views, accesses, interacts with, or is otherwise exposed to the Produced Work aware that Content was obtained from the Database, that it is available under this License, and that it is available under this License." *(sic — the license text repeats the clause; the site's rendered example is:)* "Contains information from DATABASE NAME, which is made available here under the Open Database License (ODbL)."

**Share-alike — triggered by publicly using a Derivative Database:**

> "4.4a Any Derivative Database that You Publicly Use must be only under the terms of: i. This License; ii. A later version of this License similar in spirit to this License; or iii. A compatible license."
>
> "4.4b For the avoidance of doubt, Extraction or Re-utilisation of the whole or a Substantial Part of the Contents into a new database is a Derivative Database and must comply with Section 4.4."

**What does *not* trigger share-alike — the Produced-Work carve-out:**

> "4.5b Using this Database, a Derivative Database, or this Database as part of a Collective Database to create a Produced Work does not create a Derivative Database for purposes of Section 4.4."

**Internal use carve-out:**

> "4.5c Use of a Derivative Database internally within an organisation is not to the public and therefore does not fall under the requirements of Section 4.4."

**Obligation to publish alterations if a derivative is publicly used:**

> "4.6 If You Publicly Use a Derivative Database or a Produced Work from a Derivative Database, You must also offer to recipients of the Derivative Database or Produced Work a copy in a machine readable form of: a. The entire Derivative Database; or b. A file containing all of the alterations made to the Database or the method of making the alterations to the Database..."

**(a) What ODbL means for a paid app that bundles or fetches the data.** Charging for the app is fine — 3.1 explicitly grants "commercial use." What ODbL regulates is *what you do with the database*, not your revenue. Three distinct integration patterns (see §9.3 for the full analysis): bundling an unmodified copy = "conveying the Database" (must carry the license and attribution, no share-alike on your app code); transforming/subsetting a substantial part into your own offline store = creating a **Derivative Database** (if publicly used, it must be published under ODbL per 4.4a/4.6 — your *app code* stays proprietary either way); displaying per-scan lookups = a **Produced Work** (4.5b: no derivative created; 4.3 attribution notice required).

**(b) Share-alike implications for a derived database.** If the app ships a filtered/reformatted/translated subset (e.g., "everything sold in country X with ingredients and macros, reformatted to a compact binary"), that is "Extraction or Re-utilisation of the whole or a Substantial Part of the Contents into a new database" (4.4b). Publicly using it — which shipping it inside a distributed app is — requires publishing that derivative under ODbL plus an alterations file (4.6). This is survivable (the derivative is just the data, not the app), but it means *competitors can take your curated, cleaned offline food database and reuse it*, and your app must display the ODbL attribution notice.

**(c) Attribution notice requirements.** Any app screen or data file through which users are "exposed" to OFF-derived content must carry a notice "reasonably calculated" to inform them the content came from the OFF database and is ODbL-licensed (4.3 + the site's rendered example above). In practice: a credits line on the scan-result screen and inside the data bundle.

**Separate traps:** product **images** are CC-BY-SA (share-alike for images used in-app, not ODbL), and the **individual records** are DbCL (a permissive contents license). The ODbL obligations above attach to *the database as a whole*. OFF also publishes bulk exports and warns heavy scrapers to use them \[5\].

### 2.6 Fit for this app

The only large open barcode→packaged-food source. Usable commercially, but the ODbL mechanics (§9.3) and the label-quality variance (§2.4) mean it should be a *complement* to USDA Branded Foods for barcodes, not the offline backbone, unless the app's focus is non-US markets.

---

## 3. Nutrition5k (Google Research, 2021)

### 3.1 What it contains

Real cafeteria plates with *paired* visual and nutritional data: "Scans data for 5,006 plates of food, each containing: 4 rotating side-angle videos, Overhead RGB-D images (when available), Fine-grained list of ingredients, Per-ingredient mass, Total dish mass and calories, Fat, protein, and carbohydrate macronutrient masses" \[8\] (README, verbatim). The paper adds: "Nutrition5k contains 20k short videos generated from roughly 5000 unique dishes constructed from more than 250 different ingredients. Each dish has a full breakdown of ingredient labels, their quantities, and their macronutrient information computed using the USDA Food and Nutrient Database. Furthermore, 3.5k out of the 5k dishes also include overhead RGB-D images" \[9\]. Granularity: **per-ingredient** (name, mass in grams, per-ingredient and total macros/calories) — the only commercial-usable dataset in this inventory with that combination. Intended use: training/evaluating models that predict ingredients, mass, and nutrition from images/depth.

### 3.2 Size

Official README: **5,006 plates**; paper Table 1: **5,066 unique dishes**, average **5.7 ingredients per plate**; \~20,024 videos; overhead RGB-D for \~3.5k dishes \[8\]\[9\]. The 5,006 vs 5,066 discrepancy (README vs paper) is unresolved — see §11. Train/val/test splits are published in the repo.

### 3.3 Provenance

Plates assembled in **Google cafeterias**; each ingredient added incrementally on a precision scale (**±1 g**, per paper Table 1) during scanning with a RealSense D435 depth camera. Nutrient ground truth, paper verbatim \[9\]: "Per gram nutrition content for each item was calculated using the per gram ingredient breakdown and the USDA Food and Nutrient Database. This value is then multiplied by the incremental weight measurement as the item is added to the plate to generate the ground truth annotation." → **measured masses × USDA reference values**. Images deliberately include "non-replete" complex scenes with cutlery and hands ("Real complex food scenarios... 'non-replete' complex scenes").

### 3.4 Evidence on accuracy

**Reported in the paper \[9\]** (calorie estimation error, mean absolute error as % of ground truth; test set):

| Method | Calorie MAE (g) | MAE (%) | Mass MAE (g) | Mass MAE (%) |
| --- | --- | --- | --- | --- |
| Baseline (predict mean) | 150.8 | 60.2 | 119.9 | 49.1 |
| Calorie estimation independent of portion size | 24.1 | 9.5 | — | — |
| Direct RGB (2D) calorie prediction | 70.6 | 26.1 | 67.4 | 27.7 |
| End-to-end (RGB-D + volume) | 41.3 | 16.5 | 40.4 | 16.4\* |

(\*mass MAE 40.4 g / 16.4% is the end-to-end row; the RGB-D-only row is 47.6 g / 18.8%; with the volume scalar aid, 41.3 g / 16.5%.) The key practical number for a phone-only app: **direct 2D calorie prediction 26.1% MAE**; the 16.5% result *requires the scanning rig's volume/depth input*. The paper also reports ingredient-recognition potential but the headline metric is nutrition error. (Paper Table 4: final model with image + volume achieves 29.4 g / 13.7% mass MAE — slight improvement over Table 3's configuration.)

**Human comparison, paper verbatim \[9\]:** "The average percent error for non-nutritionists is 53%... The nutritionists had a lower average percent error rate of 41%." — i.e., the best reported model (16.5% with depth) beats both human groups, but the 2D-only number does not.

**Independent verification:** no third-party replication found this session; see §11. A data-quality note exists in the official repo: GitHub issue #11 (open, Nov 2025) reports a plate with implausible **3,493 kcal** total calories for its ingredient masses \[10\] — an isolated, officially-tracked outlier, not a measured error rate.

### 3.5 License (verbatim quotes)

From the official GitHub repository README \[8\], verbatim:

> "We release all Nutrition5k data under the Creative Commons V4.0 license. You are free to share and adapt this data for any purpose, even commercially." (links to https://creativecommons.org/licenses/by/4.0/)

CC BY 4.0 = commercial use, adaptation, and redistribution permitted with attribution. **Caveat:** the statement lives in the README; the repository ships **no standalone LICENSE file** (see §11). Attribution: name the dataset and link the license; Google Research has no additional trademark grant (using the Google name in marketing would be a separate issue).

### 3.6 Fit for this app

The single best commercial-usable training source for *ingredient-level* recognition with *real* per-ingredient masses and USDA-linked nutrient vectors. Weaknesses: small (5k plates, one cafeteria system), Western-skewed (see quote in §10.4), and its ground truth is USDA-referenced, so it inherits USDA's "reference preparation" abstraction (§10.2).

---

## 4. Food-101 (ETH Zurich, 2014)

### 4.1 What it contains

"101 food categories, with 101'000 images. For each class, 250 manually reviewed test images are provided as well as 750 training images" \[11\] (official page, verbatim). Single-label dish classification only — no ingredients, no masses, no nutrition. Intended use: dish-category classification benchmark.

### 4.2 Size

**101,000 images, 101 categories**, 750 train + 250 test per class \[11\].

### 4.3 Provenance

Crowd photos scraped from a social food app. Paper verbatim \[12\]: "we have collected a novel real-world food dataset by downloading images from foodspotting.com. The site allows users to take images of what they are eating, annotate place and type of food and upload these information online." Labels derive from the platform's user tags, filtered and cleaned only for the test split: "On purpose, the training images were not cleaned, and thus still contain some amount of noise. This comes mostly in the form of intense colors and sometimes wrong labels." \[11\] (official page, verbatim).

### 4.4 Evidence on accuracy

**Paper-reported (original benchmark) \[12\]:** random forest on extracted descriptors 50.76% top-1; the CNN tried outperformed RF by 5.64 points → **56.40% top-1**. Accuracy trajectory documented by a later, independent group (Recipe1M+ paper \[19\], verbatim): "subsequent work by \[9\], \[10\] and \[11\] could only improve this result to 77.4%, 79% and 80.9%" — modern CNN/vision-transformer fine-tunes reach \~77–81% on the official test set.

**Independent label-noise audit:** the Food-101N project (CleanNet, CVPR 2018) built a 310,009-image superset from the same source with the same 101 classes, explicitly to study label noise \[14\]; a third-party audit (cleanlab) reports "We discovered thousands of label issues, outliers, ambiguous examples, and (near) duplicates in this famous computer vision dataset" \[15\]. The audit's exact target (Food-101 vs Food-101N) is muddled in the blog — see §11. Directionally consistent with the official page's own noise warning.

### 4.5 License (verbatim quotes)

**No license is stated anywhere official.** The ETH official page \[11\] and the original download offer no license terms; Hugging Face's copy of the dataset (the `ethz/food101` card, the most standard distribution today) lists **"license: unknown"** \[13\]. There is no LICENSE file in any official distribution located this session. Per this document's rules: **Food-101 is unlicensed — treat any commercial use as unclarified.** The provenance (photos scraped from a third-party platform, FoodSpotting) compounds this: the *underlying photographs'* rights sit with their original uploaders, and nothing in the dataset documentation purports to clear them. This is the single most common "everyone trains on it" dataset with the least paperwork. See §11.

### 4.6 Fit for this app

Useful as a *pretraining* corpus for dish taxonomy (101 common dish categories), with model weights shipped rather than images. Legally the weakest mainstream option; get counsel's view or a license clarification before shipping anything derived from it (see §9.4).

---

## 5. UECFood-256 (Japan)

### 5.1 What it contains

"The dataset 'UEC FOOD 256' contains 256-kind food photos. Each food photo has a bounding box indicating the location of the food item in the photo. Most of the food categories in this dataset are popular foods in Japan and other countries" \[16\] (official page, verbatim). Ships category IDs with English (`category.txt`) and Japanese (`category_ja.txt`) names, bounding boxes, and a `multiple_food.txt` flag for images containing multiple dishes. **Follow-on: UECFoodPix / UECFoodPixComplete** — "9,000 training and 1,000 test images" with pixel-wise masks over 103 classes (R-channel label maps; PixComplete uses manually refined masks where Pix used GrabCut-assisted ones) \[18\]. Intended use: dish detection/classification (256) and ingredient-level segmentation (Pix).

### 5.2 Size

256 categories; bounding-box annotations per image. **No exact total image count is published on the official page or in the system paper** — the paper states only: "UEC-Food256 is a newly-constructed food image dataset, which consists of 256 kinds of foods. Each category has more than 100 images" \[17\] (implying &gt;25,600, but the true total is not stated). Third-party sources disagree (one commonly-cited figure is 16,557 images; a Kaggle mirror counts \~31,000 files including annotation files) — see §11. UECFoodPix: 9,000 + 1,000 images \[18\].

### 5.3 Provenance

Images collected and expanded semi-automatically by the authors; the paper describes building it "by extending UEC-Food100 with transfer learning and crowd-sourcing automatically" \[17\] — i.e., search-collected images validated through crowdsourced relevance judgments, plus later manual curation for the Pix masks (GrabCut vs. manual per image class).

### 5.4 Evidence on accuracy

**Paper-reported \[17\]** (FoodCam-256 system paper): "we have achieved the 74.4% classification rate for the top 5 category candidates" and "The top-1 and top-5 rate were 50.1% and 74.4%, respectively" (5-fold cross validation, 256-class). These are 2014-era Fisher-Vector numbers; modern models do better but there is no canonical published SOTA on UEC-256 — the dataset's later literature is scattered.

### 5.5 License (verbatim quotes)

From the official page \[16\], verbatim:

> "Note that this dataset can be used only for non-commercial research purpose. If you like to use it for any other purpose, please contact us."

And for the follow-on \[18\], verbatim:

> "UECFoodPix and UECFoodPixComplete dataset can be used only for non-commercial research purpose."

**Explicit field-of-use restriction: non-commercial research only.** Disqualified for a paid app absent a separate written permission from the University of Electro-Communications (the page invites contact, so permission is *obtainable in principle*, but no standing commercial license is published).

### 5.6 Fit for this app

Excluded as-is. Its value here is (a) coverage of Japanese/East Asian dishes the Western datasets miss, and (b) documented evidence that single-dish top-1 accuracy on realistic photos was \~50% even within a curated 256-class set — a useful prior for §10.

---

## 6. Recipe1M / Recipe1M+ (MIT, 2017–2019)

### 6.1 What it contains

Over "one million cooking recipes and 13 million food images" (abstract, verbatim) \[19\]: structured recipes (title, ingredients, instructions), dish images linked to recipes, plus **ingredient-detection annotations** for a subset and, in the Recipe1M+ release, per-recipe nutrition fields mapped to USDA. Intended use: image→recipe retrieval, ingredient prediction, and (in derived work) nutrition estimation from images. Granularity: per recipe/dish.

### 6.2 Size

Paper Table I \[19\]: Recipe1M: **1,029,720 recipes**; **887,706 images**. Recipe1M+: **13,735,679 images** (train 9,727,961 / val 1,918,890 / test 2,088,828). The "intersection" subset (images verified to show the dish) is 716,480 images. USDA-linked nutrition subset (official im2recipe-Pytorch README \[20\], verbatim): "There are 35,867 recipes for training, 7,687 for validation and 7,681 for testing" with FSA traffic-light and `nutr_values_per100g` fields.

### 6.3 Provenance

Recipes "scraped from over two dozen popular cooking websites" \[19\]; images from recipe sites plus a second phase pulling candidates via Google image search ("we managed to download over 47M images," deduplicated to 13.7M) \[19\]. Ingredient-detection annotations: crowdsourced human annotation on the intersection subset. Nutrient values: recipe ingredients mapped to USDA tables (see 6.2's README fields), i.e., **model-derived per-recipe estimates, not measured values**.

### 6.4 Evidence on accuracy

**Paper-reported retrieval results \[19\].** On Recipe1M (Table 3), image→recipe (im2recipe), joint embedding + semantic regularization: **median rank 5.2, R@1 24%, R@5 51%, R@10 65%**; the strongest later baseline reported in the same table (AdaMine) reaches medR 1.0 / R@1 40% / R@5 69%. On Recipe1M+'s larger test set (Table 6), a model trained on Recipe1M+ achieves medR 5.7 / R@1 21% / R@5 49% / R@10 62% (im2recipe) — training on the larger noisier set does *not* beat the curated-subset result. Human comparison (Table 5): "on average our method with semantic regularization performs better than average AMT worker" on the judged-pair task; exact human-vs-model percentages from the table were not cleanly extractable from the PDF this session (see §11). Ingredient-detection and recipe2image numbers are in the same tables. No third-party audit found; the 65% R@10 figure is the paper's own.

### 6.5 License (verbatim quotes)

**Research-only, by explicit distribution terms.** The maintainers' official download README (torralba-lab/im2recipe-Pytorch) \[20\], verbatim:

> "After submission, we will share the necessary download links via email. Access to the dataset is granted only for research purposes to universities and research institutions."

The official project site \[21\] repeats the request-a-key flow. No standing commercial license, no CC license, no redistribution right. This is a **permission-gated** dataset: the gate is identity- and purpose-based (universities/research institutions), and a paid-app integration falls squarely outside it. (For comparison, the derivative Recipe1M images inside FoodSeg103 are discussed in §7.1 — the same provenance question appears there in sharper form.)

### 6.6 Fit for this app

Excluded for the paid app. It is nonetheless the reference for what image→recipe→nutrition pipelines achieve (and their limits: retrieval, not identification; images not portion-annotated — see §10.1). If the team wants Recipe1M's structure commercially, the realistic paths are: negotiate with the rights holders, or rebuild the pipeline from allowed sources (recipes with US-style licenses are rare; most recipe text platforms claim database rights).

---

## 7. Newer / otherwise relevant datasets

Five evaluated and included below (each with the six required fields), then the ones considered and dropped.

### 7.1 FoodSeg103 (Alibaba/Singapore Management University, 2021)

**Contains.** Real food photos with pixel-wise ingredient segmentation masks: "We build a new food image dataset FoodSeg103 containing 7,118 images. We annotate these images with 104 ingredient classes and each image has an average of 6 ingredient labels and pixel-wise masks" (official repo README, verbatim) \[22\]. The paper describes the combined effort: "we build a new food image dataset FoodSeg103 (and its extension FoodSeg154) containing 9,490 images. We annotate these images with 154 ingredient classes" \[23\] — v1 released = 103 classes / 7,118 images; FoodSeg154 was not publicly released as a benchmark \[22\]. Intended use: fine-grained ingredient segmentation.

**Size.** 7,118 images / 104 classes (repo) \[22\]; 9,490 images / 154 classes counting the unreleased extension (paper) \[23\]. Average 6 ingredient labels per image.

**Provenance.** Images curated from Recipe1M; pixel masks hand-annotated. The Hugging Face mirror card states the images are "a curated sample from Recipe1M and annotated and refined by human annotators" \[24\] — a secondary statement of provenance; the paper's data section describes collection from Recipe1M images. This matters: see License below.

**Accuracy.** Paper-reported (repo model zoo \[22\]\[23\]): best published segmentation baselines reach **45.1 mIoU / 57.4 mAcc** (ViT-16/B with MLA decoder); Swin-S UperNet 41.6 mIoU; earlier CNN baselines 27.8–34.6 mIoU. Practical reading: even the best models get roughly half of ingredient pixels right at class level — ingredient segmentation on real plates is far from solved.

**License (verbatim quotes).** Official repo README \[22\]: "This project is released under the Apache 2.0 license." (a LICENSE file is present in the repo). Hugging Face card \[24\]: "Apache 2.0 license." **Operational note:** the distributed `FoodSeg103.zip` is password-protected (password published in the README), and the **upstream images come from Recipe1M**, whose own terms are research-only (§6.5). Apache 2.0 on the *repository* does not obviously retro-clear rights in every *photograph* inherited from a research-only collection — the release is Apache 2.0, but the provenance tension is documented here and unresolved (§11). Flagged risk, not a clean bill.

**Fit.** The only public commercial-usable pixel-level ingredient dataset. Usable for a segmentation head with attribution; document the Recipe1M provenance question with counsel.

### 7.2 FooDD (Food Detection Dataset for Calorie Measurement; Pouladzadeh, Yassine, Shirmohammadi, 2015)

**Contains.** Food photographs for portion/calorie research, with a built-in scale reference: paper abstract verbatim \[29\]: "In this paper we introduce FooDD: a Food Detection Dataset of 3000 images that offer variety of food photos taken from different cameras with different illuminations. We also provide examples of food detection using graph cut segmentation and deep learning algorithms." DataPort adds: "Please note that in its full view, the human thumb in each image is approximately 5 cm by 1.2 cm" \[28\] — i.e., images embed a known-size reference for volume estimation.

**Size.** **3,000 images** (paper abstract \[29\]); download archive 4.66 GB (DataPort \[28\]).

**Provenance.** Photographs contributed/collected by the authors' group for calorie-measurement research (single- and mixed-item plates); not lab-measured per-ingredient masses. Detailed collection protocol not verified this session (§11).

**Accuracy.** No canonical public benchmark accuracy on FooDD was located this session; the companion papers report system-level calorie-estimation results on it (IEEE TIM 2014 lineage), but no verbatim number was captured — do not quote one (§11).

**License (verbatim quotes).** IEEE DataPort lists the dataset with `"license": "https://creativecommons.org/licenses/by/4.0/"` (page metadata \[28\]) — CC BY 4.0: commercial use and redistribution permitted with attribution. **Access condition, verbatim from the DataPort page \[28\]:** "This dataset requires an IEEE DataPort Subscription." (IEEE DataPort open-access subscriptions are free with registration, but access is gated through IEEE's account system, not a direct download.)

**Fit.** A commercial-usable, credit-card-free option for portion-scale imaging research; small, dated, and thin on annotations. Optional; not core.

### 7.3 UNIMIB2016 (University of Milano-Bicocca, 2017)

**Contains.** Cafeteria-tray photography: "This database can be used for food recognition. The database is composed of 1,027 tray images with multiple foods and containing 73 food categories" (official lab page, verbatim) \[25\], with per-item bounding boxes and masks. The Nutrition5k paper's related-work description: "Ciocca et al. introduce a dataset with 1,027 tray images and segmentation masks for 73 food categories but with no portion annotations" \[9\].

**Size.** 1,027 images / 73 categories \[25\].

**Provenance.** Real canteen trays photographed by the lab; items labeled per category; no masses.

**Accuracy.** The originating paper (Ciocca et al., IEEE JBHI 2017) reports its own per-category recognition results, but no verbatim metric was captured this session — none is quoted here (§11).

**License (verbatim quotes).** The official page \[25\] provides download links and a citation request but **states no license at all.** Per this document's rules: **licensing unresolved — do not integrate commercially without contacting the lab.**

**Fit.** Valuable as *evidence* for multi-dish tray composition (73 categories, real trays); not integrable as-is.

### 7.4 RecipeDB (IIIT-Delhi Complex Systems Lab, 2020)

**Contains.** Structured recipe database with per-ingredient and per-recipe nutrition: "RecipeDB... is a structured compilation of recipes, ingredients and nutrition profiles interlinked with flavor profiles and health associations. The repertoire comprises of meticulous integration of 118 171 recipes from cuisines across the globe (6 continents, 26 geocultural regions and 74 countries), cooked using 268 processes" \[27\] (Database journal, 2020). \~20,000+ ingredients (aggregators report 20,262 \[36\] — secondary, see §11). Per-ingredient quantity/unit/state; per-recipe estimated nutrition.

**Provenance.** Recipes "sourced... from many online resources, and its nutritional information from the USDA Food Composition Databases" (official FAQ, verbatim \[26\]); nutrition computed by mapping each ingredient to USDA NDB IDs and summing: "Using the name of the ingredient and its state, each ingredient was mapped to a unique 'NDB ID' from USDA database. Further using the standard nutrition data from USDA data tables, the nutritional profile of the ingredient was estimated by mapping quantity and unit" (FAQ, verbatim \[26\]). → **recipe-web scraping + USDA-derived estimates**, not measurements.

**License (verbatim quotes).** Official FAQ \[26\], verbatim:

> "The data is available under Creative Commons License Attribution-NonCommercial-ShareAlike 3.0 Unported (CC BY-NC-SA 3.0)"

NonCommercial **and** ShareAlike — doubly disqualified for a paid app: no commercial use, and any adaptation must be shared under the same license. Documented here because it is the best-structured open global-recipe resource and because its USDA-mapping methodology is reusable knowledge even where its data is not.

**Fit.** Excluded commercially. Its ingredient→USDA mapping approach (Q11 of the FAQ) is a useful *method* reference for building your own USDA-mapped recipe layer from commercially-clean inputs.

### 7.5 Open Images V7 (Google) — food subset

**Contains.** "a dataset of \~9M images annotated with image-level labels, object bounding boxes, object segmentation masks, visual relationships, and localized narratives" \[30\] (official facts page, verbatim). It includes food/dish classes among its 600 boxable classes (dishes photographed in context — restaurant plates, store shelves — rather than isolated studio shots). There is no official "food subset"; one is derived by filtering the class list (the download tooling supports class-filtered image lists). Intended use: object detection/classification pretraining, including multi-object plates.

**Size.** \~9M images; dense annotations over 1.9M images \[30\]. Food-class image counts are not published as a single number and were not compiled this session (§11).

**Provenance.** Images sourced from Flickr under claimed CC licenses; annotations by professional Google annotators.

**License (verbatim quotes).** Official facts page \[30\], verbatim:

> "The annotations are licensed by Google LLC under CC BY 4.0 license. The images are listed as having a CC BY 2.0 license. Note: while we tried to identify images that are licensed under a Creative Commons Attribution license, we make no representations or warranties regarding the license status of each image"

That no-warranty sentence is the operative commercial caveat: images are *listed as* CC BY 2.0 but individual image license status is not guaranteed — a nonzero royalty-style risk when shipping derived models at scale. Annotations are cleanly CC BY 4.0.

**Fit.** A supplement for detection-style pretraining (multi-dish scenes, cutlery, hands), not a nutrition source. Worth using for scene-context robustness with attribution; weigh the image-license no-warranty risk.

### 7.6 Considered and dropped

- **VireoFood-172 (Fudan/CityU)** — 172-class Chinese food dataset. The official Fudan FVL page returned **404** on fetch this session and the City University of Hong Kong host was unreachable; no primary license statement could be located \[37\]. Dropped per the documentation rule: no verifiable license → no inclusion. (Chinese-cuisine coverage remains a real gap — see §10.4.)
- **Food-101N** — not dropped but folded into §4 as accuracy evidence: it is a 310,009-image noisy superset of Food-101 built to study label noise \[14\]; its own page states no license, so it is evidence, not an integration candidate.
- **DeepFood (Chang et al., 2016)** — a recognition *system* paper built on Food-101-style data, not a redistributable public dataset (from general knowledge, not re-verified this session — §11).
- **"Indian food" Kaggle datasets** (e.g., Indian Food Images) — personal uploads, no documented license or provenance; dropped per the documentation rule.
- **FoodCam-100 (UEC)** — subsumed by UECFood-256's non-commercial terms (§5.5).

---

## 8. Licensing comparison table

| Dataset | License (primary source) | Commercial use | Redistribution / app bundling | Attribution burden |
| --- | --- | --- | --- | --- |
| **USDA FoodData Central** | Public domain; CC0 1.0 (USDA API Guide \[1\]) | **Yes** — explicit | **Yes** — no conditions; snapshot bundling fine | Requested, not required ("we request that users list FoodData Central as the source") |
| **Open Food Facts** | ODbL 1.0 (database); DbCL (contents); CC-BY-SA (images) (OFF data page \[5\]) | **Yes** — ODbL §3.1 "explicitly include commercial use" | **Conditional** — verbatim copy: keep license + notices; *derived/substantial* store: share-alike if publicly used (§4.4a/4.6) | **Required** — ODbL §4.3 notice "reasonably calculated" to reach users |
| **Nutrition5k** | CC BY 4.0 (README statement \[8\]) | **Yes** — "even commercially" (README) | Yes, with attribution | Name + license link |
| **Food-101** | **None stated** (official page silent \[11\]; HF "unknown" \[13\]) | **Unclarified** | **Unclarified** — photos scraped from FoodSpotting | — (no terms exist to follow) |
| **UECFood-256** | Non-commercial research only (official page \[16\]) | **No** — explicit restriction | No (research use only) | Citation per page |
| **UECFoodPix / PixComplete** | Non-commercial research only (official page \[18\]) | **No** | No | Citation per page |
| **Recipe1M / Recipe1M+** | Research-only, permission-gated (official README \[20\]: "only for research purposes to universities and research institutions") | **No** | No (access-gated; no redistribution right) | Citation per paper |
| **FoodSeg103** | Apache 2.0 (official repo \[22\]) | **Yes** — with the Recipe1M-upstream caveat (§7.1) | Yes, license file included | LICENSE + copyright notice |
| **FooDD** | CC BY 4.0 (IEEE DataPort metadata \[28\]) | **Yes** | Yes, with attribution; access via free IEEE DataPort account | Credit authors + license |
| **UNIMIB2016** | **None stated** (official page \[25\]) | **Unclarified** | **Unclarified** | Citation requested |
| **RecipeDB** | CC BY-NC-SA 3.0 (official FAQ \[26\]) | **No** — NonCommercial | Share-alike also applies | Attribution + same-license |
| **Open Images (food subset)** | Annotations CC BY 4.0; images "listed as" CC BY 2.0 **with no-warranty disclaimer** (facts page \[30\]) | **Yes, with caveat** | Yes | Attribution; verify image licenses individually if shipping images |

---

## 9. Recommendation for a paid iOS app

### 9.1 The combination (what to integrate)

**Nutrition lookup (offline, bundled): USDA FoodData Central.** Download the full CSV release \[4\], derive a compact on-device store (SQLite/DuckDB/flatbuffers) filtered to the fields and locales the app needs, and refresh quarterly. CC0 means no attribution obligation (do it anyway in an About screen), no share-alike, no field restrictions, and no vendor relationship. Use Branded Foods for barcode lookups, FNDDS/SR Legacy/Foundation for ingredient-level nutrition. This is the only nutrition database in this inventory whose license cannot be argued about.

**Ingredient recognition (training): Nutrition5k as the core supervised set, FoodSeg103 for the segmentation head, Open Images food classes for scene-context pretraining.** Nutrition5k (CC BY 4.0) is the only commercially-usable dataset linking real photos to per-ingredient masses and USDA-linked nutrient vectors — exactly the supervision the app's ingredient→nutrition path needs. FoodSeg103 (Apache 2.0) adds pixel-level ingredient masks for a segmentation head, with the documented Recipe1M-provenance caveat (§7.1) put to counsel. Open Images (annotations CC BY 4.0) helps the model handle cluttered multi-object plates before fine-tuning on Nutrition5k.

**Barcode layer (optional, non-US markets): Open Food Facts via the fetch pattern (§9.3), not bundled.** ODbL is workable commercially, but the share-alike analysis and the label-quality variance (§2.4) argue for treating OFF as a *live lookup complement* rather than the offline backbone. USDA Branded Foods (1.99M products, CC0) covers most barcode volume for a US-focused launch without any ODbL obligations.

**Ship model weights, not dataset images.** For Food-101-derived pretraining, the license hole (§4.5) is the risk; weights are a materially different exposure than redistributing photographs, but "materially different" is not "clear" — see §9.4.

### 9.2 What is disqualified, and why

- **UECFood-256, UECFoodPix, FoodCam-100** — verbatim "can be used only for non-commercial research purpose" \[16\]\[18\]. Paid app = outside the grant. Contact the authors if Japanese-dish coverage becomes priority-one.
- **Recipe1M / Recipe1M+** — "Access to the dataset is granted only for research purposes to universities and research institutions" \[20\]. A company is not a "research institution" for this purpose; there is no commercial license to buy as-is.
- **RecipeDB** — CC BY-NC-SA 3.0 \[26\]: NonCommercial (bars paid use) and ShareAlike (bars closed derivative stores) simultaneously.
- **UNIMIB2016** — no license statement exists \[25\]; do not integrate without written permission.
- **Food-101** — no license stated anywhere official \[11\]\[13\]; usable as inspiration/pretraining at counsel's discretion, not as a cleared asset (§9.4).

### 9.3 ODbL integration patterns (which trigger share-alike, which avoid it)

Let "publicly use" mean distributing the app or exposing the data beyond your organization (ODbL 4.5c/4.6). Three patterns:

1. **Per-scan API fetch (safest).** App scans barcode → server queries OFF API → result shown in-app, product cached locally. Under ODbL 4.5b this is a **Produced Work**: "Using this Database... to create a Produced Work does not create a Derivative Database for purposes of Section 4.4." No share-alike. Obligation: the §4.3 attribution notice on the screen where users see OFF data, e.g. "Contains information from Open Food Facts, which is made available here under the Open Database License (ODbL)." Respect OFF's fair-use framing for the API ("1 API call = 1 real scan by a user" \[5\]) — bulk pre-caching products users haven't scanned would contradict its spirit and its API terms.
2. **Bundled *unmodified* export.** Shipping the official dump verbatim inside the app is conveying the Database itself: carry the ODbL license text and attribution; **no share-alike** (you're not altering it). But a raw 0.9 GB+ CSV inside an app bundle is impractical, and re-serving it inside a paid product is off-brand for the community even where permitted.
3. **Bundled *derived* store (most practical, most constrained).** Filtering/subsetting/reformatting "the whole or a Substantial Part of the Contents into a new database" creates a **Derivative Database** (4.4b). Shipping it in the app = publicly using it → 4.4a requires publishing that derived database under ODbL-compatible terms, and 4.6 requires offering "a copy in a machine readable form" of the derivative or "a file containing all of the alterations made... or the method of making the alterations." Your **app code** never becomes ODbL; the **derived data** becomes public. If the team builds real value into a cleaned/normalized OFF store (dedup, language normalization, category pruning), pattern 3 *gives that value away* to competitors. Decide with eyes open, or use pattern 1 + USDA CC0 offline.

### 9.4 Trade-offs, named

- **USDA-only nutrition** (vs adding OFF): *gives up* non-US packaged-product coverage and crowd-maintained freshness (USDA Branded updates lag store shelves; SR Legacy is frozen at 2018). *Buys* zero license risk. Reverses if the launch market is non-US and barcode coverage metrics slip.
- **Nutrition5k as core recognition supervision** (vs Recipe1M+/UEC): *gives up* an order of magnitude of image diversity and any East-Asian dish coverage (5k plates, one cafeteria system, "mostly western style dishes" \[9\]). *Buys* per-ingredient mass ground truth and a clean license. Mitigate with FoodSeg103 + Open Images pretraining; the license-clean path is smaller-data, so budget for a first-party collection program (photograph dishes with staff consent + own kitchen measurements) — which no public dataset can replace for accuracy anyway (§10).
- **Food-101 pretraining at all:** *gives up* license clarity for a modest quality boost on 101 dish categories. Reverses if counsel clears it or if pretraining on Open Images + internal data proves adequate (likely within 1–2 points on a Nutrition5k-tuned head, untested — §11).
- **Bundling a derived OFF store** (pattern 3): *gives up* the exclusivity of any curated offline food database you build (it must be republished). *Buys* true offline barcode lookup. Only take it if offline-barcode is a launch requirement; otherwise per-scan fetch + USDA offline wins.

---

## 10. Remaining accuracy gaps

What the recommended combination still cannot do well — each tied to the evidence found:

**10.1 Portion-size estimation from a phone camera.** Nutrition5k's own numbers: direct 2D calorie prediction **26.1% MAE**; the **16.5%** result requires the rig's depth/volume inputs a consumer phone lacks (LiDAR iPhones change this partially — untested here); mass MAE \~27.7% in 2D \[9\]. Independent human evidence brackets the difficulty: laypeople are off by \~53% and nutritionists by \~41% from photos, and "The calorie content of energy-dense foods was overestimated (P=.02)" \[32\]. So: ingredient *identification* can be good; calorie *numbers* will inherit a ±25% structural error in 2D mode, best case, on Nutrition5k-like cafeteria foods. No recommended dataset fixes this; depth or reference-object prompting (a FooDD-style known-size cue in UX, §7.2) is the mitigation.

**10.2 Per-preparation nutrient variance.** Every USDA-linked source (FDC itself, Nutrition5k's ground truth, RecipeDB, Recipe1M+'s nutrition fields) ultimately reports *reference* values for *standard* preparations — not the actual plate. USDA's own provenance statements make this explicit: SR Legacy mixes "analyses, imputations, and the published literature" \[2\]; FNDDS values describe survey foods \[2\]. Same dish, different cook: unmodeled variance. The app should present values as reference estimates, not measurements.

**10.3 Packaged-food label errors.** Branded Foods is "received from food industry data providers" \[2\] — transcription of labels, with no USDA lab audit. OFF's crowd transcriptions show material incoherence: 5.5% of complete labels failing energy/macro consistency in the (caveated, §2.4) 2026 audit, worst 20.8% in protein bars, \~1 in 3 products lacking complete labels \[31\]\[38\]. A barcode-scan feature cannot be more accurate than the label data underneath it; consider cross-checking scanned values against OFF *and* USDA Branded when both have the GTIN, and displaying derivation-code provenance where available.

**10.4 Regional-cuisine coverage.** Nutrition5k: "the limited geographic nature of the collection inherently skews the food seen to mostly western style dishes" \[9\]. The main East-Asian alternatives (UEC-256, VireoFood-172) are non-commercial or unverifiable (§5, §7.6); UNIMIB2016 is Italian-canteen and unlicensed. RecipeDB's global coverage is NC-licensed. The recommended stack is Western-biased at every layer — a real product gap for any non-Western launch, fillable only by first-party collection or licensing negotiations.

**10.5 Multi-dish plate recognition.** Real meals are trays with three dishes. Food-101/UEC-256 are single-dish by construction (UEC ships a `multiple_food.txt` flag because its own data confounds this); FoodSeg103's best models reach \~45 mIoU \[22\] — half of ingredient pixels wrong at class level; UEC-256's 2014-era system managed 50.1% top-1 on single dishes \[17\]. Nothing in the recommended stack is *trained* for multi-dish composition; Open Images helps with scene context, but plate-level multi-dish decomposition is an open gap to be solved in-house.

**10.6 Crowd-derived dish labels.** The Food-101 family's training labels are noisy by design ("wrong labels... mostly in the form of intense colors and sometimes wrong labels" \[11\]) and third-party audits report "thousands of label issues, outliers, ambiguous examples, and (near) duplicates" \[15\]. Any model pretrained on such data inherits those priors; the recommended Nutrition5k fine-tune mitigates but does not eliminate it.

**10.7 The structural hole.** No public, commercially-usable dataset combines dish images + recipes + per-ingredient mass + measured nutrients at scale. Recipe1M+ has the first three but is research-only (§6); Nutrition5k has all four but 5k plates (§3); OFF has barcodes but no cooking context. The recommended combination is a deliberately narrowed bet: ingredient-level accuracy on Western cafeteria-style dishes, reference-grade (not measured) nutrition, and barcode lookup — everything beyond that is first-party data work.

---

## 11. Unverified claims

Mirroring the practice of the contamination-survey artifact in this project: anything below could not be confirmed from a primary source during this session's research and should not be cited as fact without checking.

 1. **UEC-256 total image count.** Official page and paper publish no total ("more than 100" per category \[16\]\[17\]). The widely-copied figure of 16,557 images and a Kaggle mirror's \~31,000 files conflict. Unresolved.
 2. **Recipe1M+ human-trial percentages.** The TPAMI paper's Table 5 compares the model to AMT workers ("on average our method with semantic regularization performs better than average AMT worker" \[19\]); the surrounding table's per-condition human percentages (e.g., 81.6±8.9) could not be unambiguously extracted from the PDF text layer. Use only the qualitative statement.
 3. **Food-101 licensing.** Confirmed: no license statement on the official page; HF card says "unknown." Unverified: whether ETH would grant a license on request, and the chain of rights in the underlying FoodSpotting photos. "Many people train on it" is not evidence of clearance.
 4. **FoodSeg103 upstream provenance.** The Hugging Face card states images are "a curated sample from Recipe1M" \[24\] (secondary source); the paper's exact provenance sentence was not directly quoted this session. The legal question — whether Apache 2.0 on the FoodSeg103 repo clears photographs originating from the research-only Recipe1M — is unresolved and needs counsel.
 5. **Nutrition5k license file.** "CC BY 4.0" is stated in the README \[8\] (and links the correct deed), but the repo ships no standalone LICENSE file; whether Google attaches any additional terms at download was not verified.
 6. **Cleanlab/Food-101N audit target.** The cleanlab blog's description ("This dataset contains 101k images" \[15\]) appears to conflate Food-101 (101,000 images) with Food-101N (310,009 images). The "thousands of label issues" finding is qualitatively useful but its exact object is muddled.
 7. **FooDD collection protocol and accuracy.** Verified: 3,000 images, CC BY 4.0 metadata, IEEE DataPort subscription-gated access \[28\]\[29\]. Unverified: the exact collection method (crowdsourcing mechanics), per-image annotations, and any published accuracy number (none quoted above for this reason).
 8. **UNIMIB2016 recognition accuracy.** The 2017 IEEE JBHI paper reports results, but no metric was extracted from a primary source this session. The 1,027 images / 73 categories counts are verified \[25\].
 9. **RecipeDB ingredient count.** 20,262 ingredients comes from a third-party aggregator \[36\]; the OUP paper snippet was truncated ("blending over 20 \[thousand?\]"). The 118,171 recipes / 26 regions / 74 countries counts are from the paper snippet \[27\].
10. **Open Images food coverage.** Food classes exist among the 600 boxable classes, but no official food-subset size was compiled this session; any "food subset" number would be a derived, unverifiable-until-recomputed figure.
11. **Open Food Facts product count** (4,805,482 \[6\]) is a live, continuously-changing homepage figure (October 10, 2026) — do not treat as a dataset constant.
12. **Foundation Foods count discrepancy.** `food.csv` shows 469 Foundation entries; `foundation_food.csv` has 395 rows \[4\]. Both from the same official release; the definitional difference (e.g., sub-samples or aggregation rows) was not resolved.
13. **Third-party audit of USDA Branded Foods.** No independent accuracy audit of FDC Branded data was located this session; the absence of evidence is not evidence of accuracy.
14. **Lean/OFF audit status** \[31\]\[38\]: confirmed non-peer-reviewed (figshare preprint), company-authored (Lean), France-only, coherence-based. Any reuse should carry those caveats; its figures should not be quoted as OFF's error rate.
15. **Nutrients 2023 validation study** \[33\]: cited qualitatively (validation of crowdsourced food-image annotation for nutrition-environment assessment) from search metadata only; its specific numbers were not extracted.
16. **VireoFood-172's identity and terms.** The Fudan FVL page (404 on fetch) and CityU host (unreachable) left the paper identity, size (172 classes is from secondary context \[37\]), and any license unverifiable. Dropped accordingly.
17. **DeepFood** characterization (system paper, not a dataset) is from general knowledge, not re-verified this session.
18. **iPhone-LiDAR portion estimation** (§10.1's parenthetical) is a reasoned expectation, not a measured result.

---

## 12. References

 1. USDA FoodData Central — API Guide (licensing, citation, API key, rate limits): https://fdc.nal.usda.gov/api-guide/
 2. USDA FoodData Central — FAQ (data-type descriptions and provenance): https://fdc.nal.usda.gov/faq/
 3. USDA FoodData Central — Downloadable Data (releases): https://fdc.nal.usda.gov/download-datasets/
 4. USDA FDC full CSV release, 2026-04-30 (counts counted this session): https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_csv_2026-04-30.zip
 5. Open Food Facts — official data page (licenses, exports, API fair use): https://world.openfoodfacts.org/data
 6. Open Food Facts — homepage (live product count, 2026-10-10): https://world.openfoodfacts.org/
 7. Open Data Commons — Open Database License (ODbL) v1.0 full text: https://opendatacommons.org/licenses/odbl/1-0/
 8. Nutrition5k — official GitHub repository (README: contents, license statement): https://github.com/google-research-datasets/Nutrition5k
 9. Nutrition5k paper, CVPR 2021 (Table 1, Table 3, Table 4, provenance, human study): https://openaccess.thecvf.com/content/CVPR2021/papers/Tham_Both_Eyes_Open_Nutrition5k_Towards_Understanding_Dietary_Habits_Using_Computer_CVPR_2021_paper.pdf — project page: https://nutrition5k.github.io/
10. Nutrition5k GitHub issue #11 (3,493-kcal outlier dish): https://github.com/google-research-datasets/Nutrition5k/issues/11
11. Food-101 — official ETH Zurich page (counts, noise warning): https://data.vision.ee.ethz.ch/cvl/datasets_extra/food-101/
12. Food-101 paper (Bossard, Guillaumin, Van Gool, ECCV 2014): https://data.vision.ee.ethz.ch/cvl/datasets_extra/food-101/static/bossard_eccv14_food-101.pdf
13. ethz/food101 — Hugging Face dataset card ("license: unknown"): https://huggingface.co/datasets/ethz/food101
14. Food-101N project page (CleanNet, CVPR 2018; 310,009 images): https://kuanghuei.github.io/Food-101N/
15. Cleanlab — Food-101/101N label-issues audit blog: https://cleanlab.ai/blog/learn/csa/csa-5/
16. UEC FOOD-256 — official dataset page (terms, contents): http://foodcam.mobi/dataset256.html
17. FoodCam-256 system paper (Kawano & Yanai, 2014; top-1/top-5, construction): https://mm.cs.uec.ac.jp/pub/conf14/141106kawano_0.pdf
18. UECFoodPix — official page (9,000/1,000 images, 103 classes, non-commercial terms): https://mm.cs.uec.ac.jp/uecfoodpix/
19. Recipe1M+ paper (Marin et al., TPAMI 2019; arXiv:1810.06553 — counts, Table I/III/V/VI, provenance): https://arxiv.org/abs/1810.06553
20. im2recipe-Pytorch — official access README (research-only grant; USDA nutrition subset counts): https://github.com/torralba-lab/im2recipe-Pytorch
21. Recipe1M+ official project site: https://im2recipe.csail.mit.edu/
22. FoodSeg103 — official repository (7,118 images, 104 classes, Apache 2.0, model zoo): https://github.com/LARC-CMU-SMU/FoodSeg103-Benchmark-v1
23. FoodSeg103 paper (Wu et al., 2021; arXiv:2105.05409 — 9,490 images, 154 classes): https://arxiv.org/abs/2105.05409
24. EduardoPacheco/FoodSeg103 — Hugging Face card (Recipe1M provenance statement): https://huggingface.co/datasets/EduardoPacheco/FoodSeg103
25. UNIMIB2016 — official lab page (1,027 trays, 73 categories): http://www.ivl.disco.unimib.it/activities/food-recognition/
26. RecipeDB — official FAQ (license Q20/Q22, USDA mapping Q10/Q11, sources Q17): https://cosylab.iiitd.edu.in/recipedb/FAQ
27. RecipeDB paper (Batra et al., Database 2020; 118,171 recipes): https://academic.oup.com/database/article/6006228
28. FooDD — IEEE DataPort page (CC BY 4.0 metadata, subscription gate, thumb reference): https://ieee-dataport.org/open-access/foodd-food-detection-dataset-calorie-measurement-using-food-images
29. FooDD paper (Pouladzadeh, Yassine, Shirmohammadi, ICIAP 2015 Workshops — 3,000 images): https://link.springer.com/chapter/10.1007/978-3-319-23222-5_54
30. Open Images V7 — official facts page (\~9M images, license statements): https://storage.googleapis.com/openimages/web/factsfigures_v7.html
31. Lean/OFF label-coherence audit (2026, figshare preprint): https://figshare.com/articles/preprint/\_/27573357 ; walkthrough: https://lean-app.com/en/etude-base-donnees-calories/ ; dev.to summary: https://dev.to/leanapp/openfoodfacts-1-in-3-products-unusable-here-are-the-study-numbers-1lc4
32. Zhou et al., "Calorie Estimation From Pictures of Food: Crowdsourcing Study," Interact J Med Res 2018;7(2):e17: https://www.i-jmr.org/2018/2/e17
33. "Using Crowdsourced Food Image Data for Assessing Restaurant Nutrition Environment: A Validation Study," Nutrients 2023, 15(19):4287: https://www.mdpi.com/2072-6643/15/19/4287
34. Kaggle mirror of UEC-Food256 (file-count context only): https://www.kaggle.com/datasets/rkuo2000/uecfood256
35. Secondary UEC-256 image-count claims (context only, conflicting): https://shakex.github.io/lmsi-uec-food/
36. RecipeDB ingredient count (secondary aggregator): https://bioinformaticshome.com/db/tool/recipedb/
37. VireoFood-172 — Fudan FVL dataset page (404 at fetch, 2026-10-10): https://fvl.fudan.edu.cn/dataset/vireofood172/list.htm
38. Lean study summary page: https://lean-app.com/en/etude-base-donnees-calories/