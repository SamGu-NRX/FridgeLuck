import type {
  ConfidenceAssessRequest,
  ConfidenceAssessResponse,
  ConfidenceMode,
  ConfidenceOutcomeRequest,
  ConfidenceSignalAssessment,
  ConfidenceSignalInput
} from "../types/contracts.js";

interface TrustState {
  alpha: number;
  beta: number;
}

// These are emitted by liveContextService and the iOS reverse-scan and recipe producers.
const KNOWN_SIGNAL_KEYS = new Set([
  "live.recipe_context",
  "live.camera_frame",
  "live.ingredient_coverage",
  "gemini.live_scene",
  "recipe_generation.scan_confidence",
  "reverse_scan.vision_detection",
  "reverse_scan.recipe_match",
  "reverse_scan.required_coverage",
  "reverse_scan.candidate_margin",
]);

// Keep recent diagnostic history without retaining every outcome for the process lifetime.
// No memory measurement supports this exact count yet.
const MAX_OUTCOME_EVENTS = 1_000;

function object(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object.`);
  }
  return value as Record<string, unknown>;
}

function score(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${path} must be a finite number in [0, 1].`);
  }
  return value;
}

function text(value: unknown, path: string, maxLength: number): string {
  if (typeof value !== "string" || value.length > maxLength) {
    throw new Error(`${path} must be a string of at most ${maxLength} characters.`);
  }
  return value;
}

/** Parse untrusted HTTP outcomes; internal replay callers retain their typed API. */
export function parseConfidenceOutcome(value: unknown): ConfidenceOutcomeRequest {
  const request = object(value, "outcome");
  const assessment = object(request.assessment, "assessment");
  const outcomeReward = score(request.outcomeReward, "outcomeReward");
  if (!Array.isArray(assessment.signals) || assessment.signals.length > KNOWN_SIGNAL_KEYS.size) {
    throw new Error("assessment.signals must be an array with at most one entry per known signal.");
  }
  const seen = new Set<string>();
  const signals = assessment.signals.map((value: unknown, index: number) => {
    const signal = object(value, `assessment.signals[${index}]`);
    if (typeof signal.key !== "string" || !KNOWN_SIGNAL_KEYS.has(signal.key) || seen.has(signal.key)) {
      throw new Error(`assessment.signals[${index}].key must be a unique known signal.`);
    }
    seen.add(signal.key);
    // The update algorithm already caps evidence weight at 1.6. Reject rather than clamp HTTP input.
    if (typeof signal.weight !== "number" || !Number.isFinite(signal.weight) || signal.weight <= 0 || signal.weight > 1.6) {
      throw new Error(`assessment.signals[${index}].weight must be finite and in (0, 1.6].`);
    }
    return {
      key: signal.key,
      rawScore: score(signal.rawScore, "signal.rawScore"),
      adjustedScore: score(signal.adjustedScore, "signal.adjustedScore"),
      trustMean: score(signal.trustMean, "signal.trustMean"),
      trustUncertainty: score(signal.trustUncertainty, "signal.trustUncertainty"),
      weight: signal.weight,
      // Bound retained/display text; these exact lengths have not been measured in production.
      reason: text(signal.reason, "signal.reason", 1_000),
    };
  });
  if (assessment.mode !== "exact" && assessment.mode !== "review_required" && assessment.mode !== "estimate_only") {
    throw new Error("assessment.mode is invalid.");
  }
  if (typeof assessment.deterministicReady !== "boolean") {
    throw new Error("assessment.deterministicReady must be a boolean.");
  }
  if (!Array.isArray(assessment.reasons) || assessment.reasons.length > KNOWN_SIGNAL_KEYS.size) {
    throw new Error("assessment.reasons must be a bounded array.");
  }
  return {
    assessment: {
      mode: assessment.mode,
      overallScore: score(assessment.overallScore, "assessment.overallScore"),
      deterministicReady: assessment.deterministicReady,
      reasons: assessment.reasons.map((value: unknown) => text(value, "assessment.reasons[]", 1_000)),
      signals,
    },
    outcomeReward,
    contextKey: request.contextKey === undefined ? undefined : text(request.contextKey, "contextKey", 1_000),
    note: request.note === undefined ? undefined : text(request.note, "note", 1_000),
  };
}

interface ConfidenceEvent {
  signalKey: string;
  rawScore: number;
  outcomeReward: number;
  contextKey?: string;
  note?: string;
  createdAt: string;
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function priorFor(signalKey: string): TrustState {
  const key = signalKey.toLowerCase();
  if (key.includes("ocr_exact")) return { alpha: 7.0, beta: 2.0 };
  if (key.includes("vision")) return { alpha: 6.0, beta: 2.4 };
  if (key.includes("ocr_fuzzy")) return { alpha: 3.4, beta: 3.0 };
  if (key.includes("portion")) return { alpha: 2.8, beta: 3.6 };
  if (key.includes("macro")) return { alpha: 4.4, beta: 2.8 };
  if (key.includes("gemini")) return { alpha: 4.8, beta: 2.7 };
  if (key.includes("recipe")) return { alpha: 4.5, beta: 2.9 };
  return { alpha: 4.0, beta: 3.0 };
}

function trustMean(trust: TrustState): number {
  return trust.alpha / (trust.alpha + trust.beta);
}

function trustUncertainty(trust: TrustState): number {
  const mean = trustMean(trust);
  return Math.sqrt((mean * (1 - mean)) / (trust.alpha + trust.beta + 1));
}

function normalizeSignal(input: ConfidenceSignalInput): ConfidenceSignalInput {
  return {
    key: input.key,
    rawScore: clamp01(input.rawScore),
    weight: Math.max(0.05, input.weight ?? 1.0),
    reason: input.reason ?? input.key
  };
}

export class ConfidenceService {
  private readonly trustBySignal = new Map<string, TrustState>();
  private readonly events: ConfidenceEvent[] = [];

  assess(request: ConfidenceAssessRequest): ConfidenceAssessResponse {
    const signals = request.signals.map(normalizeSignal);
    const hardFailReasons = request.hardFailReasons ?? [];

    if (signals.length === 0) {
      return {
        mode: "estimate_only",
        overallScore: 0,
        deterministicReady: false,
        reasons: ["No confidence signals available."],
        signals: []
      };
    }

    const assessments = signals.map((signal) => this.assessSignal(signal));

    const totalWeight = assessments.reduce((sum, signal) => sum + signal.weight, 0.0);
    const weightedLogSum = assessments.reduce(
      (sum, signal) => sum + signal.weight * Math.log(Math.max(signal.adjustedScore, 0.0001)),
      0.0
    );

    let overall = Math.exp(weightedLogSum / Math.max(totalWeight, 0.0001));
    const lowSignals = assessments.filter((signal) => signal.adjustedScore < 0.45);
    const contradictionPenalty = lowSignals.length * 0.08;
    overall = clamp01(overall - contradictionPenalty);

    const reasons = [...hardFailReasons];
    for (const signal of lowSignals.slice(0, 3)) {
      reasons.push(`Low confidence in ${signal.reason.toLowerCase()}.`);
    }

    let mode: ConfidenceMode;
    if (hardFailReasons.length > 0) {
      mode = "estimate_only";
      overall = Math.min(overall, 0.42);
    } else {
      const minAdjusted = Math.min(...assessments.map((signal) => signal.adjustedScore));
      if (overall >= 0.84 && minAdjusted >= 0.62) {
        mode = "exact";
      } else if (overall >= 0.57) {
        mode = "review_required";
      } else {
        mode = "estimate_only";
      }
    }

    if (reasons.length === 0) {
      reasons.push(`Confidence mode: ${mode}.`);
    }

    return {
      mode,
      overallScore: clamp01(overall),
      deterministicReady: mode === "exact",
      reasons,
      signals: assessments
    };
  }

  recordOutcome(request: ConfidenceOutcomeRequest): void {
    const reward = clamp01(request.outcomeReward);
    const now = new Date().toISOString();

    for (const signal of request.assessment.signals) {
      const calibrationReward = clamp01(1 - Math.abs(reward - signal.adjustedScore));
      const weightedReward = clamp01(reward * 0.55 + calibrationReward * 0.45);
      const updateWeight = Math.max(0.25, Math.min(signal.weight, 1.6));
      const current = this.getTrust(signal.key);
      const decay = 0.997;
      const next: TrustState = {
        alpha: 1 + Math.max(0, (current.alpha - 1) * decay) + weightedReward * updateWeight,
        beta: 1 + Math.max(0, (current.beta - 1) * decay) + (1 - weightedReward) * updateWeight
      };

      this.trustBySignal.set(signal.key, next);
      this.events.push({
        signalKey: signal.key,
        rawScore: signal.rawScore,
        outcomeReward: weightedReward,
        contextKey: request.contextKey,
        note: request.note,
        createdAt: now
      });
    }

    if (this.events.length > MAX_OUTCOME_EVENTS) {
      this.events.splice(0, this.events.length - MAX_OUTCOME_EVENTS);
    }
  }

  calibrationSnapshots(limit = 50): Array<{
    signalKey: string;
    eventCount: number;
    averageRawScore: number;
    averageOutcomeReward: number;
    averageAbsoluteError: number;
    trustMean: number;
    trustUncertainty: number;
  }> {
    const grouped = new Map<string, ConfidenceEvent[]>();

    for (const event of this.events) {
      const bucket = grouped.get(event.signalKey) ?? [];
      bucket.push(event);
      grouped.set(event.signalKey, bucket);
    }

    return [...grouped.entries()]
      .map(([signalKey, items]) => {
        const trust = this.getTrust(signalKey);
        const averageRawScore = items.reduce((sum, item) => sum + item.rawScore, 0) / items.length;
        const averageOutcomeReward =
          items.reduce((sum, item) => sum + item.outcomeReward, 0) / items.length;
        const averageAbsoluteError =
          items.reduce((sum, item) => sum + Math.abs(item.rawScore - item.outcomeReward), 0) /
          items.length;

        return {
          signalKey,
          eventCount: items.length,
          averageRawScore,
          averageOutcomeReward,
          averageAbsoluteError,
          trustMean: trustMean(trust),
          trustUncertainty: trustUncertainty(trust)
        };
      })
      .sort((a, b) => b.eventCount - a.eventCount)
      .slice(0, Math.max(1, Math.min(limit, 200)));
  }

  private assessSignal(input: ConfidenceSignalInput): ConfidenceSignalAssessment {
    const trust = this.getTrust(input.key);
    const mean = trustMean(trust);
    const uncertainty = trustUncertainty(trust);
    const sampleSize = trust.alpha + trust.beta;
    const trustInfluence = Math.max(0.2, Math.min((sampleSize - 2.0) / 18.0, 1.0));
    const trustWeightedRaw = input.rawScore * mean;
    const blended = input.rawScore * (1 - trustInfluence) + trustWeightedRaw * trustInfluence;
    const uncertaintyPenalty = 0.2 * uncertainty;

    return {
      key: input.key,
      rawScore: input.rawScore,
      adjustedScore: clamp01(blended - uncertaintyPenalty),
      trustMean: mean,
      trustUncertainty: uncertainty,
      weight: input.weight ?? 1,
      reason: input.reason ?? input.key
    };
  }

  private getTrust(signalKey: string): TrustState {
    return this.trustBySignal.get(signalKey) ?? priorFor(signalKey);
  }
}
