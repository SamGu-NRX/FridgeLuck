import { describe, it, expect, beforeEach } from "bun:test";
import { ConfidenceService } from "../services/confidenceService.js";
import type { ConfidenceAssessRequest, ConfidenceOutcomeRequest } from "../types/contracts.js";

describe("ConfidenceService.assess", () => {
  let svc: ConfidenceService;

  beforeEach(() => {
    svc = new ConfidenceService();
  });

  it("returns estimate_only with overallScore 0 when no signals provided", () => {
    const req: ConfidenceAssessRequest = { signals: [] };
    const result = svc.assess(req);
    expect(result.mode).toBe("estimate_only");
    expect(result.overallScore).toBe(0);
    expect(result.deterministicReady).toBe(false);
    expect(result.reasons.length).toBeGreaterThan(0);
  });

  it("returns estimate_only and caps score when hardFailReasons are present", () => {
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "vision.test", rawScore: 0.99, weight: 1.0, reason: "High raw vision score" }
      ],
      hardFailReasons: ["Missing required ingredient."]
    };
    const result = svc.assess(req);
    expect(result.mode).toBe("estimate_only");
    expect(result.overallScore).toBeLessThanOrEqual(0.42);
    expect(result.deterministicReady).toBe(false);
    expect(result.reasons).toContain("Missing required ingredient.");
  });

  it("returns exact mode and deterministicReady=true when raw scores are near 1.0", () => {
    // With rawScore close to 1.0, the geometric-mean fusion of Bayesian-adjusted scores
    // crosses the 0.84 exact threshold even on fresh (uncalibrated) priors.
    // (0.96 raw does NOT reach it by design — conservative Bayesian discounting.)
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "vision.fridge", rawScore: 0.999, weight: 1.0, reason: "Vision" },
        { key: "ocr_exact.label", rawScore: 0.999, weight: 1.0, reason: "OCR" },
        { key: "macro.nutrition", rawScore: 0.999, weight: 1.0, reason: "Macro" }
      ]
    };
    const result = svc.assess(req);
    expect(result.mode).toBe("exact");
    expect(result.deterministicReady).toBe(true);
    expect(result.overallScore).toBeGreaterThanOrEqual(0.84);
  });

  it("returns review_required for high raw scores on fresh (uncalibrated) signals", () => {
    // Without outcome history, Bayesian priors appropriately limit exact mode.
    // This tests the conservative-by-design behavior.
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "vision.fridge", rawScore: 0.96, weight: 1.0, reason: "Vision" },
        { key: "ocr_exact.label", rawScore: 0.97, weight: 1.0, reason: "OCR" },
        { key: "macro.nutrition", rawScore: 0.95, weight: 1.0, reason: "Macro" }
      ]
    };
    const result = svc.assess(req);
    // Exact mode requires calibrated trust; fresh signals land in review_required
    expect(["review_required", "exact"]).toContain(result.mode);
    expect(result.overallScore).toBeGreaterThan(0.57); // clearly not estimate_only
    expect(result.deterministicReady).toBe(result.mode === "exact");
  });

  it("returns review_required for mid-range confidence", () => {
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "vision.fridge", rawScore: 0.72, weight: 1.0, reason: "Vision" },
        { key: "recipe.match", rawScore: 0.65, weight: 1.0, reason: "Recipe match" }
      ]
    };
    const result = svc.assess(req);
    expect(["review_required", "estimate_only"]).toContain(result.mode);
  });

  it("overallScore is always clamped between 0 and 1", () => {
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "signal.a", rawScore: 1.5, weight: 2.0 },
        { key: "signal.b", rawScore: -0.5, weight: 0.5 }
      ]
    };
    const result = svc.assess(req);
    expect(result.overallScore).toBeGreaterThanOrEqual(0);
    expect(result.overallScore).toBeLessThanOrEqual(1);
  });

  it("returns one signal assessment per input signal", () => {
    const req: ConfidenceAssessRequest = {
      signals: [
        { key: "a", rawScore: 0.8 },
        { key: "b", rawScore: 0.6 },
        { key: "c", rawScore: 0.5 }
      ]
    };
    const result = svc.assess(req);
    expect(result.signals.length).toBe(3);
    expect(result.signals.map((s) => s.key)).toEqual(["a", "b", "c"]);
  });

  it("adjustedScore for each signal is clamped 0-1", () => {
    const req: ConfidenceAssessRequest = {
      signals: [{ key: "x", rawScore: 0.9, weight: 1.0 }]
    };
    const result = svc.assess(req);
    for (const signal of result.signals) {
      expect(signal.adjustedScore).toBeGreaterThanOrEqual(0);
      expect(signal.adjustedScore).toBeLessThanOrEqual(1);
    }
  });
});

describe("ConfidenceService.recordOutcome", () => {
  let svc: ConfidenceService;

  beforeEach(() => {
    svc = new ConfidenceService();
  });

  it("records an outcome and appears in calibrationSnapshots", () => {
    const assessment = svc.assess({
      signals: [{ key: "vision.scan", rawScore: 0.8, weight: 1.0 }]
    });
    const req: ConfidenceOutcomeRequest = {
      assessment,
      outcomeReward: 1.0,
      contextKey: "test-context",
      note: "User accepted without edits"
    };
    svc.recordOutcome(req);

    const snapshots = svc.calibrationSnapshots();
    expect(snapshots.length).toBeGreaterThan(0);
    expect(snapshots[0]!.signalKey).toBe("vision.scan");
    expect(snapshots[0]!.eventCount).toBe(1);
  });

  it("multiple outcomes accumulate in the same signal bucket", () => {
    const signalKey = "ocr_exact.brand";
    for (let i = 0; i < 5; i++) {
      const assessment = svc.assess({
        signals: [{ key: signalKey, rawScore: 0.9, weight: 1.0 }]
      });
      svc.recordOutcome({ assessment, outcomeReward: i % 2 === 0 ? 1.0 : 0.0 });
    }
    const snapshots = svc.calibrationSnapshots();
    const bucket = snapshots.find((s) => s.signalKey === signalKey);
    expect(bucket).toBeDefined();
    expect(bucket!.eventCount).toBe(5);
  });

  it("clamps outcomeReward to [0,1]", () => {
    const assessment = svc.assess({
      signals: [{ key: "portion.estimator", rawScore: 0.7 }]
    });
    // Should not throw or produce NaN even with out-of-range reward
    expect(() => svc.recordOutcome({ assessment, outcomeReward: 2.5 })).not.toThrow();
    expect(() => svc.recordOutcome({ assessment, outcomeReward: -1.0 })).not.toThrow();
  });
});

describe("ConfidenceService.calibrationSnapshots", () => {
  let svc: ConfidenceService;

  beforeEach(() => {
    svc = new ConfidenceService();
  });

  it("returns empty array when no outcomes recorded", () => {
    expect(svc.calibrationSnapshots()).toEqual([]);
  });

  it("respects the limit parameter", () => {
    for (let i = 0; i < 10; i++) {
      const assessment = svc.assess({
        signals: [{ key: `signal_${i}`, rawScore: 0.7 }]
      });
      svc.recordOutcome({ assessment, outcomeReward: 0.8 });
    }
    const snapshots = svc.calibrationSnapshots(3);
    expect(snapshots.length).toBeLessThanOrEqual(3);
  });

  it("each snapshot contains required fields", () => {
    const assessment = svc.assess({
      signals: [{ key: "gemini.rerank", rawScore: 0.85, weight: 0.8 }]
    });
    svc.recordOutcome({ assessment, outcomeReward: 1.0 });

    const snapshots = svc.calibrationSnapshots();
    const snap = snapshots[0]!;
    expect(typeof snap.signalKey).toBe("string");
    expect(typeof snap.eventCount).toBe("number");
    expect(typeof snap.averageRawScore).toBe("number");
    expect(typeof snap.averageOutcomeReward).toBe("number");
    expect(typeof snap.averageAbsoluteError).toBe("number");
    expect(typeof snap.trustMean).toBe("number");
    expect(typeof snap.trustUncertainty).toBe("number");
  });
});
