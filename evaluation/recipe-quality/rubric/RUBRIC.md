# Recipe-quality rubric — a cook reads the recipe

Status: working rubric for the burst11 catalog audit (`packet burst11-fridgeluck-recipe-rubric`,
base `alpha` @ ef236fcd). Scope: every corpus recipe **outside** the amounts set (171
recipes with a non-staple unknown-amount line are burst11 amounts-a/b's scope, not ours).

The pipeline's gates already check rights, food-safety wording and nutrition arithmetic.
Nothing checks whether a recipe makes sense to *cook*, so this rubric is scored the way a
cook reads: could I shop for this, cook it tonight, and want to eat it again? Seven criteria,
each 0–2. Max 14. Mechanical criteria (marked **[M]**) are checked by `audit.py` over every
in-scope recipe; the rest are judged by hand on a seeded sample.

---

## C1 — Lines match the title and the steps **[M]**

Every ingredient line earns its place: the title or some step names it. And the reverse:
nothing a step tells the cook to use is missing from the line list.

| Score | Anchor |
|---|---|
| 2 | Every line is named in a step (or the title), and every food a step names has a line. |
| 1 | A staple/garnish line is never named in any step, but the cook cannot be misled: nothing a step names lacks a line. |
| 0 | A step tells the cook to use a food no line contains (e.g. rcp-000167 tops with sliced banana; no banana line), or a headline ingredient from the title has no line (e.g. a "Maple Oatmeal" with neither maple nor the titled spice). |

Mechanical forms: *title-token coverage* (a title token no line's name/alias covers —
rough, has false positives like "butter" in "butter bean"), *step-names-missing-food*
(a step token that is a known ingredient alias with no line), and *unused lines* (a line
no step's `uses` references — cook mode cannot show it on any step).

## C2 — Amounts are plausible for the servings **[M]**

Read the grams as a cook: would this dish feed N people, not N banquet tables? Anchored on
per-serving energy measured from the vocabulary per-100g rows.

| Score | Anchor |
|---|---|
| 2 | Amounts read like a real recipe at the stated servings; per-serving kcal within 150–1300. |
| 1 | Individually plausible but one amount is clearly mis-scaled for the dish (≈2× a normal quantity), or per-serving kcal 1300–1526. |
| 0 | An amount is wrong in kind (a headline ingredient missing, a unit mismatch like 2 cups of oil) or per-serving kcal > 1526 / < 150. |

## C3 — Step order: prep before heat, preheat before bake, rest after meat

| Score | Anchor |
|---|---|
| 2 | Prep precedes any heat applied to the same ingredient; any oven preheat precedes the bake/roast; cooked meat gets a rest (or a rest is genuinely unnecessary, e.g. ground meat crumbled into sauce). |
| 1 | One ordering slip that does not change the outcome: preheat stated mid-recipe but still before the bake; rest implied but not stated after a quick sear. |
| 0 | Heat before prep of the same ingredient ("fry the onion" as step 1, "dice the onion" as step 2), a bake/roast before any preheat, or a whole-cut roast with no rest mention at all. |

## C4 — Doneness stated as the corpus's FSIS thermometer checks **[M]**

Animal protein must be done by thermometer (the corpus safety block), never by colour or
time alone. The corpus gate refuses under-cover recipes at compile time, so a score below 2
here is about wording a cook actually reads, not missing checks.

| Score | Anchor |
|---|---|
| 2 | Every FSIS class in the lines is covered by a safety block, and the step text asks for the thermometer rather than a colour. |
| 1 | Coverage is present but the wording leans on visual cues beside the thermometer ("cook until no longer pink, 165 °F on a thermometer"). |
| 0 | Doneness by colour/time with no thermometer on an animal-protein step, or a check below the FSIS minimum (should be impossible to compile — if seen, flag to the pipeline). |

Mechanical form: a phrase scan (`no longer pink`, `juices run clear`, `until golden*` on
flesh/egg steps) plus coverage from `food_safety.required_classes` / `uncovered_classes`.

## C5 — Sodium per serving against the FDA 2,300 mg Daily Value **[M]**

| Score | Anchor |
|---|---|
| 2 | ≤ 1150 mg per serving (≤ 50% of the Daily Value). |
| 1 | 1151–2300 mg: fits inside the DV but spends most of it on one dish. |
| 0 | > 2300 mg per serving: one serving exceeds the entire Daily Value. |

## C6 — Flavour balance (salt, acid, fat, heat) for the cuisine

| Score | Anchor |
|---|---|
| 2 | Salt + acid + fat all present (heat where the cuisine expects it), or a deliberate, honest absence where the dish type does not want it (overnight oats need no acid). |
| 1 | Two of the four axes present; the dish reads flat but coherent for its cuisine. |
| 0 | One axis only (e.g. a taco filling with salt but no acid, fat or heat), or a clash (a bright vinegar salsa built with no fat to carry it). |

## C7 — The time claim fits the steps **[M]**

`minutes` is the promise the app shows. The steps' own timers must fit inside it, with
sensible room for untimed prep.

| Score | Anchor |
|---|---|
| 2 | Sum of step timers ≤ `minutes`, leaving plausible room for prep. |
| 1 | Sum of step timers exceeds `minutes` by ≤ 25% (tight but a confident cook could just about make it). |
| 0 | Sum of step timers exceeds `minutes` by > 25% (a "15-minute" recipe with a 20-minute simmer), or a cook/reheat/chill overnight step contradicts the band. |

---

## How the scores are used

- **Mechanical sweep [M]:** `audit.py` computes C1's three forms, C2's kcal band, C4's
  phrase/coverage scan, C5, and C7's timer sum over *every* in-scope recipe. Counts land in
  `audit-results.json`.
- **Hand-scored sample:** `random.Random(20261016)` over the sorted in-scope corpus ids,
  60 recipes, recorded in `sample-scores.json` with a one-line reason per score.
- **Fixes:** the real C1/C2 defects and the lowest-scoring sample recipes are corrected via
  `data/recipes/fixes/rubric.json` (≤ 25 recipes). Amount and step-text fixes keep the
  rights pin; any fix that changes a title or ingredient name sets `changes_rights_pin` and
  says why.
- **Compiler changes are out of scope here** but `report.md` names the defect classes that
  need one (e.g. `uses` linkage in `compile_bundle.step_uses`).
