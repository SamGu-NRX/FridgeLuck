# Corpus ingestion report

Branch `fleet/fl-recipe-corpus-v2`. Contract: `data/recipes/SCHEMA.md`
(fixed; not edited by this task). Rights verdicts: `data/recipes/RIGHTS-AUDIT.md`
and source terms in `data/recipes/SOURCES.md` (branch `obv/fl-next-recipe-fidelity`,
fetched read-only, never merged). Build date of every `access_date` below:
2026-10-11. All numbers in this report are measured this session; the tooling
that produced them lives in `data/recipes/tools/`.

## Totals (this task's corpus)

| Measure | Value |
|---|---|
| Recipes in `corpus.jsonl` | 27 |
| Rights records in `rights_manifest.json` | 27 (every `source_ref` resolves) |
| Ingredient lines | 159 resolved / 159 (100.0%) |
| Quantity kinds | 158 `source_grams`, 1 `household`, 0 `unknown`, 0 `weighed` |
| Allergen/diet claims | 73, all matching the suite AllergenScanner recomputation (0 unchecked, 0 stripped) |
| Food-safety lint | 27/27 pass |
| Cuisines | american, asian, indian, italian, mediterranean, mexican (6/6) |
| Meal slots | breakfast 9, lunch 21, dinner 17 |
| Time bands | 0-15: 16, 16-30: 10, 31-45: 1 — 46-60 and 61+ absent (see Limits) |

Validation loop (exact command in the PR Proof section): `rs.py` lint green
over the full corpus, `rights.py` completeness green (no quarantined recipe in
`corpus.jsonl`), `bands.py` counts above.

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

## Limits and handoff

- **Corpus size vs the 400-recipe bar:** this task's licensed/in-house share
  yields 27 recipes. The cleared third-party sources cannot raise it under
  the evidence rules (see per-source sections); the volume must come from
  originals (Part 5's `data/recipes/originals/`, ingested by a separate task).
- **Time bands 46-60 and 61+** contain no recipes from this task's sources
  (all ingested recipes are <=45 min). The suite counts bands over the
  *declared* set; the integration task owns the full-scorecard run.
- **Suite C full scorecard** runs against the final merged corpus in the
  integration task; the component runs (rs/rights/bands) in this task's Proof
  cover this task's corpus only.
- Nothing in `evaluation/`, `scripts/`, `apps/`, or `packages/` was modified;
  SOURCES.md, RIGHTS-AUDIT.md, and SCHEMA.md were consumed read-only.
