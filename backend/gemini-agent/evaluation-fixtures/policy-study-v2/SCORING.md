# Scoring and verification handoff — run `2026-10-10-r1`

This documents the scoring layer for the frozen `policy-study-v2` family and the
scored run under `runs/2026-10-10-r1/`. The family, its builder, and its fixture
tests are described in `policy-study-spec-v2.md` and `../build-manifest.json`
(that manifest is owned by the builder; this run adds its own hash manifest).

## Naming correction: identity evidence is a synthetic mapped proxy

Review finding on PR #46 (`build_cases.py:318-345`): for the `food101-photo`
stratum, `draw_detections` synthesizes each case's detections from the **mapped
recipe's own required/optional ingredient list** (presence-drawn, with
co-occurring fillers). The `native_recipe_identity` target then names the
recipe that generated the evidence. No Food-101 photograph was downloaded,
retained, or used anywhere in the family.

Consequences, which apply to every identity number in this document and in
`scoring-summary.json`:

- Identity metrics measure **mapped-recipe recovery from synthetic mapped
  evidence** — a closed-loop consistency check of the producer projection and
  ranking over ingredient evidence — **not photograph recipe recognition** and
  not photograph recipe truth.
- The metric name in the frozen labels (`native_recipe_identity`) is
  historical. The frozen inputs are hash-locked and left byte-identical; the
  scoring summary now declares this provenance explicitly in
  `identity_evidence` (`kind: "synthetic-mapped-proxy"`).
- Precision/coverage figures should be read as proxy outcomes on synthetic
  evidence. They say nothing about performance on real photographs.

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
   and missing run artifacts (20 tests; full backend suite: 332 pass).

## Grouped intervals

Evaluation cases are not independent: cases with byte-identical producer
evidence (producer-equivalence groups) necessarily share outcomes. Every
headline interval below is therefore reported two ways:

- **Wilson 95%** — the naive binomial band, kept as an ungrouped reference.
- **Grouped 95% CI** — a deterministic cluster bootstrap over the
  producer-equivalence groups (groups resampled with replacement, rate
  recomputed over all cases in sampled groups; 10,000 iterations, fixed seed
  `20261010`), so byte-reproducibility is preserved.

On this run the largest multi-case group is the 6-case empty-evidence group, so
grouped intervals sit close to the Wilson bands (e.g. fixed-rule adoption
precision: Wilson 0.927–0.978, grouped 0.935–0.984). The grouped machinery
matters for any future family with heavier evidence reuse; unit tests verify it
widens correctly under within-cluster correlation.

## Findings (1,008 evaluation cases; 200 development cases excluded from all rates)

All identity rates are **synthetic mapped proxies** (see the naming correction
above), computed only over the 408 Food-101 cases where a mapped-recipe
identity target exists. The 600 Nutrition5k evaluation cases have no
native-recipe identity target (unknown plate recipes) and are excluded from
identity rates.

- **Producer ranking is shared by all arms** (arms differ only in the decision
  policy), so top-1/top-3 identity accuracy is identical across arms:
  **top-1 310/408 (75.98%; Wilson 0.716–0.799, grouped 0.718–0.801)**,
  **top-3 346/408 (84.80%; Wilson 0.810–0.880, grouped 0.811–0.882)**.
- **Fixed-rule top-pick** (adopt when deterministic readiness and no hard fail):
  456/1,008 adopted (45.2% coverage), with adoption precision **95.95%** on the
  247 adopted cases that have identity truth (Wilson 0.927–0.978, grouped
  0.935–0.984). 546 reviews, 0 estimates.
- **Learner arms never auto-adopt** on evaluation cases (0 adopts): no recorded
  evaluation case satisfied deterministic readiness. The warm arm (200 dev
  episodes replayed) shifts mode distribution only: 196 reviews / 806 estimates
  vs 245 / 757 cold. Friction is 100% for both learner arms as configured.
- **Risk/coverage sweeps** (adopt when score ≥ t and no hard fail; risk over
  identity-adjudicable adopted cases; grouped precision CI per point in the
  summary):
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
  adjudicated identities. No Brier-style probability is derived from them.
- **Live Decisions arm: not run.** No operator-supplied access or spend limits
  were available; no live inference was made and none is imputed.

## What was not checked, and source-reconstruction limits

- **No Apple-platform build.** The learner arms were produced by the real Swift
  `ConfidenceLearningService` compiled for Linux (Swift 6.1.2, GRDB 7.10.0).
  No iOS/macOS build of the app was produced; platform behavior is covered
  only by the hosted CI.
- **Two Linux build copies are unreconstructible.** The Linux compile applied a
  small `os`-module logger shim to `ConfidenceLearningService.swift` and
  `RecipeRepository.swift` before compiling. Those shimmed copies were **not
  retained**, so the exact edits cannot be reconstructed: the hashes recorded
  in `build-record.json` attest which sources were compiled, but the delta from
  the committed repository sources is not recoverable from anything in this
  repository. `preprocess_learner.py` and `main.swift` **do** match their
  recorded hashes exactly.
- **No photographic source exists to reconstruct.** Food-101 images were never
  downloaded; the family's evidence is synthetic by construction, so no
  artifact of this run can be re-derived from, or validated against, a
  photograph.
- **Producer parity is a cross-check, not a second producer.** It recomputes
  the documented projection over recorded outputs; it validates consistency,
  not an independent implementation path.
- Amount outcomes are not adjudicable (no quantity decisions exported).

## Handoff

Frozen provenance hashes (SHA-256), verified at scoring time:

- Family build manifest: `2fba0c1046bd22f659f70c8410441d37880322a9935d0fe4ae70887e65d6c543` (`build-manifest.json`)
- Run manifest: `6a78777e82a00678f92f7bfc4cd5979549d3ce991a5fff1e8bda95af12bd1d92` (`runs/2026-10-10-r1/run-manifest.json`)
- Study arms (actual run, preserved byte-identically): `f2fac4f969ac89cb2b05af7801d078cbd6dcb328e648d4d0027c4e0e9294385f` (`runs/2026-10-10-r1/study-arms.json`)

Deliverable: draft PR #46, `obv/fl-next-decisions-comparison-r1` →
`feat/routing-eval-harness`. The run artifacts are actual recorded output of the
Swift learner; nothing was regenerated or imputed to produce them.

Continuation steps, in order:

1. **Live Decisions arm** — blocked on operator-supplied credentials and
   approved request/spend limits. When provided, run the same frozen
   `requests.jsonl` through direct `POST /v1/decisions` and score with the same
   layer; until then it stays reported `not-run` (already encoded in the
   summary and tests).
2. **Amount study** — extend the runner to export per-ingredient quantity
   decisions; the 600-case weighed-mass truth is already frozen and the scorer
   already accounts for coverage. A new run id (do not mutate `2026-10-10-r1`).
3. **Photograph-grounded identity study** — if real recognition is to be
   measured, build a new family whose evidence derives from actual images
   (e.g. the pinned ingredient-recognition checkpoint from the dish-ambiguity
   benchmark); do not reuse `draw_detections` proxies for that purpose.
4. **Verification after any touch** — `bun scripts/scorePolicyStudyV2.ts`
   (no `--write`) must exit 0 with zero parity failures; `bun test` full suite
   green; any change to a frozen file must fail scoring, by design.

## Files

- `run-manifest.json` — SHA-256 of all frozen inputs and run artifacts.
- `scoring-summary.json` — scorer output (reproducible; see test), including
  the `identity_evidence` provenance declaration and grouped intervals.
- `study-arms.json` — recorded per-case outcomes for cold/devwarm learner arms
  plus the degenerate arm; SHA-256 `f2fac4f969ac89cb2b05af7801d078cbd6dcb328e648d4d0027c4e0e9294385f`.
- `execution-record.json`, `build-record.json`, `run.log`, `parity-result.json` —
  Swift run, build, log, and parity evidence.
- `scripts/scorePolicyStudyV2.ts` + `src/evaluation/policyStudyV2Scoring.ts` —
  scoring CLI and library.
- `src/__tests__/policyStudyV2Scoring.test.ts` — tamper/regression tests.
