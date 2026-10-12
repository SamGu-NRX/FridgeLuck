# SCORECARD.md — the scorecard contract (runner side)

This document is the contract between the **scorecard runner**
(`evaluation/run.py`, owned by fl-eval-harness-f1) and the **suites** it
runs. PLAN.md ("The scorecard (evals first)",
`docs/spec/overhaul-20261011/PLAN.md`) defines the suites A–G and their
bars. `evaluation/CONTRACTS.md` (suite A sub-thread) indexes each suite to
its canonical sources.

## 1. The registry owns the bars (defect 3)

`evaluation/registry.json` is the **runner-owned source of truth** for the
expected suite spine *and* every metric's label and bar. PLAN.md says:
*"The bars are the lead's choice, not measured optima. A suite can only
move a bar with a recorded reason."*

- Suites **declare metric ids and labels** that match the registry exactly.
  They may omit bars entirely (the runner injects the registered bar).
- A suite's own bars are **never trusted**. Pass/fail is derived by the
  runner from the **registry bar** + the emitted value + the emitted
  interval (`suite_contract.derive_status`). For `>=` bars the interval's
  **low end** must clear the bar; for `<=` bars the high end must; an
  `==` bar ignores the interval (it is kept as evidence only).
- A suite whose results differ from the registry — **missing metric,
  extra metric, different label, different bar** — FAILS with a reason
  naming the exact mismatch. Dropping a metric cannot hide a failing bar;
  adding one cannot inflate a pass.
- Moving a bar: edit `registry.json` with a recorded reason (the `reason`
  or `source` field on the metric), citing PLAN.md or an operator
  decision. A suite cannot move a bar from its own code.

Registry metric fields: `label` (exact human label the suite must emit),
`bar` (`{"op": "<=|>=|==", "value": n}`), optional `interval_required`
(`true`: the bar applies to the metric's 95% interval low end — a point
estimate without an interval cannot pass; suite B's NDCG bars set it),
and `source` or `reason` (recorded provenance — PLAN row or operator
decision). Suite fields: `id`, `letter`, `title`, `owner_task`,
`platform` (`any`|`macos`), optional `timeout_s` (default 1800 s).

## 2. Suite file contract (how B, D and E wire in — defect 6)

A delivering task adds **exactly one directory**,
`evaluation/suites/<id>/` (e.g. `learning/`, `lechef/`, `community/`),
containing:

1. `suite.json` — manifest: `{"id", "letter", "title", "owner_task",
   "platform", "timeout_s" (optional)}`. The manifest must not carry
   `metrics`: the registry owns the bars, and a manifest cannot set them.
2. `suite.py` — executable checker with the CLI:
   - `suite.py --out DIR --repo-root ROOT` — run the checks, write
     `DIR/results.json`, exit 0. Exit code is **not** a verdict; the
     results file is. Missing inputs ⇒ still exit 0, with every affected
     metric `not-run` and a reason.
   - `suite.py --self-test` — plant the suite's own failure cases and
     verify they are caught (section 6). Exit 0 only when all are.
3. Optional: `selftest/*.json` planted cases for the runner-level
   convention (section 5).

**No runner-side changes are needed** to wire a suite: the runner
discovers the directory, merges the manifest over the registry spine, and
judges its results against the registered metrics. Suites B (learning,
fl-learning-lab-f1), D (lechef, fl-lechef-f1) and E (community,
fl-community-f1) are registered in `registry.json` today; until their
directories exist they report **not-run naming the owner task**.

Suite D's job-success metric is named **"Harness conformance (% of
scripted cook jobs)"** (`harness_conformance_pct`, bar `>= 90`): it
measures the scripted fake-provider harness's conformance, not LeChef
quality.

## 3. results.json schema

```json
{
  "suite": "<registry id>",
  "letter": "<registry letter>",          // required, must match registry
  "title": "<registry title>",            // required, must match registry
  "metrics": [
    {
      "id": "<registry metric id>",
      "metric": "<registry label>",
      "value": 55,                         // for measurable metrics
      "interval": [0.22, 0.35],            // required where the registry sets
                                           // interval_required; otherwise optional
      "bar": {"op": "==", "value": 200},   // optional; NEVER trusted (evidence only)
      "status": "not-run",                 // only allowed value: "not-run"
      "reason": "why not-run"              // required for not-run
    }
  ],
  "run": {"run_id": "...", "git_sha": "...", "started_at": "..."},
                                       // REQUIRED: the producer binding, copied
                                       // from the FL_RUN_BINDING env var (section 4)
  "run_status": "ok"                   // OPTIONAL: omit, or "ok"; any failure value
                                       // (e.g. "infrastructure-failure") refuses the
                                       // emission (section 4)
}
```

Rules:

- `letter`/`title` are **required on every emission** and must match the
  registry identity. A payload without them is how a scorecard renders
  "?. suite" (defect seen on suite A before its fix); the runner rejects
  missing or differing identity as a registry mismatch.
- A `status` of `pass`/`fail` emitted by the suite is **stripped and
  re-derived** by the runner from the registry bar. Only `not-run` (with a
  reason) is honoured as declared.
- **Stamp the `run` binding yourself**: the runner passes this run's
  identity to the suite as the `FL_RUN_BINDING` environment variable
  (JSON: `run_id`, `git_sha`, `started_at`); a conforming suite writes
  `results["run"] = json.loads(os.environ["FL_RUN_BINDING"])`. The runner
  **verifies** the emitted producer binding instead of overwriting it —
  a result bound to another run (a stale copy from an old `out/`
  directory) or written without a binding is rejected to `not-run` with
  the mismatch named (section 4).

## 4. Run binding, fresh output, and failed-run admission (defect 4)

Every admitted result is bound to **its producing run**, and suite
results are bound to **this run**:

- The runner hands its identity —
  `{"run_id": "r-YYYYMMDDTHHMMSSZ-xxxxxxxx", "git_sha": "<head>", "started_at": "...Z"}`
  — to every suite as the `FL_RUN_BINDING` environment variable. The
  suite stamps it as the producer binding on its results, and the runner
  **preserves and verifies** the emitted binding instead of overwriting
  it: a result whose binding names another run, or an output written
  without one, is rejected to `not-run` with the reason naming the
  mismatch. A suite that copies cached passing results from an old
  `out/` directory therefore cannot relabel them with a fresh binding.
- Rows the runner authors itself (a `not-run` refusal, a registry-
  mismatch report, an admitted-import record) are bound to this run by
  the runner.
- **Explicit failed-run admission**: a result whose own `run_status`
  reports an infrastructure failure — or that otherwise lacks verifiable
  run provenance — lands `not-run` with the reason, never as a
  zero-issues pass. A dead simulator or a crashed audit cannot be scored
  as a clean run.

Fresh output per run: the runner **removes `out/<id>/` before executing a
suite**, so an exit-zero suite that emits nothing cannot reuse a previous
pass — it reports `not-run` ("wrote no results.json"). A prior run's
results can never survive into a new scorecard.

## 5. macos-import rule

Suites with `platform: "macos"` (F ui-polish, G journeys) run only on
macOS: via the existing iOS CI targets, or via a workflow proposed under
`ci/pending-workflows/` and approved by Sam. On other hosts the runner
imports the committed `out/<id>/results.json` **only when the payload
proves itself**:

- `git.sha` — the **full SHA of the producing run**, equal to the current
  head;
- `run_url` — **this repository's GitHub Actions URL for the run**
  (`https://github.com/SamGu-NRX/FridgeLuck/actions/runs/<id>`);
- `run.run_id` (numeric), `run.started_at` — the producing run's identity.

The runner then **re-verifies the run against GitHub's REST API**
(`GET /repos/SamGu-NRX/FridgeLuck/actions/runs/<id>`, token from
`GITHUB_TOKEN`/`SECRET_GITHUB_TOKEN`): the run must exist and its
recorded `head_sha` must be the current head. A synthetic URL
(`ci.example.test` and friends) is **not provenance**; a fabricated run
id, a foreign head behind a real run id, or a network that blocks
verification each fail closed to **not-run** with the reason — live-
reachability checks that could not run are labeled `UNVERIFIED-NATIVE`
in the refusal. An admitted import is marked `"source": "imported"`,
keeps the producing run's identity under `native_run`, and records the
verification evidence (`verified_via: "github-rest"`, run id, head,
`checked_at`) under `import_provenance`.

## 6. Planted-failure self-tests

`python3 evaluation/run.py --self-test` plants failures and verifies every
one is caught; it exits **0 only when every planted failure is caught**
(exit 2 otherwise, 1 on infrastructure errors). Three layers:

1. **Runner-owned cases** (`RUNNER_CASES` in `run.py`): the minimum set —
   dropped metric, weakened bar, extra metric, stale-result reuse attempt,
   stale-result copies carrying an old or no producer binding, missing
   binding fields, unbound imported result, head-mismatched import,
   synthetic-URL import (`ci.example.test`), forged-head import behind a
   real run id, network-unreachable import, infrastructure-failure
   zero-issues emission, a learning point estimate without the required
   interval, absent suite dir, missing/wrong `letter`/`title` identity,
   plus the legacy honesty cases (crash, honest fail, honest pass, liar,
   missing inputs, interval on an `==` bar) and B/D/E wiring cases against
   the real registry. Each case plants a synthetic suite (or import
   payload) in a temp tree and asserts the exact reported rows. Runner
   cases assert the **entire expected row set**: a positive control must
   not be "caught" while an extra identity-contract failure hides beside
   it.
2. **Per-suite planted cases** — the convention other sub-threads use to
   add cases from their own directories: put JSON case files in
   `evaluation/suites/<id>/selftest/*.json`. Schema (same keys as the
   runner-owned cases): `case` (name), `emit` (results payload the planted
   `suite.py` writes — `null` for exit-0-silence, `"crash"` for a crash),
   optional `import_source` (macos suites), `expect_rows` (list of
   `{"id", "status", "reason_contains"}`), optional `expect_source`,
   `forbid_ids`, `expect_file_absent`, `skip_on_macos`. Cases run against
   the real registry; the runner reports `caught`/`UNCAUGHT` per case.
   Per-suite `expect_rows` names the rows under test — honest rows may sit
   alongside them (the runner's own cases, by contrast, assert the exact
   row set).
   `evaluation/tests/planted_failures.py` replays the review plants
   directly against any runner (`--run-py <path>`, `--expect-green` to
   enforce) — see `evidence-base-plants.txt` (red at base 9e04af4) and
   `evidence-branch-plants.txt` (all caught on the branch).
3. **Suite-internal `--self-test`**: every present suite must also catch
   its own planted failures (exit 0), and the runner runs it as part of
   `--self-test`.

A planted failure that comes back uncaught fails the whole self-test with
the offending rows named. Suite-internal self-tests validate against the
bare contract (structure + derivation); **registry and identity rules are
judged by the runner only**, so they have exactly one owner.

## 7. Ownership and boundaries

- Runner-owned (this task): `evaluation/run.py`,
  `evaluation/suite_contract.py`, `evaluation/registry.json`,
  `evaluation/SCORECARD.md`, `evaluation/out/**` (regeneration).
- Suite-owned (their tasks): everything under
  `evaluation/suites/<id>/` — including that suite's `selftest/` cases.
- `evaluation/CONTRACTS.md`: suite A sub-thread (canonical source index).
- No CI/workflow edits: proposals are staged under
  `ci/pending-workflows/` with a first-line purpose+trigger comment.
- Regenerated `out/` artifacts are committed only when produced from a
  **clean tree** — the scorecard header records the git SHA and dirty
  state, and a dirty-tree scorecard is not evidence.
