# Review-new: a cook's read of the 60 newest recipes

Packet `burst14-fridgeluck-review-new-recipes` · base alpha `af85600867bc9f8d6a68963205e9d502c2dc3df7` · 2026-10-16 · reviewed by the Burst 14 cook-review agent.

## Scope

The 60 recipes the October 16 catalog rebuild (#210) shipped from the two originals packets: `rcp-000935..rcp-000964` (30 breakfasts, `data/recipe-sources/breakfast-2026-10`, #201) and `rcp-000965..rcp-000994` (30 pantry lunches/dinners, `data/recipe-sources/pantry-2026-10`, #203). They had passed every mechanical gate; nobody had read them the way a cook reads a recipe — can I put this in front of a home cook, at the stated time, with the stated equipment, and land the dish the title promises?

**Method.** `review.py` lists the band reproducibly from the base corpus, recompiles all 60 records in memory with the repository's own compiler, merges my hand review (verdict + findings per recipe), and emits `findings.json`. Nutrition rows are judged with the four kcal rows that burst14-fridgeluck-kcal-pins (#205) replaces this wave, applied in memory. Nothing is compiled to disk; the corpus is untouched by this packet.

**Verdicts: 58 cookable as written · 2 need a fix · 0 should be cut.**

## The two fixes (data/recipes/fixes/review-new.json)

Both are the same defect class: a step states a time and, in the same sentence, a thermometer endpoint the time cannot reach. One correct answer each, so they go in the fix file.

| Recipe | Defect | Fix |
|---|---|---|
| rcp-000940 (bánh xèo, fl-original-0774) | "Fry the shrimp … over high heat for 1 minute, until … 145 °F." A 150 g batch of raw shrimp at high heat needs 2–3 minutes to reach 145 °F; 1 minute serves undercooked shrimp with a false reading promised. | Step 3 now reads "2 to 3 minutes, until an instant-read thermometer reads 145 °F in the thickest shrimp." |
| rcp-000956 (chili avocado toast with poached eggs, fl-original-0790) | "Poach the eggs … for 3 minutes, until … 160 °F in the yolk." A yolk at a bare simmer crosses 160 °F around 4–5 minutes; 3 minutes leaves it near 140–145 °F. | Step 3 now reads "4 to 5 minutes, until an instant-read thermometer reads 160 °F in the yolk." |

No shape, title, ingredient-name, or rights changes; `changes_rights_pin` unset; `before_sha256` pinned to the base corpus lines. `data/recipes/fixes/test_review_new.py` (14 tests) covers the packet; all pass, including `validate_corpus.py` exit 0 over the patched corpus.

## Findings by class

**1. The FSIS gate forces nonsense thermometer wording in 6 recipes.** The catalog gate requires a thermometer sentence on raw-egg and raw-fish steps, which is right for seared salmon (rcp-000939 reads perfectly) but wrong for formats a probe cannot meaningfully read: egg ribbons in swirling soup (000966), the center of a pancake (000953), a thin omelette (000942), a poached yolk (000956), and canned tuna — commercially sterilised, so the 145 °F check is theater — in 000979/000986/000987. The wording survives the gates, but it tells cooks to do things they won't do. Suggested for the checkers: exempt canned fish and soften to a doneness cue where a probe reading is structurally impractical.

**2. The corrupt `water` vocabulary row inflates sodium and kcal wherever water has a gram line.** The shipped row (fdc 170132: 20 kcal, 2.08 g protein, 358 mg sodium per 100 g) is not water. rcp-000952 shows 650 mg/serving where ~626 mg is phantom water sodium; rcp-000958 shows 792.5 with ~534 phantom (real custard ≈ 260 mg); rcp-000957 shows 295 with ~215 phantom. #205 owns the row; this packet documents the blast radius so the nutrition-change audit doesn't misread the deltas.Recipes with un-grammed water lines ("5 cups", "3 tablespoons") dodge the corruption by accident — which argues for fixing the row rather than the convention.

**3. Cooked-vs-dry rows and cup conversions disagree about rice.** Two separate problems. (a) rcp-000959's glutinous rice is rinsed and simmered (dry measure) but the `glutinous_rice` row is a cooked-rice row, so the compiled 316 kcal/serving understates the real ~460 — #205's four rows don't cover `glutinous_rice`. (b) The `conversion_ref` on rice cups pins the FNDDS *cooked*-rice cup (158 g) on lines the steps treat as dry ("rinse the rice"), understating rice mass ~15% across the pantry packet's rice lines (000967 checked directly). And rcp-000965's "2.5 cup rice" is only cookable as day-old *cooked* rice in the promised 20 minutes — flag it so #205 treats that line as a cooked-rice line.

**4. Ingredient keys exist without per-100g rows, so kcal coverage is partial and the 150 kcal floor false-alarms.** `labneh` and `zaatar` (rcp-000946: compiled 118.8 kcal/serving, real ≈ 180–200), `flattened_rice` (000944), `callaloo_greens` (000951). The dishes are fine; the vocabulary is incomplete.

**5. The six-value cuisine taxonomy squeezes world cuisines.** West African plantain-and-egg skillet → `indian` (000963), Eastern European cottage-cheese bowl → `italian` (000964), buttered onion rice → `italian` (000967), oat porridge → `italian` twice (000990, 000991), chicken-corn-butter → `mexican` (000969). No one-correct value exists inside the taxonomy; if these matter, the taxonomy needs new values, not edits to these records.

**6. Step→ingredient linkage false-positives are a compiler artifact, not a cook problem.** "Serve over the warm rice," "blend everything," "the broth is lightly thickened" name foods in prose without using lines; roughly 43 of the 60 carry `unused-lines` flags that read fine to a cook. Worth teaching `step_uses` pronoun/generic references before the next audit drowns in them.

**7. Water has no staple convention.** Some recipes give water a gram line (and inherit the corrupt row), others say "5 cups of water" with no line and take a `missing_food` flag. Pick one convention; both exist today.

**8. Tight timer promises, individually noted in findings.json:** rcp-000945 (shakshuka, 25 min with zero prep room), rcp-000950 (200 g potato tender in 10), rcp-000980 (four dipped toasts in batches in 15), rcp-000966/000938 (tight but workable). rcp-000982 vs 000983 boil potatoes for an unstated size with different implied times — ambiguous rather than wrong, left as findings.

**9. Taste notes that need Sam's judgment, not a fix:** rcp-000936's forced hard-set yolk (the gate changes the dish); rcp-000948's timid 20 g harissa; rcp-000972's chana saag with no acid and the packet's no-oil design; rcp-000978's "brown the chicken in a dry nonstick pot … scraping the browned bits" — with no fat, nothing browns and there are no bits; rcp-000979's 2-minute coat-a-spoon sauce; rcp-000940's garbled assembly step 6 and its second, unreachable 145 °F check on re-warmed shrimp. None is a one-correct-answer defect; none went in the fix file.

**Ten worst recipes, worst first:** 000940, 000956, 000959, 000952, 000958, 000978, 000965, 000946, 000963, 000979.

## Assumptions and what I could not check

- **Shelf read.** No stove, no probes, no poached egg timed with a thermometer this session. The 4–5 minute poach and 2–3 minute shrimp times are standard cook knowledge and FSIS-consistent with each step's own endpoint, not instrumented measurements.
- **kcal/sodium numbers** use #205's four rows in memory; after #205 lands, the compiled values in findings.json should be regenerated and will shift for the 13 recipes touching those rows.
- **Active-time convention** assumed for rcp-000955's overnight chill against a 10-minute promise.
- **Verdict taxonomy** — "needs a fix" is reserved for one-correct-answer defects that fit the fix-file schema; every taste and taxonomy judgment stays in findings because no single correct edit exists.
- **Not run:** the repository's iOS test suite (nothing here touches Swift), the full bundle rebuild (owned by #205/#210), and any check that would need `validate_corpus` history changes — note for whoever applies this packet: `plan()` must treat already-applied packets (amounts-a, amounts-b, rubric) as history rather than refusing the whole directory on stale shas.

## Where everything lives

- Per-recipe verdicts, findings, mechanical flags, and compiled nutrition: `evaluation/recipe-quality/review-new/findings.json` (regenerate with `python3 evaluation/recipe-quality/review-new/review.py`).
- Fix file: `data/recipes/fixes/review-new.json`. Tests: `data/recipes/fixes/test_review_new.py`.
- Fix-packet application contract: `data/recipes/fixes/README.md`.
