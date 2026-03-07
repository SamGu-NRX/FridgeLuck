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
