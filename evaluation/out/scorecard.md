# FridgeLuck overhaul scorecard

Generated 2026-10-11T12:55:29Z · git `5edf21b51694` (eval/scorecard-runner, dirty) · python 3.13.14 · linux

**5 pass · 7 fail · 8 not-run** — a suite whose inputs are missing reports not-run, never pass.

## ?. pantry-truth `pantry-truth` (run, 17.1s)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Stock counted twice (plan battery) | 37 | — | == 0 | fail |  |
| Sufficient claimed without quantity evidence (line audit over 200 pairs) | 209 | — | == 0 | fail |  |
| Fit-line text correct (200-pair audit) | 55 | — | == 200 | fail |  |

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

## F. UI polish `ui-polish` (imported)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Body-text contrast violations (< 4.5:1) | — | — | — | not-run | this host is linux and has no Xcode or iOS simulator; the XCUITest arm requires macOS. It runs via .github/workflows/eval-macos.yml (macos-26, Xcode 26.6); no committed macOS CI results were imported either. |
| Touch-target violations (44 pt; 64 pt cook) | — | — | — | not-run | this host is linux and has no Xcode or iOS simulator; the XCUITest arm requires macOS. It runs via .github/workflows/eval-macos.yml (macos-26, Xcode 26.6); no committed macOS CI results were imported either. |
| Clipped primary labels at XXL Dynamic Type | — | — | — | not-run | this host is linux and has no Xcode or iOS simulator; the XCUITest arm requires macOS. It runs via .github/workflows/eval-macos.yml (macos-26, Xcode 26.6); no committed macOS CI results were imported either. |
| Audited screens reachable | — | — | — | not-run | this host is linux and has no Xcode or iOS simulator; the XCUITest arm requires macOS. It runs via .github/workflows/eval-macos.yml (macos-26, Xcode 26.6); no committed macOS CI results were imported either. |
| STATIC (supporting evidence): declared-token contrast violations | 5 | [5, 5] | <= 0 | fail |  |
| STATIC (supporting evidence): declared frame minimums below 44 pt | 3 | [3, 4] | <= 0 | fail |  |
| STATIC (supporting evidence): XXL clipping-risk markers | 27 | [27, 28] | <= 0 | fail |  |

## G. Journeys `journeys` (imported)

| metric | value | interval | bar | status | reason |
| --- | --- | --- | --- | --- | --- |
| Runnable journeys passing with no crash | — | — | — | not-run | this host is linux and has no Xcode or iOS simulator; the XCUITest journeys require macOS. They run via .github/workflows/eval-macos.yml (macos-26, Xcode 26.6); no committed macOS CI results were imported either. |
| STATIC (supporting evidence): journeys with a discoverable entry affordance | 7 | — | == 9 | fail |  |

*Bars are the lead's choices from PLAN.md ("The scorecard"), not measured optima. Suites B, D and E are delivered by the learning, LeChef and community tasks (see SCORECARD.md for their file contract).*
