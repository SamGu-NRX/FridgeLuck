import { expect, test } from "bun:test";
import { readFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { assessTS, assertLockAvailable, auditPolicySource, SPEC_POLICY_SHA256, SPEC_POLICY_REFERENCE_COMMIT, crossCheck, type SwiftDocument } from "../evaluation/runReverseMeal.js";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseStates, parseReplay, projectState } from "../evaluation/reverseMealProjection.js";
import { canonicalJson } from "../evaluation/canonicalJson.js";
const fixtures = "/Users/samgu/.t3/scratch/2026-10-07-all-right-i-want-you-f82246a0/fridgeluck-eval";
const rows = parseStates(readFileSync(`${fixtures}/reverse-meal-states-v1.jsonl`, "utf8"));
const replay = parseReplay(readFileSync(`${fixtures}/reverse-meal-replay-v1.json`, "utf8"), rows);
test("policy freeze accepts documented comment-only drift but rejects executable changes", () => {
  const reference = spawnSync("git", ["show", `${SPEC_POLICY_REFERENCE_COMMIT}:apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift`], { encoding: "utf8" });
  expect(reference.status).toBe(0);
  const current = readFileSync(fileURLToPath(new URL("../../../../apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift", import.meta.url)), "utf8");
  const audit = auditPolicySource(reference.stdout, current);
  expect(audit.reference_sha256).toBe(SPEC_POLICY_SHA256);
  expect(audit.source_bytes_identical).toBe(false);
  expect(audit.executable_lines_identical).toBe(true);
  expect(() => auditPolicySource(reference.stdout, reference.stdout + "\n// authored test comment\n")).not.toThrow();
  expect(() => auditPolicySource(reference.stdout, current.replace("verdict != .estimateOnly", "true"))).toThrow("Executable policy source changed");
  expect(() => auditPolicySource("invalid reference", current)).toThrow("frozen hash");
});
test("updated build script requires shell-owned lease, lock, release and raised floor", () => {
  const script = readFileSync(fileURLToPath(new URL("../../../../apps/ios/Tools/reverse-meal-eval/run.sh", import.meta.url)), "utf8");
  expect(script).toContain('lr-reap" --run fridgeluck');
  expect(script).toContain('acquire --run fridgeluck --kind heavy --est-mem 1 --est-disk 0.3 --ttl 30 --owner-pid $$');
  expect(script).toContain('trap release_lease EXIT');
  expect(script).toContain('df -k /');
  expect(script).toContain('8388608');
  expect(script).toContain('/usr/bin/lockf -k "$HOME/.long-run/locks/heavy.lock" swiftc');
});
test("all TypeScript candidates are reproducible and case-order independent", () => {
  for (const arm of ["ios-A0", "ios-A1-proxy", "ios-A1-truth-control"] as const) {
    const forward = Object.fromEntries(rows.map(r => [r.case_id, assessTS(r, replay, arm)]));
    const reverse = Object.fromEntries([...rows].reverse().map(r => [r.case_id, assessTS(r, replay, arm)]));
    expect(forward).toEqual(reverse);
    for (const row of rows) if (projectState(row.producer_state).hardFailReasons.length) expect(forward[row.case_id]!.mode).toBe("estimate_only");
  }
});
test("proxy and truth control use different reward columns without evaluation feedback", () => {
  const row = rows[5]!;
  expect(assessTS(row, replay, "ios-A1-proxy").overallScore).not.toBe(assessTS(row, replay, "ios-A1-truth-control").overallScore);
  expect(assessTS(row, replay, "ios-A0").overallScore).not.toBe(assessTS(row, replay, "ios-A1-proxy").overallScore);
});
test("locking refuses existing artifacts and does not overwrite bytes", () => {
  mkdirSync("/tmp/fl-tc/reverse-meal", { recursive: true });
  const dir = mkdtempSync("/tmp/fl-tc/reverse-meal/lock-test-");
  expect(() => assertLockAvailable(dir)).not.toThrow();
  writeFileSync(`${dir}/manifest.json`, "sentinel");
  expect(() => assertLockAvailable(dir)).toThrow("Refusing to overwrite");
  expect(readFileSync(`${dir}/manifest.json`, "utf8")).toBe("sentinel");
});
test("cross-check reports mismatches without reconciling scores or raw modes", () => {
  const one = [rows[0]!];
  const doc: SwiftDocument = {
    serializer: "synthetic-test-only", checks: {},
    projections: one.map(r => ({ case_id: r.case_id, request: projectState(r.producer_state), serialized_request: canonicalJson(projectState(r.producer_state)) })),
    replay_projections: Object.entries(replay.states).map(([id, s]) => ({ state_id: id, request: projectState(s), serialized_request: canonicalJson(projectState(s)) })),
    candidates: ["ios-A0", "ios-A1-proxy", "ios-A1-truth-control"].map(candidate => ({ candidate: candidate as SwiftDocument["candidates"][number]["candidate"], results: [{ case_id: one[0]!.case_id, assessment: { mode: "exact", overallScore: 1, signals: [] }, trust_state: [], events: Array(candidate === "ios-A0" ? 0 : 48).fill(null), db_assertions: { after_event_rows: candidate === "ios-A0" ? 0 : 48, after_trust_rows: candidate === "ios-A0" ? 0 : 4, events_per_key: candidate === "ios-A0" ? 0 : 12, blended_reward_assertions: candidate === "ios-A0" ? 0 : 48, second_instance_persistence: true } }] }))
  };
  const original = canonicalJson(doc);
  const result = crossCheck(one, replay, doc);
  expect(result.all_agree).toBe(false);
  expect(result.mismatches).toHaveLength(3);
  expect(result.comparisons[0]).toMatchObject({ swift_mode: "exact", ts_mode: "estimate_only", hard_failure_violation: true });
  expect(canonicalJson(doc)).toBe(original);
  doc.projections[0]!.request = { signals: [], hardFailReasons: [] };
  expect(crossCheck(one, replay, doc).mismatches[0]!.kind).toBe("projection");
  doc.projections[0]!.request = projectState(one[0]!.producer_state);
  const actual = assessTS(one[0]!, replay, "ios-A0");
  doc.candidates[0]!.results[0]!.assessment.mode = actual.mode;
  doc.candidates[0]!.results[0]!.assessment.overallScore = actual.overallScore + 0.5e-12;
  expect(crossCheck(one, replay, doc).comparisons[0]!.scores_agree).toBe(true);
  doc.candidates[0]!.results[0]!.assessment.overallScore = actual.overallScore + 2e-12;
  expect(crossCheck(one, replay, doc).comparisons[0]!.scores_agree).toBe(false);
  expect(crossCheck(one, replay, doc).mismatches.some(m => m.candidate === "ios-A0")).toBe(true);
});
