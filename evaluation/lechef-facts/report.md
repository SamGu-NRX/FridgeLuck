# Facts apply — confirmation-rate report

The five wave-A fact-review bands (A–E, packets `burst14-fridgeluck-facts-review-*`)
were applied to `backend/gemini-agent/src/lechef/canon/ingredient-facts/facts.json`
by `src/run/apply-facts-review.ts` (commit `8807edbb`, all 434 reviews, zero
refusals; a second run is a no-op). This report measures what the apply did to
confirmation asks, using `src/run/confirmation-rate.ts`.

## The four measures

| Measure | Before | After |
|---|---|---|
| Confirmation asks, all (ingredient, allergen) restrictions | 2,373 of 4,340 (54.7%) | **483 of 4,340 (11.1%)** |
| Confirmation asks, compound ingredients' own states | 438 of 1,050 (41.7%) | **382 of 1,050 (36.4%)** |
| Key-in-two-files collisions | 0 | 0 |
| Refused band files / refused reviews | 0 / 0 | 0 / 0 |

An ingredient asks for confirmation on an allergen when its own canon state for
that token is missing or reviewed `unknown`; a reviewed `free` clears silently
and a reviewed `contains` is a hard violation, not a question. The canon's
allergen tokens are the ten the review format pins (shellfish is split into
`crustaceanShellfish` and `molluscanShellfish`); mustard has no canon token and
is pinned to ask-zero by `allergens.ts` `ASKS_BY_DESIGN`, so it is not counted
here. Denominators: 434 facts × 10 tokens = 4,340 restrictions; 105 compound
facts × 10 = 1,050 own-state restrictions.

## Reading the numbers

- The apply cleared 1,890 asks outright (2,373 → 483, 54.7% → 11.1%). The
  clearing is concentrated on simple ingredients: 1,935 of the 2,373 pre-apply
  asks sat on non-compound facts, and 101 remain after the apply.
- The remaining 483 asks sit 79% on compound ingredients' own states (382 of
  483). That is the reviewed-unknown residue the bands deliberately kept:
  compound foods whose state varies by brand or recipe (hydrolysed plant
  protein's source plant, region-specific add-ins), which must keep asking
  rather than clear on uncertainty.
- Zero collisions and zero refusals on the real run: the five bands partitioned
  the canon's 434 facts exactly (87 + 82 + 84 + 95 + 86), every `before_sha256`
  matched at apply time, and no key was reviewed twice across band files. The
  counts above are recomputed from the band files against the before snapshot
  by `confirmation-rate.ts` (dry run), so they stay reproducible.

## Provenance and reproduction

- Before snapshot: `evaluation/lechef-facts/before-facts.json`, extracted with
  `git show 8807edbb^:backend/gemini-agent/src/lechef/canon/ingredient-facts/facts.json`
  (the pre-apply merge state of the five input packets).
- After canon: the live `facts.json` on `obv/burst14-fridgeluck-facts-apply`.
- Reproduce: `cd backend/gemini-agent && bun run src/run/confirmation-rate.ts`.
- The apply itself: `cd backend/gemini-agent && bun run src/run/apply-facts-review.ts`
  (a dry run with `--write=false`; on the applied canon it reports
  `applied: 0, unchanged: 434`).
