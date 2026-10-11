# FridgeLuck overhaul scorecard

Generated 2026-10-11T23:29:37Z · run `r-20261011T232923Z-827d154d` (started 2026-10-11T23:29:23Z) · git `33857f03836e` (eval/scorecard-runner) · python 3.13.14 · linux

**5 pass · 5 fail · 5 not-run** — a suite whose inputs are missing reports not-run, never pass.

## A. Pantry truth `pantry-truth` (run, 13.9s)

**registry mismatch:** results are missing 'letter' — required by the results.json schema (the suite's identity from its suite.json/registry entry)

**registry mismatch:** results are missing 'title' — required by the results.json schema (the suite's identity from its suite.json/registry entry)

**registry mismatch:** metric 'plan_battery_rows_present' (Plan battery rows present (PLAN.md line 49)) is missing from the suite results — the registry requires it; dropping a metric cannot hide a failing bar

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Stock counted twice (plan battery) | 37 | — | == 0 | fail |  |
| Sufficient claimed without quantity evidence (line audit over 200 pairs) | 209 | — | == 0 | fail |  |
| Fit-line text correct (200-pair audit) | 55 | — | == 200 | fail |  |
| Plan battery rows present (PLAN.md line 49) | — | — | == 3 | fail | metric 'plan_battery_rows_present' (Plan battery rows present (PLAN.md line 49)) is missing from the suite results — the registry requires it; dropping a metric cannot hide a failing bar |
| suite identity (letter/title per registry) | — | — | — | fail | results are missing 'letter' — required by the results.json schema (the suite's identity from its suite.json/registry entry); results are missing 'title' — required by the results.json schema (the suite's identity from its suite.json/registry entry) |

## B. Learning `learning` (runner, 0.0s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| B. Learning | — | — | — | not-run | suite not yet delivered by fl-learning-lab-f1 (no evaluation/suites/learning/) |

## C. Recipe corpus quality and rights `recipes` (run, 0.1s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Rights-clear recipes (complete per-recipe manifest evidence) | 530 | — | >= 400 | pass |  |
| Food-safety linter pass (% of corpus) | 100.0 | — | == 100 | pass |  |
| Lines resolved with quantity evidence (%) | 100.0 | — | >= 95 | pass |  |
| Unchecked allergen/diet claims (after linter strip) | 0 | — | == 0 | pass |  |
| Declared cuisines and time bands represented (%) | 100.0 | — | == 100 | pass |  |

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

*Bars are the lead's choices, owned by `evaluation/registry.json` from PLAN.md ("The scorecard"); a suite cannot add, drop or re-bar a metric. Every result is bound to this run (run id, git `33857f03836e`, start time). Suites B, D and E are delivered by the learning, LeChef and community tasks (see SCORECARD.md for their file contract).*
