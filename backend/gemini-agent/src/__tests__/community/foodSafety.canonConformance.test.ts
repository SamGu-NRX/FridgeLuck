/**
 * The vendored canon's conformance kit, replayed through the TypeScript
 * adapter. The kit is the canon's own fixture set (vendored verbatim from
 * FridgeLuck PR #126, branch overhaul/food-safety-canon, hash-verified at
 * load): every case pins an exact finding sequence, the clean replay must
 * stay clean, and every finding kind and copy-lint pattern must be covered.
 *
 * This is the load-bearing proof that the gate's lint semantics are the
 * canon's — the adapter passes the whole kit or the suite fails.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runConformanceKit } from "../../community/foodSafety/canonLinter.js";
import { defaultVendoredCanonDir } from "../../community/foodSafety/canonPackage.js";

const CANON_DIR = defaultVendoredCanonDir();

const CONFORMANCE_FILES: readonly string[] = [
  "cases-copy-lint.json",
  "cases-fail-closed.json",
  "cases-review-and-legacy.json",
  "cases-temperature-errors.json",
  "true-negatives.json",
  "replay-clean.json",
];

describe("the vendored canon conformance kit replays through the TypeScript adapter", () => {
  test("every case pins its exact finding sequence, the clean replay stays clean, coverage is complete", () => {
    const files: Record<string, string> = {};
    for (const name of CONFORMANCE_FILES) {
      files[name] = readFileSync(join(CANON_DIR, "conformance", name), "utf8");
    }
    const report = runConformanceKit(
      files,
      readFileSync(join(CANON_DIR, "rules.json"), "utf8"),
      readFileSync(join(CANON_DIR, "copy-lint-patterns.json"), "utf8"),
    );
    const failed = report.caseResults.filter((result) => !result.ok);
    if (failed.length > 0) {
      console.log(
        failed.map((f) => `${f.caseID}: ${f.problems.join("; ")}`).join("\n"),
      );
    }
    expect(failed).toHaveLength(0);
    expect(report.replayProblems).toHaveLength(0);
    expect(report.coverageProblems).toHaveLength(0);
    // The kit's full case count: 5 copy + 2 fail-closed + 7 review/legacy +
    // 8 temperature-error + 12 true-negative cases, plus the 4 replay-clean
    // cases replayed in both directions. If the canon's kit grows, this pin
    // must be updated consciously.
    expect(report.caseResults.length).toBe(38);
    expect(report.ok).toBe(true);
  });
});
