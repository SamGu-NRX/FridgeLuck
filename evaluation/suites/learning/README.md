# Suite B — learning: activation-gate bar for the learned taste ranker

**The bar (PLAN scorecard B).** A learned ranker may be enabled ONLY if, on
this preregistered simulation campaign, it beats BOTH the current rule
ranker AND an explicit-profile-only baseline on NDCG@10 among feasible
picks, with the 95% interval low at **+10% relative improvement or better**,
**zero hard-restriction violations**, and **median taste-shift recovery
within 6 cooks**. The parent's activation decision reads this suite's
scorecard; this README maps the numbers to the bar.

## What runs where

| Piece | Path | Role |
|---|---|---|
| Campaign | `packages/FLTaste/Eval` (SwiftPM, `fltaste-eval` CLI) | Replays simulated households through 12 ranker arms against hidden ground truth; emits `campaign/*.json` |
| Arms + stats | `packages/FLTaste/Eval/Sources/FLTasteEvalCore` | Pairing, bootstrap CIs, activation-gate verdict, per-(seed, arm) checkpoints |
| Suite wiring | `evaluation/suites/learning/suite.py` | Reads committed `campaign/` artifacts, re-derives every status under the shared contract, fail-closes to `not-run`, writes `results.json` |

The campaign is offline and deterministic: household generation, regime
assignment, and arm/seed enumeration derive from the seed alone; identical
seed + config + arms reproduce byte-identical metrics (tested in
`EvalTests`, including a determinism test and an oracle-vs-random sanity
test).

## Metric-by-metric mapping to the PLAN bar

| Suite metric | Bar | Campaign evidence |
|---|---|---|
| `ndcg_lift_vs_rule` | 95% interval low >= +10% relative | Paired per-seed NDCG@10 (engine vs rule-port); bootstrap interval carried from `gate.json`, widened to include the suite-recomputed point |
| `ndcg_lift_vs_profile` | 95% interval low >= +10% relative | Same pairing vs `profile-only` |
| `restriction_violations` | == 0, ever | Sum of `restrictionViolations` across engine arm seeds; a violation is a bug or a bar failure, never a rounding |
| `shift_recovery_cooks` | median <= 6 | Median cooks for the engine to re-align after the vegetarian shift; a censored observation (no recovery seen) reports 999 and fails |
| `preregistered_scale` | == 1 (full 5,000 x 20 grid) | Config actually executed; 0 whenever a reduced grid was run |

`preregistered_scale` is the fail-close rule for compute: a reduced grid
reports honest lift intervals, but the card derives a fail on this metric
until the unreduced grid runs, so a reduced-scale pass can never masquerade
as the full activation decision. The absence of the full grid is documented
in `RESULTS.md` with measured throughput as evidence.

## Honesty contract

- **Statuses are derived, never asserted.** `suite.py` recomputes values
  from the committed per-seed results and applies bars via the shared
  contract (`evaluation/suite_contract.py`; a vendored fallback with
  identical semantics is compiled in when the runner branch is not yet
  merged). A hand-written `"status": "pass"` is stripped.
- **Fail-closed inputs.** Any missing or unreadable campaign artifact, any
  invalid producing SHA, or any manifest without toolchain identity
  produces an all-`not-run` card with a reason. Stale or hand-written
  results are not accepted.
- **Tamper evidence.** If the recomputed point estimate falls outside the
  gate file's carried interval, the interval is widened to include the
  recomputed value before the bar is applied — a stale or tampered gate
  file cannot keep a violated bar at pass.
- **Planted-failure self-test.** `suite.py --self-test` plants a flipped
  winner, planted violations, a deleted gate file, a stale provenance SHA,
  a shrunk scale, and a lying emitter, and must catch all of them
  (`caught k/k planted failures`, exit 0).

## Running

```bash
# The campaign (offline Swift; resumable checkpoints per seed batch)
cd packages/FLTaste/Eval
swift build -c release
.build/release/fltaste-eval campaign --config <CampaignConfig.json>

# The scorecard card
python3 evaluation/suites/learning/suite.py --out <abs-out-dir>
python3 evaluation/suites/learning/suite.py --self-test --out <abs-out-dir>
```

The committed `campaign/` artifacts were produced by the fltaste-eval CLI
at the git SHA in `campaign/PROVENANCE.json` (reproduction commands,
machine provenance, and wall time are in `packages/FLTaste/Eval/RESULTS.md`).
