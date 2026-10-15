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

Section 10 records the release-gate corrections made on 2026-10-11 after
the review at `4b6e163` and its re-review at `0f39ea8`: the 25 seeds and
the 2 NHS recipes moved to quarantine for rights, FSIS
doneness endpoints and thermometer wording corrected in 74 originals (89 steps),
916 unproven claims removed, and the NHS conversion rebuilt on the same
rules. The tables below are current. Sections 1–9 describe the work as it
was done; where their numbers predate section 10, they say so.

## Totals (current corpus)

| Measure | Value |
|---|---|
| Recipes in `corpus.jsonl` | 401 (all originals) |
| Recipes in `quarantine.jsonl` | 27, all for rights: the 25 bundled seeds (rights rest on missing attribution) and the 2 NHS recipes (their pages' own terms reserve rights) — section 10 |
| Rights records in `rights_manifest.json` | 401, each verified against `data/recipes/evidence/rights.json` |
|   — by source type | 260 `original` + 141 `original-rewrite` |
| Ingredient lines | 2612 resolved / 2829 (92.33%) — see section 8 |
| Quantity kinds | 2354 `household`, 258 `source_grams`, 217 `unknown`, 0 `weighed` |
| Allergen/diet claims | 65 (nut-free 34, gluten-free 13, dairy-free 9, vegetarian 7, vegan 2), each on a recipe whose every ingredient has known composition (section 10) |
| Thermometer checks | 261 steps; 25 reheat steps, each with its own 165 °F check |
| Food-safety gate | 401/401 pass `food_safety.py`; 401/401 pass suite C `rs.py` at `26c7004` |
| Cuisines | american 103, asian 59, indian 52, italian 65, mediterranean 66, mexican 56 (6/6) |
| Meal slots | breakfast 45, lunch 148, dinner 262 |
| Time bands | 0-15: 35, 16-30: 151, 31-45: 128, 46-60: 46, 61+: 41 |
| Bands represented | 14/14 (all six cuisines, three slots, five time bands) |
| Cross-product cells filled | 75/90 (informational) |
| Dedupe (all 401) | 0 duplicate ids, 0 (title, core-ingredient) collisions |

Validation loop: `python3 -I data/recipes/tools/validate_corpus.py
--suite-dir <suite at 26c7004>` plus `python3 -I -m unittest discover -s
data/recipes/tools -p 'test_*.py'`. The validator runs suite C's `rs.py`,
`rights.py` and `bands.py`, then this branch's gates (`food_safety.py`,
`composition.py`, `rights_evidence.py`) and the quarantine check.

## Suite C criteria status (final corpus)

| Suite C bar | Threshold | Measured | Verdict |
|---|---|---|---|
| Rights-clear recipes | >= 400 (target 1500) | 401/401 verified against pinned evidence; 27 quarantined | **PASS** (1 over the bar) |
| Food-safety linter | 100% pass | 401/401 (suite `rs.py` at `26c7004` and `food_safety.py`) | **PASS** |
| Unchecked allergen/diet claims | 0 | 0 unchecked under suite C at `26c7004` and at `9e04af4` | **PASS** |
| Declared bands covered | every band >= 1 recipe | 14/14 bands | **PASS** |
| Lines resolved with quantity evidence | >= 95% | 2612/2829 = 92.33% | **FAIL — see section 8** |

One bar fails. The quarantined recipes took 159 fully resolved lines with
them, so the gap grew: 0.95 × 2829 = 2687.55, the bar needs 2688 resolved
lines, and the corpus has 2612, short by 76 (it was 68 at 428 recipes). The 217
unresolved lines are unchanged; section 8 describes them.

## 1. Bundled seed conversion — 25 recipes, now quarantined

**Status (2026-10-11, section 10):** all 25 moved to
`data/recipes/quarantine.jsonl`. Their rights records below rest only on
missing attribution, which shows neither authorship nor permission. The
rest of this section describes the conversion as it was done.

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

## 2. NHS website recipes — 2 ingested of 196 parsed, now quarantined

**Status (2026-10-11, section 10):** both moved to `quarantine.jsonl`. The
recipe pages link the Healthier Families Terms of Website Use, which reserve
all rights and bar commercial use without a licence; the records below cite
the general nhs.uk OGL release. The rest of this section describes the
ingestion as it was done.

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
suppressed). Section 10 removed all 4: an unaliased name has unknown
composition, which blocks every claim on the recipe.

One defect was found and fixed before the first commit: the leftover
heuristic fabricated a reheat step for a cold yogurt-berry dish; reheating
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
injected on a deep copy, never persisted). No other field was touched at
ingestion. Section 10 later corrected 89 safety steps in 74 originals and
removed unproven claims; those edits are listed in
`tools/fix_doneness.py` and belong upstream in the originals too.

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

**Result (measured on the 428):** 2087 verified (line, pair) annotations landed on
**405 of 428** recipes, from **79 of 279 pairs**. On the current 401 the
annotations number 1887 on 380 recipes, still from 79 pairs; the rest left
with the quarantined recipes. Candidate verdicts
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

**Current (401 recipes, after section 10):** 2612 of 2829 lines resolved =
92.33%; the bar needs 2688, short by 76. The quarantined recipes' 159 lines
were all resolved, so quarantining them widened the gap. The 217 unresolved lines
below are unchanged. The rest of this section is the measurement on 428.

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

## 10. Release-gate corrections (2026-10-11)

The review at `4b6e163` blocked on five findings that suite C's linter at
`26c7004` did not catch, and the re-review at `0f39ea8` found four gaps in
the first fixes. Each is now a gate in `validate_corpus.py`, with planted
failures in `tools/test_gates.py`. The paragraphs below describe the gates
as they stand.

**Rights (finding 3).** `rights_evidence.py` accepts a record only when the
evidence it cites is pinned in `data/recipes/evidence/rights.json` and agrees
with it; a citation's spelling clears nothing. `pin_rights_evidence.py`
writes that file from git: every authoring record at
`overhaul/original-recipes` `607ef99`, with its recipe's title and a hash of
its ingredient names, and the terms each external source was checked
against, with page hashes and quoted sentences. An original must cite its
own record at that commit, and the record must carry
`LicenseRef-FL-Original`, the app's permissions and this recipe's identity.
An external source clears only with a pinned "verified" verdict. Any other
source type is refused until a form is added. Evidence that
only lists absences (no Source line, present since the initial commit, not
in the BBC scrape cache) is refused. The 25 seeds had nothing else, and
SPEC 3.5 says the 25 non-BBC bundled recipes are not automatically clear,
so `quarantine.py --rights` moved them to `quarantine.jsonl` with the
reason and the old record. `scripts/generate_recipes.md` gives an LLM batch
prompt for extending the catalog, but no record says how the 25 were
written, so it is not authorship evidence. Original text is also checked
against the bundled catalog: the 401 originals share at most 9 consecutive
words with it, all stock phrases; the gate refuses 12.

Checking the NHS terms changed their verdict. The two NHS Healthier Families
pages link their own Terms of Website Use (fetched 2026-10-11): "All such
rights are reserved" and "You must not use any part of the content on the
Site for commercial purposes without obtaining a licence". The records cite
the general nhs.uk OGL release (terms 3.3) instead. With the two in
conflict, the permissions are unknown, so fl-nhs-0001 and fl-nhs-0002 moved
to quarantine.

**Doneness endpoints (finding 1).** `food_safety.py` encodes the USDA FSIS
Safe Minimum Internal Temperature Chart, fetched 2026-10-11 (page "Last
Updated: Apr 14, 2025"; rows quoted in `FSIS_ROWS`). Each ingredient name
maps to a class: poultry including ground poultry 165 °F; ground meat and
raw sausage 160 °F; whole cuts of beef, pork, veal and lamb 145 °F with a
3-minute rest stated in the check's step; fish and shellfish 145 °F; eggs
160 °F, with yolk and white firm (a jammy yolk fails, as in 0152); precooked
poultry or meat and ham 165 °F. Each class cites the chart row it encodes,
and an animal food with no row (venison, rabbit, game birds, offal other
than poultry giblets) refuses the recipe instead of getting a guessed
endpoint. Titles naming casseroles, bakes,
gratins, lasagne, strata, stuffing or fish pie add the 165 °F casserole
endpoint for the finished dish. Ready-to-eat products (stock, fish sauce,
canned fish, anchovies, buns) carry no class. Foods cooked or mixed
together reach the strictest minimum: a check whose step names several
foods, or that cooks a mixture an earlier step made raw (egg folded into
fish cakes), must reach the highest. Every reheating step carries its own
165 °F check. `fix_doneness.py` applied 48 endpoint edits; the main
groups: 7 casseroles and bakes raised to 165 °F (0008, 0102, 0149, 0200,
0235, 0332, 0359); rests added to 20 whole-cut checks; egg coverage at
160 °F or above in 6 recipes (0014, 0124, 0178, 0287, 0321, 0343; the cod
cakes had relied on the 145 °F poach after raw egg went in, and the freezer
burritos pulled the eggs early); a flank steak no longer pulled at
140 °F on carryover (0023); missing checks added for sausages (0252, 0309)
and reheated rice (0095).

**Cook-facing text (finding 2).** Every step with a check now tells the cook,
in one clause, to read the endpoint on a thermometer in the food. Keywords
are not enough: the clause needs a measuring verb, must not negate the
reading ("a thermometer reading 165 F is unnecessary"), and must not tie the
number to an oven or grill setting; a negated rest ("do not rest 3
minutes") is not a rest. No step judges doneness by look or states an
internal temperature without a check. 48 text edits; four steps named the
thermometer and the number without a reading instruction (0124, 0147, 0365,
0375; 0365 also relied on carryover); six
checks that sat on browning or garnish steps moved to the step where the
food finishes cooking (0137, 0146, 0171, 0227, 0377, 0396).
`convert_bundled.py` now writes the check into the seed step it attaches
to. Each edit is asserted against the exact text it replaces, and the test
suite checks that the edits applied to the originals as ingested at
`4b6e163` reproduce the committed steps.

**Claims (finding 4).** `composition.py` refuses a claim when any
ingredient name does not resolve in suite C's `allergens.json` (unknown
composition), when a line offers alternatives that are not all known and
allowed ("ghee or vegetable oil" on fl-original-0065), when a resolved
ingredient varies by product (stock: meat, milk, wheat; cheese: animal
rennet; tamari, curry powder, chaat masala, miso, chipotle in adobo,
baking powder: wheat or barley; pasta and wheat noodles: egg; breads and
tortillas: milk, egg, lard; oats: cross-contact; sugar: bone char for
vegan), or when a step names a conflicting food the list omits. A step
phrase that contains a conflicting word without being that food is exempt
only from the claims it does not contradict: "peanut butter" passes the
dairy-free scan and still fails nut-free. Compound foods named in a step
block every claim they contradict (pesto, mayonnaise, Worcestershire, fish
and oyster sauce, teriyaki, hoisin, miso, gochujang, custard, marzipan).
`strip_unproven_claims.py` removed 916 of 981 claims and never adds one.
By reason, a claim counted under each that applies: unknown composition
881, product-dependent composition 272, conflicting food in a step 88,
alternatives 18. 362 of the 403 recipes then in the corpus contain at least one name the
alias table cannot resolve (the commit message of `0f39ea8` says 342; 362
is the measured count). Claims come back when a composition source covers
those names: alias rows in `allergens.json` or the FLIngredientFacts
package. The 65 kept claims also verify under suite C at `9e04af4`, which
treats unresolved names as unchecked.

**NHS conversion (finding 5).** `ingest_nhs.py` `build_steps` takes each
doneness clause's endpoint from the recipe's ingredients through
`food_safety.py` instead of the clause (turkey mince 165 °F, pork loin
145 °F with rest), checks every reheating step at 165 °F whatever was
checked before, adds one closing check naming any food still unchecked at
the strictest remaining endpoint (165 °F for a casserole), and skips a
page whose steps fail the gate. The old table used classes the schema does
not have (`meat_pork`, `meat_red`, `seafood`). NHS and NHLBI claims now
pass the composition gate, `ingest_originals.py` stops a recipe that fails
either gate, and NHS method text is HTML-decoded. The NHS pages are not
cached on this machine, so ingestion was not re-run. The two NHS recipes
needed no doneness check (a yogurt-berry chill and porridge); their only
data change was "don&#x27;t" decoded to "don't", before they moved to
quarantine for rights.

**What the gate does not know.** It classifies by ingredient name and finds
foods cooked together by the words a step uses, so it is a floor, not a
reading of the recipe. Known approximations: chorizo is always 160 °F
(cured chorizo is ready to eat); bacon is a whole cut at 145 °F with rest
(FSIS gives no bacon temperature; "Ham, Fresh or Smoked (Uncooked)" is the
nearest row); stuffed vegetables and traybakes are not casseroles; any
cheese may use animal rennet.

**Suite C at `9e04af4`.** The newer suite adds a pinned FSIS canon. On the
current corpus with that canon, 51 recipes still fail its R3 rule with 55
violations, and none is a missed endpoint. The suite's keywords classify
ready-to-eat products: "chicken stock" as poultry (13), canned tuna (10)
and fish sauce (2) as fish, "burger buns" as ground meat (5), and "ground
pork" as a whole cut (1). It also wants every class named by its own
check, where this gate accepts a stricter check on the same food or
mixture: egg in meatloaf, meatballs, breading and casseroles (6), poultry
in a pasta bake checked at 165 °F as a casserole (1), fish and shellfish
in egg-bound patties checked at 160 °F (2), and precooked poultry covered
by its 165 °F reheat check (2). The last 13 are steps that say "warm
through" for food that reached its endpoint earlier in the same cook,
which the suite reads as reheating.
The validator still pins `26c7004`, whose lint call takes no canon. Fixing
the suite's keyword table belongs to the eval task (PR #88); the operator
ruled no edits under `evaluation/`.

## Limits and handoff

- **Release status:** 4/5 suite C bars pass on the current 401 (rights
  >= 400 with one to spare, 100% linter pass, 0 unchecked claims, 14/14
  bands); the >= 95% quantity-evidence bar fails at 2612/2829 resolved
  (92.33%), short 76 lines. Before section 10 it was 2771/2988 (92.74%),
  short 68. The operator ruled HOLD: no edits to
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
- **Corpus size vs the 1500 target:** 401 rights-clear recipes, one over
  the 400 bar; two more quarantines drop below it. Growth continues
  through new originals or newly cleared sources under the same evidence
  rules.
- **The 25 seeds** come back only with an affirmative authorship or
  permission record, and **the 2 NHS recipes** only when someone with
  authority settles which NHS terms govern Healthier Families pages. Pin the
  evidence in `tools/pin_rights_evidence.py`, then move them out of
  quarantine.
- **Upstream:** the 89 safety-step corrections (`tools/fix_doneness.py`)
  were made in the corpus because that is where the recipes ship. They
  belong in `data/recipes/originals/` too, which `fl-original-recipes-f1`
  owns; until then a re-ingest must run `fix_doneness.py`.
- **Claims:** 65 survive. Most recipes lost theirs because an ingredient
  name does not resolve in `allergens.json`; adding reviewed alias rows or
  landing FLIngredientFacts restores them through the same gate.
- Cross-product cells 75/90 (informational; the suite counts bands over the
  declared set, which is full: 14/14).
- Nothing in `evaluation/`, `scripts/`, `apps/`, or `packages/` was
  modified; SCHEMA.md, SOURCES.md, RIGHTS-AUDIT.md, `data/recipes/originals/`,
  `data/substitutions/`, and the FLSubstitutions package were consumed
  read-only. Suite C fixtures were never copied or counted.
- MyPlate retry and the BBC cache replacement (sections 4–5) remain
  follow-ups for their owning branches; unchanged by this integration.
**Writer ruling (2026-10-11, operator).** `fl-original-recipes-f1` now owns PR #107, `overhaul/original-recipes`, and `data/recipes/originals/`; this programme has stopped writing that branch and directory. This programme's commits on `overhaul/original-recipes` — all authored Sam Gu <127461594+SamGu-NRX@users.noreply.github.com> with the obvious-autobuild[bot] co-author trailer, diffs confined to `data/recipes/originals/`, append-only — were: Part 5 (thread th_MzvPCFVg) `654afe2`, `47e9274`, `9b69c34`, `0b7a08b`; Part 5b continuation M4-M11 (thread th_lm6J9eSh) `1855545`, `0fc9b63`, `f484ebb`, `667b759`, `9bf12e5`, `dc3e6da`, `f04f508`, `607ef99`. Branch head at handoff: `607ef99`, still this programme's last commit — the new owner has not yet appended. The operator's 19:10Z instruction to fold #111 into #107 is voided by the same ruling and was never acted on here. The food-safety rulebook (#97) belongs to `fl-root-food-safety-f1`. This programme's scope stands: the rights audit, PR #43, licensed ingestion into `corpus.jsonl` (ingesting `data/recipes/originals` through the same validation as any source), and substitution table (#114). Open with the operator: the quantity-gap decision, now 76 lines at 92.33% after the quarantines (upstream re-authoring vs accept as shipped); any `data/recipes/originals/` re-authoring routes through `fl-original-recipes-f1`.

## 11. Ingredient identity, nutrition, and bundle-v2 compilation (2026-10-15)

This section covers the follow-on work on branch
`obv/burst5-fridgeluck-rcp-pipeline`: resolving every corpus ingredient name
to a canonical vocabulary key and a verified USDA FDC row, computing recipe
nutrition from those rows, compiling the full bundle-v2 artifact, and
validating it against the `recipe-bundle-v2` contract.

### Outputs

| Artifact | Contents |
|---|---|
| `data/ingredients/vocabulary.json` | 222 canonical keys, 424 surface-name mappings; every entry carries `fdc_id`, `fdc_ref`, class, and per-100g nutrition pulled from pinned bulk CSVs |
| `data/recipes/build/recipes-v2.json` | all 401 recipes compiled (ids `rcp-000167`+), 218 ingredients used |
| `data/recipes/legacy-ingredient-map.json` | regenerated; conforms to `ingredient-identity.schema.json` (verified with jsonschema) |
| `data/ingredients/fdc-new-rows.json` | 79 FDC rows beyond the bundled 800-row catalog |
| `data/recipes/tools/tests/test_pipeline.py` | 14 portable tests (pytest, 14/14 pass) |

### Nutrition provenance and merge order

Per-100g values come from the CC0 bulk CSVs (FNDDS 2024-10-31, SR Legacy
2018-04, `/tmp/fdc`, outside the repo) under FDC nutrient ids 208/203/205/291/269/307/1093;
FNDDS uses a distinct sodium id (1093) from SR Legacy, and the loader
recognizes both. When a bundled-catalog row carries only a partial nutrient
set, the bulk FDC row wins per field and the catalog fills gaps; no value is
synthesized, and missing nutrients are emitted as explicit 0.0 rather than
omitted, so the schema's seven required fields are always present.

### Data defects found and fixed during audit

| Key | Defect found | Resolution |
|---|---|---|
| `mint` | FNDDS `mint*` resolves only to "Mint julep" (187 kcal/100 g — a cocktail) | pinned to SR Legacy 173474 Peppermint, fresh |
| `salt` | bundled-catalog prefix hit was "Salt Pork (Raw, Cured)" (748 kcal) | pinned to SR Legacy 173468 Salt, table |
| `egg` | catalog row was "Egg (Whole, Raw, Frozen, Salted)" — 3663 mg sodium/100 g, which drove rcp-000324 to 6097 mg/serving | pinned to SR Legacy 171287 Egg, whole, raw, fresh; the legacy identity map now inherits vocabulary resolutions so legacy `egg` also leaves the salted row |
| `salmon`, `anchovies`, `avocado`, `bell_pepper`, `chickpea(s)`, `heavy_cream` | curated canon ids are Foundation Foods rows absent from the bulk CSVs and the catalog rows carried kcal 0 with nonzero macros | each pinned to a verified SR Legacy row (175167, 174183, 171705, 170108, 173756, 170859) |

### Validator corrections

The initial validator run reported 44 problems; after the fixes above it
passes clean on the full bundle. Two validator-side corrections were needed
because the original checks were themselves wrong:

- **Atwater cross-check**: carbs-by-difference include fiber, so the expected
  kcal is now `4P + 4(C−F) + 2F + 9Fat` with an absolute 50 kcal floor (small
  absolute deltas on low-energy foods are relative noise). Recipes whose
  ingredients include alcohol (`red_wine`, `rum`, `mirin`, ...) are exempt:
  alcohol contributes 7 kcal/g the shipped macros cannot express.
- **Sodium plausibility** correctly caught the salted-egg defect above and
  passes once the row was fixed — the check was right, the data was wrong.

### Measured results

| Check | Result |
|---|---|
| `validate_bundle.py recipes-v2.json` | PASS (0 problems) |
| Mapping audit | every one of the 410 distinct corpus ingredient names maps to a canonical key |
| Nutrition coverage | 259 estimated (full per-100g × household grams), 142 partial, 0 computed — every recipe carries nutrition with an explicit basis string |
| Determinism | `build_vocab.py` + `compile_bundle.py` twice → byte-identical `vocabulary.json`, `name-mappings.json`, `recipes-v2.json` (md5 verified) |
| Tests | `python3 -m pytest data/recipes/tools/tests/ -q` → 14 passed |

### Limits and assumptions

- The bundle is written to `data/recipes/build/`, not `apps/ios/`; app-bundle
  integration is the integration thread's work.
- 38 vocabulary keys lack per-100g rows (no acceptable FDC row found); they
  stay explicit rather than guessed, and recipes using them are `partial`.
- Nutrition is `estimated`, not lab-derived: per-100g × household grams with
  the corpus's own conversion refs; cooking losses are not modeled.
- The 15 `unresolved` legacy identity-map entries are unchanged from the
  committed map; the map's `proposed` entries inherit vocabulary pins only
  where the vocabulary resolved.
- The rights prose allows statuses the bundle schema does not
  (`original`/`quarantined` only are machine-enforced); disclosed in section 10.

## 12. Review response — validator fail-open findings (2026-10-15)

The independent review of draft PR #158 (comment 6199420190) confirmed every
shipped number reproduces but found the validator's fail-closed claim check
inoperative. All four ranked findings are fixed in this revision; each fix
lands with a test that failed before it.

| # | Finding | Fix | Fail-first test |
|---|---|---|---|
| 1 (HIGH) | `validate_bundle.py` read `e.get("class")` but the vocabulary emits `classes` (plural list; 0 of 222 entries carry a singular field), so the claim check never fired; blocker set also named `dairy_egg`, a legacy-map category that no entry has as a class | read `classes` plural into sets; blockers rewritten in class names — vegan blocks meat/fish/shellfish/dairy/egg; vegetarian blocks meat/fish/shellfish (lacto-ovo convention; zero live conflicts, re-verified) | `test_validator_rejects_vegetarian_claim_on_meat_line` (seeded `vegetarian` on a meat line passed before, fails after), `test_claim_blockers_use_real_class_names` |
| 2 (MED) | FSIS gate read the same dead map (`has_protein` always False); endpoint temperatures were never checked against FSIS tables at all, only the `source` string | gate reads the fixed map over meat/fish/shellfish; new check: each endpoint must meet the FSIS minimum for the classes the step itself uses (`CLASS_TO_FSIS`; generic `meat` requires the strictest subtype minimum, 165 F, since the class does not distinguish poultry/ground/whole-cut) | `test_validator_rejects_sub_fsis_thermometer_endpoint` (60 C endpoint now fails), `test_validator_accepts_compliant_thermometer_endpoint` (74 C passes) |
| 3 (MED) | per-serving kcal silently clamped to [10, 2500] and the Atwater check validated the clamped number | clamp replaced by a loud `SystemExit` in `compile_bundle.per_serving_kcal`, matching sodium's fail-loud behavior; changes no shipped value (live kcal range 25.3–1844.7, zero values at either bound — asserted) | `test_per_serving_kcal_fails_loud_outside_range`, plus `test_bundle_contains_no_clamped_values` pinning the no-op |
| 4 (MINOR) | dead entries: `cherry tomatoes → cherry_tomato` shadowed by a later duplicate (the key never existed), an orphan `jarred roasted red peppers → roasted_red_peppers` mapping plus its dead `CONDIMENT_KEYS` membership, and a line-830 `... if False else set()` no-op assigned but never read | all four deleted | `test_surface_mapping_targets_all_exist_in_vocabulary` — which found the orphan entry beyond the reviewer's example |

Verification after the fixes: `build_vocab.py` + `compile_bundle.py` rebuild
all three data artifacts byte-identical (md5-checked against pre-fix), real
bundle validates PASS under the now-live checks, full suite
`python3 -m pytest data/recipes/tools/tests/test_pipeline.py -q` → 21 passed.
The suite needs `/tmp/fdc` (USDA bulk CSVs) and `/tmp/canon` (canon from
`origin/eval/scorecard-runner` at `evaluation/suites/recipes/canon/
ingredient-facts/`) to run the builders; a fresh clone without them cannot
exercise the determinism test — noted by the reviewer, unchanged here.
