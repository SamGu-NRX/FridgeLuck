/**
 * M1 contract tests: state transitions of the REAL ConfidenceService.
 *
 * Every expected value is recomputed here by hand-derived formulas
 * (model.ts) — Beta posteriors, the 0.997 decay recursion, geometric-mean
 * fusion, clamps and mode thresholds — never by calling into the service.
 */
import { describe, it, expect } from "bun:test";
import { ConfidenceService } from "../../../../src/services/confidenceService.js";
import {
  PRIOR_MEAN_ANCHORS,
  expectedAssessSignal,
  expectedFusion,
  expectedPrior,
  expectedSingleKeyChain,
  trustMean as modelTrustMean,
  trustUncertainty as modelTrustUncertainty
} from "../model.js";

describe("ConfidenceService state transitions (M1)", () => {
  it("returns the literal estimate_only response for empty signals and touches no state", () => {
    const svc = new ConfidenceService();
    const res = svc.assess({ signals: [] });
    expect(res).toEqual({
      mode: "estimate_only",
      overallScore: 0,
      deterministicReady: false,
      reasons: ["No confidence signals available."],
      signals: []
    });
    expect(svc.calibrationSnapshots()).toEqual([]);
  });

  it("treats recordOutcome with an empty-signal assessment as a no-op", () => {
    const svc = new ConfidenceService();
    const assessment = svc.assess({ signals: [] });
    svc.recordOutcome({ assessment, outcomeReward: 1.0 });
    expect(svc.calibrationSnapshots()).toEqual([]);
  });

  it("matches the hand-derived Bayesian update for a single outcome", () => {
    const svc = new ConfidenceService();
    const res = svc.assess({ signals: [{ key: "vision.scan", rawScore: 0.8, weight: 1.0 }] });
    // Independent step-0 expectations from the {6.0, 2.4} prior.
    const step0 = expectedAssessSignal({ alpha: 6.0, beta: 2.4 }, "vision.scan", 0.8, 1.0);
    expect(res.signals[0]!.adjustedScore).toBeCloseTo(step0.adjustedScore, 9);
    expect(res.signals[0]!.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.vision, 9);

    svc.recordOutcome({ assessment: res, outcomeReward: 1.0 });

    const chain = expectedSingleKeyChain("vision.scan", [{ rawScore: 0.8, weight: 1.0, reward: 1.0 }]);
    const snaps = svc.calibrationSnapshots();
    expect(snaps.length).toBe(1);
    expect(snaps[0]!.eventCount).toBe(1);
    expect(snaps[0]!.trustMean).toBeCloseTo(modelTrustMean(chain.finalTrust), 9);
    expect(snaps[0]!.trustUncertainty).toBeCloseTo(modelTrustUncertainty(chain.finalTrust), 9);
  });

  it("accumulates repeated outcomes with the 0.997 decay recursion", () => {
    const svc = new ConfidenceService();
    const steps = [1.0, 0.0, 1.0, 0.0, 1.0].map((reward) => ({
      rawScore: 0.9,
      weight: 1.0,
      reward
    }));
    for (const step of steps) {
      const res = svc.assess({ signals: [{ key: "ocr_exact.brand", rawScore: step.rawScore, weight: step.weight }] });
      svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
    }
    const chain = expectedSingleKeyChain("ocr_exact.brand", steps);
    const snap = svc.calibrationSnapshots().find((s) => s.signalKey === "ocr_exact.brand");
    expect(snap).toBeDefined();
    expect(snap!.eventCount).toBe(5);
    expect(snap!.trustMean).toBeCloseTo(modelTrustMean(chain.finalTrust), 9);
    expect(snap!.trustUncertainty).toBeCloseTo(modelTrustUncertainty(chain.finalTrust), 9);
  });

  it("a fresh instance restarts from priors while the old instance keeps its in-memory state", () => {
    const svc = new ConfidenceService();
    for (const reward of [1.0, 0.0, 1.0]) {
      const res = svc.assess({ signals: [{ key: "ocr_exact.brand", rawScore: 0.9, weight: 1.0 }] });
      svc.recordOutcome({ assessment: res, outcomeReward: reward });
    }
    expect(svc.calibrationSnapshots().length).toBe(1);

    const fresh = new ConfidenceService();
    const freshFirst = fresh.assess({ signals: [{ key: "ocr_exact.brand", rawScore: 0.9, weight: 1.0 }] });
    // Independent anchor: fresh state ⇒ the ocr_exact prior mean 7/9 again.
    expect(freshFirst.signals[0]!.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.ocrExact, 9);
    expect(fresh.calibrationSnapshots()).toEqual([]);
  });

  it("clamps rawScore, applies the weight floor, and clamps rewards before updating", () => {
    const svc = new ConfidenceService();
    const steps = [
      { rawScore: 1.5, weight: 0, reward: 2.5 }, // raw → 1.0, weight → 0.05, reward → 1.0
      { rawScore: -0.5, weight: 5, reward: -1.0 } // raw → 0.0, weight → 5, reward → 0.0
    ];
    for (const step of steps) {
      const res = svc.assess({ signals: [{ key: "portion.est", rawScore: step.rawScore, weight: step.weight }] });
      // Literal clamp expectations, independent of trust state:
      // rawScore clamps into [0,1]; weight floors at 0.05 (no upper clamp here).
      if (step.rawScore === 1.5) {
        expect(res.signals[0]!.rawScore).toBe(1.0);
        expect(res.signals[0]!.weight).toBe(0.05); // max(0.05, 0)
      } else {
        expect(res.signals[0]!.rawScore).toBe(0.0);
        expect(res.signals[0]!.weight).toBe(5); // no upper clamp at normalize time
      }
      svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
    }
    const chain = expectedSingleKeyChain("portion.est", steps);
    const snap = svc.calibrationSnapshots().find((s) => s.signalKey === "portion.est");
    expect(snap!.trustMean).toBeCloseTo(modelTrustMean(chain.finalTrust), 9);
  });

  it("caps overall at 0.42 with hard-fail reasons and preserves reason order", () => {
    const svc = new ConfidenceService();
    const res = svc.assess({
      signals: [{ key: "gemini.rerank", rawScore: 0.85, weight: 1.0 }],
      hardFailReasons: ["Missing required ingredient."]
    });
    const model = expectedFusion(
      [expectedAssessSignal(expectedPrior("gemini.rerank"), "gemini.rerank", 0.85, 1.0)],
      ["Missing required ingredient."]
    );
    expect(res.mode).toBe("estimate_only");
    expect(res.overallScore).toBeCloseTo(model.overallScore, 9);
    expect(res.overallScore).toBeLessThanOrEqual(0.42);
    expect(res.reasons).toEqual(model.reasons);
    expect(res.reasons[0]).toBe("Missing required ingredient.");
  });

  it("reaches exact mode for a fresh high-raw trio exactly as the fusion math predicts", () => {
    const svc = new ConfidenceService();
    const signals = [
      { key: "vision.fresh", rawScore: 0.999, weight: 1.0 },
      { key: "ocr_exact.fresh", rawScore: 0.999, weight: 1.0 },
      { key: "macro.fresh", rawScore: 0.999, weight: 1.0 }
    ];
    const res = svc.assess({ signals });
    const model = expectedFusion(
      signals.map((s) => expectedAssessSignal(expectedPrior(s.key), s.key, s.rawScore, s.weight))
    );
    expect(res.mode).toBe("exact");
    expect(res.deterministicReady).toBe(true);
    expect(res.overallScore).toBeCloseTo(model.overallScore, 9);
    expect(res.reasons).toEqual(model.reasons); // fallback mode line
  });

  it("applies the contradiction penalty and lowercases the offending signal's reason", () => {
    const svc = new ConfidenceService();
    const signals = [
      { key: "vision.high", rawScore: 0.9, weight: 1.0 },
      { key: "portion.low", rawScore: 0.3, weight: 1.0 }
    ];
    const res = svc.assess({ signals });
    const model = expectedFusion(
      signals.map((s) => expectedAssessSignal(expectedPrior(s.key), s.key, s.rawScore, s.weight))
    );
    expect(res.overallScore).toBeCloseTo(model.overallScore, 9); // includes the 0.08 penalty
    expect(res.reasons).toEqual(model.reasons);
    expect(res.reasons).toContain("Low confidence in portion.low.");
  });

  it("tracks a 20-step history through the decay recursion", () => {
    const svc = new ConfidenceService();
    const steps = Array.from({ length: 20 }, (_, i) => ({
      rawScore: 0.7,
      weight: 1.0,
      reward: i % 2 === 0 ? 1.0 : 0.0
    }));
    for (const step of steps) {
      const res = svc.assess({ signals: [{ key: "macro.twenty", rawScore: step.rawScore, weight: step.weight }] });
      svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
    }
    const chain = expectedSingleKeyChain("macro.twenty", steps);
    const snap = svc.calibrationSnapshots().find((s) => s.signalKey === "macro.twenty");
    expect(snap!.eventCount).toBe(20);
    expect(snap!.trustMean).toBeCloseTo(modelTrustMean(chain.finalTrust), 9);
    expect(snap!.trustUncertainty).toBeCloseTo(modelTrustUncertainty(chain.finalTrust), 9);
  });

  it("clamps the snapshot limit: 0 yields one bucket, oversized limits cap at 200", () => {
    const svc = new ConfidenceService();
    for (const key of ["a.key", "b.key", "c.key"]) {
      const res = svc.assess({ signals: [{ key, rawScore: 0.7, weight: 1.0 }] });
      svc.recordOutcome({ assessment: res, outcomeReward: 1.0 });
    }
    expect(svc.calibrationSnapshots(0).length).toBe(1);
    expect(svc.calibrationSnapshots(2).length).toBe(2);
    expect(svc.calibrationSnapshots(1000).length).toBe(3); // ≤ 200 cap, 3 buckets exist
  });
});
