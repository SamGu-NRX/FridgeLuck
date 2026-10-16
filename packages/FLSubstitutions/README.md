# FLSubstitutions

Lookup over FridgeLuck's reviewed, context-specific substitution table
(SPEC overhaul-20261011 §3.5). Foundation-only; builds and tests on Linux.

## What it guarantees

- **Refusal before suggestion.** A swap whose substitute would carry a class
  an eater's restriction forbids is refused — for every eater, with compound
  ingredients expanded (soy sauce is soy **and** gluten; pesto is tree nuts
  **and** dairy). The sweep test runs every pair against every restriction
  set and asserts zero allergen-introducing suggestions.
- **Honest verdicts.** A pair applies to a recipe line as `verified`,
  `plausible`, `unsupported`, or `unknown`. `verified` requires both sourced
  function evidence and sourced ratio evidence. Conflicting evidence ranks
  `plausible` at best. `unknown` stays unknown; it is never offered as if it
  were evidence.
- **Determinism.** Same inputs produce the same ranked output, every time
  (ranking: verdict, then pair id; asserted byte-identical in tests).
- **No silent unit conversion.** Gram scaling is offered only for
  `weight`-basis ratios; kitchen-unit bases carry their own statements.

## Use

```swift
import FLSubstitutions

let table = try SubstitutionTable(data: tableJSON)  // data/substitutions/pairs.json

// Ranked, safe swaps for an eater set:
let swaps = try table.swaps(
    for: "soy sauce",
    role: .umami,
    restrictions: ["gluten-free"]        // unknown names throw, never dropped
)

// Full picture including refusals, with reasons:
let candidates = try table.swapCandidates(
    for: "soy sauce", role: .umami, restrictions: ["gluten-free"]
)
for candidate in candidates where candidate.isRefused {
    // candidate.recheck.violated names the classes that caused the refusal
}
```

The canonical table lives at `data/substitutions/pairs.json`.
`SubstitutionTable.loadDefault()` locates it in-repo for tests and tooling;
app bundles embed the JSON and construct from `Data`. Schema, evidence
statuses, macro-delta method, and the shared Suite C allergen contract are
documented in `data/substitutions/SCHEMA.md`.

## Tests

```sh
swift test
```

33 tests cover compound-allergen refusals, ratio scaling with the math shown,
role-mismatch refusals, the all-pairs × all-restrictions sweep, byte-identical
determinism, schema/citation validation, and the Suite C contract alignment.
