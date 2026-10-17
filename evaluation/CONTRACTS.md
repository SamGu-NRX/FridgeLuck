# Contracts: suites and their canonical sources

One index binding every suite in `evaluation/suites/` to the canonical
sources it must consume — the rulebook, datasets, schemas and identifier
registries that decide what the suites measure. A suite consumes a canonical
source as recorded here; it never reimplements, copies, or forks it, and it
never maintains a competing registry of its own.

Revisions below were fetched from origin and verified on **2026-10-11**;
this file records the heads observed that day. Re-verify a pointer before
relying on it: a moved branch is re-fetched and this index updated, not
assumed.

## The availability rule (binding)

**When a canonical source is absent from the scored tree — branch not
merged, file missing, package not built or not loaded — every dependent
check fails closed with a reason naming the absent source: it never
passes and is never silently skipped.**

This is SCORECARD.md's one rule ("a suite whose inputs are missing reports
`not-run` with the reason, never pass") applied to canonical sources: an
absent canon is a missing input. The runner contract enforces the same
fail-closed rule for every suite (a crash, timeout or malformed emission is
`not-run` with the reason); each suite applies it to its own sources the
same way — suite A additionally fails its battery closed when a required
PLAN.md row goes missing (`suites/pantry-truth/suite.py`,
`enforce_battery_completeness`).

## Shared contracts (every suite)

| Contract | Where |
| --- | --- |
| results.json schema, derived status, bars | `evaluation/SCORECARD.md` (this branch) |
| identity spine (suite id, letter, title, owner) | `evaluation/registry.json` + `evaluation/suites/<id>/suite.json` |
| what each suite runs, and its pass bars | PLAN.md, "The scorecard (evals first)", lines 49–55 on `docs/spec-overhaul-20261011` (head `2e33b5a`, fetched 2026-10-11; SCORECARD.md pins revision 2 of the spec) |

## A. Pantry truth (`pantry-truth`, PLAN.md line 49)

| Canonical source | Where it lives | Revision (verified) | What depends on it |
| --- | --- | --- | --- |
| SPEC §3.2 pantry truth | `docs/spec/overhaul-20261011/SPEC.md` on branch `docs/spec-overhaul-20261011` | head `2e33b5a`, 2026-10-11 | the ledger model and pair verdicts (`fit_oracle.py`): sufficiency counts, swap coverage, no overclaim, no percentage |
| Production corpus of record | `apps/ios/Resources/data.json` on the scored tree | SHA256 recorded per run in results.json `grounding` | the 200 audited (pantry, recipe) pairs and the plan scenarios are generated against it |
| USDA curated catalog (auxiliary) | `scripts/data/catalog/usda_curated_ingredients.json` on the scored tree | recorded per run; an absent catalog is recorded as absent and does not block | name-based grounding coverage only |

Suite A has no LLM arm (PLAN.md line 49: seeded property tests plus the
200-pair audit), so no model or endpoint source is bound here.

## B. Learning (`learning`, PLAN.md line 50)

Not yet delivered. No canonical source outside the suite's own frozen
simulator fixtures is recorded yet; its bars are PLAN.md line 50. Its owner
task records its sources in this index when the suite lands.

## C. Recipes (`recipes`, PLAN.md line 51)

| Canonical source | Where it lives | Revision (verified) | What depends on it |
| --- | --- | --- | --- |
| Corpus report of record | `data/recipes/REPORT.md` on branch `fleet/fl-recipe-corpus-v2` (PR #113); the schema contract it cites is `data/recipes/SCHEMA.md` | head `4b6e163`, 2026-10-11 | corpus validator rows, rights records, quantity-evidence coverage (≥ 95%) |
| Food-safety rulebook + linter | `packages/FLFoodSafety` (`Rulebook.swift`, `StepLinter.swift`) and `data/food-safety/` (`rules.json`, `SCHEMA.md`, `SHELF-LIFE.md`, `COPY.md`) on branch `overhaul/food-safety-canon` (PR #126) | head `a23439c`, 2026-10-11 | "100% pass the linter" |
| Allergen/diet facts | `FLIngredientFacts`, branch `overhaul/ingredient-facts` | branch pushed at head `5597db7`, 2026-10-11, **as a seeded skeleton** (package README only — the dataset and audit are not delivered yet) | "0 unchecked allergen or diet claims" — dependent checks fail closed until the facts source actually lands |

## D. LeChef (`lechef`, PLAN.md line 52)

| Canonical source | Where it lives | Revision (verified) | What depends on it |
| --- | --- | --- | --- |
| Food-safety rulebook + linter | same canon as suite C: `packages/FLFoodSafety` + `data/food-safety/` on `overhaul/food-safety-canon` (PR #126) | head `a23439c`, 2026-10-11 | "0 food-safety violations"; timers prompt checks and never issue safety verdicts |

## E. Community (`community`, PLAN.md line 53)

| Canonical source | Where it lives | Revision (verified) | What depends on it |
| --- | --- | --- | --- |
| Canonical safety and allergen sources | the rulebook/linter (PR #126) and `FLIngredientFacts` (branch `overhaul/ingredient-facts`) | as rows C2/C3 above | recipe publication fails closed when either source is absent or not loaded — a recipe never publishes on unknown ingredient properties |

## F. UI polish / G. Journeys (PLAN.md lines 54–55)

| Canonical source | Where it lives | Revision (verified) | What depends on it |
| --- | --- | --- | --- |
| Accessibility identifiers | **`docs/screens/a11y-identifiers.md` on branch `overhaul/design-system` (PR #96) — THE canonical contract for both suites** | head `2289586`, fetched 2026-10-11 | every identifier assertion in suites F and G |

This file deliberately defines **no identifier list of its own**. The doc
on that branch is the only registry of accessibility identifiers; suites F
and G reference it by path and revision, exactly as recorded above. When it
is absent from the scored tree, identifier checks fail closed with a reason
naming the missing document — never pass, never against a local copy.

## Keeping this index true

When a canonical source moves — a branch head advances, a skeleton delivers
its dataset, a PR merges — the task that starts consuming the new revision
updates this index in the same change. A suite scored against a source whose
recorded revision no longer matches the scored tree is, per the availability
rule, a suite whose inputs are missing: it fails closed with the reason.
