# Scorecard: schema and suite contract

This directory decides what "best" means for the FridgeLuck overhaul. The suite
names, owners and pass bars come from `PLAN.md` ("The scorecard (evals first)")
on `docs/spec-overhaul-20261011` (revision 2, 2026-10-11, commit `062d20f`).
Every overhaul task reports its results through a suite here, so that the
variants the overhaul builds are judged by the same instrument that measured
the baseline.

The runner is `evaluation/run.py`, built by `fl-eval-harness-f1`.

## Running

```bash
python3 evaluation/run.py --list        # expected suites, present or not, with owners
python3 evaluation/run.py --all         # run every suite runnable on this host
python3 evaluation/run.py --suite pantry-truth --suite recipes
python3 evaluation/run.py --self-test   # planted failures must all be caught (exit 2 if not)
```

Outputs: `evaluation/out/scorecard.json` and `evaluation/out/scorecard.md`,
plus per-suite artifacts under `evaluation/out/<suite>/`.

Exit codes: `0` when the scorecard was produced (pass/fail is data reported
honestly — a failing bar is a correct scorecard, not a runner failure);
`1` on infrastructure errors; `2` when `--self-test` finds an uncaught planted
failure.

## The one rule

**A suite whose inputs are missing reports `not-run` with the reason, never
pass.** The runner fail-closes the same way: a suite that crashes, times out,
or emits malformed results is `not-run` with the reason. Nothing in this
directory can upgrade `not-run` to `pass`, and no suite can declare `pass` on
a violated bar — status is derived (below), not asserted.

## Suite layout (file contract for every suite, including B, D and E)

```
evaluation/suites/<suite-id>/
  suite.json     # manifest (below)
  suite.py       # entry point (below)
  ...            # datasets, fixtures, adapters, checker code
```

`suite.json`:

```json
{
  "id": "pantry-truth",          // must equal the directory name; the scorecard suite field
  "letter": "A",                 // letter in PLAN.md's scorecard table
  "title": "Pantry truth",
  "owner_task": "fl-eval-harness-f1 (suite A sub-thread)",
  "platform": "any",             // "any" | "macos" — macos suites run only in approved native CI (see "macOS-only suites")
  "timeout_s": 1800              // optional, default 1800
}
```

`suite.py` interface: the runner invokes

```bash
python3 suite.py --out <abs evaluation/out/<id>> --repo-root <abs repo root>
```

(cwd is the suite directory). The suite writes `<out>/results.json` and may
write any other artifacts next to it. Printing human progress to
stdout/stderr is fine; the results file is the interface.

## results.json schema

```json
{
  "suite": "pantry-truth",
  "letter": "A",
  "title": "Pantry truth",
  "run_at": "2026-10-11T12:00:00Z",
  "toolchain": {"swift": "swift-6.4 ...", "...": "..."},
  "metrics": [
    {
      "id": "stock_double_count",
      "metric": "Stock counted twice (audit)",
      "value": 0,
      "interval": [0, 0],
      "bar": {"op": "<=", "value": 0, "label": "0 stock counted twice"},
      "status": "pass",
      "detail": "optional human explanation",
      "evidence": {"path": "…", "note": "…"}
    }
  ]
}
```

Field rules:

- `id` unique within the suite; `metric` is the human label shown on the card.
- `value` is numeric for any bared metric. String findings go in `detail`.
- `bar` is `{"op": "<=" | ">=" | "==", "value": n}` and may carry a `label`.
- `interval` is an optional `[low, high]` confidence/observed interval.
  **When present, the bar is applied to the conservative bound** (`>=` bars
  use the low end, `<=` bars the high end). Equality bars reject intervals.
- `reason` is **required** for `not-run` and should say precisely which input
  is missing or why the check could not run.

### Status is derived, not declared

For any metric with a `bar`, the contract computes the status from `value`,
`bar` and `interval` (`suite_contract.check_bar`). A suite cannot assert
`pass`; a planted or buggy "pass" on a violated bar is stripped and the honest
`fail` is reported. The only status a suite declares is `not-run`, which
requires a reason. Suite self-tests exploit this: they plant corrupted inputs
and assert the derived status flips to `fail`.

## Suite identity: the registry

`evaluation/registry.json` is the expected spine (suites A–G from PLAN.md,
with owner tasks). `run.py --list` shows every expected suite with `present:
yes/no`. A registry entry without a directory reports:

> `not-run — suite not yet delivered by <owner_task> (no evaluation/suites/<id>/)`

so the scorecard shows the whole programme shape before every suite exists.
A directory with a manifest but no registry entry is also discovered, so a
delivering task is never silently dropped.

## macOS-only suites (F `ui-polish`, G `journeys`)

They run under XCUITest on macOS (macos-26, Xcode 26.6). Per the standing
rule, the fleet never edits or installs CI: native execution happens only in
the existing iOS CI targets, or in a workflow proposed under
`ci/pending-workflows/eval-macos.yml` and approved and installed by Sam.
Native arms without a real run are labelled UNVERIFIED-NATIVE in the
delivering PR — never reported as verified-native-ci. On non-macOS hosts the
runner imports the suite's committed `evaluation/out/<id>/results.json`
(produced from an approved native run and committed together with the run
URL) and re-validates it under this contract; `source` is marked `imported`. With no committed results the suite
reports `not-run` with that reason — never pass.

## Wiring contract for suites B (learning), D (lechef) and E (community)

The learning, LeChef and community tasks own their directories
`evaluation/suites/learning/`, `evaluation/suites/lechef/` and
`evaluation/suites/community/` respectively. To join the scorecard a task
commits its suite directory (manifest + `suite.py` + fixtures) following this
document — no runner file needs to change; discovery is by convention. Until
then the registry shows them `not-run` with their owner named.

Result-file contract if a task wants the runner to pick up results it
produced elsewhere (e.g. on a cluster): write
`evaluation/out/<suite-id>/results.json` in exactly this schema and commit it
with the git SHA and toolchain it was produced at; the runner validates it as
`source: "imported"` on the next run. Anything invalid is not-run, never pass.

## Bars

Bars are the lead's choices recorded in PLAN.md, not measured optima. A suite
can only move a bar with a recorded reason in PLAN.md. The bundled bars:

| Suite | Metric | Bar |
| --- | --- | --- |
| A | stock counted twice | `== 0` |
| A | "sufficient" without evidence | `== 0` |
| A | fit-line text correct (200-pair audit) | `== 200` |
| B | NDCG@10 vs rule ranker / profile-only | interval low ≥ +10% relative, 0 restriction violations, shift recovery ≤ 6 cooks (owner suite implements) |
| C | rights-clear recipes | `>= 400` (toward 1,500) |
| C | food-safety linter pass | `== 100%` |
| C | lines resolved with quantity evidence | `>= 95%` |
| C | unchecked allergen/diet claims | `== 0` |
| C | cuisines and time bands represented | every declared band has >= 1 recipe |
| D | food-safety violations / unapproved actions | `== 0` |
| D | job success / timer correctness | `>= 90%` / `== 100%` |
| E | private-field leaks / authorization failures | `== 0` |
| E | moderation transitions covered | `== 100%` |
| F | body-text contrast violations | `== 0` |
| F | touch-target violations (44 pt; 64 pt cook) | `== 0` |
| F | clipped primary labels at XXL Dynamic Type | `== 0` |
| G | journeys pass with no crash | `== 100%` of runnable journeys |

## Self-tests: a broken check cannot report pass

Every suite implements `--self-test`:

```bash
python3 evaluation/suites/<id>/suite.py --self-test
```

It plants deliberate failures (corrupted fixtures, flipped labels, a lying
emitter) and asserts its own scoring catches each one, printing
`caught k/k planted failures`. `run.py --self-test` runs five planted runner
scenarios (crash, honest-fail, honest-pass, liar, missing-inputs) plus every
present suite's `--self-test`, and exits 2 if anything is uncaught.

## Baselines and what is committed

`evaluation/out/` holds committed evidence, refreshed deliberately:
`BASELINE.md` is the current app's first full scorecard; `out/<suite>/`
holds each suite's latest committed results and artifact summaries. Regenerated
files (scorecard.json/md) are committed when they document a milestone.
