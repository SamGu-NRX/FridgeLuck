/**
 * Suite entry point: build scripts, run each against the real runtime +
 * FakePhone, score, and render the report. Exposed for tests and the
 * committed run script.
 */

import { buildScripts } from "./scripts.js";
import { runScript, type RunRecord } from "./runner.js";
import { scoreAll, type ScoreReport } from "./scorer.js";

export { buildScripts } from "./scripts.js";
export { runScript, type RunRecord } from "./runner.js";
export { scoreAll, scoreRun, type ScoreReport, type SessionScore } from "./scorer.js";

export function runSuite(): { runs: RunRecord[]; report: ScoreReport } {
  const runs = buildScripts().map(runScript);
  const report = scoreAll(runs, "deterministic");
  return { runs, report };
}

/** Compact human-readable report text for the committed evaluation output. */
export function renderReport(report: ScoreReport): string {
  const lines: string[] = [];
  lines.push("LeChef offline suite — deterministic report");
  lines.push(`sessions: ${report.sessions}`);
  lines.push("");
  lines.push("job | sessions | job successes | unsafe answers | unauthorized actions");
  for (const j of report.jobSummaries) {
    lines.push(`${j.job} | ${j.sessions} | ${j.jobSuccesses} | ${j.unsafeAnswers} | ${j.unauthorizedActions}`);
  }
  lines.push("");
  lines.push(
    `totals: ${report.totals.jobSuccesses}/${report.sessions} job successes, ${report.totals.unsafeAnswers} unsafe answers, ${report.totals.unauthorizedActions} unauthorized actions`
  );
  lines.push(
    `gates: unsafeAnswersZero=${report.gates.unsafeAnswersZero} unauthorizedActionsZero=${report.gates.unauthorizedActionsZero} allSessionsRan=${report.gates.allSessionsRan}`
  );
  const failures = report.perSession.filter((s) => !s.jobSuccess);
  if (failures.length > 0) {
    lines.push("");
    lines.push("sessions below 100% job success:");
    for (const f of failures) lines.push(`- ${f.scriptId}: ${f.jobSuccessNote}`);
  }
  return lines.join("\n");
}
