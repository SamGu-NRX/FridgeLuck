/**
 * M1 contract tests: key handling of the REAL ConfidenceService.
 *
 * Pins, against hand-derived anchors (not calls into the service):
 * - priors are selected from the LOWERCASED key by ordered substring match;
 * - surrounding whitespace does not change prior selection;
 * - non-ASCII case variants (fullwidth) do not fold to ASCII → default prior;
 * - learned state is stored under the VERBATIM key, so prior-equivalent keys
 *   still accumulate distinct learned states;
 * - reason strings fold case but preserve whitespace (public-output nuance).
 */
import { describe, it, expect } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { ConfidenceService } from "../../../../src/services/confidenceService.js";
import {
  BASE_KEY,
  EXPECTED_VARIANT_COUNTS,
  KEY_VARIANTS,
  PRIOR_MEAN_ANCHORS,
  VARIANT_STEPS,
  expectedSingleKeyChain,
  trustMean as modelTrustMean
} from "../model.js";
import { firstAssessOf, measureVariantPairCounts, runInterleaved } from "../experiments.js";

describe("ConfidenceService key/prior contract (M1)", () => {
  it("selects the vision prior for exact, mixed-case and whitespace variants of the base key", () => {
    for (const variant of KEY_VARIANTS.filter((v) => v.priorClass === "vision")) {
      const first = firstAssessOf(new ConfidenceService(), variant.key);
      // Independent anchor: vision prior is {6.0, 2.4} → mean 6/(6+2.4).
      expect(first.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.vision, 9);
      expect(first.trustUncertainty).toBeGreaterThan(0);
      expect(first.mode).toBe("review_required"); // raw 0.8 on fresh prior
    }
  });

  it("falls back to the default prior for a fullwidth (non-ASCII-folding) case variant", () => {
    const fullwidth = KEY_VARIANTS.find((v) => v.label === "fullwidth-unicode")!;
    const first = firstAssessOf(new ConfidenceService(), fullwidth.key);
    // Independent anchor: default prior {4.0, 3.0} → mean 4/7. toLowerCase() does
    // not fold fullwidth letters to ASCII, so the "vision" needle never matches.
    expect(first.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.default, 9);
  });

  it("matches priors by substring, not exact equality", () => {
    const first = firstAssessOf(new ConfidenceService(), "myvision.custom");
    expect(first.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.vision, 9);
  });

  it("resolves the prior table in order: ocr_exact wins over vision", () => {
    const first = firstAssessOf(new ConfidenceService(), "ocr_exact.vision");
    // Independent anchor: ocr_exact prior {7.0, 2.0} → mean 7/9.
    expect(first.trustMean).toBeCloseTo(PRIOR_MEAN_ANCHORS.ocrExact, 9);
  });

  it("folds case but preserves whitespace in public reason strings", () => {
    const exact = firstAssessOf(new ConfidenceService(), BASE_KEY, 0.3).reasons;
    const mixed = firstAssessOf(new ConfidenceService(), "Vision.Scan", 0.3).reasons;
    const whitespace = firstAssessOf(new ConfidenceService(), " vision.scan ", 0.3).reasons;
    expect(exact).toEqual(["Low confidence in vision.scan."]);
    // Case is folded away in reasons...
    expect(mixed).toEqual(["Low confidence in vision.scan."]);
    // ...but the verbatim whitespace survives: the key's own spaces are kept,
    // so the rendered line has a double space and a space before the period.
    expect(whitespace).toEqual(["Low confidence in  vision.scan ."]);
  });

  it("stores learned state under the verbatim key: interleaved variants fragment into separate buckets", () => {
    const keys = [BASE_KEY, "Vision.Scan"];
    const assignments = VARIANT_STEPS.map((step, idx) => ({ key: keys[idx % 2]!, step }));
    const buckets = runInterleaved(assignments);

    expect(buckets.length).toBe(2);
    const exact = buckets.find((b) => b.signalKey === BASE_KEY);
    const mixed = buckets.find((b) => b.signalKey === "Vision.Scan");
    expect(exact).toBeDefined();
    expect(mixed).toBeDefined();
    expect(exact!.eventCount).toBe(3);
    expect(mixed!.eventCount).toBe(3);

    // Each bucket's trust must equal the hand-derived chain over ITS OWN event
    // subset (exact got steps 0/2/4, mixed got steps 1/3/5) — not the merged set.
    const expectedExact = expectedSingleKeyChain(BASE_KEY, [0, 2, 4].map((i) => VARIANT_STEPS[i]!));
    const expectedMixed = expectedSingleKeyChain("Vision.Scan", [1, 3, 5].map((i) => VARIANT_STEPS[i]!));
    expect(exact!.trustMean).toBeCloseTo(modelTrustMean(expectedExact.finalTrust), 9);
    expect(mixed!.trustMean).toBeCloseTo(modelTrustMean(expectedMixed.finalTrust), 9);
  });

  it("counterfactual merged-key run keeps a single bucket that matches neither interleaved bucket", () => {
    const merged = runInterleaved(VARIANT_STEPS.map((step) => ({ key: BASE_KEY, step })));
    expect(merged.length).toBe(1);
    expect(merged[0]!.eventCount).toBe(6);

    const assignments = VARIANT_STEPS.map((step, idx) => ({
      key: idx % 2 === 0 ? BASE_KEY : "Vision.Scan",
      step
    }));
    const interleaved = runInterleaved(assignments);
    const expectedMerged = expectedSingleKeyChain(BASE_KEY, VARIANT_STEPS);
    expect(merged[0]!.trustMean).toBeCloseTo(modelTrustMean(expectedMerged.finalTrust), 9);
    for (const bucket of interleaved) {
      expect(Math.abs(bucket.trustMean - merged[0]!.trustMean)).toBeGreaterThan(1e-9);
    }
  });

  it("measures prior-equivalence vs learned-state counts and records them", () => {
    const counts = measureVariantPairCounts();
    expect(counts.variants).toBe(EXPECTED_VARIANT_COUNTS.variants);
    expect(counts.totalPairs).toBe(EXPECTED_VARIANT_COUNTS.totalPairs);
    expect(counts.priorEquivalent).toBe(EXPECTED_VARIANT_COUNTS.priorEquivalent);
    expect(counts.priorDistinct).toBe(EXPECTED_VARIANT_COUNTS.priorDistinct);
    expect(counts.learnedStateDistinct).toBe(EXPECTED_VARIANT_COUNTS.learnedStateDistinct);
    expect(counts.learnedStateShared).toBe(EXPECTED_VARIANT_COUNTS.learnedStateShared);
    expect(counts.priorEquivalentButStateDistinct).toBe(
      EXPECTED_VARIANT_COUNTS.priorEquivalentButStateDistinct
    );

    // Commit the measured counts as the M1 record (deterministic content).
    const record = {
      tool: "m1-variant-counts",
      generatedBy: "bun test tools/offline/confidence-contract/tests",
      hypothesis:
        "Priors are chosen from the lowercased key but learned state is stored under the verbatim key.",
      variants: KEY_VARIANTS,
      counts,
      expected: EXPECTED_VARIANT_COUNTS,
      priorMeanAnchors: PRIOR_MEAN_ANCHORS
    };
    const resultsDir = path.join(import.meta.dir, "..", "results");
    mkdirSync(resultsDir, { recursive: true });
    writeFileSync(path.join(resultsDir, "m1-variant-counts.json"), JSON.stringify(record, null, 2) + "\n");
  });
});
