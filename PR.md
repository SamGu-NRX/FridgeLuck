<<<<<<< HEAD
# feat(lechef): sourced allergen review of ingredient facts, band B

## What changed and why

Band B of the ingredient-facts review: a sourced re-review of the 82 LeChef
ingredient facts from `chili-powder` to `glutinous-rice` (inclusive, JavaScript
default string sort), stored as
`backend/gemini-agent/src/lechef/canon/ingredient-facts/review/band-b.json`
(schema `fridgeluck/facts-review/v1`, base commit `af85600`).

Each review entry carries all ten allergen tokens and — for facts without
components — all five diet states, each with a state, an evidence kind, and a
sourced note. `changes` records only genuine state transitions from the
current canon (7 facts), never the completion of missing fields. This band
follows the same shape and policy as band A; canon application is left to the
dedicated apply burst.

Key decisions (full evidence inline in the packet):

- **Coconut and coconut oil**: `treeNuts` corrected `unknown → free` with FDA
  Edition 5 guidance — coconut is no longer on the FDA tree-nut list (still
  disclosed voluntarily by many manufacturers). EFSA/FDA FALCPA context noted
  in the evidence.
- **Dashi** corrected `wheat free → unknown` and `soy free → unknown`:
  commercial dashi granules very commonly contain wheat and/or soybean
  (flavour enhancers, hydrolysed protein); the current `free` states were
  wrong, not merely missing.
- **Clam/crab/cod**: shellfish/finfish facts keep their hard
  allergen carries and get complete free states for the other nine tokens.
- **Fat-source-varies / flavourings-unknown** placeholders now review all ten
  tokens and all five diets as `unknown`, with per-token notes; the previous
  blanket `allowed` diet states were corrected to `unknown` — those
  placeholders cannot guarantee any diet.
- **Couscous, durum-wheat-flour, farro** keep `glutenFree: violated`
  (wheat-derived); the packet does not regress it.
- **Flatbread** keeps category-level unknowns (wheat/milk/egg/sesame vary by
  type and brand; a label settles it) and corrects `vegetarian unknown →
  allowed` (no formulation carries meat, fish or shellfish).
- Ask reduction across the band (82 facts × 9 restrictions): **507 → 169**
  confirmation-required prompts, printed by the test before/after.

## How it was checked

- `bun install --frozen-lockfile` — 222 packages installed.
- `bun run check` — `tsc -p tsconfig.json --noEmit`, clean.
- `bun test` — **383 pass, 0 fail, 7336 expects** across 28 files, including
  the new `factsReviewBandB.test.ts` (11 tests, 2056 expects):
  - packet covers exactly the 82 band keys, each once, schema/packet/band
    count asserted;
  - every review carries all ten allergen tokens in valid states, and all
    five diet states on component-less facts;
  - reference-kind evidence must carry an https URL and a retrieval date;
  - every fact still hashes to its `before_sha256` (or already equals the
    review applied), so the test stays green after the apply burst;
  - safety anchors run against a patched TEMPORARY copy of `src/lechef` using
    the production `allergenViolations` lookup: reviewed `contains` states
    (crab×shellfish, couscous×wheat, cod×fish, chocolate×milk) still flag
    hard violations; reviewed `free` states (garlic, cucumber, cumin, dill,
    daikon, ginger, cranberries) clear without asking; reviewed `unknown`
    states (chocolate, dashi, flatbread) and the formulation-variable
    placeholders still ask; coconut facts stop asking tree-nut-free eaters.

## What was not checked

- The packet is not applied to `facts.json` (separate apply burst covers all
  bands); the test verifies the apply result on a temporary copy only.
- Coconut tree-nut relabelling is FDA (US) guidance; other jurisdictions
  (e.g. EU) still list coconut as a tree nut — diet/allergen consumers outside
  the US should re-check before relying on the `free` state.

## Assumptions

- Band boundaries follow the task title: keys `chili-powder`..`glutinous-rice`
  inclusive under JavaScript default sort — 82 facts, matching band A's
  ordering convention.
- Unknown states on brand- or formulation-variable foods ("a label settles
  it") are the correct fail-closed representation, consistent with the canon's
  recheck behaviour.
- `changes` records state corrections only, matching band A's semantics.
=======
# Band-c ingredient-facts review (gnocchi → mustard) — `burst14-fridgeluck-facts-review-c`

Draft pull request for `burst14-fridgeluck-facts-review-c`, branch `obv/burst14-fridgeluck-facts-review-c`, base `alpha` (`af85600867bc9f8d6a68963205e9d502c2dc3df7` — alpha was still at that commit; `git merge origin/alpha` reported "Already up to date" immediately before the commit).

## What changed, and why

Two files, exactly the two paths the task allows:

1. **`backend/gemini-agent/src/lechef/canon/ingredient-facts/review/band-c.json`** — a sourced review of all 84 `facts.json` keys from `gnocchi` to `mustard` inclusive (default string sort; 19 compound foods, 65 single foods). Every fact gets all ten allergen tokens (`milk, egg, fish, crustaceanShellfish, molluscanShellfish, treeNuts, peanuts, wheat, soy, sesame`); every component-less fact gets all five diet states (`vegan, vegetarian, pescatarian, dairyFree, glutenFree`); 106 state changes are itemised with reasons and evidence pointers.

   Rules followed:
   - **Incomplete compounds** (`compositionComplete` false — gnocchi, gochujang, green-curry-paste, hao-you, hoisin, italian-sausage, kimchi, massaman-curry-paste, mayonnaise, miso, mole) are explicit `unknown` on every token: an incomplete component list cannot certify what lies beyond it, so the compound's own prior `free`/`contains` states were demoted. The allergen still flows through the component facts (the lookup visits every component), so nothing is loosened — e.g. gnocchi still hard-violates `wheat` through `wheat-flour`.
   - **Complete compounds** (gremolata, gyoza-skins, hollandaise, hot-sauce, lard, hummus…) are `free` on every token with `compound composition` evidence naming the component list — nothing beyond the listed components carries the allergen. hummus `sesame` and hollandaise `milk`/`egg` move `contains` → `free` (sesame comes from tahini, dairy from butter — already on the components); gyoza-skins `wheat` moves `contains` → `free` (wheat comes from wheat-flour).
   - **hao-you (oyster sauce)** keeps `molluscanShellfish: contains` (oysters are bivalve molluscs — Annex II item 14); wheat and soy are `unknown` (`brand-variable formulation`: wheat flour and soy sauce vary by brand).
   - **Singles** keep their existing `free`/`contains` states and evidence verbatim; missing states are filled with FDA Major Food Allergens + USDA FoodData Central category references. Taxonomy-sensitive gaps on animal foods cite Regulation (EU) No 1169/2011 Annex II: lobster/mussel/fish facts now state both shellfish tokens, closing the app's `shellfish` restriction gap (it checks crustacean and mollusc tokens but no fact had molluscan states).
   - Specific singles: hydrolysed-plant-protein is `unknown` on soy/wheat (source plant varies by brand: soy, wheat or corn) and `unknown` for `glutenFree`; mustard is `free` on milk with a note that mustard is EU Annex II item 10 but not among the ten reviewed tokens; ketchup cites the catsup standard of identity (21 CFR 155.194); malt-vinegar notes barley is not an FDA major allergen; honey/maple/molasses/MSG/lactic-cultures carry one-line composition reasoning.
   - **Diets** for singles: existing entries preserved verbatim; missing ones added from the food's composition (meat facts violate vegan/vegetarian/pescatarian; dairy facts are vegetarian/pescatarian-compatible; honey violates vegan; all singles allowed for dairyFree; glutenFree allowed except the hydrolysate).

   Effect, measured with the real `allergenViolations` lookup over the band's facts: **confirmation asks drop from 513 to 152** (out of 756 fact × restriction checks; 9 restrictions incl. the combined shellfish group). Per restriction before → after: milk 49→17, wheat 54→16, egg 55→16, peanuts 57→18, treeNuts 56→19, soy 54→17, fish 55→18, shellfish 78→15, sesame 55→16.

2. **`backend/gemini-agent/src/__tests__/lechef/factsReviewBandC.test.ts`** — packet test that (a) pins the review to exactly the band's keys (schema `fridgeluck/facts-review/v1`, packet id, band bounds/count), (b) validates state and evidence vocabulary on every token and diet state, (c) proves each fact either still hashes to its recorded `before_sha256` or already has the review applied (stays green after `burst14-fridgeluck-facts-apply` runs), and (d) applies the band to a temp copy of the real canon + `allergens.ts` and asserts anchors via `allergenViolations` — mussel hard-violates shellfish, gnocchi still hard-violates wheat through its component, grapes' shellfish ask clears, hydrolysed-plant-protein still asks on soy — and that the ask total strictly drops.

## How I checked it

All run in the sandbox (no Xcode):

```
bun install                                      # 222 packages
bun run check                                    # tsc -p tsconfig.json --noEmit — clean
bun test src/__tests__                           # 377 pass, 0 fail (12,795 expect calls)
bun run src/run/lechef-suite.ts                  # 92/92 sessions, 0 unsafe answers, 0 unauthorized actions; exit 0
```

Baseline ask measurement (before the review applies), via the repo's own lookup:

```
milk 49, wheat 54, egg 55, peanuts 57, treeNuts 56, soy 54, fish 55, shellfish 78, sesame 55 — total 513 / 756
```

After-apply measurement is asserted in the test and logged by it (`asks after: … total 152`). The band review generator is deterministic and derives `before_sha256` from the checked-out `facts.json` at the base commit.

Sources verified during the review: the eCFR page for 21 CFR 155.194 and the EUR-Lex page for Regulation (EU) No 1169/2011 were fetched and read. The FDA "Major Food Allergens" page returned no extractable text to my fetcher — its URL is cited by the existing canon convention and was verified structurally, not by reading page text.

## What I could not check

- The iOS app is untouched and uncompiled (no Xcode in this environment); the change is data + a backend test only.
- Hosted macOS CI was not run (no pull request is opened from this flow).
- The FDA page's wording was not machine-read (see above).
- The test's applied-band check runs against a temp copy of the canon, not against `facts.json` in place, so "asks after 152" is the effect when the apply packet runs, not the current tree state.

## Assumptions

- Oyster sauce (`hao-you`) contains molluscan shellfish (oysters, EU Annex II item 14) and its wheat/soy content is brand-variable.
- Incomplete compounds stay `unknown` on their own tokens even where a component carries the allergen; the component facts carry the `contains`.
- Complete compounds' listed components are their full composition; `free` beyond the components follows.
- Existing per-state evidence on single foods was correct as reviewed and was preserved rather than rewritten.
- Existing diet states on compounds were preserved (compounds take no diets in the review; the apply packet's merge keeps them).
>>>>>>> origin/obv/burst14-fridgeluck-facts-review-c
