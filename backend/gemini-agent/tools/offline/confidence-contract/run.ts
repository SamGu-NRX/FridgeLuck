/**
 * M2 runner: measures the ACTUAL production ConfidenceService, unchanged.
 *
 * Import/instantiate only — no server, model, network or cloud calls. Sections:
 * - variants: identical fixed histories through fresh instances per key
 *   variant (public-output differences across key variants);
 * - withinInstance: interleaved variants in ONE instance (learned-state
 *   fragmentation) versus the merged-key counterfactual;
 * - restart: in-process recreation AND a real subprocess (simulated restart)
 *   to expose in-memory state reset;
 * - calibrationCost: snapshot cost at increasing event volumes;
 * - host/memory identity alongside every measurement.
 *
 * Deterministic via --seed. Run from backend/gemini-agent:
 *   bun tools/offline/confidence-contract/run.ts --seed 20261010 --out tools/offline/confidence-contract/results
 */
import { mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ConfidenceService } from "../../../src/services/confidenceService.js";
import {
  BASE_KEY,
  KEY_VARIANTS,
  VARIANT_STEPS,
  buildProbeSteps,
  mulberry32
} from "./model.js";
import {
  measureVariantPairCounts,
  runInterleaved,
  runIsolatedChain,
  runRestartInProcess
} from "./experiments.js";

function parseArgs(argv: string[]): { seed: number; out: string } {
  let seed = 20261010;
  let out = "tools/offline/confidence-contract/results";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--seed") seed = Number(argv[i + 1]);
    else if (argv[i] === "--out") out = argv[i + 1]!;
  }
  if (!Number.isFinite(seed)) throw new Error("--seed must be a finite number");
  return { seed, out };
}

function round(value: number, digits = 3): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function maxAbsDiff(a: number[], b: number[]): number {
  if (a.length !== b.length) return Number.POSITIVE_INFINITY;
  let max = 0;
  for (let i = 0; i < a.length; i++) max = Math.max(max, Math.abs(a[i]! - b[i]!));
  return max;
}

const parsed = parseArgs(process.argv.slice(2));
const seed = parsed.seed;
const outDir = path.resolve(parsed.out);

// ---------- host identity + memory ----------
const memStart = process.memoryUsage();
const host = {
  platform: process.platform,
  arch: process.arch,
  bunVersion: Bun.version,
  cpuCount: os.cpus().length,
  memory: {
    rssStartMb: round(memStart.rss / 1048576, 2),
    heapUsedStartMb: round(memStart.heapUsed / 1048576, 2)
  }
};

// ---------- 1) cross-instance variant chains (public-output differences) ----------
const variantRecords = KEY_VARIANTS.map((variant) => {
  const iso = runIsolatedChain(variant.key, VARIANT_STEPS);
  return {
    label: variant.label,
    key: variant.key,
    priorClass: variant.priorClass,
    firstAssess: iso.perStep[0]!,
    perStepTrustMean: iso.perStep.map((s) => s.trustMean),
    perStepAdjusted: iso.perStep.map((s) => s.adjustedScore),
    perStepOverall: iso.perStep.map((s) => s.overallScore),
    finalTrustMean: iso.finalTrustMean,
    finalTrustUncertainty: iso.finalTrustUncertainty,
    eventCount: iso.eventCount,
    snapshotKey: iso.snapshotKeys[0] ?? null,
    lowStepReason: iso.perStep[3]!.reasons // step 4 is the forced low-signal step
  };
});

const base = variantRecords[0]!;
const variantComparisons = variantRecords.slice(1).map((record) => {
  const trustMeanDiff = maxAbsDiff(record.perStepTrustMean, base.perStepTrustMean);
  const adjustedDiff = maxAbsDiff(record.perStepAdjusted, base.perStepAdjusted);
  const overallDiff = maxAbsDiff(record.perStepOverall, base.perStepOverall);
  return {
    label: record.label,
    numbersIdenticalToExact: trustMeanDiff === 0 && adjustedDiff === 0 && overallDiff === 0,
    maxTrustMeanDiff: trustMeanDiff,
    maxAdjustedDiff: adjustedDiff,
    maxOverallDiff: overallDiff,
    lowStepReasonIdenticalToExact:
      JSON.stringify(record.lowStepReason) === JSON.stringify(base.lowStepReason),
    snapshotKeyDiffersFromExact: record.snapshotKey !== base.snapshotKey
  };
});

// ---------- 2) within-instance fragmentation vs merged counterfactual ----------
const twoKeys = [BASE_KEY, "Vision.Scan"];
const twoKeyInterleaved = runInterleaved(
  VARIANT_STEPS.map((step, idx) => ({ key: twoKeys[idx % 2]!, step }))
);
const mergedCounterfactual = runInterleaved(VARIANT_STEPS.map((step) => ({ key: BASE_KEY, step })));

const allVariantSteps = [...VARIANT_STEPS, ...VARIANT_STEPS];
const allVariantsInterleaved = runInterleaved(
  allVariantSteps.map((step, idx) => ({ key: KEY_VARIANTS[idx % KEY_VARIANTS.length]!.key, step }))
);

// ---------- 3) restart: in-process recreation + real subprocess ----------
const probeSteps = buildProbeSteps(seed);
const restartInProcess = runRestartInProcess(BASE_KEY, probeSteps);

const probePath = path.join(import.meta.dir, "restart-probe.ts");
const probe = Bun.spawnSync([process.execPath, probePath, "--seed", String(seed)], {
  stdout: "pipe",
  stderr: "pipe"
});
const probeStdout = probe.stdout.toString().trim();
let probeParsed: unknown = null;
try {
  probeParsed = JSON.parse(probeStdout);
} catch {
  probeParsed = null; // verification below records the failure; never swallow silently
}
interface ProbeShape {
  initialTrustMean?: number;
  afterHistoryTrustMean?: number;
  afterHistoryEventCount?: number;
}
const probeShape = probeParsed as ProbeShape | null;
const subprocess = {
  command: ["<bun>", "restart-probe.ts", "--seed", String(seed)],
  exitCode: probe.exitCode,
  parsed: probeParsed,
  stderrTail: probe.exitCode === 0 ? "" : probe.stderr.toString().slice(0, 300)
};
const subprocessMatchesInProcess =
  probe.exitCode === 0 &&
  probeShape !== null &&
  typeof probeShape.initialTrustMean === "number" &&
  typeof probeShape.afterHistoryTrustMean === "number" &&
  Math.abs(probeShape.initialTrustMean - restartInProcess.firstStepTrustMean) <= 1e-12 &&
  Math.abs(probeShape.afterHistoryTrustMean - restartInProcess.finalTrustMean) <= 1e-12 &&
  probeShape.afterHistoryEventCount === restartInProcess.finalEventCount;

// ---------- 4) calibrationSnapshots cost at increasing event volumes ----------
const costKeys = Array.from({ length: 10 }, (_, i) => `vision.volume.${i}`);
const volumes = [100, 1000, 5000];
const calibrationCost = volumes.map((events) => {
  const rng = mulberry32(seed + events);
  const svc = new ConfidenceService();
  const t0 = performance.now();
  for (let i = 0; i < events; i++) {
    const key = costKeys[i % costKeys.length]!;
    const res = svc.assess({ signals: [{ key, rawScore: rng(), weight: 1.0 }] });
    svc.recordOutcome({ assessment: res, outcomeReward: rng() });
  }
  const recordLoopMs = performance.now() - t0;

  const snapshotTimes: number[] = [];
  let bucketCount = 0;
  for (let run = 0; run < 7; run++) {
    const t = performance.now();
    const snaps = svc.calibrationSnapshots();
    snapshotTimes.push(performance.now() - t);
    bucketCount = snaps.length;
  }
  const sorted = [...snapshotTimes].sort((a, b) => a - b);
  const rssAfter = process.memoryUsage().rss;
  return {
    events,
    distinctKeys: costKeys.length,
    recordLoopMs: round(recordLoopMs),
    snapshotMedianMs: round(sorted[Math.floor(sorted.length / 2)]!),
    snapshotMinMs: round(sorted[0]!),
    snapshotMaxMs: round(sorted[sorted.length - 1]!),
    bucketCount,
    rssAfterMb: round(rssAfter / 1048576, 2)
  };
});

// ---------- 5) variant pair counts (same experiment as M1, re-measured) ----------
const counts = measureVariantPairCounts();

// ---------- memory end ----------
const memEnd = process.memoryUsage();

const measurements = {
  tool: "confidence-contract-runner",
  seed,
  expectedModel: "model.ts (hand-derived from confidenceService.ts at main@1151588d)",
  host,
  memoryEnd: {
    rssEndMb: round(memEnd.rss / 1048576, 2),
    heapUsedEndMb: round(memEnd.heapUsed / 1048576, 2)
  },
  variants: {
    baseLabel: base.label,
    records: variantRecords,
    comparisons: variantComparisons
  },
  withinInstance: {
    twoKey: {
      keys: twoKeys,
      interleavedBuckets: twoKeyInterleaved,
      mergedCounterfactualBuckets: mergedCounterfactual
    },
    allVariants: {
      stepCount: allVariantSteps.length,
      buckets: allVariantsInterleaved
    }
  },
  restart: {
    inProcess: restartInProcess,
    subprocess,
    subprocessMatchesInProcess
  },
  calibrationCost,
  counts
};

mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, "measurements.json");
writeFileSync(outPath, JSON.stringify(measurements, null, 2) + "\n");

console.log(`measurements written: ${path.relative(process.cwd(), outPath)}`);
console.log(`variants: ${variantRecords.length} keys, ${variantComparisons.length} comparisons`);
console.log(
  `restart: resetDiff=${restartInProcess.resetDiff} subprocessMatchesInProcess=${subprocessMatchesInProcess}`
);
console.log(
  `counts: priorEquivalent=${counts.priorEquivalent}/${counts.totalPairs} stateDistinct=${counts.learnedStateDistinct}/${counts.totalPairs}`
);
for (const c of calibrationCost) {
  console.log(
    `cost: events=${c.events} recordLoopMs=${c.recordLoopMs} snapshotMedianMs=${c.snapshotMedianMs} buckets=${c.bucketCount} rssAfterMb=${c.rssAfterMb}`
  );
}
