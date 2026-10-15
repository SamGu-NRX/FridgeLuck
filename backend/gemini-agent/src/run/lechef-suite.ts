/**
 * Committed LeChef suite run (SPEC §7): runs the 65-session matrix end to end
 * and prints the deterministic report. The suite is self-contained (fake model
 * + FakePhone + ManualClock): no network, no Gemini keys, no device.
 */

import { renderReport, runSuite } from "../lechef/suite/index.js";

const { report } = runSuite();
console.log(renderReport(report));

if (!report.gates.unsafeAnswersZero || !report.gates.unauthorizedActionsZero || !report.gates.allSessionsRan) {
  console.error("suite gates failed");
  process.exit(1);
}
