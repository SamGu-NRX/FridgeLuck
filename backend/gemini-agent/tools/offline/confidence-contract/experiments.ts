/**
 * Experiment drivers that execute the ACTUAL production ConfidenceService
 * (imported unchanged from src/services/confidenceService.js) and return
 * plain measurement data. Import-only: no network, no filesystem, no clock —
 * callers decide what to time and where to persist.
 */
import { ConfidenceService } from "../../../src/services/confidenceService.js";
import {
  KEY_VARIANTS,
  VARIANT_STEPS,
  type StepTriple
} from "./model.js";

/** Tolerance used when classifying two measurements as "the same number". */
export const NUMERIC_EPS = 1e-12;

export function numsEqual(a: number, b: number, eps = NUMERIC_EPS): boolean {
  return Math.abs(a - b) <= eps;
}

export interface FirstAssess {
  trustMean: number;
  trustUncertainty: number;
  adjustedScore: number;
  mode: string;
  overallScore: number;
  reasons: string[];
}

/** First assess() on a fresh service — a pure prior read (assess never mutates state). */
export function firstAssessOf(
  svc: ConfidenceService,
  key: string,
  rawScore = 0.8,
  weight = 1.0
): FirstAssess {
  const res = svc.assess({ signals: [{ key, rawScore, weight }] });
  const signal = res.signals[0];
  if (!signal) throw new Error(`assess returned no signal assessment for key ${JSON.stringify(key)}`);
  return {
    trustMean: signal.trustMean,
    trustUncertainty: signal.trustUncertainty,
    adjustedScore: signal.adjustedScore,
    mode: res.mode,
    overallScore: res.overallScore,
    reasons: [...res.reasons]
  };
}

export interface IsolatedChain {
  key: string;
  perStep: Array<{
    adjustedScore: number;
    trustMean: number;
    trustUncertainty: number;
    mode: string;
    overallScore: number;
    reasons: string[];
  }>;
  finalTrustMean: number;
  finalTrustUncertainty: number;
  eventCount: number;
  snapshotKeys: string[];
}

/** Drives the full assess -> recordOutcome chain for one verbatim key on a fresh instance. */
export function runIsolatedChain(key: string, steps: StepTriple[]): IsolatedChain {
  const svc = new ConfidenceService();
  const perStep: IsolatedChain["perStep"] = [];
  for (const step of steps) {
    const res = svc.assess({ signals: [{ key, rawScore: step.rawScore, weight: step.weight }] });
    const signal = res.signals[0];
    if (!signal) throw new Error(`assess returned no signal assessment for key ${JSON.stringify(key)}`);
    perStep.push({
      adjustedScore: signal.adjustedScore,
      trustMean: signal.trustMean,
      trustUncertainty: signal.trustUncertainty,
      mode: res.mode,
      overallScore: res.overallScore,
      reasons: [...res.reasons]
    });
    svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
  }
  const snaps = svc.calibrationSnapshots(200);
  const own = snaps.find((b) => b.signalKey === key);
  return {
    key,
    perStep,
    finalTrustMean: own ? own.trustMean : Number.NaN,
    finalTrustUncertainty: own ? own.trustUncertainty : Number.NaN,
    eventCount: own ? own.eventCount : 0,
    snapshotKeys: snaps.map((b) => b.signalKey)
  };
}

export interface Bucket {
  signalKey: string;
  eventCount: number;
  trustMean: number;
  trustUncertainty: number;
  averageRawScore: number;
  averageOutcomeReward: number;
  averageAbsoluteError: number;
}

/** Drives pre-assigned (key, step) pairs through ONE shared instance; returns its snapshot buckets. */
export function runInterleaved(assignments: Array<{ key: string; step: StepTriple }>): Bucket[] {
  const svc = new ConfidenceService();
  for (const { key, step } of assignments) {
    const res = svc.assess({ signals: [{ key, rawScore: step.rawScore, weight: step.weight }] });
    svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
  }
  return svc.calibrationSnapshots(200).map((b) => ({ ...b }));
}

export interface VariantPairCounts {
  variants: number;
  totalPairs: number;
  priorEquivalent: number;
  priorDistinct: number;
  learnedStateDistinct: number;
  learnedStateShared: number;
  priorEquivalentButStateDistinct: number;
  priorEquivalentPairs: Array<[string, string]>;
  priorDistinctPairs: Array<[string, string]>;
}

/**
 * Measures, for every unordered variant pair:
 * - prior equivalence: identical prior read (trustMean/trustUncertainty/adjustedScore)
 *   from fresh instances of the REAL service;
 * - learned-state distinction: driving the same interleaved history through ONE
 *   instance yields a separate snapshot bucket per verbatim key (not a merged one).
 */
export function measureVariantPairCounts(): VariantPairCounts {
  const firsts = new Map<string, FirstAssess>();
  for (const variant of KEY_VARIANTS) {
    firsts.set(variant.label, firstAssessOf(new ConfidenceService(), variant.key));
  }

  let priorEquivalent = 0;
  let priorDistinct = 0;
  let learnedStateDistinct = 0;
  let learnedStateShared = 0;
  let priorEquivalentButStateDistinct = 0;
  const equivalentPairs: Array<[string, string]> = [];
  const distinctPairs: Array<[string, string]> = [];

  for (let i = 0; i < KEY_VARIANTS.length; i++) {
    for (let j = i + 1; j < KEY_VARIANTS.length; j++) {
      const a = KEY_VARIANTS[i]!;
      const b = KEY_VARIANTS[j]!;
      const fa = firsts.get(a.label)!;
      const fb = firsts.get(b.label)!;
      const samePrior =
        numsEqual(fa.trustMean, fb.trustMean) &&
        numsEqual(fa.trustUncertainty, fb.trustUncertainty) &&
        numsEqual(fa.adjustedScore, fb.adjustedScore);
      if (samePrior) {
        priorEquivalent += 1;
        equivalentPairs.push([a.label, b.label]);
      } else {
        priorDistinct += 1;
        distinctPairs.push([a.label, b.label]);
      }

      // Same instance, interleaved: even keys get even steps, odd keys odd steps.
      const assignments = VARIANT_STEPS.map((step, idx) => ({
        key: (idx % 2 === 0 ? a : b).key,
        step
      }));
      const buckets = runInterleaved(assignments);
      const bucketA = buckets.find((x) => x.signalKey === a.key);
      const bucketB = buckets.find((x) => x.signalKey === b.key);
      const half = Math.floor(VARIANT_STEPS.length / 2);
      const stateDistinct =
        buckets.length === 2 &&
        bucketA !== undefined &&
        bucketB !== undefined &&
        bucketA.eventCount === half &&
        bucketB.eventCount === half;
      if (stateDistinct) learnedStateDistinct += 1;
      else learnedStateShared += 1;
      if (samePrior && stateDistinct) priorEquivalentButStateDistinct += 1;
    }
  }

  return {
    variants: KEY_VARIANTS.length,
    totalPairs: priorEquivalent + priorDistinct,
    priorEquivalent,
    priorDistinct,
    learnedStateDistinct,
    learnedStateShared,
    priorEquivalentButStateDistinct,
    priorEquivalentPairs: equivalentPairs,
    priorDistinctPairs: distinctPairs
  };
}

export interface RestartMeasurement {
  firstStepTrustMean: number;
  finalTrustMean: number;
  finalEventCount: number;
  afterRecreateTrustMean: number;
  afterRecreateSnapshotCount: number;
  /** |trustMean after recreation − trustMean at the first (prior-based) step|: 0 ⇒ state was reset. */
  resetDiff: number;
}

/**
 * Simulated restart inside one process: run a history on an instance, then
 * compare a fresh instance's prior read against the first (prior-based) step.
 */
export function runRestartInProcess(key: string, steps: StepTriple[]): RestartMeasurement {
  const first = steps[0];
  if (!first) throw new Error("restart probe needs at least one step");
  const svc = new ConfidenceService();
  const firstAssess = svc.assess({ signals: [{ key, rawScore: first.rawScore, weight: first.weight }] });
  const firstSignal = firstAssess.signals[0];
  if (!firstSignal) throw new Error("assess returned no signal assessment");
  const firstStepTrustMean = firstSignal.trustMean;

  for (const step of steps) {
    const res = svc.assess({ signals: [{ key, rawScore: step.rawScore, weight: step.weight }] });
    svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
  }
  const beforeSnaps = svc.calibrationSnapshots(200);
  const before = beforeSnaps.find((b) => b.signalKey === key);

  const fresh = new ConfidenceService();
  const after = firstAssessOf(fresh, key, first.rawScore, first.weight);
  const afterRecreateSnapshotCount = fresh.calibrationSnapshots(200).length;

  return {
    firstStepTrustMean,
    finalTrustMean: before ? before.trustMean : Number.NaN,
    finalEventCount: before ? before.eventCount : 0,
    afterRecreateTrustMean: after.trustMean,
    afterRecreateSnapshotCount,
    resetDiff: Math.abs(after.trustMean - firstStepTrustMean)
  };
}
