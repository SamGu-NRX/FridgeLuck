# scan-correction-eval

Does scan-correction learning still behave when you watch it over time —
not just at the unit-test threshold?

This tool evaluates the FridgeLuck correction pipeline (the real
`LearningService` + `ConfidenceRouter`) over long correction histories:
clean feedback, noisy feedback, changed products, conflicting users, and
delays/restarts. It compares the current policy against no-learning and two
bounded alternatives implemented **only in this tool** — production code is
never edited; defects found are recorded as reduced records in `DEFECTS.md`.

Populations here are engineering assumptions for stress-testing policy
behavior. Nothing here is a human study, and `ConfidenceLearningService`
(meal photos) is explicitly out of scope.

## Layout

| Piece | What it is |
|---|---|
| `sequences.py` | Generator: 6 families x 50 seeds (300 histories). Truth and feedback come from two independent named RNG streams. |
| `reference.py` | Hand arithmetic model of the current policy (normalized key, count+1 upsert, argmax by count/last_used_at/rowid, auto at count >= 2). |
| `check_histories.py` | Validates shape, closed-form expected decisions, structural invariants, restart equivalence, and the dev/held-out split; writes `data/expected_current.json`. |
| `tests/` | pytest suite over counts, determinism, stream independence, split controls, reference units, and checker mutations. |
| `SwiftReplay/` | Swift package that replays the **real** `LearningService` and `ConfidenceRouter` in fresh GRDB databases over these histories (milestone 2). Built and passing; see below. |
| `score.py` | Formal scoring (milestone 3, built): dev-only policy selection, held-out scoring with seed-grouped bootstrap intervals, `--verify-report` tamper check. |
| `data/` | Committed histories, manifest (seed/family counts), expected outcomes, and replay results. |

## Families (committed counts)

All families have 50 seeds. `clean` seeds 25-49 are null-feedback controls
(feedback drawn with no signal) used to baseline wrong auto-corrections.

| Family | Kind | Scans | Feedback | Restarts | Delays |
|---|---|---|---|---|---|
| clean | development | 450 | 300 | 100 | 50 |
| noisy | development | 400 | 400 | 50 | 50 |
| changed | development | 550 | 450 | 50 | 50 |
| conflict | development | 400 | 400 | 50 | 50 |
| delay | development | 400 | 250 | 100 | 200 |
| heldout-combined | **held-out** | 450 | 400 | 50 | 50 |

The held-out family is never used for policy selection; `score.py` enforces
the split.

## Commands

```bash
python3 apps/ios/Tools/scan-correction-eval/sequences.py
python3 apps/ios/Tools/scan-correction-eval/check_histories.py
python3 -m pytest apps/ios/Tools/scan-correction-eval/tests -q

# Swift replay (milestone 2): sync + build + all 300 histories x 4 arms (~3 min)
bash apps/ios/Tools/scan-correction-eval/SwiftReplay/Scripts/run_replay.sh
python3 apps/ios/Tools/scan-correction-eval/SwiftReplay/Scripts/tally_replay.py

# Formal scoring (milestone 3) and tamper check
python3 apps/ios/Tools/scan-correction-eval/score.py
python3 apps/ios/Tools/scan-correction-eval/score.py --verify-report
```

### Swift replay (milestone 2)

`SwiftReplay` syncs verbatim copies of the production `LearningService` and
`ConfidenceRouter` into `Sources/AppSources` (via `sync_sources.py`, with a
Linux `Detection` shim and the schema extract; `--check` fails on drift), then
replays every committed history under four arms:

- **current** — the real `LearningService` (auto-correct at count >= 2)
- **no_learning** — baseline: never auto-corrects
- **recency_window** — alternative: only the last 5 corrections vote
- **conflict_abstain** — alternative: abstain on any ambiguity

Cross-checks enforced by the XCTest run on every seed/arm: the `current` arm
matches the hand-computed reference decisions in `data/expected_current.json`
scan-for-scan; restarting the service from the database reproduces identical
decisions; reopening the database reproduces identical decisions.

Full-run results (committed under `data/replay-out/`, 2,650 scans x 4 arms):
`conflict_abstain` removes wrong auto-corrections in the conflict family
(250 -> 0) at the cost of never auto-correcting there; `recency_window` cuts
wrong auto-corrections in the changed family by a third (150 -> 100) and adds
correct auto-corrections (300 -> 350); `current` and `noisy`/`clean` families
behave as the Python reference predicted.

### Formal scoring (milestone 3)

`score.py` turns the frozen replay results into `data/replay-out/score-report.json`:

- **Selection** uses development families only. Rule, fixed in advance:
  maximize net auto-corrections (`correctAuto - wrongAuto`); tie-break fewer
  wrong, then arm name. On this run it selects **conflict_abstain**
  (dev net 935 vs 684 recency_window, 584 current, 0 no_learning). The rule
  prices one wrong silent auto-correction equal to one correct one —
  conservative; the full trade-off table is in the report.
- **Held-out** (`heldout-combined`) is scored after selection, never during.
  With 95% seed-grouped bootstrap intervals (1,000 resamples, seed
  20261010): conflict_abstain wrong 21 CI [14, 28] vs current wrong 121
  CI [114, 128]; current correct 229 CI [222, 236] vs conflict_abstain 200.
  Degenerate CIs (e.g. recency_window wrong [100, 100]) mean every held-out
  seed carries exactly the same count — the family construction is that
  regular, not a resampling bug (the tally's per-seed rows show it).
- **`--verify-report`** re-hashes the frozen results and recomputes every
  number in the stored report; edited results, dropped cases, or an edited
  report refuse to verify.

Scorer tests: `tests/test_score.py` (synthetic data only) — selection
isolation from held-out, tie-breaks, bootstrap determinism, and tamper /
dropped-case / edited-report refusals. Full suite: 21 pytest cases pass.

## Status / handoff

See `DEFECTS.md` for production defects found (as reduced records, not edits)
and the PR body for the full run log.
