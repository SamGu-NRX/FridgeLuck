# part1-rewrite — writer notes

Rewrites of the weakest bundled recipes: sodium cuts with honest accounting,
FSIS thermometer doneness at the exact class temperature, and original prose.
The `rw-ginger-egg-fried-rice.json` exemplar shows the required shape.

## Recipe index (bundled id → rewrite)

| bundled | rewrite | sodium/serving |
|---|---|---|
| 59 | `rw-chilli-con-carne-black-beans` | 637 (was 11,165) |
| 126 | `rw-smacked-cucumber-noodle-salad` | 714 flagged (was 2,747) |
| 105 | `rw-sheet-pan-satay-chicken-strips` | 602 (was 1,603) |
| 134 | `rw-crispy-soy-potatoes-with-tuna-yogurt` | 542 flagged (was 1,529) |
| 162 | `rw-shiitake-ramen-noodle-soup` | 775 (was 1,471) |
| 125 | `rw-sesame-lime-chicken-salad-with-edamame` | 593 (was 1,450) |

The authoritative numbers are the `nutrition_per_serving` blocks that
`tools/nutrition.py --write --part part1-rewrite` generates — never hand-edited.

## Mapping decisions worth knowing

- **Ground beef** maps to fdc 168608 ("Ground Beef (Grass-Fed, Raw)"). It is the
  only clean raw-beef row in the committed catalog and serves as a lean-beef
  proxy; a 70/30 alternative would add fat, not sodium. Noted here rather than
  silently substituted.
- **Canned tuna** maps to fdc 171986 ("Canned Tuna (In Water)") because the
  rewrite specifies water-packed tuna. The bundled line's data.json sodium
  (338 mg/100 g) is brine-packed — do not cross-map the two states.
- **Eggs and cooked rice** map to the data.json core table (`bundled_id` "1"
  and "2") — the catalog's egg rows are all Frozen/Canned states, and row
  168883 "White Rice (Cooked)" carries dry-rice macros (370 kcal/100 g), a
  known trap recorded in the map notes.
- **Kidney → black beans** (chilli): the catalog has no kidney-bean row, so
  `kidney beans` would be unmapped (and `kidney` fires a strict scanner
  pattern). Black beans have fdc 173735 and no-salt canned versions are a
  like-for-like pantry swap; the change note says so.
- **Tamari** shares fdc 174278 with soy sauce; it is a separate map key so the
  satay rewrite can carry a gluten-free claim cleanly.
- **Avocado has no usable catalog row** (the only search hit is a zero-kcal
  Foundation Foods row with nonzero macros). Burrito-bowl rewrites leave it
  unmapped on purpose.

## Deliberate salty-unmapped flags

- `rw-smacked-cucumber-noodle-salad` carries `salt` (1 tsp draining salt): it
  is mostly rinsed off before dressing, so the honest options were flag or
  lie. The flag stands and the change note explains it.
- `rw-crispy-soy-potatoes-with-tuna-yogurt` carries `sriracha` (2 tsp): kept
  for dish identity; no committed row exists. Its true contribution is roughly
  100 mg/serving, so read that recipe's number as "plus sriracha".

Everything else in these six recipes is mapped; there are no stock, bouillon,
or broth lines hiding unmapped sodium — the ramen broth is built from shiitake
in water, which is why its number is trustworthy.

## Budget arithmetic

`rw-smacked-cucumber-noodle-salad` (tagged `budget`), per 2 servings:
noodles $0.38 + cucumber $0.79 + salt $0.01 + soy sauce 24 g $0.62 + tahini
$0.33 + rice vinegar 2 tbsp $0.08 + sugar $0.015 + chili flakes $0.06 +
sichuan peppercorns $0.08 + green onions (3 tbsp of a bunch) $0.45 + cilantro
$0.10 + oil $0.12 = **$3.14 total ≈ $1.57/serving**.

Prices are the `tables/cost-assumptions.json` shelf assumptions; they are
inputs, not measurements.

## Deferred, and why

Fish-fillet and prawn recipes from the high-sodium list stay unrewritten: the
committed catalog has no clean cod/tilapia/shrimp rows (only zero-kcal
Foundation Foods hits), so any sodium/kcal number for them would be invented.
Measure-the-dry-state options (dry rice, dry noodles) are used wherever
possible for exactly this reason.
