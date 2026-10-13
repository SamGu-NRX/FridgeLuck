/**
 * M3 report verifier: verifies the committed measurement results against
 * hand-computed expected states (independent arithmetic), and proves it
 * DETECTS deliberately corrupted copies — keys merged case-insensitively,
 * events dropped — while the clean report verifies.
 *
 * The verifier recomputes every value-based expectation from model.ts (the
 * hand-derived oracle, never the service) and additionally pins the prior
 * table to literals embedded BELOW (so even a tampered model.ts would be
 * caught on the prior anchors). Timing fields are verified structurally
 * (present, positive, finite), never exactly — they are environment-dependent.
 *
 * Run from backend/gemini-agent:
 *   bun tools/offline/confidence-contract/report.ts --verify-report
 *
 * Exit code 0 iff every clean check passes AND every mutation is detected.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import {
  BASE_KEY,
  EXPECTED_VARIANT_COUNTS,
  KEY_VARIANTS,
  VARIANT_STEPS,
  buildProbeSteps,
  expectedPrior,
  expectedSingleKeyChain,
  trustMean as modelTrustMean,
  trustUncertainty as modelTrustUncertainty
} from "./model.js";

const VALUE_EPS = 1e-9;

// ---------- literals embedded HERE, independent of model.ts (double anchor) ----------
const PRIOR_TABLE_LITERALS: ReadonlyArray<{ needle: string; alpha: number; beta: number }> = [
  { needle: "ocr_exact", alpha: 7.0, beta: 2.0 },
  { needle: "vision", alpha: 6.0, beta: 2.4 },
  { needle: "ocr_fuzzy", alpha: 3.4, beta: 3.0 },
  { needle: "portion", alpha: 2.8, beta: 3.6 },
  { needle: "macro", alpha: 4.4, beta: 2.8 },
  { needle: "gemini", alpha: 4.8, beta: 2.7 },
  { needle: "recipe", alpha: 4.5, beta: 2.9 }
];
const DEFAULT_PRIOR_LITERALS = { alpha: 4.0, beta: 3.0 };

// ---------- minimal structural types for the committed results ----------
interface Bucket {
  signalKey: string;
  eventCount: number;
  trustMean: number;
  trustUncertainty: number;
  averageRawScore: number;
  averageOutcomeReward: number;
  averageAbsoluteError: number;
}
interface VariantRecord {
  label: string;
  key: string;
  priorClass: string;
  perStepTrustMean: number[];
  perStepAdjusted: number[];
  perStepOverall: number[];
  finalTrustMean: number;
  finalTrustUncertainty: number;
  eventCount: number;
  snapshotKey: string | null;
}
interface Comparison {
  label: string;
  numbersIdenticalToExact: boolean;
  maxTrustMeanDiff: number;
  maxAdjustedDiff: number;
  maxOverallDiff: number;
  lowStepReasonIdenticalToExact: boolean;
  snapshotKeyDiffersFromExact: boolean;
}
interface CostRow {
  events: number;
  distinctKeys: number;
  recordLoopMs: number;
  snapshotMedianMs: number;
  bucketCount: number;
  rssAfterMb: number;
}
interface Measurements {
  seed: number;
  host: { platform: string; arch: string; bunVersion: string; cpuCount: number };
  variants: { records: VariantRecord[]; comparisons: Comparison[] };
  withinInstance: {
    twoKey: { interleavedBuckets: Bucket[]; mergedCounterfactualBuckets: Bucket[] };
    allVariants: { buckets: Bucket[] };
  };
  restart: {
    inProcess: {
      firstStepTrustMean: number;
      finalTrustMean: number;
      finalEventCount: number;
      afterRecreateTrustMean: number;
      afterRecreateSnapshotCount: number;
      resetDiff: number;
    };
    subprocess: {
      exitCode: number;
      parsed: { initialTrustMean?: number; afterHistoryTrustMean?: number; afterHistoryEventCount?: number } | null;
    };
    subprocessMatchesInProcess: boolean;
  };
  calibrationCost: CostRow[];
  counts: Record<string, number>;
}
interface M1CountsFile {
  counts: Record<string, number>;
  expected: Record<string, number>;
  variants: Array<{ label: string; key: string; priorClass: string }>;
}

interface Check {
  name: string;
  status: "pass" | "fail";
  detail: string;
}

function close(a: number, b: number, eps = VALUE_EPS): boolean {
  return Math.abs(a - b) <= eps;
}

function fmt(value: number): string {
  return String(Number(value.toFixed(12)));
}

function cloneJson<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

// ---------- the verification pipeline (pure over the loaded results) ----------

function verifyMeasurements(m: Measurements): Check[] {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean, detail: string): void => {
    checks.push({ name, status: ok ? "pass" : "fail", detail });
  };

  // 0) prior table literals (independent anchor on model.ts itself)
  let priorOk = true;
  const priorDetails: string[] = [];
  for (const literal of PRIOR_TABLE_LITERALS) {
    const computed = expectedPrior(`x${literal.needle}x`);
    if (!close(computed.alpha, literal.alpha) || !close(computed.beta, literal.beta)) {
      priorOk = false;
      priorDetails.push(`${literal.needle}: model=${computed.alpha}/${computed.beta} literal=${literal.alpha}/${literal.beta}`);
    }
  }
  const defaultComputed = expectedPrior("no.needle.matches");
  if (
    !close(defaultComputed.alpha, DEFAULT_PRIOR_LITERALS.alpha) ||
    !close(defaultComputed.beta, DEFAULT_PRIOR_LITERALS.beta)
  ) {
    priorOk = false;
    priorDetails.push(
      `default: model=${defaultComputed.alpha}/${defaultComputed.beta} literal=${DEFAULT_PRIOR_LITERALS.alpha}/${DEFAULT_PRIOR_LITERALS.beta}`
    );
  }
  add("priorTableLiterals", priorOk, priorOk ? "model prior table matches embedded literals" : priorDetails.join("; "));

  // 1) per-variant chains recomputed from hand-derived arithmetic
  for (const record of m.variants.records) {
    const chain = expectedSingleKeyChain(record.key, VARIANT_STEPS);
    const expMean = chain.steps.map((s) => s.trustMean);
    const expAdjusted = chain.steps.map((s) => s.adjustedScore);
    const expOverall = chain.steps.map((s) => s.overallScore);
    const meanDiff = Math.max(...expMean.map((v, i) => Math.abs(v - record.perStepTrustMean[i]!)));
    const adjDiff = Math.max(...expAdjusted.map((v, i) => Math.abs(v - record.perStepAdjusted[i]!)));
    const overallDiff = Math.max(...expOverall.map((v, i) => Math.abs(v - record.perStepOverall[i]!)));
    const finalOk =
      close(record.finalTrustMean, modelTrustMean(chain.finalTrust)) &&
      close(record.finalTrustUncertainty, modelTrustUncertainty(chain.finalTrust));
    const countOk = record.eventCount === VARIANT_STEPS.length;
    const priorMean = modelTrustMean(expectedPrior(record.key));
    const firstOk = close(record.perStepTrustMean[0]!, priorMean);
    add(
      `variantChain:${record.label}`,
      meanDiff <= VALUE_EPS && adjDiff <= VALUE_EPS && overallDiff <= VALUE_EPS && finalOk && countOk && firstOk,
      `per-step diffs mean=${fmt(meanDiff)} adjusted=${fmt(adjDiff)} overall=${fmt(overallDiff)}; finalTrustMean=${fmt(record.finalTrustMean)} vs ${fmt(modelTrustMean(chain.finalTrust))}; eventCount=${record.eventCount}; firstStep=${fmt(record.perStepTrustMean[0]!)} vs priorMean=${fmt(priorMean)}`
    );
  }

  // 2) recorded comparisons consistent with the hand-derived prior classes
  for (const comparison of m.variants.comparisons) {
    const variant = KEY_VARIANTS.find((v) => v.label === comparison.label);
    if (!variant) {
      add(`variantComparison:${comparison.label}`, false, "unknown label");
      continue;
    }
    const samePriorClass = variant.priorClass === "vision";
    const diffOk = samePriorClass
      ? comparison.numbersIdenticalToExact && comparison.maxTrustMeanDiff === 0
      : !comparison.numbersIdenticalToExact &&
        close(comparison.maxTrustMeanDiff, Math.abs(5 / 7 - 4 / 7), 1e-9);
    // Reason strings fold case but keep the verbatim whitespace: identical to the
    // exact key's line iff the lowercased key IS the base key.
    const reasonOk = samePriorClass
      ? comparison.lowStepReasonIdenticalToExact === (variant.key.toLowerCase() === BASE_KEY)
      : !comparison.lowStepReasonIdenticalToExact;
    add(
      `variantComparison:${comparison.label}`,
      diffOk && reasonOk && comparison.snapshotKeyDiffersFromExact,
      `numbersIdentical=${comparison.numbersIdenticalToExact} maxTrustMeanDiff=${fmt(comparison.maxTrustMeanDiff)} reasonIdentical=${comparison.lowStepReasonIdenticalToExact} snapshotKeyDiffers=${comparison.snapshotKeyDiffersFromExact}`
    );
  }

  // 3) within-instance fragmentation vs merged counterfactual
  const interleaved = m.withinInstance.twoKey.interleavedBuckets;
  const expExact = expectedSingleKeyChain(BASE_KEY, [0, 2, 4].map((i) => VARIANT_STEPS[i]!));
  const expMixed = expectedSingleKeyChain("Vision.Scan", [1, 3, 5].map((i) => VARIANT_STEPS[i]!));
  const interOk =
    interleaved.length === 2 &&
    interleaved.some((b) => b.signalKey === BASE_KEY && b.eventCount === 3 && close(b.trustMean, modelTrustMean(expExact.finalTrust))) &&
    interleaved.some((b) => b.signalKey === "Vision.Scan" && b.eventCount === 3 && close(b.trustMean, modelTrustMean(expMixed.finalTrust)));
  add(
    "withinInstance.twoKey.interleaved",
    interOk,
    `buckets=${interleaved.length} [${interleaved.map((b) => `${b.signalKey}#${b.eventCount}@${fmt(b.trustMean)}`).join(", ")}]`
  );

  const counterfactual = m.withinInstance.twoKey.mergedCounterfactualBuckets;
  const expMerged = expectedSingleKeyChain(BASE_KEY, VARIANT_STEPS);
  const cfOk =
    counterfactual.length === 1 &&
    counterfactual[0]!.signalKey === BASE_KEY &&
    counterfactual[0]!.eventCount === VARIANT_STEPS.length &&
    close(counterfactual[0]!.trustMean, modelTrustMean(expMerged.finalTrust));
  add(
    "withinInstance.twoKey.counterfactual",
    cfOk,
    `buckets=${counterfactual.length} eventCount=${counterfactual[0] ? counterfactual[0].eventCount : "none"} trustMean=${counterfactual[0] ? fmt(counterfactual[0].trustMean) : "none"} vs ${fmt(modelTrustMean(expMerged.finalTrust))}`
  );

  // all-variant interleaving: variant i owns steps i and i+6 (round-robin over 12)
  const allBuckets = m.withinInstance.allVariants.buckets;
  let allOk = allBuckets.length === KEY_VARIANTS.length;
  const allDetails: string[] = [];
  for (let i = 0; i < KEY_VARIANTS.length; i++) {
    const variant = KEY_VARIANTS[i]!;
    const bucket = allBuckets.find((b) => b.signalKey === variant.key);
    if (!bucket) {
      allOk = false;
      allDetails.push(`missing bucket ${JSON.stringify(variant.key)}`);
      continue;
    }
    const ownSteps = [i, i + KEY_VARIANTS.length].map((idx) => allVariantSteps[idx]!);
    const chain = expectedSingleKeyChain(variant.key, ownSteps);
    if (bucket.eventCount !== 2 || !close(bucket.trustMean, modelTrustMean(chain.finalTrust))) {
      allOk = false;
      allDetails.push(`${variant.label}: eventCount=${bucket.eventCount} trustMean=${fmt(bucket.trustMean)} vs ${fmt(modelTrustMean(chain.finalTrust))}`);
    }
  }
  add("withinInstance.allVariants", allOk, allOk ? "6 verbatim buckets, each matching its 2-step chain" : allDetails.join("; "));

  // 4) restart: state reset measured in-process and in a real subprocess
  const restart = m.restart.inProcess;
  const probeChain = expectedSingleKeyChain(BASE_KEY, buildProbeSteps(m.seed));
  const priorMeanVision = modelTrustMean(expectedPrior(BASE_KEY));
  const restartOk =
    close(restart.firstStepTrustMean, priorMeanVision) &&
    close(restart.finalTrustMean, modelTrustMean(probeChain.finalTrust)) &&
    restart.finalEventCount === buildProbeSteps(m.seed).length &&
    close(restart.afterRecreateTrustMean, priorMeanVision) &&
    restart.afterRecreateSnapshotCount === 0 &&
    restart.resetDiff === 0;
  add(
    "restart.inProcess",
    restartOk,
    `firstStep=${fmt(restart.firstStepTrustMean)} final=${fmt(restart.finalTrustMean)} events=${restart.finalEventCount} afterRecreate=${fmt(restart.afterRecreateTrustMean)} snapshots=${restart.afterRecreateSnapshotCount} resetDiff=${restart.resetDiff}`
  );

  const sub = m.restart.subprocess;
  const subOk =
    sub.exitCode === 0 &&
    sub.parsed !== null &&
    close(sub.parsed.initialTrustMean ?? Number.NaN, priorMeanVision) &&
    close(sub.parsed.afterHistoryTrustMean ?? Number.NaN, modelTrustMean(probeChain.finalTrust)) &&
    sub.parsed.afterHistoryEventCount === probeChain.steps.length &&
    m.restart.subprocessMatchesInProcess === true;
  add(
    "restart.subprocess",
    subOk,
    `exitCode=${sub.exitCode} initial=${fmt(sub.parsed?.initialTrustMean ?? Number.NaN)} afterHistory=${fmt(sub.parsed?.afterHistoryTrustMean ?? Number.NaN)} events=${sub.parsed?.afterHistoryEventCount ?? "none"} matchesFlag=${m.restart.subprocessMatchesInProcess}`
  );

  // 5) cost structure (timings are environment-dependent: structural checks only)
  const cost = m.calibrationCost;
  const volumes = [100, 1000, 5000];
  const costOk =
    cost.length === volumes.length &&
    cost.every((row, i) => {
      const structural =
        row.events === volumes[i] &&
        row.distinctKeys === 10 &&
        Number.isFinite(row.recordLoopMs) &&
        row.recordLoopMs > 0 &&
        Number.isFinite(row.snapshotMedianMs) &&
        row.snapshotMedianMs > 0 &&
        row.bucketCount === 10 &&
        row.rssAfterMb > 0;
      return structural;
    });
  add(
    "cost.structure",
    costOk,
    cost.map((row) => `${row.events}: record=${fmt(row.recordLoopMs)}ms snap=${fmt(row.snapshotMedianMs)}ms buckets=${row.bucketCount} rss=${row.rssAfterMb}MB`).join("; ")
  );

  // 6) measured counts equal the hand-derived literals
  const countsOk =
    m.counts.totalPairs === EXPECTED_VARIANT_COUNTS.totalPairs &&
    m.counts.priorEquivalent === EXPECTED_VARIANT_COUNTS.priorEquivalent &&
    m.counts.priorDistinct === EXPECTED_VARIANT_COUNTS.priorDistinct &&
    m.counts.learnedStateDistinct === EXPECTED_VARIANT_COUNTS.learnedStateDistinct &&
    m.counts.learnedStateShared === EXPECTED_VARIANT_COUNTS.learnedStateShared &&
    m.counts.priorEquivalentButStateDistinct === EXPECTED_VARIANT_COUNTS.priorEquivalentButStateDistinct;
  add(
    "counts.measured",
    countsOk,
    `measured=${JSON.stringify(m.counts)} expected=${JSON.stringify(EXPECTED_VARIANT_COUNTS)}`
  );

  return checks;
}

function verifyM1CountsFile(file: M1CountsFile): Check[] {
  const checks: Check[] = [];
  const countsOk =
    file.expected.totalPairs === EXPECTED_VARIANT_COUNTS.totalPairs &&
    file.counts.priorEquivalent === file.expected.priorEquivalent &&
    file.counts.learnedStateDistinct === file.expected.learnedStateDistinct;
  checks.push({
    name: "m1Counts.file",
    status: countsOk ? "pass" : "fail",
    detail: countsOk ? "m1-variant-counts.json matches literals" : "m1-variant-counts.json mismatch"
  });
  const variantsOk =
    file.variants.length === KEY_VARIANTS.length &&
    file.variants.every((v, i) => v.label === KEY_VARIANTS[i]!.label && v.key === KEY_VARIANTS[i]!.key);
  checks.push({
    name: "m1Counts.variants",
    status: variantsOk ? "pass" : "fail",
    detail: variantsOk ? "variant list matches fixture literals" : "variant list drifted"
  });
  return checks;
}

// ---------- deliberate corruptions (each must be DETECTED) ----------

/** Corruption 1: merge buckets case-insensitively (the production-risk behavior). */
function mutateMergeKeys(m: Measurements): Measurements {
  const merged = cloneJson(m);
  const fold = (buckets: Bucket[]): Bucket[] => {
    const byLower = new Map<string, Bucket>();
    for (const b of buckets) {
      const key = b.signalKey.toLowerCase();
      const existing = byLower.get(key);
      if (!existing) {
        byLower.set(key, { ...b });
      } else {
        const total = existing.eventCount + b.eventCount;
        existing.trustMean =
          (existing.trustMean * existing.eventCount + b.trustMean * b.eventCount) / total;
        existing.trustUncertainty =
          (existing.trustUncertainty * existing.eventCount + b.trustUncertainty * b.eventCount) / total;
        existing.eventCount = total;
      }
    }
    return [...byLower.values()];
  };
  merged.withinInstance.twoKey.interleavedBuckets = fold(merged.withinInstance.twoKey.interleavedBuckets);
  merged.withinInstance.allVariants.buckets = fold(merged.withinInstance.allVariants.buckets);
  return merged;
}

/** Corruption 2: events dropped — decrement one bucket and delete another entirely. */
function mutateDropEvents(m: Measurements): Measurements {
  const dropped = cloneJson(m);
  const two = dropped.withinInstance.twoKey.interleavedBuckets;
  if (two[0]) two[0].eventCount -= 1;
  dropped.withinInstance.allVariants.buckets = dropped.withinInstance.allVariants.buckets.filter(
    (b) => !b.signalKey.startsWith("ＶＩＳＩＯＮ")
  );
  return dropped;
}

/** Corruption 3 (extra evidence): tamper a learned-state value. */
function mutateTamperValue(m: Measurements): Measurements {
  const tampered = cloneJson(m);
  const mixed = tampered.variants.records.find((r) => r.label === "mixed-case");
  if (mixed) mixed.finalTrustMean += 0.01;
  return tampered;
}

// ---------- main ----------

const args = process.argv.slice(2);
if (!args.includes("--verify-report")) {
  console.error("usage: bun tools/offline/confidence-contract/report.ts --verify-report [--results <dir>]");
  process.exit(2);
}

const resultsIdx = args.indexOf("--results");
const resultsDir = path.resolve(
  resultsIdx >= 0 ? args[resultsIdx + 1]! : path.join(import.meta.dir, "results")
);
const measurements = JSON.parse(
  readFileSync(path.join(resultsDir, "measurements.json"), "utf8")
) as Measurements;
const m1Counts = JSON.parse(
  readFileSync(path.join(resultsDir, "m1-variant-counts.json"), "utf8")
) as M1CountsFile;

const allVariantSteps = [...VARIANT_STEPS, ...VARIANT_STEPS];

const cleanChecks = [...verifyMeasurements(measurements), ...verifyM1CountsFile(m1Counts)];

const mutationCases: Array<{ name: string; mutated: Measurements; expectNamePrefix: string }> = [
  { name: "keys-merged-case-insensitively", mutated: mutateMergeKeys(measurements), expectNamePrefix: "withinInstance" },
  { name: "events-dropped", mutated: mutateDropEvents(measurements), expectNamePrefix: "withinInstance" },
  { name: "value-tampered", mutated: mutateTamperValue(measurements), expectNamePrefix: "variantChain:mixed-case" }
];

const mutationEvidence = mutationCases.map(({ name, mutated, expectNamePrefix }) => {
  const failed = verifyMeasurements(mutated).filter((c) => c.status === "fail");
  const detected = failed.some((c) => c.name.startsWith(expectNamePrefix));
  return {
    name,
    expectedDetectionPrefix: expectNamePrefix,
    detected,
    failingChecks: failed.map((c) => ({ name: c.name, detail: c.detail }))
  };
});

const passed = cleanChecks.filter((c) => c.status === "pass").length;
const failed = cleanChecks.length - passed;
const allDetected = mutationEvidence.every((e) => e.detected);

const evidence = {
  tool: "confidence-contract-report-verifier",
  verifiedReport: "results/measurements.json + results/m1-variant-counts.json",
  seed: measurements.seed,
  cleanChecks: cleanChecks,
  mutations: mutationEvidence,
  summary: {
    cleanChecksTotal: cleanChecks.length,
    cleanChecksPassed: passed,
    cleanChecksFailed: failed,
    mutationsTotal: mutationEvidence.length,
    mutationsDetected: mutationEvidence.filter((e) => e.detected).length,
    verdict: failed === 0 && allDetected ? "VERIFIED" : "FAILED"
  }
};

mkdirSync(resultsDir, { recursive: true });
const evidencePath = path.join(resultsDir, "verification-evidence.json");
writeFileSync(evidencePath, JSON.stringify(evidence, null, 2) + "\n");

for (const check of cleanChecks) {
  console.log(`${check.status === "pass" ? "PASS" : "FAIL"} ${check.name}: ${check.detail}`);
}
for (const mutation of mutationEvidence) {
  console.log(
    `${mutation.detected ? "DETECTED" : "MISSED"} mutation ${mutation.name} (${mutation.failingChecks.length} failing checks)`
  );
}
console.log(
  `verdict: ${evidence.summary.verdict} — clean ${passed}/${cleanChecks.length} passed, mutations detected ${mutationEvidence.filter((e) => e.detected).length}/${mutationEvidence.length}; evidence: ${path.relative(process.cwd(), evidencePath)}`
);

if (failed > 0 || !allDetected) process.exit(1);
