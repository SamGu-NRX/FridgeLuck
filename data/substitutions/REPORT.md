# Substitution coverage report

Regenerated deterministically by the `flsub-report` executable in
`packages/FLSubstitutions` from the committed table and the bundled recipe data.
Regenerate from the repository root:

    swift run -c release --package-path packages/FLSubstitutions flsub-report \
      --table data/substitutions/pairs.json \
      --recipes apps/ios/Resources/data.json \
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

## Verified-swap coverage

| Eater scope | Lines covered | Share |
| --- | --- | --- |
| No restrictions | 299 | 38.3% |
| dairy-free | 265 | 33.9% |
| egg-free | 299 | 38.3% |
| fish-free | 299 | 38.3% |
| gluten-free | 299 | 38.3% |
| nut-free | 299 | 38.3% |
| peanut-free | 299 | 38.3% |
| pescatarian | 299 | 38.3% |
| sesame-free | 299 | 38.3% |
| shellfish-free | 299 | 38.3% |
| soy-free | 278 | 35.6% |
| tree-nut-free | 299 | 38.3% |
| vegan | 265 | 33.9% |
| vegetarian | 299 | 38.3% |

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
| chicken-protein-to-seitan | chicken breast → seitan | protein | unsupported | Convention; gluten class on substitute side (S-CONTRACT). |
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
| tofu-ricotta-binder-to-real-ricotta | tofu ricotta → ricotta | binder | unsupported | Convention; recorded for the dairy-allowed direction. |
| vinegar-acid-to-lemon-juice | distilled white vinegar → lemon juice | acid | verified | USU row verbatim. |
| whole-grain-mustard-liquid-to-dijon | whole-grain mustard → Dijon mustard | liquid | plausible | Convention. |
| whole-milk-liquid-to-rice-milk | whole milk → rice milk | liquid | verified | Wyoming row verbatim. |
| yogurt-liquid-to-coconut-milk | plain yogurt → canned coconut milk | liquid | unknown | PR #49 32-49: extension guidance covers yogurt-for-sour-cream, not yogurt-to-coconut milk; the 0.9 ratio is unsupported. |

