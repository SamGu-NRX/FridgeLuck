# Bundled-recipe rights audit

Audit date: 2026-10-11. Scope: every recipe bundled in `apps/ios/Resources/data.json` at branch `obv/fl-next-recipe-fidelity` (166 recipes).

## How to read this

The app ships only recipes it has the right to ship (SPEC 3.5, `docs/spec/overhaul-20261011/SPEC.md`).
Unknown rights means quarantine. A URL attribution is not a licence.
Verdicts:

- **keep** - rights evidence found; the bundled text can stay.
- **rewrite** - keep the dish, replace the bundled text with an original recipe in our own words with our own structured steps (SPEC 3.5 default).
- **remove** - no rights evidence and no rewrite planned; the recipe leaves the bundle.

## Rights-record vocabulary (Suite C alignment)

The downstream corpus lands at `data/recipes/corpus.jsonl`, and every corpus recipe ships with a rights record (contract: `evaluation/SCORECARD.md` and `evaluation/suites/recipes/rights.py` on branch `eval/scorecard-runner`, retrieved 2026-10-11). A rights record is **complete** - and the recipe rights-clear - only when it has all of:

- `source_id`, `source_type`, `origin`, `license`, `access_date` (YYYY-MM-DD), and `license_evidence`;
- all six boolean permissions: `text`, `images`, `modification`, `attribution`, `caching`, `offline_use`.

A URL attribution grants **none** of the six permissions. Each of the 141 BBC rows carries exactly that - a bare `Source:` URL with no licence evidence - so its rights record is incomplete and the recipe quarantines (rights.py: a bbcgoodfood.com source with no licence is quarantine, SPEC 10 "no licence evidence"). That is the same finding as the rewrite verdicts below, in the Suite C vocabulary.

The 25 seed recipes' "keep" verdicts rest on in-house authorship traced through git history. Their corpus records still must be completed (origin: FridgeLuck seed; license: in-house; license_evidence: this audit) before shipping; a record that cannot be completed quarantines the recipe.

Corpus ingredient lines carry quantity evidence using exactly the kinds `weighed`, `source_grams`, `household`, `unknown` (rs.py `RESOLVED_KINDS`/`ALL_KINDS`). `weighed` means measured on a scale, never a builder estimate; a computed mass is at best `household` with a conversion (a documented `conversions.json` row, `conversion_ref` recorded); `unknown` keeps grams null and blocks "complete nutrition" and fit claims. `scripts/recipe_scraper/scrape_recipes.py` now emits exactly these kinds.

## Where the Source: line lives

The bundled schema is a positional array: `[id, title, minutes, servings, required_ingredient_pairs, optional_ingredient_pairs, instructions, tag_bitmask]`.
Attribution, where it exists, is the first line of the `instructions` string in the form `Source: <url>`.
141 of 166 recipes carry such a line; all 141 point at `www.bbcgoodfood.com`. The other 25 carry no Source line at all.

## Shared verdict: the 141 BBC Good Food recipes - rewrite

Evidence of permission found: none. The bundle records a bare URL per recipe and nothing else.
The repo contains no licence file for BBC Good Food content, no permission record, and no terms waiver.
The committed scraper cache (`scripts/recipe_scraper/.cache/bbc_goodfood_recipes.json`) is scraped site content, not permission evidence.

The site's own terms point the other way. bbcgoodfood.com is operated by Immediate Media Company Limited.
Its website terms and conditions (`https://www.immediate.co.uk/terms-and-conditions/`, retrieved 2026-10-11) state, verbatim:

> In accessing our Services, you agree that you will only access its contents for your own personal and non-commercial use and not for any commercial or other purposes, including advertising or selling any goods or services. You also agree not to adapt, alter or create a derivative work from any content on our Services except for your own personal, non-commercial use. You will need our prior written permission if you want to use any content on our Services for any other reason.

> you undertake not to copy, store in any medium (including on any other website), distribute, transmit, re-transmit, re-publish, broadcast, modify, or show in public any part of our Services without our prior written permission

The Good Food app terms (`https://www.bbcgoodfood.com/good-food-app-terms-and-conditions`, retrieved 2026-10-11) add, verbatim:

> Content may only be downloaded or used for personal use.

Bundling 141 BBC Good Food recipes - title, ingredient-expression lines, and full method text - inside a paid app is commercial redistribution of their content, not personal use.
It requires prior written permission from Immediate Media. No such permission exists in this repo.
A recipe's bare list of ingredients is generally not copyrightable, but the written method and expressive ingredient lines are; the bundle currently ships both verbatim (example: recipe id 26, `10-minute couscous salad`, whose instructions field reproduces the site's full method paragraph).

Verdict for all 141: **rewrite** - keep the dish as a concept (dish names and ingredient lists are not the problem), replace every line of expression with our own original recipe and structured steps, drop the `Source:` URL line or reduce it to an inspiration link only after legal review.
Sam makes the final call, per SPEC 3.5, ideally with legal advice.

## Redistribution findings in committed caches

BBC Good Food content is also committed inside the repo under `scripts/recipe_scraper/.cache/`, which is itself redistribution of the same material:

- `bbc_goodfood_recipes.json` - 152 scraped BBC records (152 with bbcgoodfood.com URLs); 141 titles match bundled recipes, 11 are scraped-but-unbundled.
- `bbc_goodfood_recipes.test.json` - 3 BBC records used as a test fixture.
- `data.merged.non_destructive.json` - 166 recipes: the seed 25 plus the 141 BBC-derived rows, i.e. the full redistributed corpus in one file.
- `merge_report.json` - pre-repair merge diagnostics referencing the same records.

These caches should be removed from the repo or replaced with a synthetic fixture before the corpus task ships; the rewrite verdict covers the bundled rows, and this finding covers the caches.

## The 25 seed recipes - traced individually

These 25 recipes (ids 1-25) carry no Source line. SPEC 3.5 notes they are not automatically clear, so each was traced through repo git history:

- The initial commit `69f0286` (2026-02-08, author SamGu-NRX) shipped `FridgeLuck.swiftpm/Resources/data.json` with exactly these 25 recipes and no Source lines.
- Commit `b6eaf3c` (2026-02-28) took the file from 25 to 166 recipes and introduced all 141 BBC attributions; the 25 seed rows were carried over unchanged (identical titles, verified row-by-row).
- None of the 25 titles appears in the committed BBC scrape cache (checked programmatically, per row below).
- `apps/ios/Resources/data.backup.20260228-233201.json` is a backup of the pre-hydration 25-recipe seed and contains no BBC references; the `demo/` resources and `demo_breakfast.json` contain none either.

Evidence is therefore repo-internal: in-repo authorship at the initial commit, no external attribution, generic classic-dish titles with terse original-styled method text.
Repo-internal evidence cannot exclude that the seed author reproduced an external recipe elsewhere, so the verdict below is keep **with that stated residual assumption**; Sam confirms or corrects it when signing off the audit.

## Per-recipe audit table

Regenerate with: `python3 scripts/recipe_scraper/generate_rights_audit.py`

| id | title | source url | permission evidence | verdict |
|---|---|---|---|---|
| 1 | Classic Egg Fried Rice | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 2 | Simple Cheese Omelette | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 3 | Garlic Butter Pasta | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 4 | Chicken Stir-Fry | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 5 | Tomato Egg Drop Soup | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 6 | Avocado Toast with Egg | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 7 | Black Bean Tacos | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 8 | Overnight Oats | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 9 | One-Pot Chicken Rice | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 10 | Caprese Salad | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 11 | Loaded Baked Potato | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 12 | Peanut Butter Banana Smoothie | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 13 | Vegetable Stir-Fry with Tofu | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 14 | Mediterranean Chickpea Salad | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 15 | Simple Salmon with Veggies | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 16 | Quick Tuna Salad | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 17 | Beef Taco Bowl | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 18 | Spinach Mushroom Scramble | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 19 | Coconut Curry Vegetables | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 20 | Sweet Potato & Black Bean Bowl | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 21 | Classic French Toast | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 22 | Garlic Lemon Chicken | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 23 | Mushroom Risotto | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 24 | Egg & Veggie Breakfast Wrap | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 25 | Banana Oat Pancakes | none | No Source line. In repo since 69f0286 (2026-02-08, initial commit); carried unchanged through b6eaf3c; title not in the BBC scrape cache. | keep |
| 26 | 10-minute couscous salad | https://www.bbcgoodfood.com/recipes/10minute-couscous-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 27 | Air fryer tuna pasta bake | https://www.bbcgoodfood.com/recipes/air-fryer-tuna-pasta-bake | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 28 | Allotment salad | https://www.bbcgoodfood.com/recipes/allotment-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 29 | Artichoke & aubergine rice | https://www.bbcgoodfood.com/recipes/artichoke-aubergine-rice | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 30 | Healthy chicken salad | https://www.bbcgoodfood.com/recipes/asian-chicken-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 31 | Asparagus & broad bean fattoush with crispy asparagus ends | https://www.bbcgoodfood.com/recipes/asparagus-broad-bean-fattoush-with-crispy-asparagus-ends | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 32 | Aubergine, chilli & bacon pasta | https://www.bbcgoodfood.com/recipes/aubergine-chilli-bacon-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 33 | Vegetarian enchiladas | https://www.bbcgoodfood.com/recipes/bean-enchiladas | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 34 | Black bean & pineapple salad bowl | https://www.bbcgoodfood.com/recipes/black-bean-pineapple-salad-bowl | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 35 | Black bean & tortilla soup | https://www.bbcgoodfood.com/recipes/black-bean-tortilla-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 36 | Bombay potato frittata | https://www.bbcgoodfood.com/recipes/bombay-potato-frittata | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 37 | Burrito bowl with chipotle black beans | https://www.bbcgoodfood.com/recipes/burrito-bowl-chipotle-black-beans | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 38 | Butter bean curry | https://www.bbcgoodfood.com/recipes/butter-bean-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 39 | Cajun grilled chicken with lime black-eyed bean salad & guacamole | https://www.bbcgoodfood.com/recipes/cajun-grilled-chicken-lime-black-eyed-bean-salad-guacamole | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 40 | Caramelised red onion & anchovy pasta with gremolata | https://www.bbcgoodfood.com/recipes/caramelised-red-onion-anchovy-pasta-with-gremolata | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 41 | Cardamom chicken with lime leaves | https://www.bbcgoodfood.com/recipes/cardamom-chicken-lime-leaves | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 42 | Cauliflower, paneer & pea curry | https://www.bbcgoodfood.com/recipes/cauliflower-paneer-pea-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 43 | Cavolo nero orecchiette | https://www.bbcgoodfood.com/recipes/cavolo-nero-orecchiette | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 44 | Celery soup | https://www.bbcgoodfood.com/recipes/celery-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 45 | Chetna's end-of-summer veg curry | https://www.bbcgoodfood.com/recipes/chetnas-end-of-summer-veg-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 46 | Chicken & chorizo jambalaya | https://www.bbcgoodfood.com/recipes/chicken-chorizo-jambalaya | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 47 | Chicken & chorizo ragu | https://www.bbcgoodfood.com/recipes/chicken-chorizo-ragu | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 48 | Chicken with crushed harissa chickpeas | https://www.bbcgoodfood.com/recipes/chicken-crushed-harissa-chickpeas | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 49 | Chicken jalfrezi | https://www.bbcgoodfood.com/recipes/chicken-jalfrezi | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 50 | Chicken korma | https://www.bbcgoodfood.com/recipes/chicken-korma | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 51 | Chicken, leek & brown rice stir-fry | https://www.bbcgoodfood.com/recipes/chicken-leek-brown-rice-stir-fry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 52 | Chicken & lemon skewers | https://www.bbcgoodfood.com/recipes/chicken-lemon-skewers | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 53 | Chicken madras | https://www.bbcgoodfood.com/recipes/chicken-madras | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 54 | Chicken and mushrooms | https://www.bbcgoodfood.com/recipes/chicken-mushrooms | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 55 | Chicken parmesan | https://www.bbcgoodfood.com/recipes/chicken-parmigiana | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 56 | Chicken satay salad | https://www.bbcgoodfood.com/recipes/chicken-satay-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 57 | Chicken & tzatziki wraps | https://www.bbcgoodfood.com/recipes/chicken-tzatziki-wraps | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 58 | Chinese chicken curry | https://www.bbcgoodfood.com/recipes/chinese-chicken-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 59 | Healthy chilli con carne | https://www.bbcgoodfood.com/recipes/chunky-chilli | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 60 | Coconut & squash dhansak | https://www.bbcgoodfood.com/recipes/coconut-squash-dhansak | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 61 | Cod with cucumber, avocado & mango salsa salad | https://www.bbcgoodfood.com/recipes/cod-cucumber-avocado-mango-salsa-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 62 | Crab linguine with chilli & parsley | https://www.bbcgoodfood.com/recipes/crab-linguine-chilli-parsley | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 63 | Creamy pesto & kale pasta | https://www.bbcgoodfood.com/recipes/creamy-pesto-kale-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 64 | Creamy tomato risotto | https://www.bbcgoodfood.com/recipes/creamy-tomato-risotto | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 65 | Crispy grilled feta with saucy butter beans | https://www.bbcgoodfood.com/recipes/crispy-grilled-feta-saucy-butter-beans | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 66 | Crunchy noodle salad | https://www.bbcgoodfood.com/recipes/crunchy-noodle-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 67 | Curried cod | https://www.bbcgoodfood.com/recipes/curried-cod | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 68 | Curried satay noodles | https://www.bbcgoodfood.com/recipes/curried-sate-noodles | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 69 | Diet cola chicken | https://www.bbcgoodfood.com/recipes/diet-cola-chicken | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 70 | Double bean & roasted pepper chilli | https://www.bbcgoodfood.com/recipes/double-bean-roasted-pepper-chilli | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 71 | Duck ragu with pappardelle & swede | https://www.bbcgoodfood.com/recipes/duck-ragu-pappardelle-swede | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 72 | Easiest ever seafood rice | https://www.bbcgoodfood.com/recipes/easiest-ever-paella | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 73 | Easy risotto with bacon & peas | https://www.bbcgoodfood.com/recipes/easy-risotto-bacon-peas | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 74 | Egg-fried noodles with beansprouts | https://www.bbcgoodfood.com/recipes/egg-fried-noodles-with-beansprouts | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 75 | Fresh salmon niçoise | https://www.bbcgoodfood.com/recipes/fresh-salmon-nicoise | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 76 | Giant couscous salad with charred veg & tangy pesto | https://www.bbcgoodfood.com/recipes/giant-couscous-salad-with-charred-veg-tangy-pesto | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 77 | Ginger chicken udon noodles | https://www.bbcgoodfood.com/recipes/ginger-chicken-udon-noodles | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 78 | Green goddess avocado salad | https://www.bbcgoodfood.com/recipes/green-goddess-avocado-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 79 | Halloumi, carrot & orange salad | https://www.bbcgoodfood.com/recipes/halloumi-carrot-orange-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 80 | Halloumi pasta | https://www.bbcgoodfood.com/recipes/halloumi-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 81 | Healthy bolognese | https://www.bbcgoodfood.com/recipes/healthy-bolognese | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 82 | Healthy chicken burritos | https://www.bbcgoodfood.com/recipes/healthy-chicken-burritos | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 83 | Healthy pad Thai | https://www.bbcgoodfood.com/recipes/healthy-chicken-pad-thai | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 84 | Healthy chicken pasta bake | https://www.bbcgoodfood.com/recipes/healthy-chicken-pasta-bake | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 85 | Healthy gnocchi | https://www.bbcgoodfood.com/recipes/healthy-gnocchi | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 86 | Healthy tikka masala | https://www.bbcgoodfood.com/recipes/healthy-tikka-masala | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 87 | Hummus flatbread pizzas with roasted veg | https://www.bbcgoodfood.com/recipes/hummus-flatbread-pizzas-with-roasted-veg | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 88 | Indian chickpeas with poached eggs | https://www.bbcgoodfood.com/recipes/indian-chickpeas-poached-eggs | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 89 | Italian borlotti bean, pumpkin & farro soup | https://www.bbcgoodfood.com/recipes/italian-borlotti-bean-pumpkin-farro-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 90 | Italian vegetable soup | https://www.bbcgoodfood.com/recipes/italian-vegetable-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 91 | Jerk chicken burger | https://www.bbcgoodfood.com/recipes/jerk-chicken-burger | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 92 | Jerk-style cauliflower with coconut rice | https://www.bbcgoodfood.com/recipes/jerk-style-cauliflower-with-coconut-rice | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 93 | Kidney bean curry | https://www.bbcgoodfood.com/recipes/kidney-bean-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 94 | Masala frittata with avocado salsa | https://www.bbcgoodfood.com/recipes/masala-frittata-avocado-salsa | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 95 | Mexican bean soup with guacamole | https://www.bbcgoodfood.com/recipes/mexican-bean-soup-guacamole | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 96 | Mexican chicken stew with quinoa & beans | https://www.bbcgoodfood.com/recipes/mexican-chicken-stew-quinoa-beans | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 97 | Tomato penne with avocado | https://www.bbcgoodfood.com/recipes/mexican-penne-avocado | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 98 | Miso noodles with fried eggs | https://www.bbcgoodfood.com/recipes/miso-noodles-fried-eggs | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 99 | Moroccan aubergine & chickpea salad | https://www.bbcgoodfood.com/recipes/moroccan-aubergine-chickpea-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 100 | Moroccan chicken | https://www.bbcgoodfood.com/recipes/moroccan-chicken-one-pot | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 101 | Moroccan chicken stew | https://www.bbcgoodfood.com/recipes/moroccan-chicken-stew | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 102 | Moroccan-style chickpea soup | https://www.bbcgoodfood.com/recipes/moroccan-chickpea-soup-0 | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 103 | Moroccan chickpea, squash & cavolo nero stew | https://www.bbcgoodfood.com/recipes/moroccan-chickpea-squash-kale-stew | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 104 | Nduja & spring greens pasta | https://www.bbcgoodfood.com/recipes/nduja-spring-greens-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 105 | Nutty chicken satay strips | https://www.bbcgoodfood.com/recipes/nutty-chicken-sate-strips | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 106 | One-pan beef stew with vegetable mash | https://www.bbcgoodfood.com/recipes/one-pan-beef-stew-with-vegetable-mash | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 107 | One-pot garlicky chicken thighs & giant cous cous | https://www.bbcgoodfood.com/recipes/one-pot-garlicky-chicken-thighs-giant-cous-cous | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 108 | One-pot goulash pasta | https://www.bbcgoodfood.com/recipes/one-pot-goulash-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 109 | Tomato & pasta soup | https://www.bbcgoodfood.com/recipes/orzo-tomato-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 110 | Paillard of chicken with lemon & herbs | https://www.bbcgoodfood.com/recipes/paillard-chicken-lemon-herbs | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 111 | Pasta with pine nuts, broccoli, sardines & fennel | https://www.bbcgoodfood.com/recipes/pasta-pine-nuts-broccoli-sardines-fennel | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 112 | Peanut lime salad | https://www.bbcgoodfood.com/recipes/peanut-lime-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 113 | Pasta arrabbiata with aubergine | https://www.bbcgoodfood.com/recipes/penne-arrabbiata-aubergine | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 114 | Sausage traybake | https://www.bbcgoodfood.com/recipes/pesto-sausage-traybake | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 115 | Pomegranate chicken with almond couscous | https://www.bbcgoodfood.com/recipes/pomegranate-chicken-almond-couscous | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 116 | Prawn & salmon burgers with spicy mayo | https://www.bbcgoodfood.com/recipes/prawn-salmon-burgers-spicy-mayo | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 117 | Pulled chicken & black bean chilli | https://www.bbcgoodfood.com/recipes/pulled-chicken-black-bean-chilli | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 118 | Quick chicken hummus bowl | https://www.bbcgoodfood.com/recipes/quick-chicken-hummus-bowl | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 119 | Salade niçoise | https://www.bbcgoodfood.com/recipes/salade-nicoise | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 120 | Salmon salad with sesame dressing | https://www.bbcgoodfood.com/recipes/salmon-salad-sesame-dressing | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 121 | Sardine tomato pasta with gremolata | https://www.bbcgoodfood.com/recipes/sardine-tomato-pasta-with-gremolata | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 122 | Sweet potato & peanut curry | https://www.bbcgoodfood.com/recipes/satay-sweet-potato-curry | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 123 | Sausage & kale minestrone | https://www.bbcgoodfood.com/recipes/sausage-kale-minestrone | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 124 | Sea bass with sizzled ginger, chilli & spring onions | https://www.bbcgoodfood.com/recipes/sea-bass-sizzled-ginger-chilli-spring-onions | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 125 | Sesame chicken salad | https://www.bbcgoodfood.com/recipes/sesame-chicken-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 126 | Sichuan smacked cucumber noodles | https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 127 | Quick and easy fish stew | https://www.bbcgoodfood.com/recipes/simple-fish-stew | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 128 | Smoky beans on toast | https://www.bbcgoodfood.com/recipes/smoky-beans-toast | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 129 | Smoky chickpea salad | https://www.bbcgoodfood.com/recipes/smoky-chickpea-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 130 | Smoky tomato, chipotle & charred corn soup | https://www.bbcgoodfood.com/recipes/smoky-tomato-chipotle-charred-corn-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 131 | Smoky white bean & ricotta traybake | https://www.bbcgoodfood.com/recipes/smoky-white-bean-ricotta-traybake | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 132 | Healthy spaghetti bolognese | https://www.bbcgoodfood.com/recipes/so-simple-spaghetti-bolognese | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 133 | Somerset stew with cheddar & parsley mash | https://www.bbcgoodfood.com/recipes/somerset-stew-cheddar-parsley-mash | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 134 | Soy-baked potatoes with tuna sriracha mayo | https://www.bbcgoodfood.com/recipes/soy-baked-potatoes-with-tuna-sriracha-mayo | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 135 | Spiced carrot & lentil soup | https://www.bbcgoodfood.com/recipes/spiced-carrot-lentil-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 136 | Spiced lentil & butternut squash soup | https://www.bbcgoodfood.com/recipes/spiced-lentil-butternut-squash-soup | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 137 | Spicy bean & avocado quesadillas | https://www.bbcgoodfood.com/recipes/spicy-bean-avocado-quesadillas | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 138 | Spicy cucumber & watermelon salad | https://www.bbcgoodfood.com/recipes/spicy-cucumber-watermelon-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 139 | Spicy harissa bean stew | https://www.bbcgoodfood.com/recipes/spicy-harissa-bean-stew | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 140 | Spicy root & lentil casserole | https://www.bbcgoodfood.com/recipes/spicy-root-lentil-casserole | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 141 | Spicy tofu tahini noodle salad | https://www.bbcgoodfood.com/recipes/spicy-tofu-tahini-noodle-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 142 | Spinach, sweet potato & lentil dhal | https://www.bbcgoodfood.com/recipes/spinach-sweet-potato-lentil-dhal | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 143 | Spring chicken in a pot | https://www.bbcgoodfood.com/recipes/spring-chicken-pot | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 144 | Spring tabbouleh | https://www.bbcgoodfood.com/recipes/spring-tabbouleh | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 145 | Spring vegetable & cauliflower tabbouleh | https://www.bbcgoodfood.com/recipes/spring-vegetable-cauliflower-tabbouleh | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 146 | Sticky aubergine & tomato salad | https://www.bbcgoodfood.com/recipes/sticky-aubergine-tomato-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 147 | Sticky miso aubergine traybake | https://www.bbcgoodfood.com/recipes/sticky-miso-aubergine-traybake | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 148 | Super-veg pasta | https://www.bbcgoodfood.com/recipes/super-veg-pasta | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 149 | Superhealthy salmon burgers | https://www.bbcgoodfood.com/recipes/superhealthy-salmon-burgers | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 150 | Superhealthy Singapore noodles | https://www.bbcgoodfood.com/recipes/superhealthy-singapore-noodles | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 151 | Taco salad | https://www.bbcgoodfood.com/recipes/taco-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 152 | Thai-style steamed fish | https://www.bbcgoodfood.com/recipes/thai-style-steamed-fish | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 153 | Tomato & black bean taco salad | https://www.bbcgoodfood.com/recipes/tomato-black-bean-taco-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 154 | Tomato, pepper & bean one pot | https://www.bbcgoodfood.com/recipes/tomato-pepper-bean-one-pot | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 155 | Tomato soup & hummus crispbreads | https://www.bbcgoodfood.com/recipes/tomato-soup-hummus-crispbreads | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 156 | Tomato & thyme cod | https://www.bbcgoodfood.com/recipes/tomato-thyme-cod | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 157 | Tuna, bean & olive salad | https://www.bbcgoodfood.com/recipes/tuna-bean-olive-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 158 | Tuna, caper & chilli spaghetti | https://www.bbcgoodfood.com/recipes/tuna-caper-chilli-spaghetti | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 159 | The ultimate makeover: Chicken pie | https://www.bbcgoodfood.com/recipes/ultimate-makeover-chicken-pie | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 160 | Vegan chickpea curry jacket potatoes | https://www.bbcgoodfood.com/recipes/vegan-chickpea-curry-jacket-potato | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 161 | Vegan chilli | https://www.bbcgoodfood.com/recipes/vegan-chilli | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 162 | Vegetarian ramen | https://www.bbcgoodfood.com/recipes/vegetarian-ramen | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 163 | Veggie olive wraps with mustard vinaigrette | https://www.bbcgoodfood.com/recipes/veggie-olive-wraps-mustard-vinaigrette | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 164 | Venetian duck ragu | https://www.bbcgoodfood.com/recipes/venetian-duck-ragu | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 165 | Warm cauliflower salad | https://www.bbcgoodfood.com/recipes/warm-cauliflower-salad | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |
| 166 | Zesty haddock with crushed potatoes & peas | https://www.bbcgoodfood.com/recipes/zesty-haddock-crushed-potatoes-peas | URL attribution only; no licence evidence in repo; Immediate Media terms require prior written permission for non-personal use (shared verdict above). | rewrite |

## Summary

| verdict | count |
|---|---|
| keep | 25 |
| rewrite | 141 |
| remove | 0 |
| needs review | 0 |
| total | 166 |

## What this means for the corpus task

None of the 141 rewritten recipes can contribute text to the corpus. After the rewrite or removal of the BBC rows, the honest starting corpus is the 25 seed originals plus newly written original recipes.
Cleared sources (`SOURCES.md` in this directory) add: NHS recipe content under the Open Government Licence v3.0 with attribution, NHLBI federal recipe collections for recipes NHLBI itself authored, and a subset of MyPlate Kitchen recipes recorded per contributor.
No large open recipe-text dataset is cleared for a paid app (see `food-data-licensing.md` on branch `docs/spec-overhaul-20261011`), so original recipes are expected to be a large share of the corpus (SPEC 3.5).
The corpus lands at `data/recipes/corpus.jsonl`; each recipe ships with a rights record in the vocabulary defined above, and a recipe whose record cannot be completed stays quarantined out of the corpus.
The corpus task must also decide the fate of the committed BBC caches (removal or synthetic-fixture replacement).
