# Scoring and verification handoff — run `2026-10-10-r1`

This documents the scoring layer for the frozen `policy-study-v2` family and the
scored run under `runs/2026-10-10-r1/`. The family, its builder, and its fixture
tests are described in `policy-study-spec-v2.md` and `../build-manifest.json`
(that manifest is owned by the builder; this run adds its own hash manifest).

## How to score

```sh
cd backend/gemini-agent
bun scripts/scorePolicyStudyV2.ts --write   # verifies, scores, rewrites scoring-summary.json
bun test src/__tests__/policyStudyV2Scoring.test.ts
```

`scoreStudy` refuses to run (`StudyVerificationError`) unless every frozen input
(`requests.jsonl`, `labels.jsonl`, `cases.jsonl`, mapping CSVs) and every run
artifact (`study-arms.json`, `execution-record.json`, `build-record.json`,
`parity-result.json`, `run.log`) matches the SHA-256 manifest in
`runs/2026-10-10-r1/run-manifest.json`. `scoring-summary.json` is deliberately
excluded from that manifest: it is the output being reproduced. A second
`scoreStudy` on the committed tree is byte-identical to the committed summary —
this is asserted by a test.

## Verification model

1. **Byte verification.** Frozen inputs and run artifacts hash-checked against
   `run-manifest.json` before anything is read semantically.
2. **Producer parity.** Every recorded outcome in `study-arms.json` is
   recomputed from `requests.jsonl` with the documented producer projection
   (detection routing → `routedSearch` → four-signal projection → learner
   assessment → hard-fail gates) and compared field-by-field. The recorded
   `parity-result.json` reports 0 failures over 1,208 cases; the scorer
   recomputes this independently and refuses on any mismatch.
3. **Tamper tests.** `src/__tests__/policyStudyV2Scoring.test.ts` proves the
   scorer refuses modified run bytes, deleted cases, modified frozen inputs,
   and missing run artifacts (13 tests; full backend suite: 325 pass).

## Findings (1,008 evaluation cases; 200 development cases excluded from all rates)

- **Producer ranking is shared by all arms** (arms differ only in the decision
  policy), so top-1/top-3 identity accuracy is identical across arms:
  **top-1 310/408 (75.98%, Wilson 95% CI 0.716–0.799)**, top-3 346/408 (84.80%),
  computed only over the 408 Food-101 cases where a mapped-recipe identity
  target exists. The 600 Nutrition5k evaluation cases have no native-recipe
  identity truth (unknown plate recipes) and are excluded from identity rates.
- **Fixed-rule top-pick** (adopt when deterministic readiness and no hard fail):
  456/1,008 adopted (45.2% coverage), with adoption precision **95.95%** on the
  247 adopted cases that have identity truth. 546 reviews, 0 estimates.
- **Learner arms never auto-adopt** on evaluation cases (0 adopts): no recorded
  evaluation case satisfied deterministic readiness. The warm arm (200 dev
  episodes replayed) shifts mode distribution only: 196 reviews / 806 estimates
  vs 245 / 757 cold. Friction is 100% for both learner arms as configured.
- **Risk/coverage sweeps** (adopt when score ≥ t and no hard fail; risk over
  identity-adjudicable adopted cases):
  - fixed-rule (producer confidence): t=0.3→407, 0.4→385, 0.5→280, 0.6→245,
    0.7→245, 0.8→230, 0.9→0; risk 2.5–3.7% where non-null.
  - learner-cold (learner overall score): 396, 384, 250, 245, 239, 0, 0.
  - learner-devwarm: 257, 245, 245, 25, 0, 0, 0. The warm learner scores
    systematically lower after replaying the dev episodes, so its sweep is the
    most conservative at every threshold.
- **Information limit:** 1,003 producer-equivalence groups; one group of 6
  evaluation cases shares byte-identical empty evidence while carrying 6
  distinct truth signatures. No policy can separate these cases; any arm
  differences inside the group are chance. (2 further empty-evidence cases are
  in the development slice.)
- **Amounts are not adjudicable from this run.** Weighed-mass truth exists for
  600 evaluation cases, but the runner exports no per-ingredient quantity
  decisions, so 0 amount decisions are adjudicable. Nothing is imputed;
  weighed-mass truth is committed for a future amount study.
- **Degenerate inputs (12 cases)** all failed closed: no DB events, and either
  zero candidates or a hard-fail reason.
- **Trust statistics** (means, overall scores) are learner statistics, not
  calibrated correctness probabilities; adoption precision is reported only on
  adjudicated identities.
- **Live Decisions arm: not run.** No operator-supplied access or spend limits
  were available; no live inference was made and none is imputed.

## What was not checked

- The learner arms were produced by the real Swift `ConfidenceLearningService`
  compiled for Linux (Swift 6.1.2, GRDB 7.10.0). No Apple-platform build of the
  iOS app was produced; macOS/iOS behavior is covered only by the hosted CI.
- The Linux build applied a small `os`-module logger shim to
  `ConfidenceLearningService.swift` and `RecipeRepository.swift` before
  compiling; those shimmed copies were not retained, so their recorded hashes
  in `build-record.json` attest what was compiled but cannot be re-derived
  from the committed repository sources (whose own hashes differ by exactly
  that shim). `preprocess_learner.py` and `main.swift` match their recorded
  hashes exactly.
- Producer parity covers the recorded outputs and the documented projection
  implemented in the scorer; it is a re-implementation cross-check, not a
  second independent producer.

## Files

- `run-manifest.json` — SHA-256 of all frozen inputs and run artifacts.
- `scoring-summary.json` — scorer output (reproducible; see test).
- `study-arms.json` — recorded per-case outcomes for cold/devwarm learner arms
  plus the degenerate arm; SHA-256 `f2fac4f969ac89cb2b05af7801d078cbd6dcb328e648d4d0027c4e0e9294385f`.
- `execution-record.json`, `build-record.json`, `run.log`, `parity-result.json` —
  Swift run, build, log, and parity evidence.
- `scripts/scorePolicyStudyV2.ts` + `src/evaluation/policyStudyV2Scoring.ts` —
  scoring CLI and library.
- `src/__tests__/policyStudyV2Scoring.test.ts` — tamper/regression tests.
