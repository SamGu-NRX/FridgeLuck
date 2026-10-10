// Scoring CLI for the frozen policy-study-v2 arm run.
//
//   bun scripts/scorePolicyStudyV2.ts            # score and print summary
//   bun scripts/scorePolicyStudyV2.ts --write    # also write scoring-summary.json
//
// Fails (exit 1) if any frozen input or run artifact fails byte verification,
// or if producer parity fails on any recorded outcome.

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { RUN_ID, scoreStudy, StudyVerificationError } from "../src/evaluation/policyStudyV2Scoring";

const write = process.argv.includes("--write");
const fixturesRoot = join(import.meta.dir, "..", "evaluation-fixtures", "policy-study-v2");

try {
  const summary = scoreStudy(fixturesRoot);
  if (write) {
    const out = join(fixturesRoot, "runs", RUN_ID, "scoring-summary.json");
    writeFileSync(out, JSON.stringify(summary, null, 2) + "\n");
    console.error(`wrote ${out}`);
  }
  console.log(JSON.stringify(summary, null, 2));
} catch (error) {
  if (error instanceof StudyVerificationError) {
    console.error(`scoring refused: ${error.message}`);
    process.exit(1);
  }
  throw error;
}
