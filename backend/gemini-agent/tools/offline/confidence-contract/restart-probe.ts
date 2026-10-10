/**
 * M2 subprocess probe: a REAL process recreation for the restart measurement.
 *
 * Spawned by run.ts. It loads the unchanged production ConfidenceService in a
 * bare new process (import-only: no network), reads the prior, drives the
 * seeded probe history, and prints one JSON line with the resulting state.
 * If the service had any hidden persistence, a fresh process would not start
 * from the prior — this probe is the cross-process witness for that.
 *
 * Run from backend/gemini-agent:
 *   bun tools/offline/confidence-contract/restart-probe.ts --seed 20261010
 */
import { ConfidenceService } from "../../../src/services/confidenceService.js";
import { BASE_KEY, buildProbeSteps } from "./model.js";

function parseSeed(argv: string[]): number {
  const idx = argv.indexOf("--seed");
  const seed = idx >= 0 ? Number(argv[idx + 1]) : 20261010;
  if (!Number.isFinite(seed)) throw new Error("--seed must be a finite number");
  return seed;
}

const seed = parseSeed(process.argv.slice(2));
const steps = buildProbeSteps(seed);
const svc = new ConfidenceService();

const first = svc.assess({ signals: [{ key: BASE_KEY, rawScore: steps[0]!.rawScore, weight: steps[0]!.weight }] });
const firstSignal = first.signals[0]!;
for (const step of steps) {
  const res = svc.assess({ signals: [{ key: BASE_KEY, rawScore: step.rawScore, weight: step.weight }] });
  svc.recordOutcome({ assessment: res, outcomeReward: step.reward });
}
const snaps = svc.calibrationSnapshots(200);
const own = snaps.find((b) => b.signalKey === BASE_KEY);

console.log(
  JSON.stringify({
    seed,
    platform: process.platform,
    arch: process.arch,
    bunVersion: Bun.version,
    initialTrustMean: firstSignal.trustMean,
    afterHistoryTrustMean: own ? own.trustMean : null,
    afterHistoryEventCount: own ? own.eventCount : 0
  })
);
