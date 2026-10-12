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
| `schema_version` | string | `"1.0.0"`. The package refuses any other value. |
| `created` | string | Table revision date, `YYYY-MM-DD`. |
| `roles` | array | The 11 functional roles: acid, fat, binder, leavening, thickener, liquid, aromatic, umami, sweetener, protein, garnish. |
| `allergen_classes` | array | The 9 shared restriction classes (below). |
| `restrictions` | object | Restriction name → `{ "forbids": [classes] }` (13 defined). |
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
| `classes` | Full allergen/diet class list including compound expansion. |
| `allergen_note` | Plain-language caveat (label-dependence, refined-oil exemptions). |
| `aliases` | Every name that resolves to this key; app-vocabulary names (`soy_sauce`) and display names (`soy sauce`) both resolve. |

## Pairs

Each pair is one (original → substitute) swap in one primary role.

| Field | Meaning |
| --- | --- |
| `id` | Stable snake_case identifier (original, role, substitute). |
| `original`, `substitute` | Ingredient registry keys. |
| `role` | Primary functional role (one of the 11). |
| `ratio` | `{value, basis, status, conflict_with, note}`. `basis` is one of `weight` (grams substitute per gram original), `volume_1tbsp`, `volume_1tsp`, `volume_1cup`, `count_large`, `clove`, `stick`, `package`, `sprig`, `slice`, or `special` (free-form `note` required). Only `weight`-basis ratios scale arithmetically; the package refuses silent unit conversion for the others and states the kitchen measure instead. |
| `function_status` | Evidence strength for the *function* claim. |
| `supported_also` | Other roles the pair supports, each with its own ratio status. |
| `fails` | Roles where the swap **fails**, each with a `why` (e.g. a flax egg fails as a baking leavening; applesauce fails as a creaming fat). |
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

## Macro-delta method

For a pair with both SR identities and a numeric ratio:

```
delta_nutrient = substitute_per100g × (typical_g × ratio)
               − original_per100g × typical_g
```

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

## Tests

`packages/FLSubstitutions` (`swift test`) validates the schema, citations,
coverage floors, compound-allergen refusals, ratio math with the scaling
shown, role-mismatch refusals, the all-pairs × all-restrictions allergen
sweep, byte-identical determinism, macro-delta reproduction, and the Suite C
class-vocabulary contract.
