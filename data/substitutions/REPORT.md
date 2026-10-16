# Substitution coverage report

Regenerated deterministically by the `flsub-report` executable in
`packages/FLSubstitutions` from the committed table and the bundled recipe data.
Regenerate from the repository root:

    git fetch origin overhaul/original-recipes
    git show origin/overhaul/original-recipes:data/recipes/originals/originals.jsonl > /tmp/originals.jsonl
    swift run -c release --package-path packages/FLSubstitutions flsub-report \
      --table data/substitutions/pairs.json \
      --recipes apps/ios/Resources/data.json \
      --originals /tmp/originals.jsonl \
      > data/substitutions/REPORT.md

Two runs are byte-identical. A line counts as covered when its ingredient
has at least one `verified` swap (sourced function and ratio evidence,
PR #49 semantics) for any of the pair's connected roles, and the swap is
not refused for the listed restrictions. The bundled recipes do not encode
a functional role per line, so per-role fit is decided at lookup time by
`ContextRules` — a covered line means the table has verified support for
the ingredient, not that every use of it is verified.

## Corpus

- Recipes: 166
- Ingredient lines (required + optional): 781
- Distinct app ingredients referenced: 50
- App ingredients with no table identity: 0
- Table: 279 pairs, 381 ingredients, 23 sources

## Composition status (canonical facts store)

Ingredient records by composition status in the canonical dataset (data/ingredient-facts):

- Resolved in the canonical store (composition reviewed): 124
- Unknown composition (no canonical record; rechecks ask the user under restrictions): 257

Unknown-composition ingredients, first 40 by key:

active_dry_yeast, agar, agave_syrup, allspice, almond_butter, almond_flour, almond_milk, anchovy_paste, ap_cornstarch_mix, ap_flour_leaven_mix, apple_cider, apple_juice, applesauce, aquafaba, arrowroot, avocado_oil, bacon_fat, baking_powder, baking_soda, baking_soda_cream_of_tartar, baking_soda_soured_milk, basil, beer, bittersweet_chips, black_pepper, bouillon_water, brewed_coffee, brisket, broth_beer_mix, broth_lemon_mix, broth_vinegar_mix, brown_rice, brown_sugar, buckwheat, buttered_cocoa_fat, buttermilk, cabbage, cake_flour, cane_syrup, canned_chicken, …

## Verified-swap coverage

| Eater scope | Lines covered | Share |
| --- | --- | --- |
| No restrictions | 299 | 38.3% |
| dairy-free | 58 | 7.4% |
| egg-free | 0 | 0.0% |
| fish-free | 0 | 0.0% |
| gluten-free | 0 | 0.0% |
| nut-free | 0 | 0.0% |
| peanut-free | 0 | 0.0% |
| pescatarian | 113 | 14.5% |
| sesame-free | 0 | 0.0% |
| shellfish-free | 0 | 0.0% |
| soy-free | 0 | 0.0% |
| tree-nut-free | 0 | 0.0% |
| vegan | 90 | 11.5% |
| vegetarian | 113 | 14.5% |

## Most common gaps

App ingredients whose lines have no verified swap (no restrictions),
ranked by recipe-line count, then name:

| App ingredient | Recipe lines |
| --- | --- |
| sesame_oil | 121 |
| green_onion | 99 |
| rice | 25 |
| cumin | 24 |
| black_beans | 23 |
| spinach | 20 |
| bell_pepper | 19 |
| carrot | 15 |
| tomato | 14 |
| frozen_peas | 13 |
| bread | 11 |
| cucumber | 10 |
| lettuce | 9 |
| avocado | 7 |
| broccoli | 7 |

## 40-pair audited sample

Evenly spaced across the sorted pair ids; verdicts recomputed by
`ContextRules` from the recorded evidence statuses, not restated.

| Pair | Swap | Role | Verdict | Why |
| --- | --- | --- | --- | --- |
| active-dry-yeast-leavening-to-compressed-yeast | active dry yeast → compressed fresh yeast | leavening | verified | USU row: 1 tbsp active dry = 1 package = 1 compressed cake. |
| anchovy-umami-to-anchovy-paste | anchovies → anchovy paste | umami | verified | USU row verbatim. |
| ap-flour-thickener-to-tapioca | all-purpose wheat flour → quick-cooking tapioca | thickener | verified | USU row verbatim. |
| balsamic-vinegar-acid-to-red-wine-vinegar-sugar | balsamic vinegar → red wine vinegar + sugar | acid | plausible | Convention. |
| breadcrumbs-binder-to-rolled-oats | breadcrumbs → rolled oats | binder | plausible | Convention; oats' gluten semantics documented in registry note and SCHEMA. |
| butter-fat-to-chicken-fat | butter → chicken fat (schmaltz) | fat | verified | USU chart row (chicken fat, clarified). |
| buttermilk-acid-to-milk-vinegar | buttermilk → milk + vinegar | acid | verified | USU row verbatim. |
| canola-oil-fat-to-coconut-oil | canola oil → coconut oil | fat | plausible | Same-oil-family convention; melting profile from SR data. |
| chicken-breast-protein-to-chickpeas | chicken breast → chickpeas (cooked) | protein | plausible | PR #49 4-35: beans supported as meat replacements by extension guidance; 1.3 ratio is convention. |
| chicken-protein-to-seitan | chicken breast → seitan | protein | plausible | Convention; gluten class on substitute side (S-CONTRACT). |
| cilantro-aromatic-to-parsley | cilantro → fresh parsley | aromatic | plausible | Convention. |
| cod-fish-to-haddock | cod fillets → haddock | protein | plausible | Convention; macro delta negligible (SR). |
| cornstarch-thickener-to-arrowroot | cornstarch → arrowroot starch | thickener | plausible | Convention anchored on USU's starch family. |
| cream-of-chicken-soup-liquid-to-white-sauce | condensed cream of chicken soup → white sauce (butter, flour, milk) | liquid | plausible | Convention; casserole-glue role preserved. |
| dried-herb-aromatic-to-fresh-herbs | dried oregano → fresh oregano | aromatic | verified | USU herb family row (reverse direction) verbatim. |
| egg-binder-to-flax-gel | egg → flax gel (flax egg) | binder | verified | NDSU binding row + peer-reviewed muffin study; lift loss documented. |
| egg-protein-to-egg-whites | egg → egg white | protein | verified | Purdue row verbatim. |
| fish-sauce-umami-to-salt-lime | fish sauce → salt water with lime | umami | unsupported | Convention; documented so lookups can answer honestly. |
| garlic-aromatic-to-garlic-powder | garlic → garlic powder | aromatic | verified | USU row verbatim. |
| granulated-sugar-sweetener-to-corn-syrup | granulated sugar → light corn syrup | sweetener | verified | USU row verbatim. |
| ground-beef-protein-to-lentils | ground beef → lentils (cooked) | protein | plausible | Convention; macro delta from SR (about half the protein, 4x the fiber). |
| ham-protein-to-smoked-turkey | ham → smoked turkey | protein | plausible | Convention; pork class removed. |
| honey-sweetener-to-granulated-sugar | honey → granulated sugar | sweetener | verified | USU row verbatim. |
| kosher-salt-aromatic-to-table-salt | kosher salt → salt | aromatic | plausible | Convention; recorded because volume confusion over-salts dishes. |
| mascarpone-fat-to-whipped-cream-cheese | mascarpone → whipped cream cheese | fat | plausible | Convention; dairy both sides. |
| mirin-liquid-to-sake-sugar | mirin → sake + sugar | liquid | plausible | Convention. |
| onion-aromatic-to-dried-minced-onion | onion → dried minced onion | aromatic | verified | USU row verbatim. |
| pancetta-umami-to-bacon | pancetta → bacon | umami | plausible | Convention; pork class both sides. |
| pasta-water-liquid-to-salted-water | pasta water → salted water | liquid | plausible | Convention. |
| pumpkin-pie-spice-aromatic-to-diy-blend | pumpkin pie spice → cinnamon + ginger + nutmeg + allspice | aromatic | plausible | Convention blend; grounded on USU's individual-spice rows. |
| rosemary-aromatic-to-thyme | fresh rosemary → fresh thyme | aromatic | plausible | Convention. |
| scallion-aromatic-to-chives | scallion (green onion) → chives | aromatic | plausible | Convention. |
| shortening-fat-to-butter | vegetable shortening → butter | fat | verified | USU chart row verbatim. |
| sour-cream-fat-to-avocado | sour cream → avocado | fat | unknown | PR #49 50-26: blended avocado for creamy richness is convention; no primary source for the 0.8 ratio. |
| soy-sauce-umami-to-maggi-seasoning | soy sauce → Maggi seasoning | umami | verified | NDSU record; gluten class retained on substitute per the same source's caveat. |
| tofu-ricotta-binder-to-real-ricotta | tofu ricotta → ricotta | binder | plausible | Convention; recorded for the dairy-allowed direction. |
| vinegar-acid-to-lemon-juice | distilled white vinegar → lemon juice | acid | verified | USU row verbatim. |
| whole-grain-mustard-liquid-to-dijon | whole-grain mustard → Dijon mustard | liquid | plausible | Convention. |
| whole-milk-liquid-to-rice-milk | whole milk → rice milk | liquid | verified | Wyoming row verbatim. |
| yogurt-liquid-to-coconut-milk | plain yogurt → canned coconut milk | liquid | unknown | PR #49 32-49: extension guidance covers yogurt-for-sour-cream, not yogurt-to-coconut milk; the 0.9 ratio is unsupported. |

## Composition-unknown entries seen most often

For the FLIngredientFacts coverage task (PR #127): the table entries whose
composition is unknown in the canonical facts store, ranked by how often the
ingredient appears in the recipe corpora, so reviewing the facts for the head
of this list covers the most recipe lines first. Fail-closed semantics do not
depend on this list: an unknown entry is never offered as a verified swap and
shows as a check to the user.

Occurrences are recipe ingredient lines. Bundled lines come from
`apps/ios/Resources/data.json` (required + optional refs, the same line
semantics as the Corpus section). Original lines come from
`data/recipes/originals/originals.jsonl` on `origin/overhaul/original-recipes`,
materialized read-only with `git show` (the branch is never checked out or
pushed). A corpus ingredient counts toward a table entry when the table's own
resolution matches it: an exact, case-insensitive match on the entry's key,
display name, or a recorded alias (plus the app data's
underscore-for-space fallback for snake_case ids). Corpus names that match no
table entry, or that match a composition-reviewed entry, are not listed here,
so every count below is a lower bound on the ingredient's true frequency.

Originals corpus: 401 recipes, 2829 ingredient lines, 2165 resolved to a table entry. Bundled lines resolved to an unknown-composition entry: 0.

| # | Table entry | Bundled lines | Original lines | Total |
| --- | --- | --- | --- | --- |
| 1 | salt | 0 | 91 | 91 |
| 2 | crushed tomatoes | 0 | 79 | 79 |
| 3 | vegetable oil | 0 | 43 | 43 |
| 4 | smoked paprika | 0 | 37 | 37 |
| 5 | turmeric | 0 | 28 | 28 |
| 6 | dried oregano | 0 | 24 | 24 |
| 7 | black pepper | 0 | 18 | 18 |
| 8 | ground ginger | 0 | 16 | 16 |
| 9 | fresh basil | 0 | 15 | 15 |
| 10 | brown sugar (packed) | 0 | 12 | 12 |
| 11 | lentils (cooked) | 0 | 12 | 12 |
| 12 | green cabbage | 0 | 10 | 10 |
| 13 | cornstarch | 0 | 9 | 9 |
| 14 | heavy cream | 0 | 9 | 9 |
| 15 | maple syrup | 0 | 9 | 9 |
| 16 | fresh parsley | 0 | 8 | 8 |
| 17 | eggplant | 0 | 7 | 7 |
| 18 | fresh thyme | 0 | 7 | 7 |
| 19 | mozzarella | 0 | 6 | 6 |
| 20 | wheat noodles | 0 | 6 | 6 |
| 21 | cauliflower | 0 | 5 | 5 |
| 22 | Dijon mustard | 0 | 5 | 5 |
| 23 | granulated sugar | 0 | 5 | 5 |
| 24 | baking powder | 0 | 4 | 4 |
| 25 | canned diced tomatoes | 0 | 3 | 3 |
| 26 | dried thyme | 0 | 3 | 3 |
| 27 | ground beef (90% lean) | 0 | 3 | 3 |
| 28 | rigatoni | 0 | 3 | 3 |
| 29 | toasted sesame seeds | 0 | 3 | 3 |
| 30 | apple cider | 0 | 2 | 2 |

First 30 of the 50 composition-unknown entries with at least one occurrence; the remaining 207 of 257 have zero occurrences in both corpora.

