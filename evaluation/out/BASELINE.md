# BASELINE — full scorecard run at the joined runner head

**Date:** 2026-10-11 · **Git head:** `80c4f1de223dc2c42ef4e0f444fbb4347377118a` (short `80c4f1de223d`, branch `eval/scorecard-runner`) · **Run id:** `r-20261011T233416Z-9da0d87e` (started 2026-10-11T23:34:16Z) · **Toolchain:** python 3.13.14, linux, Swift 6.4.

Produced by `python3 evaluation/run.py --all` from a fresh clone with a completely clean working tree (`git status --porcelain` empty immediately before the run; the scorecard header binds run id + git SHA with **no dirty flag**). Immediately before it, `python3 evaluation/run.py --self-test` exited 0 — 24/24 runner cases, with per-suite planted-failure batteries: pantry-truth 7/7, recipes 13/13 + controls 1/1, ui-polish 5/5, journeys 6/6. The harness is sound; the failures below are the product's honest baseline.

**Totals: 1 pass · 4 fail · 9 not-run.**

## Per-suite table

| Suite | id | status | key values |
| --- | --- | --- | --- |
| A. Pantry truth | `pantry-truth` | run (native, 13.6s) — 3 fail, 1 pass | stock counted twice **37** (bar == 0); sufficient claimed without quantity evidence **209** (bar == 0); fit-line text correct **55 / 200** (bar == 200); plan battery rows present **3/3** pass |
| B. Learning | `learning` | not-run | suite not yet delivered by `fl-learning-lab-f1` (no `evaluation/suites/learning/`) |
| C. Recipe corpus quality and rights | `recipes` | run — 1 fail, 4 not-run | rights-clear recipes **0** of 166 (bar >= 400, fail); remaining metrics not-run, fail-closed: the scored corpus is quarantined outright |
| D. LeChef | `lechef` | not-run | suite not yet delivered by `fl-lechef-f1` (no `evaluation/suites/lechef/`) |
| E. Community | `community` | not-run | suite not yet delivered by `fl-community-f1` (no `evaluation/suites/community/`) |
| F. UI polish | `ui-polish` | not-run | committed macos results refused (macos-import rule): imported results carry no git.sha |
| G. Journeys | `journeys` | not-run | committed macos results refused (macos-import rule): imported results carry no git.sha |

## Suite C — the honest bundled-baseline fail

With no `data/recipes/corpus.jsonl` on this tree, suite C scores the bundled catalog `apps/ios/Resources/data.json` as its baseline input (166 recipes, 50 ingredients, 12 tags). The rights metric fails honestly: **0 rights-clear; 166 quarantined (fail-closed)** — no per-recipe rights evidence exists in the bundled data (per-recipe manifest validation via `rights.record_status`; every needed permission must be affirmative). The other four metrics (food-safety linter pass, quantity-evidence lines, unchecked allergen/diet claims, cuisine/time-band coverage) report **not-run** with the fail-closed reason: no rights-clear recipes to score.

This is the expected, correct behavior, not a harness defect: the bundled catalog was never rights-cleared. For suite C to pass, the corpus deliverable must land at `data/recipes/` — the recipe corpus and its per-recipe rights manifests (open PRs #113 and #107) — and clear the bars: >= 400 rights-clear recipes, 100% linter pass, >= 95% quantity-evidence lines, 0 unchecked allergen/diet claims, 100% declared cuisine/time-band coverage.

## Suite A — true product failures (harness sound)

Suite A ran natively on Linux (Swift 6.4, 13.6s) and its self-test battery caught 7/7 planted failures, so the three failing metrics are genuine product signals for later work to fix, recorded here without chasing:

1. **Stock counted twice: 37** (bar == 0) — the plan battery double-counts pantry stock in 37 cases.
2. **Sufficient claimed without quantity evidence: 209** (bar == 0) — across the 200-pair line audit, 209 lines claim sufficiency without quantity evidence.
3. **Fit-line text correct: 55/200** (bar == 200) — only 55 of 200 audited fit lines render correct text.

The completeness row passes (plan battery rows present 3/3, PLAN.md line 49), confirming the battery itself is intact. These numbers are the product baseline later rounds improve.

## Pending and blocked suites

- **B/D/E are pending on their owner PRs**, not failures: learning → `fl-learning-lab-f1` (PR #115), LeChef → `fl-lechef-f1` (PR #101), community → `fl-community-f1` (PR #104). Each lands `evaluation/suites/<id>/` per the file contract in `evaluation/SCORECARD.md`.
- **F/G are blocked on macOS import provenance.** The macos-import rule (SCORECARD.md) refuses imported results without the producing run's full git SHA. A real macOS CI run at this joined head can later be imported **only if** it carries `git.sha` + run provenance.

## Canonical-source availability gaps (as of this tree)

- **`data/recipes` absent** — the `data/` directory does not exist on this branch; suite C falls back to the bundled catalog as scored input.
- **FLIngredientFacts** is a seeded skeleton on branch `overhaul/ingredient-facts` (seed commit `5597db7` "chore(ingredient-facts): seed package, dataset and audit skeletons"), README-only at that pin. No `FLIngredientFacts` package exists on this tree.
- **Food-safety rulebook** is used by suite C as a pinned snapshot: `evaluation/suites/recipes/canon/rules.json`, verbatim from `overhaul/food-safety-canon` @ `2e03467d3b0996d81bde3b9c6f3f80007b9d54ba` (see `canon/PROVENANCE.md`). `data/food-safety/` is not yet merged on this tree; the live canon branch (PR #126) is at `f515be7`.

## UNVERIFIED-NATIVE list

Nothing in this run exercised the following; they remain unverified natively:

- the executable **FLFoodSafety Swift linter** (`packages/FLFoodSafety` on the canon branch — absent on this tree; suite C lints via its Python port against the pinned snapshot),
- **iOS rendering** (no native iOS run at this head),
- **macOS suites F/G** (imported results lack provenance; no native macOS run at this head).

---

*This file is the reference later rounds diff against.* Reproduce with a clean tree: `python3 evaluation/run.py --self-test && python3 evaluation/run.py --all`.
