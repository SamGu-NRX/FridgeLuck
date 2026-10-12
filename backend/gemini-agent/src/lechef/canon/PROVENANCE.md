# Canon — pinned reviewed data (verbatim, read-only)

This directory pins the reviewed canonical packages that the LeChef tool layer
consumes. The files are **verbatim copies** of the reviewed branch content:
they are never edited in place. A dataset change is made on its own branch,
reviewed there, and re-pinned here with a new commit hash and new SHA256 lines
in the `files` block below.

- `food-safety/` — USDA FSIS safe-minimum rules, classes and copy (from
  `overhaul/food-safety-canon`). Loaded by `../foodSafety.ts`; validated on
  load, and a rulebook that fails validation disables the tool (fail closed).
- `ingredient-facts/` — FLIngredientFacts canonical identities, composition
  facts and the TypeScript conformance kit (from `overhaul/ingredient-facts`).
  Loaded by `../ingredientFacts.ts`; the conformance kit replays in
  `src/__tests__/lechef/canon-pin.test.ts`.
- `substitutions/` — the reviewed substitution table (from
  `overhaul/substitution-table`). Adapted by `../substitutions.ts` where a
  pair is covered; allergen rechecks still go through FLIngredientFacts.

Not pinned here (owned by their own branches and tasks): the food-safety
Swift linter/conformance tooling and the python runner of ingredient-facts.

## Sources

| Package | Branch | Commit | Extracted |
|---|---|---|---|
| food-safety | `overhaul/food-safety-canon` | `0b8ddca4e0dcd487829a9a5f96a17e534b2cb1a6` | 2026-10-12 |
| ingredient-facts | `overhaul/ingredient-facts` | `b0deecce36bf6ee91e6f5933e746d75466165288` | 2026-10-12 |
| substitutions | `overhaul/substitution-table` | `7b85bec01681dba4804c69fa48211ad34130a2c3` | 2026-10-12 |

## Pinned files

```json
{
  "files": [
    { "path": "food-safety/rules.json", "sha256": "ba31ca0c868268f4cc3488afaa90d08033a42dbf1ea31ed807b61a1f60e4b01b", "upstream": "data/food-safety/rules.json", "branch": "overhaul/food-safety-canon", "commit": "0b8ddca4e0dcd487829a9a5f96a17e534b2cb1a6" },
    { "path": "food-safety/README.md", "sha256": "77b09421b3b830fd4820714b3a8de74ef08ed54761b1f0a65f1b035337251f3b", "upstream": "data/food-safety/README.md", "branch": "overhaul/food-safety-canon", "commit": "0b8ddca4e0dcd487829a9a5f96a17e534b2cb1a6" },
    { "path": "food-safety/SCHEMA.md", "sha256": "63fa4e1f5eeef50f406017869078cfe0fca5c79b2a2634766fbdb24ae1d7bda1", "upstream": "data/food-safety/SCHEMA.md", "branch": "overhaul/food-safety-canon", "commit": "0b8ddca4e0dcd487829a9a5f96a17e534b2cb1a6" },
    { "path": "ingredient-facts/identities.json", "sha256": "94ca6b734605ded252baa2fe3fdc8388a3be62a99340c391de8f8012fe68fd08", "upstream": "data/ingredient-facts/identities.json", "branch": "overhaul/ingredient-facts", "commit": "b0deecce36bf6ee91e6f5933e746d75466165288" },
    { "path": "ingredient-facts/facts.json", "sha256": "9cbc3e121010a624f4569ccd2112d52e321b5b058481003829d0f9557d2bbac3", "upstream": "data/ingredient-facts/facts.json", "branch": "overhaul/ingredient-facts", "commit": "b0deecce36bf6ee91e6f5933e746d75466165288" },
    { "path": "ingredient-facts/README.md", "sha256": "90bb2bc8ba97b1ffe340d5409e4968d17c5e99ad80bd8f0114422148b1119289", "upstream": "data/ingredient-facts/README.md", "branch": "overhaul/ingredient-facts", "commit": "b0deecce36bf6ee91e6f5933e746d75466165288" },
    { "path": "ingredient-facts/conformance/cases.json", "sha256": "981e84cc72d490a0ac876da7e91214f6364d651bd1873777f88bd4996c56ee79", "upstream": "data/ingredient-facts/conformance/cases.json", "branch": "overhaul/ingredient-facts", "commit": "b0deecce36bf6ee91e6f5933e746d75466165288" },
    { "path": "ingredient-facts/conformance/runners/typescript/run_conformance.ts", "sha256": "481dabba291a177c742789c863708cec321a330cb882d4e8200ba527a209705a", "upstream": "data/ingredient-facts/conformance/runners/typescript/run_conformance.ts", "branch": "overhaul/ingredient-facts", "commit": "b0deecce36bf6ee91e6f5933e746d75466165288" },
    { "path": "substitutions/pairs.json", "sha256": "0867924174ee1b4ce99f4d31fbe7a026908c54f58c1955660d355aa6df1cbcd1", "upstream": "data/substitutions/pairs.json", "branch": "overhaul/substitution-table", "commit": "7b85bec01681dba4804c69fa48211ad34130a2c3" },
    { "path": "substitutions/SCHEMA.md", "sha256": "b68559759fb04bd11a4731a19532037df1ec86abcf1f0056fe00b6e5535d68d7", "upstream": "data/substitutions/SCHEMA.md", "branch": "overhaul/substitution-table", "commit": "7b85bec01681dba4804c69fa48211ad34130a2c3" }
  ]
}
```

## Method

Each file was extracted with `git show <commit>:<upstream-path>` at the commit
recorded above (no post-processing), then hashed with SHA256. The integrity
test re-hashes every file and fails on any mismatch, so a silent edit to the
canon cannot ship.
