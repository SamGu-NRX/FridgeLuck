# FLIngredientFacts

FridgeLuck's one canonical source for what is in an ingredient and whether it fits a
person's restrictions. Foundation-only SwiftPM package, buildable on Linux and macOS;
no UIKit, SwiftUI or GRDB dependency.

Spec context: `docs/spec/overhaul-20261011/SPEC.md` §3.1 (binding) — every substitution
rechecks all eaters' allergens, including compound ingredients. Restriction checks fail
**closed**: an ingredient whose properties are unknown means "ask the user", never
"allowed".

## Status (branch skeleton)

This branch seeds the three owned areas:

| Path | Contents |
| --- | --- |
| `packages/FLIngredientFacts` | SwiftPM package: types, loader, evaluate API, tests |
| `data/ingredient-facts` | Dataset: identities, sourced composition, conformance kit |
| `docs/audits/ingredient-facts` | Per-PR integration fix lists (one file per affected PR) |

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

Semantics (tested in the package, mirrored by the conformance runners):

1. **Fail closed.** An unresolvable name, or an ingredient with no facts, evaluates to
   `unknown` for any restriction it touches — never `allowed`.
2. **Ordering.** `violated` beats `unknown` beats `allowed`: if any known component of a
   compound violates a restriction, the result is `violated`; if none violate but a
   relevant fact is unknown, the result is `unknown` naming what is missing.
3. **Variable or unsourced properties are unknown, never false.** "Sometimes contains X"
   is not "does not contain X".
4. **Compounds stay compounds.** Soy sauce carries soy and wheat; tamari carries soy with
   wheat unknown unless product evidence says gluten-free; a certified-gluten-free
   tamari product is a distinct preparation/product form.
5. **Gluten is a separate property**, not one of the nine FDA major allergens. The
   gluten-free diet is evaluated from gluten/wheat facts plus evidence (e.g. a label
   claim).
6. **Meals use the union** of every eater's restrictions.

## Dataset

`data/ingredient-facts/` (owned by this branch) — see its README for the schema:
`identities.json`, `facts.json`, and the conformance kit under `conformance/`.

## Verification

```sh
cd packages/FLIngredientFacts && swift build && swift test
bun data/ingredient-facts/conformance/runners/typescript/run_conformance.ts
python3 data/ingredient-facts/conformance/runners/python/run_conformance.py
```

All three must exit 0; the Swift test suite runs every conformance case through the real
store.
