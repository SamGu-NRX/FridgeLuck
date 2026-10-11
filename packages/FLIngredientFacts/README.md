# FLIngredientFacts

FridgeLuck's one canonical source for what is in an ingredient and whether it fits a
person's restrictions. Foundation-only SwiftPM package, buildable on Linux and macOS;
no UIKit, SwiftUI or GRDB dependency.

Spec context: `docs/spec/overhaul-20261011/SPEC.md` §3.1 (binding) — every substitution
rechecks all eaters' allergens, including compound ingredients. Restriction checks fail
**closed**: an ingredient whose properties are unknown means "ask the user", never
"allowed".

## Status (branch `overhaul/ingredient-facts`)

| Path | Contents | State |
| --- | --- | --- |
| `packages/FLIngredientFacts` | SwiftPM package: types, loader, evaluate API, tests | **PLANNED** until the sources and tests land on this branch |
| `data/ingredient-facts` | Dataset: identities, sourced composition, conformance kit | identities.json, facts.json, generator and coverage exist; conformance kit **PLANNED** |
| `docs/audits/ingredient-facts` | Per-PR integration fix lists (owned by the parent task) | exists (parent-owned) |

Anything not yet in the tree is **PLANNED**, not shipped. Present-tense claims below
describe the pinned contract the implementations must match; they become "tested" only
when the tests exist at the pushed head.

## API contract (pinned for this branch)

Types in module `FLIngredientFacts`:

```swift
public enum FLAllergen: String, Codable, Sendable, CaseIterable {
    case milk, egg, fish, crustaceanShellfish, treeNuts, peanuts, wheat, soy, sesame
}

public enum FLDiet: String, Codable, Sendable, CaseIterable {
    case vegetarian, vegan, pescatarian, glutenFree, dairyFree
}

public struct FLRestrictions: Codable, Hashable, Sendable {
    public var allergens: Set<FLAllergen>
    public var diets: Set<FLDiet>
    /// Meal restrictions are the union of every eater's restrictions.
    public static func union(_ sets: [FLRestrictions]) -> FLRestrictions
}

public enum FLEvaluation: Codable, Sendable {
    case allowed([FLEvidence])
    case violated(FLViolation)   // reason + evidence naming the offending component
    case unknown(FLUnknown)      // what is missing, per restriction
}

public struct FLIngredientFactsStore {
    public init(dataDirectory: URL) throws   // reads data/ingredient-facts JSON
    public func resolve(_ name: String) -> FLIngredientIdentity?  // key, synonym, alias
    public func evaluate(ingredient: String, restrictions: FLRestrictions) -> FLEvaluation
}
```

## JSON representation (pinned before consumers implement it)

The dataset files are the shared contract of the Swift package and both conformance
runners. File schemas and evidence rules are pinned in
`data/ingredient-facts/README.md`; the evaluation payload shapes are pinned here.

```jsonc
// violation payload (JSON mirror of FLViolation)
{
  "ingredient": "soy sauce",
  "restriction": { "allergen": "soy" },        // or { "diet": "vegan" }
  "reason": "component 'soybeans' is a certain ingredient",
  "evidence": [ { "kind": "standard", "ref": "...", "note": "..." } ]
}

// unknown payload (JSON mirror of FLUnknown)
{
  "ingredient": "stock cube",
  "restriction": { "allergen": "soy" },
  "missing": ["no soy fact for component 'hydrolysed-plant-protein'"],
  "reason": "composition varies: ask the user or check the product label"
}

// allowed payload (JSON mirror of the associated evidence array)
[
  { "kind": "label", "ref": "certified gluten-free tamari label claim",
    "note": "product carries a certified gluten-free mark" }
]
```

**Required evidence per result.** A `violated` result must carry the evidence of the
offending fact and name the offending component in `reason`. An `allowed` result for a
restriction must carry at least one evidence item naming the fact that establishes
absence **for that same axis**: wheat avoidance is satisfied only by wheat evidence, the
gluten-free diet only by gluten evidence or a gluten-free label claim — never the other
way round (see rule 5). An `unknown` result must name in `missing` what is absent (the
ingredient, the component, the fact).

**Malformed-data rejection.** The store initializer and both runners reject (throw /
exit nonzero) on: invalid JSON; unknown allergen/diet/state/certainty strings; duplicate
keys or synonyms; component or form keys that do not resolve to a fact entry; evidence
missing `kind`, `ref` or `note`; an absence fact (`free`/`allowed`) carrying `usda` or
`recipe` evidence; wrong-state vocabularies. Unresolved ingredient names are not a
load error: `resolve` returns nil and `evaluate` returns `unknown` naming the
unresolved name.

**Aliases.** Resolution is exact after case-folding and trimming, across keys, display
names, synonyms and preparation-form synonyms. There is no fuzzy or substring matching.

**Missing per-restriction facts.** A restriction with no relevant fact for the
ingredient evaluates to `unknown` (fail closed) — never `allowed` — and names the
missing fact in `missing`.

## Semantics (tested in the package, mirrored by the conformance runners)

1. **Fail closed.** An unresolvable name, or an ingredient with no facts, evaluates to
   `unknown` for any restriction it touches — never `allowed`.
2. **Ordering.** `violated` beats `unknown` beats `allowed`: if any known component of a
   compound violates a restriction, the result is `violated`; if none violate but a
   relevant fact is unknown, the result is `unknown` naming what is missing.
3. **Variable or unsourced properties are unknown, never false.** "Sometimes contains X"
   is not "does not contain X".
4. **Compounds stay compounds.** Soy sauce carries soy and wheat; tamari carries soy
   with wheat unknown — a product ingredient declaration (not a gluten-free label)
   settles wheat; a certified-gluten-free tamari product is a distinct preparation form
   whose gluten-free claim is gluten evidence only.
5. **Wheat and gluten are two independent axes.** Wheat is one of the nine FDA major
   allergens, with its own evidence. Gluten is a separate property, with its own
   evidence (including gluten-free label claims). Evaluation never infers wheat absence
   from gluten-free evidence, gluten absence from wheat evidence, or either direction
   reversed. The FDA gluten-free labeling rule permits some processed wheat-derived
   ingredients in foods labeled gluten-free, so a gluten-free label does not establish
   wheat absence ([FDA gluten-free labeling Q&A, General question 6](https://www.fda.gov/food/nutrition-food-labeling-and-critical-foods/questions-and-answers-gluten-free-food-labeling-final-rule)).
   The gluten-free diet is evaluated from gluten facts and gluten evidence only; the
   wheat allergen check is evaluated from wheat facts only.
6. **Meals use the union** of every eater's restrictions.

## Dataset

`data/ingredient-facts/` (owned by this branch) — see its README for the pinned file
schemas: `identities.json`, `facts.json`, and the conformance kit under `conformance/`.

## Verification

All three commands run from the repository root:

```sh
swift build --package-path packages/FLIngredientFacts && swift test --package-path packages/FLIngredientFacts
bun data/ingredient-facts/conformance/runners/typescript/run_conformance.ts
python3 data/ingredient-facts/conformance/runners/python/run_conformance.py
```

All three must exit 0; the Swift test suite runs every conformance case through the real
store.
