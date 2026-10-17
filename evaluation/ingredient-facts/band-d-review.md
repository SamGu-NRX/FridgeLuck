# Band d facts review — `naan` … `sesame-oil`

Packet: `backend/gemini-agent/src/lechef/canon/ingredient-facts/review/band-d.json`
(schema `fridgeluck/facts-review/v1`, packet `burst14-fridgeluck-facts-review-d`,
base commit `af85600867bc9f8d6a68963205e9d502c2dc3df7`).

Scope: the 95 facts whose keys fall in `naan` … `sesame-oil` in JavaScript's
default string sort — one contiguous slice of the alphabet, same convention as
the other review bands.

## Method

Every one of the ten allergen tokens on every fact got an explicit state:

- **contains** (17) — the food is or contains the allergen source by identity:
  fin fish (salmon, sardine, sea bass, salt cod), durum wheat (semolina),
  sesame (seeds and oil), tree nuts (pecans, pine nuts, pistachios), peanuts
  (peanuts and peanut parts), dairy (paneer, queso fresco, ricotta), and
  molluscs (oysters, scallops) under Regulation (EU) No 1169/2011 Annex II.
- **free** (841) — identity excludes the allergen source; plant foods, pure
  fats and oils, pure salts and minerals, plain fresh meat cuts.
- **unknown** (92) — the state a label must settle: formulation-dependent
  processed foods (pork cutlets, sausage, roast turkey, red wine), allergen
  gaps US law does not force onto labels (oats' wheat cross-contact),
  and the eight band compounds whose composition is not fully reviewed
  (`naan`, `nduja`, `noodles`, `pitta`, `ramen-noodles`, `satay`,
  `sausages`), whose own states now answer only "anything beyond the listed
  components" and fail closed as unknown.

Diet states follow the reviewed allergen states on the 77 component-less
facts: 324 allowed, 50 violated (meat, fish, dairy and gluten identities),
11 unknown aligned with unknown allergen states (fining agents in wine,
rennet in queso fresco and ricotta, filler-dependent sausage, breading on
pork cutlets, self-basting turkeys, oats' gluten uncertainty).

Every `reference` evidence cites an https URL with a retrieval date
(2026-10-16): FDA's major-allergen list (21 U.S.C. 321 qq and the FDA
allergen page), USDA FDC product records for peanut oil's refined vs
unrefined split, and EU Annex II item 14 for molluscs. Uncertain states
carry a note naming what settles them (a label, the recipe prep, or a
producer's allergen statement).

Notable corrections this band makes against the current catalog:

- `peanut-oil` peanuts contains → unknown — the generic key spans highly
  refined oil (FALCPA-exempt, 21 U.S.C. 321(qq)(2)(A)) and toasted or
  cold-pressed oil (not exempt).
- `red-wine` egg/fish/milk free → unknown — producer-dependent fining
  agents (egg albumin, isinglass, casein).
- `orzo`, `parmesan`, `pasta`, `pasta-dried`, `peanut-butter`,
  `peanut-sauce`, `pesto`, `puff-pastry`, `raita` — compound own states
  reset to free under the "own state answers only beyond-components" rule;
  the allergen still resolves through their component facts.
- `oyster` / `scallop` molluscanShellfish = contains while fish and
  crustacean shellfish stay free, so the app's combined `shellfish`
  restriction still blocks them and the finer classes stay honest.
- `semolina` glutenFree violated (durum wheat), `rye-flour` glutenFree
  violated, `oats` glutenFree unknown (cross-contact varies by facility).

62 state changes from the current catalog are recorded in each review's
`changes` array with a reason and rule reference; the original state dump is
in the PR description.

## Verification

- `factsReviewBandD.test.ts` pins the packet mechanically: the reviewed keys
  are exactly the band's keys at the current `facts.json`; every fact still
  hashes to its `before_sha256` (or already equals the review applied); every
  review carries all ten allergen tokens, all five diet tokens on
  component-less facts, states inside the allowed sets, and dated https
  evidence on every reference entry.
- The test stages a temp copy of the real `src/lechef/allergens.ts` module
  graph plus canon, applies the band there, and runs `allergenViolations`:
  contains anchors fire ("sesame-oil carries sesame", "salmon carries fish",
  pesto still carries treeNuts through its pine-nuts component), free anchors
  clear silently (olive-oil, salt), unknown anchors fail closed
  ("confirmation required": sausage + wheat, red-wine + milk), and the
  combined `shellfish` restriction blocks scallops. Band ask count drops
  537 → 174 of 855 fact × restriction pairs for the nine measured
  restrictions.
- `bun run check` (tsc --noEmit) clean; `bun test src/__tests__` 376 pass,
  0 fail.

## Not checked here

- facts.json itself is untouched; the apply step (folding all bands into the
  catalog in one packet) is deliberately a separate change.
- No Xcode/macOS here: nothing iOS-side was built or run; the hosted macOS CI
  on this PR is the iOS check.
