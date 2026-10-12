# Substitution table — schema and review rules

This directory holds FridgeLuck's reviewed, context-specific substitution
table and the tooling that audits it. It exists to satisfy SPEC
overhaul-20261011 §3.5 ("Substitutions come from a reviewed,
context-specific table (ingredient pair, recipe context, quality note,
macro delta, allergen check). LeChef reasons beyond the table only when it
is empty, and says so.") and §3.1 ("Every substitution rechecks all eaters'
allergens, including compound ingredients (soy sauce contains wheat, pesto
contains nuts). Swaps describe the difference ('a little sharper') and
never promise 'no change'.").

Files:

- `pairs.json` — the table (schema version 1.0.0). The runtime consumer is
  the `FLSubstitutions` package (`packages/FLSubstitutions`).
- `REPORT.md` — generated coverage report over the bundled recipes
  (regeneration below).

## File format (`pairs.json`)

Top level:

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | string | `"1.1.0"` (adds `facts_key`, restriction `fl` mappings, and `fails[].kind`/`restrictions`). The package refuses any other value. |
| `created` | string | Table revision date, `YYYY-MM-DD`. |
| `roles` | array | The 11 functional roles: acid, fat, binder, leavening, thickener, liquid, aromatic, umami, sweetener, protein, garnish. |
| `allergen_classes` | array | The 9 shared restriction classes (below). |
| `restrictions` | object | Restriction name → `{ "forbids": [classes], "fl": {"allergens": [FLAllergen], "diets": [FLDiet]} }` (13 defined). The `fl` mapping is the shared-vocabulary screen the recheck evaluates (below); `forbids` stays as the human-readable class view. |
| `sources` | array | Source registry (below). |
| `ingredients` | object | Ingredient registry keyed by snake_case key. |
| `pairs` | array | The substitution pairs. |

JSON is emitted deterministically: keys sorted, 2-space indent, trailing
newline. Two rebuilds from the same registry are byte-identical.

## Shared allergen vocabulary (Suite C contract)

The nine restriction classes are the shared contract with Suite C's
`AllergenScanner` (`evaluation/suites/recipes/allergens.json`, branch
`eval/scorecard-runner` at `26c7004`): `gluten`, `dairy`, `egg`, `soy`,
`peanut`, `tree_nut`, `sesame`, `fish`, `shellfish`. Keeping this vocabulary
identical lets Part 1b corpus allergen claims verify under the same scanner.

Wheat is represented by the `gluten` class (soy sauce carries `soy` **and**
`gluten`); wheat-specific medical notes (coeliac vs wheat allergy) ride in
`allergen_note`, never as a separate class.

Documented extensions beyond the shared nine, used for diet semantics and
FSIS thermometer-rule triggers: `meat_poultry`, `meat_ground`,
`meat_whole_cut_pork`, `meat_whole_cut_red`, `flesh_fish`,
`flesh_shellfish`, and the markers `animal_product`, `honey`. Extensions
never appear in the shared `allergen_classes` list; a Suite C scan of a
restriction claim never needs them.

### Compound expansion

Classes describe what an ingredient **is**, not what its name says. Compound
ingredients carry every class of their components: soy sauce → soy + gluten;
pesto → tree_nut + dairy; seitan → gluten. This is enforced at the registry
level (each compound ingredient's `classes` list is complete), and the
package's recheck uses the substitute's full class list, so a refused swap
names the actual offending classes. The sweep test runs every pair against
every restriction and asserts zero allergen-introducing suggestions.

## Restrictions (13)

`dairy-free`, `egg-free`, `fish-free`, `gluten-free`, `nut-free`
(tree_nut + peanut), `peanut-free`, `pescatarian`, `sesame-free`,
`shellfish-free`, `soy-free`, `tree-nut-free`, `vegan`, `vegetarian`.

Diet restrictions forbid whole class groups (vegan forbids the four meat
classes, both flesh classes, dairy, egg, and honey; vegetarian forbids the
meat and flesh classes; pescatarian forbids the four meat classes). Unknown
restriction names are a lookup error — they are never silently dropped.

## Ingredient registry

Keyed by snake_case key. Fields:

| Field | Meaning |
| --- | --- |
| `display` | Human name used in UI text. |
| `fdc_id` | USDA FDC SR Legacy identity, or null when no defensible match exists in the dataset. Kept separate from the app's local ingredient IDs (`apps/ios/Resources/data.json`). |
| `usda_name` | The dataset name for the `fdc_id`, asserted to match exactly at build time. |
| `macros_per_100g` | kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg — from SR Legacy (downloaded 2026-10-11; April 2018 release). Null only when no identity exists. |
| `classes` | Full allergen/diet class list including compound expansion. Classes are **evidence labels** kept in step with the canonical composition facts (below); the recheck's safety decision comes from the facts store, not from this list. |
| `allergen_note` | Plain-language caveat (label-dependence, refined-oil exemptions). |
| `aliases` | Every name that resolves to this key; app-vocabulary names (`soy_sauce`) and display names (`soy sauce`) both resolve. Product claims without label evidence are not aliases: generic tamari no longer aliases "wheat-free soy sauce" — the certified gluten-free tamari product form is a distinct entry in the facts dataset (with label evidence), not an alias here. |
| `facts_key` | The canonical `FLIngredientFacts` identity this record maps to (exact-name match on the normalized name against the store's identities — never fuzzy), or null when no canonical record exists. Null fails closed: rechecks return ask-the-user for this ingredient. |

## Pairs

Each pair is one (original → substitute) swap in one primary role.

| Field | Meaning |
| --- | --- |
| `id` | Stable snake_case identifier (original, role, substitute). |
| `original`, `substitute` | Ingredient registry keys. |
| `role` | Primary functional role (one of the 11). |
| `ratio` | `{value, basis, status, conflict_with, note}`. `basis` is a free-form slug naming the kitchen statement (e.g. `weight`, `weight-cooked`, `tbsp-per-tbsp`, `quarter-cup-per-egg`, `volume-partial`); free-form `note` required where the slug alone is unclear. Only a **mass statement** (`weight`, `weight-cooked`) scales arithmetically in grams; the package refuses silent unit conversion for the others and states the kitchen measure instead. |
| `function_status` | Evidence strength for the *function* claim. |
| `supported_also` | Other roles the pair supports, each with its own evidence status and — when one is evidenced — its own ratio. An alternative role never inherits the primary ratio: scaling for an alternative role uses that role's recorded ratio or refuses to scale. |
| `fails` | Roles where the swap **fails**, each with a `why` (e.g. a flax egg fails as a baking leavening; applesauce fails as a creaming fat) and a `kind`: `functional` (the swap fails the role outright; a sourced ratio can never override it) or `conditional` (the swap works for the role but is refused for the named `restrictions` — e.g. seitan as a protein for gluten-free eaters — without degrading the swap's own verdict). |
| `preparation` | Preparation changes the swap requires. |
| `difference` | One plain-language flavour/texture sentence. Never promises "no change" (§3.1). |
| `typical_amount_g` | Typical amount of the original per use, from SR Legacy household weights where available. |
| `macro_delta` | Computed per the method below; null with `macro_delta_null_reason` when not computable. |
| `source_ids` | Registry source ids backing the pair. Every pair has at least one; a validator test fails loudly otherwise. |
| `assessment` | Reviewer note; conflicts and production divergences are recorded here. |

## Evidence statuses and verdicts

Statuses: `sourced` (a registry source states it), `convention` (standard
kitchen practice, no primary source found), `conflict` (sources disagree —
recorded, never silently resolved), `unsupported` (the claim is recorded as
unsupportable), `unknown` (no evidence found; stays unknown).

`ContextRules.verdict(for:requestedRole:)` in the package maps evidence to
verdicts exactly as follows:

| Condition | Verdict |
| --- | --- |
| `fails` entry for the role and ratio not `sourced` | `unsupported` |
| function `sourced` and ratio `sourced` | `verified` |
| function or ratio `unknown` (or missing row) | `unknown` |
| ratio `conflict` | `plausible` at best — never `verified` |
| ratio `unsupported` | `unsupported` |
| otherwise (sourced/convention function + convention ratio) | `plausible` |

A pair with no row connecting it to the requested role is `unknown` (or
`unsupported` with the recorded reason when a failure is recorded).
`unknown` is never upgraded to fit (SPEC §3.5).

A `conditional` failure row refuses the swap for its named restrictions but
leaves the swap's own verdict alone: a sourced ratio still verifies the
function for eaters the condition does not concern (review finding e —
conditional restrictions are encoded separately from actual functional
failures, so sourced ratio evidence can never paper over a role failure).

## Canonical composition rechecks (FLIngredientFacts)

`packages/FLIngredientFacts` + `data/ingredient-facts` are the canonical
composition source. The label `classes` above and that dataset were two
divergent lists describing the same ingredients; the dataset is authoritative
and the labels are kept in step with it. Every ingredient record carries an
explicit `facts_key` (exact-name mapping, 123 of 381 matched; 258 map to no
canonical record and fail closed) and every recheck evaluates the store, not
the class lists:

- **allowed** — the composition is screened and no restriction is violated.
- **violated(reason)** — a restriction forbids a component the ingredient
  actually carries (e.g. `lard` for vegetarians: pork flesh; the reason names
  the offending component).
- **unknown** — the composition cannot be settled (no canonical record, or
  record states uncertainty, e.g. generic tamari's gluten status). The swap
  fails closed: it is **never offered** under the affected restriction and
  surfaces as ask-the-user. A note to read the bottle is kept as guidance but
  cannot substitute for the recheck.

Taxonomy alignment made alongside the store: `lard` carries
`meat_whole_cut_pork`, `fish_sauce` and `worcestershire` carry `flesh_fish`,
`oyster_sauce` carries `flesh_shellfish` — the classes the vegetarian/vegan
forbids actually screen (the `animal_product` marker stays out of the forbids
lists because the canonical diet facts mark butter, eggs and honey
vegetarian-allowed; the marker remains an evidence label). Coconut milk's
label drops `tree_nut` per the store's composition verdict (coconut, water —
tree-nut free; raw coconut stays unknown in the store and its derived records
without their own composition keep failing closed). Both sides of a swap are
rechecked: a swap is offered only when the substitute screens clean AND the
recheck for the requested restrictions settles allowed.

## Macro-delta method

For a pair with both SR identities and a numeric ratio:

```
delta_nutrient = substitute_per100g × (typical_g × ratio)
               − original_per100g × typical_g
```

The arithmetic is defined only when the ratio is a **mass statement**
(`weight`, or `weight-cooked` when the cooked form is what substitutes).
Volume, count and kitchen-unit ratios are not mass ratios — multiplying grams
by them is dimensionally invalid, and partial replacements (e.g.
butter-to-applesauce) omit the retained-fat component that would have to be
evidenced separately. Every other row's `macro_delta` is null with an
explicit `macro_delta_null_reason` (review finding d).

kcal rounds to the nearest integer; other nutrients to 1 decimal. Sodium is
in mg. When either side has no SR identity, `macro_delta` is null and
`macro_delta_null_reason` states which side is missing. The package's test
suite recomputes every recorded delta from the registry's per-100 g values
and asserts equality — the recorded numbers cannot drift from the method.

## Source registry

Each source: `id`, `publisher`, `title`, `url`, `retrieved`
(`YYYY-MM-DD`, optionally followed by a parenthetical provenance note, e.g.
`2026-10-10 (PR #49)`), `what_it_shows`, and `reused_from` when the record
reuses prior work. Reuse policy: PR #49's registry
(`apps/ios/Tools/substitution-evidence/`, read-only) is reused first; new
rows come from university extension publications, peer-reviewed references,
and USDA data. Every claim in the table cites at least one registry source.

## Production consistency

All 27 production pairs from PR #49's frozen snapshot
(`evidence/pairs.snapshot.json`) are represented. Conflicts are preserved,
not resolved: the shipped egg→mashed-banana ratio (0.6) coexists with the
~1.2 supported by cited guidance (verdict stays `plausible`), and
honey→banana keeps its shipped ratio while the record notes it does not
preserve sugar content. Pairs whose evidence PR #49 marked unsupported stay
`unsupported` or `unknown` — recorded so lookups can answer honestly.

## Coverage report (`REPORT.md`)

Regenerate from the repository root:

```sh
swift run -c release --package-path packages/FLSubstitutions flsub-report \
  --table data/substitutions/pairs.json \
  --recipes apps/ios/Resources/data.json \
  > data/substitutions/REPORT.md
```

The generator parses the bundled recipe data (166 recipes; position 4 holds
required ingredient references, position 5 optional ones, each
`[ingredient_id, grams]`), resolves app ingredient names through the table's
alias map, and counts a line covered when its ingredient has at least one
`verified` swap (sourced function and ratio, PR #49 semantics) that is not
refused for the listed restrictions. The bundled recipes do not encode a
functional role per line, so per-role fit is decided at lookup time by
`ContextRules`; a covered line means the table has verified support for the
ingredient, not that every use of it is verified. The report contains no
timestamps and iterates only sorted collections — two runs are
byte-identical.

The generator loads the canonical facts dataset (sibling `data/ingredient-facts`
by default, `--facts` to override) and reports a **composition status**
section: ingredient records resolved in the canonical store vs unknown-
composition records (no canonical record; rechecks ask the user under
restrictions). Formerly the 211 empty-class-list records were invisible
inside the label lists; they now count as the unknown-composition class and
shrink visibly as records gain reviewed facts.

## Tests

`packages/FLSubstitutions` (`swift test`) validates the schema, citations,
coverage floors, compound-allergen refusals, ratio math with the scaling
shown, role-mismatch refusals, the all-pairs × all-restrictions allergen
sweep (label-derived) plus an independent store-outcome sweep (a settled
store violation must refuse everywhere it applies), byte-identical
determinism, macro-delta reproduction on mass-basis rows, and the Suite C
class-vocabulary contract. The PR #114 review's examples are first-class
cases in `ReviewerExamplesTests`: lard and worcestershire refused for
vegetarian and vegan eaters, generic tamari asking the user for gluten-free
eaters (never offered without label evidence), missing-registry substitutes
never offered, restriction unions screening both axes, and alternative roles
never scaling with the primary ratio.
