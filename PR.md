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
