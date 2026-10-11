# Corpus ingestion report

Branch `fleet/fl-recipe-corpus-v2`. Contract: `data/recipes/SCHEMA.md`
(fixed; not edited by this task). Rights verdicts: `data/recipes/RIGHTS-AUDIT.md`
and source terms in `data/recipes/SOURCES.md` (branch `obv/fl-next-recipe-fidelity`,
fetched read-only, never merged). Build date of every `access_date` below:
2026-10-11. All numbers in this report are measured this session; the tooling
that produced them lives in `data/recipes/tools/`.

This report now covers the **final combined corpus**: the Part 1b work
(sections 1–5: seeds, NHS, NHLBI, MyPlate, the BBC cache recommendation)
plus this task's ingestion of the 401 originals (section 6), the
substitution-table join (section 7), and the suite C criteria status with
the honest resolution shortfall (section 8).

## Totals (final combined corpus)

| Measure | Value |
|---|---|
| Recipes in `corpus.jsonl` | 428 (25 audited seed keepers + 2 NHS + 401 original) |
| Rights records in `rights_manifest.json` | 428 (every `source_ref` resolves; 428/428 clear) |
|   — originals split | 260 `original` + 141 `original-rewrite` (per `provenance.rewrite_of`) |
| Ingredient lines | 2771 resolved / 2988 (92.74%) — see section 8 |
| Quantity kinds | 2355 `household`, 416 `source_grams`, 217 `unknown`, 0 `weighed` |
| Allergen/diet claims | 1050 (69 seed + 4 NHS + 977 original), all matching the suite AllergenScanner recomputation (0 unchecked, 0 stripped) |
| Food-safety lint | 428/428 pass (0 violations) |
| Cuisines | american 116, asian 63, indian 53, italian 68, mediterranean 69, mexican 59 (6/6) |
| Meal slots | breakfast 54, lunch 169, dinner 279 |
| Time bands | 0-15: 51, 16-30: 161, 31-45: 129, 46-60: 46, 61+: 41 |
| Bands represented | 14/14 (all six cuisines, three slots, five time bands) |
| Cross-product cells filled | 78/90 (informational) |
| Dedupe (all 428) | 0 duplicate ids, 0 duplicate normalized titles, 0 (title, core-ingredient) collisions — re-run at ingestion |

Validation loop (exact command in the PR Verification section): `rs.py` lint
green over the full combined corpus, `rights.py` completeness green (no
quarantined recipe in `corpus.jsonl`), `bands.py` counts above.

## Suite C criteria status (final corpus)

| Suite C bar | Threshold | Measured | Verdict |
|---|---|---|---|
| Rights-clear recipes | >= 400 (target 1500) | 428/428 clear, 0 quarantined | **PASS** |
| Food-safety linter | 100% pass | 428/428 pass | **PASS** |
| Unchecked allergen/diet claims | 0 | 0 unchecked, 0 stripped | **PASS** |
| Declared bands covered | every band >= 1 recipe | 14/14 bands | **PASS** |
| Lines resolved with quantity evidence | >= 95% | 2771/2988 = 92.74% | **FAIL — see section 8** |

One bar fails. The shortfall arithmetic, its exact size, and the fix path
are in section 8; per the operator ruling, the gap closes corpus-side on
this branch via cited conversion evidence in `data/recipes/`.

## 1. Bundled seed conversion — 25 recipes ingested

**Source:** the 25 rows the rights audit marked *keep* in the bundled catalog
(`apps/ios/Resources/data.json`, branch `alpha`, 166 positional-array rows).
The audit's keep verdicts rest on in-house authorship traced through git
history.

**Conversion:** `data/recipes/tools/convert_bundled.py` maps each keep row to
RS v1: title, cuisine, meal slots (from tags), minutes, servings, steps from
the row's instructions (timers use the upper bound of stated ranges), and
ingredient grams from the bundled USDA ingredient catalog as `kind=source_grams`
with provenance citing `data.json` and the audit entry. Food-safety checks
follow SCHEMA.md §3 with cited FSIS sources; egg-protein recipes carry 160 °F
thermometer checks. Claims (69) were decided only where the suite scanner
recomputed evidence agrees; recipe 12 (peanut butter) has no `nut-free` claim —
its own content refutes it.

**Rights records:** per recipe, `source_id` `frideluck_original`,
`source_type` `original`, `license` `LicenseRef-FL-Original`,
`license_evidence` the dish's keep verdict in `data/recipes/RIGHTS-AUDIT.md`
(in-house authorship per the audit), permissions all true except `images`
(no image ships).

**Result:** ids `fl-seed-0001`–`fl-seed-0025` (SCHEMA §7 id scheme; the id
tag `seed` abbreviates the SOURCES.md key `frideluck_original`). 153 lines,
all resolved. Dedupe: one informational ingredient-set twin (an
omelette/scramble pair with different titles), no merges.

## 2. NHS website recipes — 2 recipes ingested of 196 parsed

**Source:** NHS Healthier Families recipe pages (robots.txt: path not
disallowed; fetched 2026-10-11, 0.5 s delay, 202 index-linked pages, 196 with
parseable Recipe JSON-LD, 6 unparseable).

**Rights:** OGL v3.0 — public bodies' content, reuse permitted with
attribution and an adapted-content statement, NHS photographs excluded.
Per-recipe records: `source_id` `nhs_website`, `source_type` `government`,
`license` `OGL-3.0`, `license_evidence` the OGL terms URL quoted in
SOURCES.md, `images` false, all app-required permissions true. Provenance
carries the source URL and the adaptation note.

**Quantity evidence:** 1,888 parsed lines. 478 stated grams (`source_grams`).
104 stated millilitres — the suite conversion table has **no** `ml` refs, ml
is never g, and inventing densities would fabricate mass, so ml lines stay
`unknown`. 458 spoon-style lines resolve only when the food has a tbsp/tsp
ref in the suite table. 848 "other" lines (cups of vegetables, packs, tins)
mostly have no suite ref. Recipes are ingested only at >=95% resolved lines;
**2 of 196** clear that bar (ids `fl-nhs-0001`, `fl-nhs-0002`). The rest
remain un-ingested and are not quarantined rights-wise — they are unresolved
quantity-evidence-wise; nothing was weakened to raise the yield.

**Claims:** 4 written on the 2 recipes; `raspberries` and `summer berries`
are unaliased names (recorded, and claims that could rely on them are
suppressed). One defect found and fixed pre-commit: the leftover heuristic
previously fabricated a reheat step for a cold yogurt-berry dish; reheating
is now detected only from explicit source instructions.

## 3. NHLBI Healthy Eating Recipes — 0 recipes ingested of 54 parsed

**Source:** NHLBI Healthy Eating Recipes index (the former recipes URL 301-
redirects there; fetched 2026-10-11, 54 unique recipe pages, none suspiciously
small).

**Rights — per-recipe contributor check (SOURCES.md §3):** the site notice
("The information on this site is in the public domain and may be used or
reproduced without permission") covers federal works (17 U.S.C. § 105); the
NHLBI leaflet (15-5227.pdf) states "These recipes were specially developed by
the National Heart, Lung, and Blood Institute (NHLBI)". Each page's `Recipe
Source:` credit was parsed and classified:

- **47 pages credit NHLBI's own cookbooks** (*Deliciously Healthy Dinners*,
  *Deliciously Healthy Family Meals*, *Delicious Heart Healthy Latino
  Recipes*, *Heart Healthy Home Cooking African American Style*, *Stay Young
  at Heart*) — ingest-eligible.
- **7 pages credit external community manuals** — *Honoring the Gift of Heart
  Health* (alaska-salmon-salad, chicken-chile-stew, pinto-beans,
  zucchini-medley), *Healthy Heart, Healthy Family* Filipino manual
  (fresh-lumpia-lumpiang-sariwa, marinated-chicken-adobong-manok), *Your
  Health Is Golden!* Vietnamese booklet (vietnamese-fresh-spring-rolls-goi).
  SOURCES.md names exactly this family as the external-credit trap: **these
  7 quarantine** and never enter the corpus. Any credit that is not
  recognizably an NHLBI cookbook also fails closed.

**Quantity evidence — why 0 of 47 eligible recipes ingested:** NHLBI states
most vegetable quantities in cups ("1 C onion, chopped", "2 C leeks", "1½ C
green bell pepper"), and the suite conversion table has piece refs (medium
onion, bell pepper, carrot) but **no cup refs for those foods**, so those
lines cannot resolve under SCHEMA §2 without inventing a mass. The single
best recipe reaches 89% resolved lines (braised cod with leeks: 8 of 9 lines;
the leek line is the miss); none reach 95%. Stated ounces and pounds convert
at exactly 28.3495 g/oz and 453.592 g/lb into `source_grams` with the stated
values and factors in provenance; pack weights ("1 can (14½ oz)…") carry the
net weight; stated clove counts use the `garlic_clove` ref. The tooling
(`data/recipes/tools/ingest_nhlbi.py`, measure mode) records every per-page
decision: credit, resolution fraction, and the blocking lines. Nothing was
written to the corpus from this source; no rights records were created for it
(no recipe -> no record -> nothing incomplete in the manifest).

## 4. USDA MyPlate Kitchen — 0 recipes ingested; source unreachable

**Source:** `https://www.myplate.gov/recipes` returned `000` (connection
failure) from the sandbox on repeated attempts on 2026-10-11; the recipe
index could not be retrieved, so no per-recipe contributor facts exist.

**Disposition:** SOURCES.md §4 makes MyPlate conditional on a per-recipe
contributor record (`source_id` `myplate_kitchen_<recipe>`, origin = the
recipe's recorded contributor, USDA-authored only). With no pages retrieved
there are no records to complete — the source quarantines whole (fail-closed)
and contributes 0 recipes. Retry instructions for a future run are in the PR
Handoff.

## 5. BBC Good Food scraper cache — recommendation for the PR #43 branch

**Finding (read-only; this task may not edit `scripts/`):**
`scripts/recipe_scraper/.cache/bbc_goodfood_recipes.json` on
`obv/fl-next-recipe-fidelity` (and identically on this branch) is **152 BBC
Good Food recipes, 608,281 bytes of full text**; the sibling
`bbc_goodfood_recipes.test.json` is a **3-recipe excerpt of the same BBC
content** (9,086 bytes). The rights audit found no commercial-redistribution
permission for BBC content, marked the 141 bundled BBC-derived recipes
*rewrite*, and assigns this corpus task the cache decision.

**Recommendation: replace both files with synthetic fixtures of the same JSON
shape; do not simply delete.** `git grep` shows three scripts read the cache
paths: `scripts/recipe_scraper/README.md`, `generate_rights_audit.py` (the
tool that produced RIGHTS-AUDIT.md) and `scrape_recipes.py` — deletion would
break the audit tooling's offline runs, and the audit's verdicts are
load-bearing for Parts 1a/5. A synthetic replacement keeps those runs
working: same list-of-objects shape (`ingredients[].{name, amount_unit,
amount_value, prep_actions, raw, scaled_raw}`, steps, title), clearly
fictional dish names, and a top-level `_fixture` marker stating it is not
scraped content. The `.test.json` file needs the same treatment — it is BBC
text too, not a synthetic fixture. The replaced files should land on the PR
#43 branch (which owns `scripts/recipe_scraper/`); until then the unlicensed
full text continues to sit in the repo and should not ship in any release
artifact.

## 6. Originals ingestion — 401 recipes ingested (this task)

**Source:** `data/recipes/originals/` on branch `overhaul/original-recipes`
at `607ef99` (task `fl-original-recipes-f1`): `originals.jsonl` (401 recipes,
`fl-original-0001`…`fl-original-0404`), `rights_manifest.json` (401 records),
`COVERAGE.md`. Fetched read-only; the branch was **never merged** — the files
were extracted from git and consumed, and the originals directory itself does
not exist on this branch (source tasks never write corpus files; ingestion
never rewrites source files, SCHEMA §"Who writes what").

**Re-verification before ingest (nothing taken on faith):** the originals
manifest validates 401/401 clear with the suite's `rights.py`; every recipe
was re-linted against **this** suite checkout (`eval/scorecard-runner` at
`26c7004`) with its own `conversions.json` and `allergens.json`: 0 violations,
0 unchecked, 0 stripped claims — reproducing the parent-verified numbers
exactly. Dedupe re-run across the combined 428: ids unique, 0 duplicate
normalized titles, 0 (title, core-ingredient) collisions (within originals,
against the 27, and within the batch). **401/401 accepted; 0 stopped.**

**One hygiene action:** 300 of the 401 source recipes carried a `_classes`
top-level field — computed scanner state the originals task's validation
injected and persisted. It is linter residue, not recipe content; ingestion
strips it (the same rule validate_corpus.py follows: scanner classes are
injected on a deep copy, never persisted). No other field was touched — no
title, ingredient, step, quantity, or claim was edited, added, or removed.

**Rights records:** 401 new records in `data/recipes/rights_manifest.json`
(428 total), one per recipe keyed by its id: `source_id` = the recipe id,
`source_type` `original` (260) or `original-rewrite` (141) per the recipe's
`provenance.rewrite_of` (the 141 rewrites cite the bundled recipe id in
`apps/ios/Resources/data.json`), `license` `LicenseRef-FL-Original`,
`license_evidence` pointing at the record in
`data/recipes/originals/rights_manifest.json` on `overhaul/original-recipes`
at `607ef99` plus this task's re-verification, permissions all true except
`images` (no image ships). All 428 validate clear with `rights.py`.

## 7. Substitution join — 279-pair table applied over the combined corpus

**Source:** `data/substitutions/pairs.json` on branch
`overhaul/substitution-table` at `0dc3bdf` (schema version 1.0.0: 279 pairs,
381 registered ingredients, 1122 alias names). Fetched read-only; the branch
was never edited and never merged.

**Application rules (the table's own, not this task's):** the join
(`data/recipes/tools/apply_substitutions.py`) mirrors the FLSubstitutions
package exactly. Ingredient lines resolve through the table's alias map
(`SubstitutionTable.resolveIngredientKey`: lowercased/trimmed exact match on
key, display name, or alias). `ContextRules.verdict` is evaluated for each
pair's primary role and every `supported_also` role. **Accepted =
`verified` only** — sourced function evidence AND sourced ratio evidence
(PR #49 semantics; the same bar the table's own coverage report counts).
The table's precedence rules govern and nothing is forced: a conflicting
ratio is plausible-at-best and never lands (the shipped
egg→mashed-banana conflict verifies only for its `liquid` supported role,
never for its `binder` primary role); `unknown` stays unknown;
`unsupported` is never offered; lines whose names do not resolve in the
table get nothing.

**Result (measured):** 2087 verified (line, pair) annotations landed on
**405 of 428** recipes, from **79 of 279 pairs**. Candidate verdicts
evaluated over resolving lines: 2296 verified, 3631 plausible, 299 unknown,
248 unsupported — the weaker verdicts are counted here and **not applied**.
Per-role landings: acid 152, aromatic 435, binder 99, fat 447, garnish 167,
leavening 8, liquid 493, protein 199, sweetener 68, thickener 34,
umami 193. Per source: seed 198, NHS 2, original 1887 annotations.

**Shape:** each annotated recipe carries a lean `substitutions` list —
`{"ingredient", "pair_id", "substitute", "roles"}` — a join key back into
`pairs.json`, which stays the single source of pair text, ratios, macro
deltas, and evidence. No recipe title, ingredient, step, quantity, or claim
was modified. Recipes with no accepted swap carry no field. The full
per-recipe mapping is that annotation (machine-readable); the per-pair
counts follow. Re-running the join is byte-identical (idempotent), and the
corpus validates green with the annotations in place.

| pair_id | substitute | verified roles | recipes | annotations |
|---|---|---|---|---|
| almonds-garnish-to-other-nuts | walnuts | garnish | 2 | 2 |
| almonds-garnish-to-toasted-oats-seeds | toasted_oats_seeds | garnish | 2 | 2 |
| anchovy-umami-to-anchovy-paste | anchovy_paste | umami | 1 | 1 |
| ap-flour-thickener-to-arrowroot | arrowroot | thickener | 4 | 4 |
| ap-flour-thickener-to-cornstarch | cornstarch | thickener | 4 | 4 |
| ap-flour-thickener-to-potato-starch | potato_starch | thickener | 4 | 4 |
| ap-flour-thickener-to-tapioca | tapioca | thickener | 4 | 4 |
| baking-powder-leavening-to-soda-cream-of-tartar | baking_soda_cream_of_tartar | leavening | 4 | 4 |
| baking-powder-leavening-to-soda-soured-milk | baking_soda_soured_milk | leavening | 4 | 4 |
| breadcrumbs-binder-to-cornmeal | cornmeal | binder | 8 | 8 |
| brown-sugar-sweetener-to-granulated-sugar | granulated_sugar | sweetener | 12 | 12 |
| butter-fat-to-applesauce | applesauce | fat | 50 | 50 |
| butter-fat-to-bacon-fat | bacon_fat | fat | 50 | 50 |
| butter-fat-to-chicken-fat | chicken_fat | fat | 50 | 50 |
| butter-fat-to-margarine | margarine | fat | 50 | 50 |
| butter-fat-to-olive-oil | olive_oil | fat | 50 | 50 |
| butter-fat-to-shortening | shortening | fat | 50 | 50 |
| buttermilk-acid-to-milk-vinegar | milk_vinegar_mix | acid | 2 | 2 |
| buttermilk-liquid-to-plain-yogurt | plain_yogurt | liquid | 2 | 2 |
| buttermilk-liquid-to-whole-milk | whole_milk | liquid | 2 | 2 |
| cheddar-protein-to-sharp-cheddar | cheddar_sharp | protein | 31 | 31 |
| chicken-protein-to-firm-tofu | firm_tofu | protein | 54 | 54 |
| chickpeas-protein-to-white-beans | cannellini_beans | protein | 10 | 10 |
| cocoa_powder-fat-to-unsweetened-chocolate | unsweetened_baking_chocolate | fat | 2 | 2 |
| cornmeal-binder-to-panko | panko | binder | 8 | 8 |
| cornstarch-thickener-to-ap-flour | ap_flour | thickener | 9 | 9 |
| cornstarch-thickener-to-tapioca | tapioca | thickener | 9 | 9 |
| dried-herb-aromatic-to-fresh-herbs | fresh_oregano | aromatic | 24 | 24 |
| egg-binder-to-applesauce | applesauce | liquid | 64 | 64 |
| egg-binder-to-flax-gel | flax_gel | binder | 64 | 64 |
| egg-binder-to-mashed-banana | banana | liquid | 64 | 64 |
| egg-fat-to-egg-yolks | egg_yolk | fat | 64 | 64 |
| egg-protein-to-egg-whites | egg_white | protein | 64 | 64 |
| fish-sauce-liquid-to-vegan-fish-sauce | vegan_fish_sauce | liquid | 2 | 2 |
| fresh-basil-aromatic-to-dried-basil | dried_basil | aromatic | 15 | 15 |
| fresh-ginger-aromatic-to-ground-ginger | ground_ginger | aromatic | 33 | 33 |
| fresh-parsley-garnish-to-dried-parsley | dried_parsley | garnish | 8 | 8 |
| fresh-thyme-aromatic-to-dried-thyme | dried_thyme | aromatic | 7 | 7 |
| garlic-aromatic-to-garlic-powder | garlic_powder | aromatic | 154 | 154 |
| granulated-sugar-sweetener-to-brown-sugar | brown_sugar | sweetener | 5 | 5 |
| granulated-sugar-sweetener-to-corn-syrup | corn_syrup | sweetener | 5 | 5 |
| granulated-sugar-sweetener-to-honey | honey | liquid,sweetener | 5 | 5 |
| granulated-sugar-sweetener-to-molasses | molasses | sweetener | 5 | 5 |
| ground-beef-protein-to-textured-veg-protein | textured_veg_protein | protein | 16 | 16 |
| heavy-cream-fat-to-evaporated-milk | evaporated_milk | fat | 9 | 9 |
| heavy-cream-fat-to-half-and-half | half_and_half | fat | 9 | 9 |
| heavy-cream-fat-to-milk-butter | milk_butter_combo | fat | 9 | 9 |
| honey-sweetener-to-granulated-sugar | granulated_sugar | sweetener | 36 | 36 |
| ketchup-acid-to-tomato-sauce-vinegar | tomato_sauce_vinegar_mix | acid | 1 | 1 |
| lemon-acid-to-lime | lime | acid,garnish | 90 | 90 |
| lime-acid-to-lemon | lemon | acid,garnish | 53 | 53 |
| oats-binder-to-certified-gf-oats | gf_certified_oats | binder | 13 | 13 |
| onion-aromatic-to-dried-minced-onion | dried_minced_onion | aromatic | 101 | 101 |
| onion-aromatic-to-onion-powder | onion_powder | aromatic | 101 | 101 |
| peanut-butter-protein-to-almond-butter | almond_butter | protein | 11 | 11 |
| peanut-butter-protein-to-sunflower-butter | sunflower_seed_butter | protein | 11 | 11 |
| ricotta-protein-to-cottage-cheese | cottage_cheese | protein | 2 | 2 |
| sour-cream-acid-to-plain-yogurt | plain_yogurt | acid | 6 | 6 |
| sour-cream-fat-to-plain-yogurt | plain_yogurt | fat,garnish,liquid | 6 | 6 |
| sour-cream-fat-to-sour-milk-butter | milk_butter_combo | fat | 6 | 6 |
| sour-cream-garnish-to-greek-yogurt | greek_yogurt | garnish | 6 | 6 |
| soy-sauce-liquid-to-salt-water | salt_water | liquid | 48 | 48 |
| soy-sauce-umami-to-coconut-aminos | coconut_aminos | umami | 48 | 48 |
| soy-sauce-umami-to-maggi-seasoning | maggi_seasoning | umami | 48 | 48 |
| soy-sauce-umami-to-tamari | tamari | umami | 48 | 48 |
| spaghetti-binder-to-other-pasta | rigatoni | binder | 6 | 6 |
| vegetable-oil-fat-to-applesauce-baking | applesauce | fat | 42 | 42 |
| whole-milk-liquid-to-almond-milk | almond_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-buttermilk | buttermilk | liquid | 25 | 25 |
| whole-milk-liquid-to-dry-milk | dry_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-evaporated-milk | evaporated_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-half-and-half-water | half_and_half_water | liquid | 25 | 25 |
| whole-milk-liquid-to-oat-milk | oat_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-rice-milk | rice_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-skim-milk | skim_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-sour-cream | sour_cream | liquid | 25 | 25 |
| whole-milk-liquid-to-soy-milk | soy_milk | liquid | 25 | 25 |
| whole-milk-liquid-to-water-butter | water_butter_combo | liquid | 25 | 25 |
| whole-milk-liquid-to-yogurt | plain_yogurt | liquid | 25 | 25 |

## 8. Quantity-evidence resolution — the 95% bar fails, honestly

**Measured:** 2771 of 2988 ingredient lines resolved = **92.74%**
(27 from Part 1b: 159/159 = 100%; originals: 2612/2829 = 92.33%,
reproduced exactly at this suite checkout). Kind split: 2355 `household`
(each with a `conversion_ref` that resolves in the suite's
`conversions.json`), 416 `source_grams`, 217 `unknown`, 0 `weighed`.

**The 95% bar arithmetic:** 0.95 × 2988 = 2838.6, and 2838/2988 = 94.98%,
so **2839 resolved lines** is the smallest count that satisfies the bar;
the corpus has **2771** — the bar fails by **68 resolved lines**
(2.26 points, 2771/2988 = 92.74%).

**What the 217 unresolved lines are (corrected by direct measurement, see §9):**
all originals-side, all `qty.kind="unknown"` with `grams` null, across
**137 distinct ingredient names** (staples such as breadcrumbs 8, canned
tuna 7, burger buns 6, dijon mustard 5, beef chuck roast 5, canned chopped
tomatoes 5). This section originally characterized them — per the
originals task's verification — as mostly cup/tbsp/tsp-style household
measures lacking a suite-table ref. Direct measurement (2026-10-11, §9)
refuted that: the lines carry no value, unit, or grams at all, and no
amount is stated anywhere in their recipes' records. `rs.py` resolves a
household line only when its `conversion_ref` exists with a
`grams_per_unit` — and a household annotation additionally requires a
stated positive value and unit (SCHEMA §2), so a conversion-table entry
alone cannot resolve these lines: there is no amount to multiply.

**Why this task does not fix it:** the corpus is the release-candidate data;
the conversion table is suite C's input. Inventing conversions, relabeling
unknown lines, or massaging counts would fabricate mass evidence —
prohibited by SCHEMA §2 and by this task's brief. The operator ruling
(2026-10-11, see Limits and handoff) directs the fix corpus-side on this
branch — cited household-to-grams conversion rows in `data/recipes/` with
per-line `conversion_ref`/`grams` evidence. §9 records that the ruling's
precondition (stated amounts to convert) fails for all 217 lines as
shipped: the conversion-evidence pipeline is built and self-tested here,
while the missing inputs live upstream in the originals records.

## 9. Conversion-evidence pipeline — measured, the annotation precondition fails (2026-10-11)

The operator ruling directs the 68-line gap to close corpus-side: a cited
household-to-grams table in `data/recipes/` plus per-line evidence
(`conversion_ref`, `grams`) in the corpus records. This section records
what the records actually contain, the pipeline as built, and both
measurements. Added by the conversion-evidence task on
`fleet/fl-recipe-corpus-v2` (PR #113).

**The measured shape of the 217 unresolved lines (reproducible, no
corpus file modified):**

1. `data/recipes/tools/extract_unresolved.py` — the exact worklist from
   `corpus.jsonl`: 217 unresolved lines, 137 distinct (ingredient, unit)
   pairs, 144 recipes. Every pair's unit is EMPTY: none of the 217 lines
   carries `qty.value`, `qty.unit`, or a `grams` key, and no ingredient
   name embeds a digit.
2. `data/recipes/tools/scan_inrecord_amounts.py` — scans each unresolved
   line's own recipe for an amount stated in the record (step text). One
   digit-measure candidate exists and it is a mis-attribution:
   fl-original-0028 "Soak the breadcrumbs in 1/4 cup milk" — the 1/4 cup
   is the milk's measure, not the breadcrumbs'. All 56 word-measure
   mentions in the affected recipes ("a splash of", "a pinch of", "a cup
   of") measure water, salt, oil, or dressing — never the unresolved
   ingredient.
3. Net: **0 of the 217 lines has an amount stated anywhere in the
   record.** The recipes genuinely do not quantify these ingredients
   ("Dot each pancake with blueberries", "work in the onion, breadcrumbs,
   egg", "Serve on buns with pickles and mustard").

**Why the annotation precondition fails:** a cited conversion row converts
a STATED measure to grams (`grams = amount × row grams`). These lines
state no amount, so there is nothing to multiply; annotating them
`household` would require inventing both an amount and a unit — fabricated
recipe content, prohibited by SCHEMA §2, by the ruling's own honesty rules
(estimated mass is never marked `weighed`; never an invented mass), and by
this task's brief (lines without citable evidence stay unknown). A
conversion table cannot conjure a measure.

**The pipeline as built (ready and waiting for stated amounts):**

- **Read path** (validate_corpus.py, commit 9eeef97): when
  `data/recipes/conversions.json` exists, the validator integrity-checks
  every row (id, ingredient, unit, grams > 0, source {name, url, verbatim
  quote, retrieved YYYY-MM-DD}), reports corpus-side coverage, and lints
  under BOTH read paths — pass A: the suite's current semantics (fixture
  table only); pass B: the corpus table joined over the fixture table (the
  read contract the eval harness adopts via fl-eval-harness-f1 / PR #88).
  Self-tested on a scratch copy (clearly-marked fixture row + one
  annotated line): pass B resolves the line (2772/2988, 92.77%), pass A
  reports the exact R2 message as the anticipated hard-error (reported,
  not gated; the suite itself is never modified), malformed rows fail
  field-by-field. `--corpus`/`--conversions` overrides exist for such
  scratch self-tests only.
- **Row shape (for the first citable tranche):**
  `{"id": "conv-<slug>", "ingredient": ..., "unit": ..., "grams": <number>,
  "source": {"name", "url", "quote", "retrieved"}}` — `quote` must be the
  verbatim sentence carrying the mass on the fetched page; `retrieved` the
  actual access date. Authoritative public sources only (USDA FoodData
  Central, FDA RACC, government or university-extension nutrition
  publications; a recognized industry reference only when no government
  source exists). Every row must come from a page actually fetched in the
  authoring session; never an invented quote, URL, or date; never a row
  approximated from a different food; no row for a (staple, unit) pair no
  record uses.
- **Annotation rule (applied when amounts exist):** only lines whose
  (ingredient, unit) pair has a cited row, carrying a stated positive
  amount and unit: `qty.kind="household"`, `qty.value`/`qty.unit` as
  stated, `qty.conversion_ref` = the row id, `qty.grams` = amount × row
  grams rounded to the nearest whole gram. Nothing else on the line
  changes; `weighed` is never used.
- **Why no empty table shipped:** a zero-row `conversions.json` at the
  path the harness will read would imply a read path no line exercises
  and invite the wrong inference (coverage where none exists). The table
  ships with its first citable tranche; until then the suite's fixture
  table remains the read path for the 2355 existing household refs (the
  validator prints exactly this).

**Measurements (both run this session against the extracted suite):**

- **(a) Resolution under the suite's CURRENT semantics: 2771/2988 =
  92.74% — unchanged**, exactly as predicted: the harness does not read
  corpus evidence yet (PR #88 pending), and no line changed. Full run:
  rights 428/428 clear (0 quarantined), 428/428 recipes lint clean, 0
  unchecked claims, bands 14/14 — validation green under both passes.
- **(b) Corpus-side evidence coverage: 0/217 lines annotated; 0/137
  staples covered.** Uncovered staples = all 137 (each with no unit);
  the list prints reproducibly from the validator and
  `extract_unresolved.py`.

**The precise blocker and the path to closing the gap:** the 68-line
shortfall cannot close corpus-side on this branch because the defect is
absent quantities in the authored recipes, not absent conversions — no
honest data operation on `data/recipes/` can supply an amount the recipes
never state. The fix lives upstream: the originals task
(fl-original-recipes-f1, branch `overhaul/original-recipes`) must state
amounts for these ingredients in its records (or the recipes be
re-authored with them). Once a record carries a stated (amount, unit),
this pipeline applies exactly as documented above: one cited row per
(staple, unit) → lines annotated `household` with `conversion_ref` +
`grams` → validator green under pass B → the final suite C re-proof runs
when the harness reads conversion evidence from the corpus (the re-proof
gate, unchanged).

**Idempotent re-run instructions:**

    git fetch origin eval/scorecard-runner
    rm -rf /tmp/suite && mkdir -p /tmp/suite
    git archive origin/eval/scorecard-runner evaluation/suites/recipes | tar -x -C /tmp/suite
    python3 data/recipes/tools/validate_corpus.py --suite-dir /tmp/suite/evaluation/suites/recipes
    python3 data/recipes/tools/extract_unresolved.py
    python3 data/recipes/tools/scan_inrecord_amounts.py

All three tools are deterministic, take no other inputs, and modify no
repository file; re-running converges to the same reports.

## Limits and handoff

- **Release status (operator ruling recorded 2026-10-11):** the corpus is a
  release candidate as shipped — 4/5 suite C bars pass on the full combined
  428 (rights >= 400, 100% linter pass, 0 unchecked claims, 14/14 bands);
  the >= 95% quantity-evidence bar honestly fails at 2771/2988 resolved
  (92.74%), short exactly 68 resolved lines (0.95 x 2988 = 2838.6;
  2838/2988 = 94.98%). The operator ruled HOLD: no edits to
  `eval/scorecard-runner` or anything under `evaluation/` — the suite must
  not grade data its own task supplied, so the gap closes on this branch
  via properly cited household-to-grams conversion rows in `data/recipes/`
  (one row per conversion with source, quote, and retrieval date) and
  per-line conversion evidence (`conversion_ref` and `grams`) carried in
  the corpus record itself. Estimated masses are never marked `weighed`.
  §9 records the direct measurement that all 217 lines state no amount
  anywhere in the record, so the ruling's annotation precondition fails
  as shipped: the pipeline is built and self-tested on this branch, the
  missing inputs live upstream in the originals records, and the final
  suite C re-proof runs when the eval-harness task
  (fl-eval-harness-f1, PR #88) makes suite C read conversion evidence from
  the corpus.
- The `substitutions` annotation (section 7) is a corpus-level join field
  documented here; SCHEMA.md does not describe it (not edited by this
  task). If the programme wants it normative, SCHEMA.md should gain a line
  (programme parent's call).
- **Corpus size vs the 1500 target:** 428 rights-clear recipes; growth
  beyond that continues through new originals or newly cleared sources
  under the same evidence rules.
- Cross-product cells 78/90 (informational; the suite counts bands over the
  declared set, which is full: 14/14).
- `fl-seed-0002`/`fl-seed-0018` remain core-ingredient twins (distinct
  dishes, distinct titles) — allowed by SCHEMA.md §7, informational.
- Nothing in `evaluation/`, `scripts/`, `apps/`, or `packages/` was
  modified; SCHEMA.md, SOURCES.md, RIGHTS-AUDIT.md, `data/recipes/originals/`,
  `data/substitutions/`, and the FLSubstitutions package were consumed
  read-only. Suite C fixtures were never copied or counted.
- MyPlate retry and the BBC cache replacement (sections 4–5) remain
  follow-ups for their owning branches; unchanged by this integration.
**Writer ruling (2026-10-11, operator).** `fl-original-recipes-f1` now owns PR #107, `overhaul/original-recipes`, and `data/recipes/originals/`; this programme has stopped writing that branch and directory. This programme's commits on `overhaul/original-recipes` — all authored Sam Gu <127461594+SamGu-NRX@users.noreply.github.com> with the obvious-autobuild[bot] co-author trailer, diffs confined to `data/recipes/originals/`, append-only — were: Part 5 (thread th_MzvPCFVg) `654afe2`, `47e9274`, `9b69c34`, `0b7a08b`; Part 5b continuation M4-M11 (thread th_lm6J9eSh) `1855545`, `0fc9b63`, `f484ebb`, `667b759`, `9bf12e5`, `dc3e6da`, `f04f508`, `607ef99`. Branch head at handoff: `607ef99`, still this programme's last commit — the new owner has not yet appended. The operator's 19:10Z instruction to fold #111 into #107 is voided by the same ruling and was never acted on here. The food-safety rulebook (#97) belongs to `fl-root-food-safety-f1`. This programme's scope stands: the rights audit, PR #43, licensed ingestion into `corpus.jsonl` (ingesting `data/recipes/originals` through the same validation as any source), and substitution table (#114). Open with the operator: the 68-line quantity-gap decision (upstream re-authoring vs accept 92.74% as shipped); any `data/recipes/originals/` re-authoring routes through `fl-original-recipes-f1`.
