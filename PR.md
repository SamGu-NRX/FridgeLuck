# feat(lechef): apply the five ingredient-facts review bands and measure the new confirmation rate

Human author: Sam Gu (sgu07966@gmail.com)

## What changed and why

Burst 14's five ingredient-facts review bands (A–E) are now applied to the LeChef canon. The review packets carried the judgement — sourced allergen and diet states for every one of the canon's 434 facts (87 + 82 + 84 + 95 + 86 reviews); this packet transfers it mechanically and measures what it did.

- **`src/run/apply-facts-review.ts`** reads every `review/band-*.json` (schema `fridgeluck/facts-review/v1`) and writes the reviewed states into `src/lechef/canon/ingredient-facts/facts.json`. Refusal rules, documented in `review/README.md` and enforced by the script: a `before_sha256` mismatch (unless the fact already equals its review applied — which is what makes a second run a no-op), a key reviewed in two band files, a band file that misses or overruns its key range (the whole file is refused, nothing from it applies), and a review with no allergens block. Refusals leave the fact exactly as it was.
- **The canon now carries every applied review.** The apply run applied all 434 reviews with zero refusals: no hash mismatches, no cross-file collisions, no band-coverage failures. A second run reports `applied: 0, unchanged: 434` and writes nothing — byte for byte.
- **`src/run/confirmation-rate.ts` + `evaluation/lechef-facts/report.md`** measure the four deliverable numbers (below). The apply script stays thin and mechanical; measurement lives here. The pre-apply canon is committed beside the report as `evaluation/lechef-facts/before-facts.json` (extracted from the apply commit's parent) so the "before" numbers stay reproducible after the canon moves on.
- **`src/__tests__/lechef/factsReviewApplied.test.ts`** (new) pins the apply script's contract on planted inputs in temp directories: format-preserving writes (two-space indent, no trailing newline, key order kept, untouched facts byte-identical), byte-for-byte idempotence on a second run (already-applied is not a refusal), and every refusal rule.

### The four measures

| Measure | Before | After |
|---|---|---|
| Confirmation asks, all (ingredient, allergen) restrictions | 2,373 of 4,340 (54.7%) | **483 of 4,340 (11.1%)** |
| Confirmation asks, compound ingredients' own states | 438 of 1,050 (41.7%) | **382 of 1,050 (36.4%)** |
| Key-in-two-files collisions | 0 | 0 |
| Refused band files / refused reviews | 0 / 0 | 0 / 0 |

An ingredient asks when its own canon state for a token is missing or reviewed `unknown`; a reviewed `free` clears silently, a reviewed `contains` is a hard violation, not a question. The canon's ten allergen tokens are the review format's set (shellfish is split into `crustaceanShellfish` and `molluscanShellfish`); mustard has no canon token and is pinned to ask-zero by `allergens.ts` `ASKS_BY_DESIGN`, so it is not counted. Denominators: 434 facts × 10 tokens = 4,340; 105 compound facts × 10 = 1,050. The clearing is concentrated on simple ingredients (1,935 of the 2,373 pre-apply asks sat on non-compound facts; 101 remain). The 483 surviving asks sit 79% on compound facts' own states — the reviewed-unknown residue the bands deliberately kept (source plant varies by brand, manufacturer-dependent add-ins), which must keep asking rather than clear on uncertainty.

### Apply-aware check repairs — files outside this packet's owned paths, disclosed

This packet's job is to rewrite the canon; three test files that pinned pre-apply canon states could not survive that rewrite by construction, and their repairs are part of this diff. Nothing here changes any review verdict, band file, or the app.

- **`factsReviewBandC.test.ts` / `factsReviewBandD.test.ts`** — the band tests state their own intent as "so the test stays green after the apply packet rewrites facts.json", and bands A, B, E pass unchanged. Bands C and D each had assertions that only hold pre-apply: band C's anchor required grapes × shellfish to *ask* on the live canon (the apply is required to give that fact a reviewed free state, so the anchor pins a state the packet must clear), and both bands' ask-drop assertions were strict `after < before` while staging the band *onto the current canon* (on an applied canon `before == after`, so a strict drop is unsatisfiable by construction — pre-apply they passed: verified by checking out the pre-apply `facts.json` and rerunning, 0 fail on both files). Repairs: the grapes anchor asserts the applied clears; both drops pin the invariant that holds at every stage (`after <= before` — applying a band never *adds* an ask); band C's `applyReview` helper was aligned with the shared apply contract of bands A/B/E (`run/apply-facts-review.ts`): reviewed diets merge over the fact's own, and a fact with no diets of its own and no reviewed diets gains nothing — band C's helper materialized empty `diets` blocks, which its hash-or-already-applied check then required of the canon. That semantic choice is forced: under band C's helper the already-applied checks of bands A, B and E fail on the eleven facts that carry no diets block (band A's helper is the one all three tests agree on).
- **`catalogFacts.test.ts`** — applying the bands produced one new LeChef-versus-bundle disagreement: the bundle classes coconut as `tree_nut`, the reviewed canon reads `treeNuts: free` with reference evidence (FDA "Questions and Answers Regarding Food Allergens", Edition 5, removed coconut from the Tree Nut List: "No, coconut is no longer listed in the Tree Nut List (Table 1) in the 5th edition of the Food Allergen Q&A Guidance.", retrieved 2026-10-16, with the FDA Major Food Allergens page and USDA FoodData Central). Per this burst's rule this is a bundle-side bug — the bundle's `tree_nut` class over-claims — so it is documented in the test's exception list (`BUNDLE_CLAIMS_LECHEF_FREE`) with the evidence and left for the bundle packet; the bundle is not edited from the canon side.
- **`lechefTools.test.ts`** — the ask-path pin ("a fact with no entry for the allergen asks instead of clearing") used chicken breast × wheat. After the apply no fact lacks an allergen entry anywhere (every review carries all ten tokens, and all 434 facts were reviewed); chicken breast × wheat is now reviewed free. The fail-closed ask path that survives in the canon is the reviewed unknown — the test now pins caramel colour × wheat (commonly corn, but wheat or barley malt sources exist depending on the manufacturer; reviewed unknown with reference evidence), same assertion, same finding-1 intent.

## How I checked it (commands and results)

All from `backend/gemini-agent` on this branch's head:

- `bun run src/run/apply-facts-review.ts` → `applied: 434, unchanged: 0, refused: none` on the pre-apply canon; on the applied canon → `applied: 0, unchanged: 434` and no write (idempotence, byte for byte).
- `bun test src/__tests__/lechef/factsReviewBandA.test.ts …BandB …BandC …BandD …BandE …factsReviewApplied …missingAllergenKeys …catalogFacts` → **55 pass, 0 fail** (19,544 expect() calls).
- `bun test` (full backend suite) → **427 pass, 0 fail** across 35 files (27,862 expect() calls).
- `bun run check` (tsc --noEmit) → clean.
- `bun run src/run/confirmation-rate.ts` → the table above; it re-derives collisions/refusals by dry-running the apply script against the before snapshot (`applied 434, unchanged 0, refused 0`, nothing written).
- Pre-apply green-check for the band-C/D diagnosis: `git checkout <apply-commit>^ -- …/facts.json` + rerun of both band test files → 0 fail; restored the applied canon afterwards and re-ran the apply (0 applied, 434 unchanged).

## What I couldn't check

- Nothing in this packet touches Swift/iOS, and there is no Xcode here: the diff is backend/evaluation data and tests only. The repository's hosted macOS CI runs on this PR and covers the iOS side; nothing was built locally for iOS.
- The review packets' judgements themselves (evidence quality per verdict) are out of scope here — this packet transfers reviewed states mechanically and refuses on drift.

## What I assumed

- The band tests' "stays green after the apply packet" intent outweighs their pre-apply-only assertions; the repairs above are the minimal ones that keep each test's protective intent (never-add-an-ask, contains/unknown/free anchors, fail-closed asks) while holding on an applied canon. Verified bands A, B and E pass unmodified with the aligned helper.
- "All (ingredient, allergen) restrictions" is measured over the canon's ten tokens × 434 facts; mustard is excluded because the canon has no mustard token and `allergens.ts` pins mustard to ask-zero by design.
- The pre-apply canon is committed as a snapshot (`evaluation/lechef-facts/before-facts.json`, 1.4 MB) so the before-numbers stay reproducible; its provenance (the apply commit's parent) is recorded in the report.

🔗 [Obvious Project](https://app.obvious.ai/p/fridgeluck-GmL1ONwZ) · 🧵 [Obvious Thread](https://app.obvious.ai/p/fridgeluck-GmL1ONwZ?thread=th_KY3MPujg) · 🔀 [Obvious PR Artifact](https://app.obvious.ai/link/pr-artifact/fridgeluck-apply-the-five-lechef-fact-review-bands-task:todo_F70vO9wN)
