# FridgeLuck overhaul scorecard

Generated 2026-10-12T04:15:06Z · run `r-20261012T041423Z-716a5d80` (started 2026-10-12T04:14:23Z) · git `2eedb0a22c7e` (eval/scorecard-runner) · python 3.13.14 · linux

**1 pass · 4 fail · 9 not-run** — a suite whose inputs are missing reports not-run, never pass.

## A. Pantry truth `pantry-truth` (run, 42.4s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Stock counted twice (plan battery) | 37 | — | == 0 | fail |  |
| Sufficient claimed without quantity evidence (line audit over 200 pairs) | 209 | — | == 0 | fail |  |
| Fit-line text correct (200-pair audit) | 55 | — | == 200 | fail |  |
| Plan battery rows present (PLAN.md line 49) | 3 | — | == 3 | pass |  |

## B. Learning `learning` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| B. Learning | — | — | — | not-run | suite not yet delivered by fl-learning-lab-f1 (no evaluation/suites/learning/) |

## C. Recipe corpus quality and rights `recipes` (run, 0.7s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Rights-clear recipes (complete per-recipe manifest evidence) | 0 | — | >= 400 | fail |  |
| Food-safety linter pass (% of corpus) | — | — | == 100 | not-run | no rights-clear recipes to score: the scored corpus is quarantined outright (rights metric shows the reason) |
| Lines resolved with quantity evidence (%) | — | — | >= 95 | not-run | no rights-clear recipes to score: the scored corpus is quarantined outright (rights metric shows the reason) |
| Unchecked allergen/diet claims (after linter strip) | — | — | == 0 | not-run | no rights-clear recipes to score: the scored corpus is quarantined outright (rights metric shows the reason) |
| Declared cuisines and time bands represented (%) | — | — | == 100 | not-run | no rights-clear recipes to score: the scored corpus is quarantined outright (rights metric shows the reason) |

## D. LeChef `lechef` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| D. LeChef | — | — | — | not-run | suite not yet delivered by fl-lechef-f1 (no evaluation/suites/lechef/) |

## E. Community `community` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| E. Community | — | — | — | not-run | suite not yet delivered by fl-community-f1 (no evaluation/suites/community/) |

## F. UI polish `ui-polish` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| F. UI polish | — | — | — | not-run | committed results refused (macos-import rule): imported results carry no git.sha — the macos-import rule (SCORECARD.md) requires the producing run's full SHA |

## G. Journeys `journeys` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| G. Journeys | — | — | — | not-run | committed results refused (macos-import rule): imported results carry no git.sha — the macos-import rule (SCORECARD.md) requires the producing run's full SHA |

*Bars are the lead's choices, owned by `evaluation/registry.json` from PLAN.md ("The scorecard"); a suite cannot add, drop or re-bar a metric, and bars that require intervals apply to the interval's low end. Suite results must carry this run's identity as their producer binding (passed to the suite, verified by the runner, never overwritten); imported native results keep their producing CI run's identity, re-verified against GitHub's REST API; anything without a verifiable binding reports not-run, never pass (head 2eedb0a22c7e). Suites B, D and E are delivered by the learning, LeChef and community tasks (see SCORECARD.md for their file contract).*
