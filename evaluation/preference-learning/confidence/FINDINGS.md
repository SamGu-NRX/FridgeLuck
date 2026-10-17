# FINDINGS — Part 0: Sam's Beta trust vector, as built, vs alternatives

**Scope.** `ConfidenceLearningService.swift` (alpha @ `2e77938`, 359 lines) replayed offline through a
line-cited Python port against PR #7's reverse-meal episodes (12 episodes, 11 usable after the
deliberate hard-fail row) and PR #53's changed-family correction histories (50 seeds, read-only reuse).
All numbers in `results/tables.md` / `results/metrics.json`; every table row carries a 95% bootstrap
interval (B=1000, seed 20261011) computed over episodes.

**Fidelity.** The port was differentially checked: `tests/test_port_fixtures.py` transcribes
hand-computed fixture values from the Swift source, with every constant citing its verified Swift line
(`assessSignal` 276–294, `recordOutcome` 170–232, `prior(for:)` 312–330, `sampleSize` 78–80). Say it
plainly: **the port is differentially checked, not the compiled Swift binary.** Nothing here ran the
real service on Linux or macOS — any native-only claim would be UNVERIFIED-NATIVE and none is made.

---

## 1. Where the design wins

1. **It beats the naive online learner on this data.** The expanding base-rate strawman — the floor no
   adaptive method should lose to — scores ECE 0.489 / Brier 0.369; the Beta arms score ECE 0.267
   [0.134, 0.583] (proxy channel) / 0.340 [0.152, 0.563] (truth channel), Brier ≈ 0.30 (Table 1, 6).
   The informative priors' shrinkage is doing real work at n=12.
2. **It never overclaims.** Zero exact-mode errors anywhere: all arms, all sweeps, all extended replays
   (96 updates), all held-out spec rows (exact-on-wrong = 0, Tables 3, 7, 9). The failure direction is
   over-refusal, not wrong auto-apply — the safe failure mode for a feature that bypasses review.
3. **Best out-of-sample calibration among all learners tried at this sample size.** With
   leave-one-episode-out, isotonic (ECE 0.582, Brier 0.363) and logistic (ECE 0.458, Brier 0.304) both
   lose to or tie the online Beta (ECE 0.27–0.34, Brier 0.304–0.306) — the learned alternatives overfit
   n=12 while the Beta needs no training phase at all (Table 5). The Beta core is the right *family*.
4. **Zero-training deployment, O(1) updates, interpretable state.** Two floats per signal key; the
   influence ramp, uncertainty discount, and geometric fusion are all inspectable. At moderate drift
   (capability factor 0.9 / 0.75) the mode-error bar recovers in 1 scan — because conservatism is
   already the steady state (Table 8b); in PR #53's changed family, when seeds do stabilize it takes a
   median of 1 scan (Table 8a).
5. **Collision-group honesty.** Byte-equivalent evidence (RM-03/04/13, RM-06/16) receives identical
   modes in every arm — exactly what the spec demands; the layer never pretends to separate inputs it
   cannot distinguish (Table 9).

## 2. Where it loses (structural, not tuning)

1. **The trust vector is a pure discount — it can only lower scores.** Swift lines 279–283:
   `blended = raw·(1 − influence·(1−mean)) ≤ raw` for every mean < 1. The 0.45
   "calibration" term in `recordOutcome` (lines 184–188) pays rewards for *agreeing with itself*, not
   for being right. Measured consequence: across every arm and every extended replay (1×–8×, i.e. up to
   96 updates of sustained proxy rewards 0.45–0.96), the maximum overall score ever observed is
   **0.8347 — the episode-1, priors-only value** — and the exact gate (overall ≥ 0.84 AND min-adjusted
   ≥ 0.62) is **never crossed** (Table 7). The design doc's promise — "confidence can improve without a
   large labeled dataset" — is not realized in the as-built math: accumulating evidence *deepens* the
   discount (final proxy-arm trust means 0.73–0.77 after 96 updates, 0.64–0.74 after 12), so adjusted
   scores fall toward the trust means as influence grows and stay there. The system cannot warm up
   into automation.
2. **The self-blend floors trust and distorts telemetry.** Even truth=0 outcomes store ≈ 0.4+ rewards
   when the model self-agrees, so failures partially self-forgive each episode: at severe drift
   (factor 0.6) the mode-error bar is never reached again (Table 8b), and 33/50 changed-family seeds
   never stabilize (Table 8a). Meanwhile the shipped dashboard is miscalibrated by construction:
   `calibrationSnapshots` reports error against the *stored blended* reward — **0.098 vs an actual
   raw-vs-truth error of 0.479, a 4.9× understatement** in the as-built flow (Table 2). The operator
   sees a well-calibrated system that is not.
3. **Fixed, uncalibrated thresholds.** exact 0.84/0.62, review 0.57 (Swift 141–145) sit above the
   entire reachable score range: exact mode is dead code in this regime, and the review band does all
   the work while failing to discriminate — on the 7 countable held-out rows the proxy arm puts 3
   correct and 3 wrong proposals in the identical mode (Table 9). The thresholds carry no relationship
   to any measured reliability curve. The "actions-to-useful-confidence" metric is degenerate for the
   same reason: trailing-4 mode-error ≤ 0.25 "stabilizes" at episode 2 in every arm because the fixed
   thresholds keep everything in review/estimate from the start — stability without learning.
4. **Per-key priors tax weak-but-correct episodes.** The truth-channel arm drops 2 of 4 correct
   held-out-adjacent weak-evidence episodes to estimate_only (estimate-on-correct 2, mode-error 0.182)
   where Jeffreys priors drop 1 (mode-error 0.091) — the shipped priors' conservatism costs utility on
   exactly the RM-05/RM-14 "friction" family the spec flags. The differences are not separable at
   n=11 (intervals overlap), so this is directional, not decisive.
5. **Decay is a second-order knob here.** 0.99 / 0.997 / 0.999 / none: ECE 0.339 / 0.340 / 0.340 /
   0.341 — no meaningful sensitivity over 12–96 updates (Table 4). The problems live in the discount
   structure and the reward blend, not the decay.

## 3. Recommendation: **keep with named fixes**

Replace nothing; the Beta core wins on calibration-per-sample and simplicity. But "as built" cannot
claim learning until three named fixes land:

1. **Store and learn from the raw outcome.** Persist the unblended `outcomeReward` (keep the
   agreement term as a separate diagnostic column if wanted); Beta updates and `calibrationSnapshots`
   read the raw value. This single change fixes the 4.9× telemetry gap and un-floors drift recovery.
2. **Make the trust blend two-sided.** Replace `adjusted = raw·(1−influence) + (raw·mean)·influence`
   with a shrink toward the posterior-predictive outcome, e.g.
   `adjusted = (1−influence)·raw + influence·posterior_mean`, so good outcomes can *raise* adjusted
   scores. Keep the uncertainty penalty; it has the right sign.
3. **Derive the mode thresholds from the (fixed) calibration telemetry** instead of fixed
   0.84/0.62/0.57 — the exact gate as built is unreachable dead code; a threshold tied to the measured
   reliability curve is the design's own logic taken to completion.

**Decision bar for revisiting:** if a future replay with ≥ 100 independent-label episodes shows the
logistic calibrator's leave-one-out Brier beating the fixed Beta's, the calculus shifts toward
replace; at n=12 the evidence says keep and fix.

## 4. Feed-forward note for the parent's EVAL.md

- Part 0 certifies: proxy-vs-truth distortion quantified (telemetry understatement 4.9×; ECE 0.267 vs
  0.340 proxy vs truth on identical episodes); exact-gate unreachability with a mechanism
  (pure-discount trust, max overall 0.8347 = the no-evidence value); exact-mode never misfires
  (0 exact-on-wrong everywhere) — the layer's conservatism is real and its discrimination is not.
- Part 0 does not certify: native Swift behavior (UNVERIFIED-NATIVE — port differentially checked
  against Swift-source fixtures; nothing here ran the compiled service), generalization beyond the
  12-episode replay and PR #53's changed family, or the fixed thresholds' behavior on other flows
  (reverse-meal only). Those need their own harness instances.
- Reuse credit: PR #7's replay JSON (`truth_reward`/`proxy_reward` arms, state projection rules from
  its spec); PR #53's `histories.json` changed family + replay protocol (branch read-only, files
  credited with re-verified hashes in `data/PROVENANCE.md`).
