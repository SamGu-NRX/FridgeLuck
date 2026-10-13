/**
 * Independent expectation model for the production ConfidenceService contract.
 *
 * Every formula and constant below is hand-derived from reading
 * backend/gemini-agent/src/services/confidenceService.ts as of main@1151588d.
 * Nothing in this file imports or instantiates the production service: the
 * contract tests, the seeded runner and the report verifier all compare the
 * REAL service against this oracle. If the service's math changes on purpose,
 * update these expectations deliberately in review — a diff here is a contract
 * change, never a silent one.
 *
 * Measured contract (from reading the service, to be pinned by tests):
 * - priorFor() picks the prior by LOWERCASED substring match (first needle in
 *   table order wins); surrounding whitespace is irrelevant, and non-ASCII
 *   case variants (e.g. fullwidth letters) do not fold to ASCII.
 * - Learned state is stored in a Map keyed by the VERBATIM input key, so keys
 *   that share a prior still accumulate separate trust states.
 * - trustBySignal and events live on the instance; nothing is persisted, so a
 *   fresh instance (or process) restarts from priors with an empty event log.
 */

// ---------- trust math (mirrors confidenceService.ts helpers) ----------

export interface TrustState {
  alpha: number;
  beta: number;
}

export interface StepTriple {
  /** Pre-clamp raw score as a caller would pass it. */
  rawScore: number;
  /** Pre-normalize weight; undefined means the service default of 1.0. */
  weight?: number;
  /** Pre-clamp outcome reward. */
  reward: number;
}

/** Ordered prior table from priorFor(): the first case-insensitive substring hit wins. */
export const PRIOR_TABLE: ReadonlyArray<{ needle: string; alpha: number; beta: number }> = [
  { needle: "ocr_exact", alpha: 7.0, beta: 2.0 },
  { needle: "vision", alpha: 6.0, beta: 2.4 },
  { needle: "ocr_fuzzy", alpha: 3.4, beta: 3.0 },
  { needle: "portion", alpha: 2.8, beta: 3.6 },
  { needle: "macro", alpha: 4.4, beta: 2.8 },
  { needle: "gemini", alpha: 4.8, beta: 2.7 },
  { needle: "recipe", alpha: 4.5, beta: 2.9 }
];

export const DEFAULT_PRIOR: TrustState = { alpha: 4.0, beta: 3.0 };

/** priorFor() selects by lowercased substring; storage uses the verbatim key. */
export function expectedPrior(signalKey: string): TrustState {
  const key = signalKey.toLowerCase();
  for (const row of PRIOR_TABLE) {
    if (key.includes(row.needle)) return { alpha: row.alpha, beta: row.beta };
  }
  return { ...DEFAULT_PRIOR };
}

export function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

export function trustMean(trust: TrustState): number {
  return trust.alpha / (trust.alpha + trust.beta);
}

export function trustUncertainty(trust: TrustState): number {
  const mean = trustMean(trust);
  return Math.sqrt((mean * (1 - mean)) / (trust.alpha + trust.beta + 1));
}

// ---------- assess math (mirrors normalizeSignal + assessSignal + assess) ----------

export interface AssessmentExpectation {
  key: string;
  rawScore: number;
  adjustedScore: number;
  trustMean: number;
  trustUncertainty: number;
  weight: number;
  reason: string;
}

/** Expected single-signal assessment given the current trust state for that key. */
export function expectedAssessSignal(
  current: TrustState,
  key: string,
  rawScore: number,
  weight: number | undefined
): AssessmentExpectation {
  const raw = clamp01(rawScore);
  const w = Math.max(0.05, weight ?? 1.0);
  const sampleSize = current.alpha + current.beta;
  const mean = trustMean(current);
  const uncertainty = trustUncertainty(current);
  const trustInfluence = Math.max(0.2, Math.min((sampleSize - 2.0) / 18.0, 1.0));
  const blended = raw * (1 - trustInfluence) + raw * mean * trustInfluence;
  const adjustedScore = clamp01(blended - 0.2 * uncertainty);
  return {
    key,
    rawScore: raw,
    adjustedScore,
    trustMean: mean,
    trustUncertainty: uncertainty,
    weight: w,
    reason: key
  };
}

export type ConfidenceModeExpectation = "exact" | "review_required" | "estimate_only";

export interface FusionExpectation {
  mode: ConfidenceModeExpectation;
  overallScore: number;
  deterministicReady: boolean;
  reasons: string[];
}

/** Expected geometric-mean fusion, contradiction penalty, mode thresholds and reason list. */
export function expectedFusion(
  signals: AssessmentExpectation[],
  hardFailReasons?: string[]
): FusionExpectation {
  const fails = hardFailReasons ?? [];
  const totalWeight = signals.reduce((sum, s) => sum + s.weight, 0.0);
  const weightedLogSum = signals.reduce(
    (sum, s) => sum + s.weight * Math.log(Math.max(s.adjustedScore, 0.0001)),
    0.0
  );
  let overall = Math.exp(weightedLogSum / Math.max(totalWeight, 0.0001));
  const low = signals.filter((s) => s.adjustedScore < 0.45);
  overall = clamp01(overall - low.length * 0.08);

  const reasons = [...fails];
  for (const s of low.slice(0, 3)) reasons.push(`Low confidence in ${s.reason.toLowerCase()}.`);

  let mode: ConfidenceModeExpectation;
  if (fails.length > 0) {
    mode = "estimate_only";
    overall = Math.min(overall, 0.42);
  } else {
    const minAdjusted = Math.min(...signals.map((s) => s.adjustedScore));
    if (overall >= 0.84 && minAdjusted >= 0.62) mode = "exact";
    else if (overall >= 0.57) mode = "review_required";
    else mode = "estimate_only";
  }
  if (reasons.length === 0) reasons.push(`Confidence mode: ${mode}.`);
  return { mode, overallScore: clamp01(overall), deterministicReady: mode === "exact", reasons };
}

/** The literal response for an empty signal list (no prior reads, no state changes). */
export const EMPTY_SIGNALS_RESPONSE = {
  mode: "estimate_only" as const,
  overallScore: 0,
  deterministicReady: false,
  reasons: ["No confidence signals available."],
  signals: []
};

// ---------- update math (mirrors recordOutcome) ----------

export const DECAY = 0.997;

export function expectedNextTrust(
  current: TrustState,
  reward: number,
  adjustedScore: number,
  weight: number
): TrustState {
  const r = clamp01(reward);
  const calibrationReward = clamp01(1 - Math.abs(r - adjustedScore));
  const weightedReward = clamp01(r * 0.55 + calibrationReward * 0.45);
  const updateWeight = Math.max(0.25, Math.min(weight, 1.6));
  return {
    alpha: 1 + Math.max(0, (current.alpha - 1) * DECAY) + weightedReward * updateWeight,
    beta: 1 + Math.max(0, (current.beta - 1) * DECAY) + (1 - weightedReward) * updateWeight
  };
}

// ---------- chained single-key expectation ----------

export interface ChainStepExpectation {
  adjustedScore: number;
  trustMean: number;
  trustUncertainty: number;
  mode: ConfidenceModeExpectation;
  overallScore: number;
  reasons: string[];
}

export interface ChainExpectation {
  steps: ChainStepExpectation[];
  finalTrust: TrustState;
}

/** Expected assess -> recordOutcome chain on one verbatim key, starting from the fresh prior. */
export function expectedSingleKeyChain(key: string, steps: StepTriple[]): ChainExpectation {
  let trust = expectedPrior(key);
  const out: ChainStepExpectation[] = [];
  for (const step of steps) {
    const assessment = expectedAssessSignal(trust, key, step.rawScore, step.weight);
    const fusion = expectedFusion([assessment]);
    out.push({
      adjustedScore: assessment.adjustedScore,
      trustMean: assessment.trustMean,
      trustUncertainty: assessment.trustUncertainty,
      mode: fusion.mode,
      overallScore: fusion.overallScore,
      reasons: fusion.reasons
    });
    trust = expectedNextTrust(trust, step.reward, assessment.adjustedScore, assessment.weight);
  }
  return { steps: out, finalTrust: trust };
}

// ---------- shared fixtures ----------

export const BASE_KEY = "vision.scan";

export interface KeyVariant {
  label: string;
  key: string;
  /** Hand-derived prior class: which prior this key selects. */
  priorClass: "vision" | "default";
}

/**
 * Controlled variants of the base key. The first five all lowercase to a
 * string containing "vision" (same prior), while the fullwidth variant does
 * not fold to ASCII, so it falls through to the default prior.
 */
export const KEY_VARIANTS: KeyVariant[] = [
  { label: "exact", key: "vision.scan", priorClass: "vision" },
  { label: "mixed-case", key: "Vision.Scan", priorClass: "vision" },
  { label: "upper-case", key: "VISION.SCAN", priorClass: "vision" },
  { label: "surrounding-whitespace", key: " vision.scan ", priorClass: "vision" },
  { label: "tab-newline-whitespace", key: "\tvision.scan\n", priorClass: "vision" },
  { label: "fullwidth-unicode", key: "ＶＩＳＩＯＮ.scan", priorClass: "default" }
];

/** Fixed 6-step history driven through every variant (step 4 is low raw → forces a reason line). */
export const VARIANT_STEPS: StepTriple[] = [
  { rawScore: 0.82, weight: 1.0, reward: 1.0 },
  { rawScore: 0.64, weight: 1.0, reward: 0.0 },
  { rawScore: 0.91, weight: 1.0, reward: 1.0 },
  { rawScore: 0.3, weight: 1.0, reward: 0.0 },
  { rawScore: 0.77, weight: 1.0, reward: 1.0 },
  { rawScore: 0.55, weight: 1.0, reward: 0.0 }
];

/**
 * Hand-derived pair counts over KEY_VARIANTS:
 * - C(6,2) = 15 unordered pairs;
 * - 5 keys share the vision prior class → C(5,2) = 10 prior-equivalent pairs;
 * - the fullwidth key is the only default-class key → 5 prior-distinct pairs;
 * - every distinct string owns its own Map entry → 15 distinct learned states, 0 shared.
 */
export const EXPECTED_VARIANT_COUNTS = {
  variants: 6,
  totalPairs: 15,
  priorEquivalent: 10,
  priorDistinct: 5,
  learnedStateDistinct: 15,
  learnedStateShared: 0,
  priorEquivalentButStateDistinct: 10
} as const;

/** Hand-computed prior mean anchors: vision 6/(6+2.4) = 5/7, ocr_exact 7/9, default 4/7. */
export const PRIOR_MEAN_ANCHORS = {
  vision: 6.0 / 8.4,
  ocrExact: 7.0 / 9.0,
  default: 4.0 / 7.0
} as const;

/** mulberry32 seeded PRNG — deterministic, offline. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Deterministic probe history shared verbatim by run.ts and restart-probe.ts. */
export function buildProbeSteps(seed: number, count = 5): StepTriple[] {
  const rng = mulberry32(seed);
  const steps: StepTriple[] = [];
  for (let i = 0; i < count; i++) {
    steps.push({ rawScore: rng(), weight: 1.0, reward: rng() });
  }
  return steps;
}
