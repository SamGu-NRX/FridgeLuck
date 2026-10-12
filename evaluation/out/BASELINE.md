# BASELINE — full scorecard run at the joined runner head (r3)

**Date:** 2026-10-12 · **Git head:** `f5fe7f1826b7d39d9ef42a7414f137b24811cdee` (short `f5fe7f1826b7`, branch `eval/scorecard-runner`) · **Run id:** `r-20261012T030131Z-83c68ad8` (started 2026-10-12T03:01:31Z) · **Toolchain:** python 3.13.14, linux, Swift 6.4.

Produced by `python3 evaluation/run.py --all` from a fresh clone with a completely clean working tree at `f5fe7f1` (`git status --porcelain` empty immediately before the run; the scorecard header binds run id + git SHA with **no dirty flag**). `f5fe7f1` is the join of the r3 review-fix parts (A safety lint, B allergen facts, C corpus/quantity evidence, D runner identity/provenance, E suite-A battery completeness), where suites A and C now stamp the `FL_RUN_BINDING` producer binding the runner hands them (SCORECARD.md §3/§4): the runner verifies the emitted binding and refuses unbound or stale results to not-run — it never overwrites one. Immediately before the run, `python3 evaluation/run.py --self-test` exited 0 — **36/36 runner cases**, with per-suite planted-failure batteries: pantry-truth 7/7, recipes 16/16 + controls 2/2 + part-A safety-lint battery 4/4, ui-polish 5/5, journeys 6/6; the full five-command battery was re-run green (all exit 0) on the committed record tree. The harness is sound; the failures below are the product's honest baseline.

**Totals: 1 pass · 4 fail · 9 not-run.** (Unchanged from the r2 baseline at `80c4f1de`: the r3 parts hardened provenance and harness conformance, not the measured product values.)

## Per-suite table

| Suite | id | status | key values |
| --- | --- | --- | --- |
| A. Pantry truth | `pantry-truth` | run (native, 82.3s, producer-bound) — 3 fail, 1 pass | stock counted twice **37** (bar == 0); sufficient claimed without quantity evidence **209** (bar == 0); fit-line text correct **55 / 200** (bar == 200); plan battery rows present **3/3** pass |
| B. Learning | `learning` | not-run | suite not yet delivered by `fl-learning-lab-f1` (no `evaluation/suites/learning/`) |
| C. Recipe corpus quality and rights | `recipes` | run (producer-bound) — 1 fail, 4 not-run | rights-clear recipes **0** of 166 (bar >= 400, fail); remaining metrics not-run, fail-closed: the scored corpus is quarantined outright |
| D. LeChef | `lechef` | not-run | suite not yet delivered by `fl-lechef-f1` (no `evaluation/suites/lechef/`) |
| E. Community | `community` | not-run | suite not yet delivered by `fl-community-f1` (no `evaluation/suites/community/`) |
| F. UI polish | `ui-polish` | not-run | committed macos results refused (macos-import rule): imported results carry no git.sha |
| G. Journeys | `journeys` | not-run | committed macos results refused (macos-import rule): imported results carry no git.sha |

Both `evaluation/out/pantry-truth/results.json` and `evaluation/out/recipes/results.json` carry the verified producer binding of this run (`run_id` `r-20261012T030131Z-83c68ad8`, `git_sha` `f5fe7f1…`, `started_at` `2026-10-12T03:01:31Z`).

## Suite C — the honest bundled-baseline fail

With no `data/recipes/corpus.jsonl` on this tree (no `data/` directory at all), suite C scores the bundled catalog `apps/ios/Resources/data.json` as its baseline input (166 recipes). The rights metric fails honestly: **0 rights-clear; 166 quarantined (fail-closed)** — no per-recipe rights evidence exists in the bundled data (per-recipe manifest validation via `rights.record_status`; every needed permission must be affirmative; SPEC 3.5: unknown rights means quarantine). The other four metrics (food-safety linter pass, quantity-evidence lines, unchecked allergen/diet claims, cuisine/time-band coverage) report **not-run** with the fail-closed reason: no rights-clear recipes to score.

This is the expected, correct behavior, not a harness defect: the bundled catalog was never rights-cleared. For suite C to pass, the corpus deliverable must land at `data/recipes/` — the recipe corpus and its per-recipe rights manifests (open PRs #113 and #107) — and clear the bars: >= 400 rights-clear recipes, 100% linter pass, >= 95% quantity-evidence lines, 0 unchecked allergen/diet claims, 100% declared cuisine/time-band coverage.

## Suite A — true product failures (harness sound)

Suite A ran natively on Linux (Swift 6.4, 82.3s) and its self-test battery caught 7/7 planted failures, so the three failing metrics are genuine product signals for later work to fix, recorded here without chasing:

1. **Stock counted twice: 37** (bar == 0) — the plan battery double-counts pantry stock in 37 cases.
2. **Sufficient claimed without quantity evidence: 209** (bar == 0) — across the 200-pair line audit, 209 lines claim sufficiency without quantity evidence.
3. **Fit-line text correct: 55/200** (bar == 200) — only 55 of 200 audited fit lines render correct text.

The completeness row passes (plan battery rows present 3/3, PLAN.md line 49), confirming the battery itself is intact. The values are identical to the r2 baseline — the r3 parts changed the evaluation harness, not these product behaviors — and remain the product baseline later rounds improve.

## Pending and blocked suites

- **B/D/E are pending on their owner PRs**, not failures: learning → `fl-learning-lab-f1` (PR #115), LeChef → `fl-lechef-f1` (PR #101), community → `fl-community-f1` (PR #104). Each lands `evaluation/suites/<id>/` per the file contract in `evaluation/SCORECARD.md`, and its runs must stamp the `FL_RUN_BINDING` producer binding their runner passes (the same rule suites A and C now follow).
- **F/G are blocked on macOS import provenance.** The macos-import rule (SCORECARD.md) refuses imported results without the producing run's provenance: the payload must carry the producing run's full `git.sha` (equal to the head being regenerated), `run_url`, `run.run_id` and `run.started_at`, and the runner re-verifies the GitHub run through the REST API before admitting it. A real macOS CI run produced at a given head can be imported only into a scorecard regenerated at that same head; anything without a verifiable binding reports not-run, never pass.

## Canonical-source availability gaps (as of this tree)

- **`data/recipes` absent** — the `data/` directory does not exist on this branch; suite C falls back to the bundled catalog as scored input.
- **FLIngredientFacts absent on this tree** — no `data/ingredient-facts/` and no pinned snapshot; allergen/diet claims fail closed (held, never cleared) while facts are unavailable (exercised by `evaluation/suites/recipes/test_allergen_facts.py` case B4). The facts deliverable (PR #127, branch `overhaul/ingredient-facts`) owns that source.
- **Food-safety rulebook** is used by suite C as a pinned snapshot: `evaluation/suites/recipes/canon/rules.json`, verbatim from `overhaul/food-safety-canon` @ `2e03467d3b0996d81bde3b9c6f3f80007b9d54ba` (see `canon/PROVENANCE.md`). `data/food-safety/` is not yet merged on this tree; the live canon branch (PR #126) is owned by `fl-root-food-safety-f1`.

## UNVERIFIED-NATIVE list

Nothing in this run exercised the following; they remain unverified natively:

- the executable **FLFoodSafety Swift linter** (`packages/FLFoodSafety` on the canon branch — absent on this tree; suite C lints via its Python port against the pinned snapshot),
- **iOS rendering** (no native iOS run at this head),
- **macOS suites F/G** (imported results lack provenance; no native macOS run at this head).

---

*This file is the reference later rounds diff against.* Reproduce with a clean tree: `python3 evaluation/run.py --self-test && python3 evaluation/run.py --all`.
