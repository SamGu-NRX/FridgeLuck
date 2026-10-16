/**
 * Committed LeChef suite run (SPEC §7): runs the 92-session matrix (65 base +
 * 27 safety attacks) end to end and prints the deterministic report. The suite
 * is self-contained (fake model + FakePhone + ManualClock): no network, no
 * Gemini keys, no device.
 */

import { renderReport, runSuite } from "../lechef/suite/index.js";

const { report, coverageAllCovered } = runSuite();
console.log(renderReport(report, coverageAllCovered));

if (!report.gates.unsafeAnswersZero || !report.gates.unauthorizedActionsZero || !report.gates.allSessionsRan || !coverageAllCovered) {
  console.error("suite gates failed");
  process.exit(1);
}
