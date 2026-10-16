# Legacy recipe audit — what misleads or slips past the safety screen

**Branch:** `obv/burst12-fridgeluck-legacy-audit` (base `alpha`)
**Scope:** all 166 legacy recipes in `apps/ios/Resources/data.json` (the original bundled corpus), checked line-by-line against the household safety boundary shipped by PR #204: the plan and its screens see ingredient **lines**; anything the **steps** name but the lines omit never reaches them.

**Verdict:** 128 of 166 recipes (77%) must be hidden. 110 hides are content bugs — a headline food with no matching line, or a diet tag the dish contradicts. The other 18 are already quarantined for rights. The worst offenders: 41 recipes carry a diet tag their own text contradicts — 18 "vegan" recipes name cheese, meat, fish, egg, honey, cream or yogurt in their title, steps or lines — and 38 hide a headline protein, grain or dairy item the plan can never supply (28 missing cheese, 23 missing chicken, 18 missing pasta).

## How each recipe was checked

One rule per failure mode; every hide reason carries evidence quoting the offending text. Regenerate with `python3 evaluation/legacy-recipe-audit/audit.py` → writes `data/recipes/legacy-audit.jsonl` (byte-identical across runs; tests pin this).

| # | Rule | Hides on | Kept findings |
|---|------|----------|---------------|
| a | **Missing headline.** A food family named in the title, or in steps for animal/gluten families, with no matching ingredient line (required *or* optional — the app renders both). | "Chicken madras" (id 53) has no chicken line; "Cavolo nero orecchiette" (43) cooks orecchiette and ricotta, ships oil + garlic only. | 162 |
| b | **Diet-tag contradiction.** vegan/vegetarian/low_carb/gluten_free tag vs the families present in title, steps or lines. | "Cod with… salsa" (61) tagged vegetarian+vegan; "Healthy gnocchi" (85) tagged vegan and low_carb. | 41 |
| c | **Implausible required mass.** < 150 g or > 2 kg required, per serving. | Review-only, not a hide. | 30 reviews |
| d | **Implausible sodium.** Modeled required-line sodium over the EFSA adult guidance level. | Review-only. Uses real sodium facts where present (id 6 verified 3629 mg, exceeding the level in both calculations); absent facts use the dry-equivalent approximation. | 4 reviews |
| e | **Third-party source.** BBC Good Food steps text bundled in the app. | Review-only — the rights audit (PR #204 packet, `data/recipes/quarantine.jsonl`) owns that call. | 141 reviews |
| f | **Rights quarantine.** Recipe id referenced by a `quarantine.jsonl` rights record (`fl-seed-0001..0025` → bundled ids 1–25). | Always hides. | 25 |
| g | **Dropped after hand-check.** Every (a)/(b) firing was reviewed against the full recipe text; 36 findings across 25 recipes were dropped as false positives with the reason recorded in the row's `dropped_false_positives` field and in the table's `DROPPED_FALSE_POSITIVES` entries. | — | 36 drops |

Matching is curated term families (cheese, chicken, pasta, noodle, …) with three structural guards, each added to kill an observed false-positive class:

- **Longest-match-wins with span blanking** — "butter beans" fires the legume family, never dairy "butter"; "coconut milk" never dairy "milk"; multi-signal phrases ("egg noodle" = egg + noodle) are explicit.
- **Plural variants** — "peanuts", "anchovies", "egg noodles" all match; recipes write plurals.
- **Generic-sibling suppression** — a salmon line satisfies a generic "fish" mention, chicken satisfies "meat", pine nuts satisfy "nuts"; the generic only flags when no specific sibling is present anywhere.

## What the hand-check changed

Every (a)/(b) firing was read against the full recipe text. 36 findings dropped in six classes (all recorded in `DROPPED_FALSE_POSITIVES` with the exact wording that triggered them):

1. **Serving suggestions** (10) — "serve with basmati rice / naan / flatbread / couscous / crusty bread" names a side, not a component (ids 50, 53, 100, 102, 117, 131, 135, 140, 156, 49). Naan already covered by the recipe's own bread line (42, 60, 135, 140, 42).
2. **Either/or alternatives in text** (4) — "serve on lettuce leaves **or** bread" (16), "honey **or** sugar" (141), "flour tortillas if that's what you have" (35), "some pasta or potatoes, **if you like**" (55).
3. **Tool names** (2) — "potato masher" is not a potato (48, 88).
4. **Negligible quantities** (1) — a 1-tbsp flour dusting does not break a low_carb tag (54); the missing-headline flour flag stays.
5. **Optional add-ins / toppings menus** (9) — id 154's BBC page ships a "Choose your toppings" menu (bacon, poached egg, feta, ciabatta, yogurt) that fired seven flags on an otherwise correctly-vegan one-pot; id 133's "if you're adding sausages to any portion".
6. **Non-ingredient text** (3) — "cauliflower **steaks**" is a cut, not beef (92; the bare `steak` term was removed from the beef family); "wrap up like a **cracker** in baking parchment" is a simile (163); id 105's note "some **nut butters** are thicker than others" is prose about an ingredient already on a line (mapped to the peanut family, satisfied).

Four recipes (49, 92, 102, 163) drop out of the hide list entirely and move to the review rows; the rest keep their genuine findings.

## The list

`data/recipes/legacy-audit.jsonl` — one row per hidden recipe: `legacy_id`, `title`, `verdict`, `reasons[]`, `evidence[]` (parallel array quoting the title/steps excerpt for each reason), `dropped_false_positives[]`. 128 rows; counts: (a) 162, (b) 41, (f) 25, plus (c) 30, (d) 4, (e) 141 review rows and (g) 36 drops.

Shape of what remains: cheese headlines missing on 28 recipes, chicken on 23, pasta on 18, noodles on 11; vegan contradicted on 18 recipes, low_carb on 16, vegetarian on 7. The BBC-imported block (ids 26–166) carries almost all of it — the 25 seed recipes are hidden on rights alone, and their content issues (id 2's milk-in-steps omelette, id 7/8/11/23/25 vegan tags on butter/cream/honey dishes) are noted in their rows too.

## Verification

- `python3 evaluation/legacy-recipe-audit/audit.py` → `recipes=166 hides=128 (a)162 (b)41 (c)30 (d)4 (e)141 (f)25 (g)36`, wrote `data/recipes/legacy-audit.jsonl`.
- `python3 -m pytest evaluation/legacy-recipe-audit/test_audit.py -q` → **28 passed** (15.3 s). Pins: phrase-over-inner-word matching, plural matching, generic-sibling suppression, title/steps missing-headline behavior, tag-contradiction behavior, the (c)/(d) bands, the drop mechanism on ids 15/48/92/105/154, quarantine mapping, and byte-stable regeneration whose output matches the committed JSONL.
- Hand-check: every (a)/(b) firing read against full recipe text across three passes (term fixes → plural fix + drop table → serve-with/tool/prose drops); verdicts diffed between passes and the final delta verified to match the intended drops exactly.
- Sodium math cross-checked against PR #196's required-only recompute convention (id 6: 3629 mg by both).

## Not verified / limitations

- **No Xcode here** — nothing iOS was built; this PR changes only bundled data + Python evaluation files. The JSONL is consumed by future evaluation tooling; nothing in the app reads it yet.
- Sodium (d) and mass (c) are review-only bands with judgment thresholds, not hard safety claims.
- (a) covers animal/gluten families in steps; non-animal, non-gluten step-only foods (e.g. a missing lemon) are not hides — they are plan shortfalls, not screen escapes.
- The quarantine mapping derives ids from `rights_record.origin` text ("bundled recipe id N"); an entry phrased differently would be missed — the test asserts all 25 current entries resolve.

## Assumptions

- Optional lines count as lines: the app renders them, so "if using" items satisfy (a). The boundary's hide semantics (PR #204) drop flagged *optional* lines but keep the recipe.
- "Serve with" sides are not components; preparation instructions ("dust the fish in flour", "toast the breadcrumbs") are.
- Fish sauce, chicken stock and similar derived foods count as their source family — a fish-allergic household following the steps gets fish even when no fish line exists.
