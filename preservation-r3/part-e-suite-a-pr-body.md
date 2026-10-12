## Why

`evaluation/CONTRACTS.md` binds suite A to fail its battery **closed** when a required PLAN.md row goes missing (`suites/pantry-truth/suite.py`, `enforce_battery_completeness`), and the registry metric `plan_battery_rows_present` (bar `== 3`) makes presence of all three PLAN.md line-49 battery rows a judged bar, not decoration. The reviewer's position on criterion 5 — *already met in source* — is **confirmed by this verification**: on every path probed, a planted missing plan-probe row fails the run and can never pass silently. The one hardening gap found was real: suite A shipped **no** runner-level `selftest/` planted cases, so the runner-side enforcement of its battery was pinned only by generic runner-owned cases against synthetic registries.

## What changed

- Adds `evaluation/suites/pantry-truth/selftest/*.json` — five planted cases the runner judges against the **real registry** in `evaluation/run.py --self-test`: a battery row dropped from the emission, the completeness row itself dropped, a tampered completeness count (`value: 2`), a suite re-barring the completeness row (`== 2`), and a crashed suite. All five must be caught; the runner self-test goes from 24/24 (+ a "no selftest/ cases yet" note for suite A) to 29/29 with suite A cases named.
- **No enforcement code changed.** Verification found the in-source enforcement airtight, so nothing was weakened to force a red (per the task: "already enforced, verified" is a valid outcome). Files touched: `evaluation/suites/pantry-truth/selftest/{missing-battery-row,dropped-completeness-row,lying-completeness-count,rebarred-completeness,crashed-battery}.json` only.

## Proof

Exact commands and trimmed real output. Probes at base `9e04af4` unless noted; the plant is the only tree modification (the scorecard header honestly records `dirty: true` for those runs).

**1. Clean-tree full runner at base — letter A renders, battery complete, completeness row passes:**

```
$ python3 evaluation/run.py --out /tmp/card/clean
scorecard: 1 pass, 4 fail, 9 not-run
```
Suite A rows (from `scorecard.json`): `stock_counted_twice` fail (value 37), `sufficient_claimed_without_quantity_evidence` fail (value 209), `fit_line_text_correct_200` fail (value 55 of 200), `plan_battery_rows_present` **pass (value 3, bar `== 3`)**. Heading: `## A. Pantry truth \`pantry-truth\` (run, 60.3s)`. The three battery rows fail on **baseline production behavior** — real findings from the Swift-compiled production fit probe (Swift 6.4, Linux), which is the scorecard doing its job; the completeness row passes because all three rows were emitted.

**2. Plant at base: one required plan-probe row missing from the emission — the run fails closed, never silent:**

```
$ python3 evaluation/run.py --suite pantry-truth --out /tmp/card/plant
scorecard: 0 pass, 3 fail, 1 not-run
```
- `sufficient_claimed_without_quantity_evidence`: **not-run** — reason: `required plan battery row missing: sufficient_claimed_without_quantity_evidence (Sufficient claimed without quantity evidence (line audit over 200 pairs)) — PLAN.md line 49 requires it of suite A; the battery cannot pass with rows missing`
- `plan_battery_rows_present`: **fail (value 2, bar `== 3`)**

Heading still renders `A. Pantry truth`. Re-probed identically at merged head `05dda6a` after Part A's merge.

**3. Standalone suite path, same plant:** `suite.py --out … --repo-root …` exits 0 (per SCORECARD.md the exit code is not a verdict) but the emitted `results.json` is honest — the missing row is not-run with the reason above and the completeness row is fail (2 vs `== 3`). Registry-level judging is runner-owned by design (SCORECARD.md §6: "registry and identity rules are judged by the runner only, so they have exactly one owner").

**4. Battery-definition tamper (row removed from `METRIC_DEFS`):** the suite crashes (`IndexError` in `run_suite`) and the runner fail-closes: `pantry-truth_suite: not-run — suite exited with code 1: … IndexError: list index out of range`. Never a silent pass.

**5. Self-test with the new cases (at merged head `05dda6a`):**

```
$ python3 evaluation/run.py --self-test
  caught  planted pantry-truth-missing-battery-row
  caught  planted pantry-truth-dropped-completeness-row
  caught  planted pantry-truth-lying-completeness-count
  caught  planted pantry-truth-rebarred-completeness
  caught  planted pantry-truth-crashed-battery
  caught  suite pantry-truth --self-test: caught 7/7 planted failures
self-test ok: 29/29 runner cases + suites behaved as required

$ python3 evaluation/suites/pantry-truth/test_battery_completeness.py
caught 3/3 planted checks
```

**6. Letter-A rendering in every reachable state** (clean-tree regenerations; `evaluation/out/` left uncommitted per task):

| state | heading | suite A rows |
| --- | --- | --- |
| run (battery emitted) | `## A. Pantry truth \`pantry-truth\` (run, 60.3s)` | 3 battery rows + completeness **pass (3 == 3)** |
| fail (planted missing row) | `## A. Pantry truth \`pantry-truth\` (run, 61.7s)` | missing row **not-run with reason**, completeness **fail (2 vs == 3)** |
| not-run (crashed suite) | `## A. Pantry truth \`pantry-truth\` (runner, 0.0s)` | `pantry-truth_suite` **not-run** — `suite exited with code 3` |

## Tradeoffs / Risk

- The five cases repeat registry metric ids and labels as literals: if the registry renames a label, the case fails with a precise mismatch reason. That is the intended pin — these cases exist to fail loudly when suite A's registry contract drifts.
- An all-rows-**pass** suite A card is not reachable at any baseline head because production genuinely fails the truth bars (37 / 209 / 55) — that is the measured result on this host's real probe run, not a host limitation; the probe compiled and ran (Swift 6.4, Linux x86_64).
- Base refresh: merged `origin/eval/scorecard-runner` (`17953ed1`, Part A safety lint) as merge commit `05dda6a`; the merge diff touches only `evaluation/suites/recipes/` files — no suite A files.

## Handoff

- **Done:** full-runner-path verification at base `9e04af4` and merged head `05dda6a` (plants: emission-missing row, definition tamper, standalone path, crash path); five runner-level planted cases added; `run.py --self-test` 29/29 and `test_battery_completeness.py` 3/3 green at the pushed head; letter-A rendering verified in run/fail/not-run states from clean-tree regenerations.
- **Not done:** nothing in scope. No `evaluation/registry.json` change needed — if the lead ever wants stronger wording, the registry's `reason` field already records the fail-closed contract (recommendation only; runner-owned file, untouched).
- **Next steps:** none for this criterion — reviewer can re-verify with the commands in Proof. For later parts: after further merges to `eval/scorecard-runner`, re-run `python3 evaluation/run.py --self-test` (it re-runs these cases against the real registry).
- Head: `05dda6a3033b3fefdcef321b4b8a7428058620fc` (branch `eval/scorecard-e-suite-a`).

🔗 [Obvious Project](https://app.obvious.ai/p/fridgeluck-VgF1kF5T) · 🧵 [Obvious Thread](https://app.obvious.ai/p/fridgeluck-VgF1kF5T?thread=th_IUaFmgMu) · 🔀 [Obvious PR Artifact](https://app.obvious.ai/link/pr-artifact/fridgeluck-scorecard-runner-overhaul-task:todo_KPtjnO0o)
