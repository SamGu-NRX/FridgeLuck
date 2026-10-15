import { createHash } from "node:crypto";
import { ConfidenceService } from "../services/confidenceService.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";
import { canonicalJson } from "./canonicalJson.js";
import { validateRequest, type RoutingRequest } from "./routingInput.js";

// Synthetic development state, authored from source priors and signal-key vocabulary
// only, not the running service's learned state, not tuned on held-out labels or outcomes.
export const DEV_SEQUENCE = [
  { key: "vision.identity", rawScore: 0.85, rewards: [1, 1, 1, 0, 1, 1, 0, 1] },
  { key: "ocr_exact.identity", rawScore: 0.95, rewards: [1, 1, 1, 1, 1, 1] },
  { key: "ocr_fuzzy.identity", rawScore: 0.70, rewards: [1, 0, 1, 0, 0, 1] },
  { key: "portion.visual", rawScore: 0.70, rewards: [0, 0.5, 0, 0.5, 0, 0] },
  { key: "manual.scale", rawScore: 0.98, rewards: [1, 1, 1, 1] },
  { key: "gemini.live_scene", rawScore: 0.80, rewards: [1, 0, 1, 1] }
] as const;
export const DEV_SEQUENCE_HASH = createHash("sha256").update(canonicalJson(DEV_SEQUENCE)).digest("hex");
const warmedKeys = new Set<string>(DEV_SEQUENCE.map(block => block.key));

function normalize(assessment: ConfidenceAssessResponse, request: RoutingRequest, warm: boolean) {
  if (assessment.deterministicReady !== (assessment.mode === "exact")) throw new Error("Bayesian conformance: deterministicReady disagrees with mode");
  if (!Number.isFinite(assessment.overallScore) || assessment.overallScore < 0 || assessment.overallScore > 1) throw new Error("Bayesian conformance: overallScore outside [0,1]");
  return {
    status: "ok" as const,
    mode: assessment.mode,
    diagnostics: {
      overallScore: assessment.overallScore,
      signals: assessment.signals.map(({ key, adjustedScore, trustMean }) => ({ key, adjustedScore, trustMean })),
      warmedSignalKeys: warm ? [...new Set(request.signals.map(s => s.key).filter(k => warmedKeys.has(k)))].sort() : []
    }
  };
}
export function assessCold(request: RoutingRequest) {
  validateRequest(request);
  return normalize(new ConfidenceService().assess(request), request, false);
}
export function assessWarm(request: RoutingRequest) {
  validateRequest(request);
  const service = new ConfidenceService();
  for (const block of DEV_SEQUENCE) {
    for (const outcomeReward of block.rewards) {
      const developmentRequest = {
        signals: [{ key: block.key, rawScore: block.rawScore, weight: 1, reason: block.key }],
        hardFailReasons: []
      };
      service.recordOutcome({ assessment: service.assess(developmentRequest), outcomeReward, contextKey: "dev-warm-v1" });
    }
  }
  return normalize(service.assess(request), request, true);
}
