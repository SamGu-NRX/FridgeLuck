# feat(lechef): sourced allergen review of ingredient facts, band A

Branch: `obv/burst14-fridgeluck-facts-review-a` · Base: `alpha` @ `af856008`
Packet: `burst14-fridgeluck-facts-review-a`

## What changed and why

The LeChef allergen recheck (`backend/gemini-agent/src/lechef/allergens.ts`) asks a
restricted eater "confirmation required" for every ingredient whose fact lacks an
explicit allergen state. A measured baseline (commit af856008) put those prompts at
499 across the band covered here: facts `achiote-paste` through `chili-peppers`
inclusive in JavaScript default string sort — 87 keys, of which 68 had no allergen
states at all and 19 were compounds with partial, largely unsourced states.

This change adds the band's review, not the application of it:

- `backend/gemini-agent/src/lechef/canon/ingredient-facts/review/band-a.json` — a
  `fridgeluck/facts-review/v1` packet: for each band key, all ten allergen states
  (milk, egg, fish, crustaceanShellfish, molluscanShellfish, treeNuts, peanuts,
  wheat, soy, sesame), each with evidence `{kind, ref, note}`; and for every
  component-less fact, all five diet states (vegan, vegetarian, pescatarian,
  dairyFree, glutenFree). `before_sha256` pins each reviewed fact so a later apply
  can detect drift. 870 allergen entries total.
- `backend/gemini-agent/src/__tests__/lechef/factsReviewBandA.test.ts` — pins the
  review (see How it was checked).

`facts.json`, `identities.json` and `allergens.ts` are deliberately untouched: a
separate apply packet writes the review into `facts.json` mechanically. The test is
written so it stays green after that apply (hash-or-already-applied check).

### Review decisions

- **Plain single foods** (produce, plain meats, plain dairy like milk/butter/yogurt,
  grains, legumes, oils, sugar, salt): a food carries none of the ten major
  allergens unless it IS one, so all ten states are `free` with a reference
  evidence (FDA major food allergens list + USDA FoodData Central category;
  Regulation (EU) No 1169/2011 Annex II item 14 cited alongside FDA for
  molluscanShellfish since FDA does not regulate molluscs). Diet states follow the
  plain food: e.g. plain chicken is vegan/vegetarian-violated, dairy/gluten-free
  allowed; honey stays vegan-violated. Barley is wheat-`free` (wheat is a different
  species) but glutenFree-`violated`.
- **Compounds fail closed.** `free` only where `compositionComplete` is true and
  every component is certain/typical in identity (e.g. baguette wheat-`free` at the
  compound layer because the allergen enters only through the certain `wheat-flour`
  component; bechamel milk/wheat-`free`; aioli egg-`free`). Where composition is
  incomplete or component identities vary (egg:variable, milk:variable,
  additives:variable — bread, breadcrumbs, burger buns, cheese, beef meatballs,
  black-bean paste/sauce, black vinegar, chicharrones), the compound's own state is
  `unknown` so the recheck keeps asking rather than silently clearing.
- **Commercial beef-stock and chicken-stock keep all states `unknown`** (brand
  formulations vary); the test asserts they still ask wheat-, milk- and soy-free
  eaters after apply.
- **51 existing states were corrected, all with stated reasons.** The load-bearing
  ones: bread/breadcrumbs/burger-buns/cheese `contains` → `unknown` (the prior
  "contains" had no source and over-blocks, but the truth is formulation-dependent,
  not free); aioli/baguette/bechamel `contains` → `free` (allergen enters only via a
  listed, certain component the recheck already traces); beef-meatballs and
  chicharrones unsourced `free` states → `unknown`; cheddar vegetarian
  `allowed` → `unknown` (coagulant varies — matches the cheese fact); beef-vegetable-stock and broth glutenFree `allowed` → `unknown` (the task's
  own stock-additives finding). One noisy prior state was honored as-is: chicken
  stock's `wheat: unknown` pin is preserved.
- **Not touched:** facts outside the band, `identities.json` (the "chicken" identity
  still aliases "chicken-stock" today — the review covers the plain meat; the
  small-fixes packet removes that alias), CI/deploy config, secrets.

## How it was checked

Environment: Linux sandbox, bun 1.3.14, TypeScript 5.x. Working tree at commit
`4e202b55` (work-branch tip).

- `bun install` — 222 packages.
- `bun run check` (`tsc -p tsconfig.json --noEmit`) — exit 0.
- `bun test src/__tests__` — **382 pass, 0 fail** across 28 files, including the new
  `factsReviewBandA.test.ts` (10 tests, 1940 expects): band coverage exact
  (87 keys, each once), ten allergen tokens per fact, five diet states on
  component-less facts, reference evidence must contain an https URL and a
  retrieval date, every fact still hashes to its `before_sha256`, and anchors
  asserted against the **production** recheck applied to a temporary patched canon
  copy: almonds×treeNuts hard-violates, six band singles clear all nine restrictions
  with zero asks, bread×sesame still asks, stocks still ask wheat/milk/soy.
- `bun run src/run/lechef-suite.ts` — **92/92 job successes, 0 unsafe answers, 0
  unauthorized actions**, all gates true.
- Band ask count per restriction (87 facts × 9 restrictions, before → after):
  milk 48→16, wheat 46→15, egg 50→17, peanuts 55→22, treeNuts 53→22, soy 53→20,
  fish 52→22, shellfish 87→22, sesame 55→22 — **total 499→178**.
- Integrity script over band-a.json: 870 entries, no nulls, all states valid, every
  entry carries kind/ref/note evidence.

## What could not be checked

- No Xcode here: nothing iOS was built or run; this change touches no iOS code.
  Hosted macOS CI on this branch is the check for that (expected: no impact).
- Brand-name products were not checked against physical labels; every
  formulation-dependent food is `unknown` and asks instead of asserting.
- The apply packet does not exist yet, so end-to-end `facts.json` behavior after
  application is proven only on the test's temporary copy.

## Assumptions

- Band boundaries are inclusive key ranges on JavaScript default string sort, per
  the task.
- Pescatarian excludes meat but allows fish/shellfish; vegan/vegetarian follow the
  canonical diet-state semantics already in facts.json.
- Compounds inherit only via listed components (recheck behavior), so the review
  records the compound's own state, and component `variable` identity is treated as
  uncertain for the fail-closed rule.
- The review file's `retrieved 2026-10-16` dates mark when the cited reference
  pages were consulted for this review.
