# docs/audits/ingredient-facts

Integration fix lists for FridgeLuck restriction checks that fail open. One file per
affected PR: `PR-93.md`, `PR-94.md`, `PR-99.md`, `PR-101.md`, `PR-102.md`, `PR-103.md`,
`PR-105.md`, `PR-114.md`, `PR-117.md`, `PR-119.md`.

Each file records, at that PR's current head:

1. Where the restriction code sits (file paths and symbols, head SHA).
2. The fail-open behavior found — an ingredient missing from a local list counts as
   allowed; properties absent ⇒ allowed; gluten-free claimed without product evidence.
3. The exact changes needed to call `FLIngredientFacts` (or to load
   `data/ingredient-facts` and run the conformance kit): import and load the store,
   replace per-module lists with `evaluate(ingredient:restrictions:)`, treat `unknown`
   as "ask the user", never as allowed, and union every eater's restrictions for a meal.

The same list is posted as one comment on the corresponding PR. Nothing is pushed to
those PRs' branches.
