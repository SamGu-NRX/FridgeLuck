import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { scoreReverseMeal, parseLabels, parsePredictions, parseParity, validateV1Family, CAVEATS, actionFor, type OutcomeLabel, type Prediction } from "../evaluation/scoreReverseMeal.js";
import { projectState, type StateRow } from "../evaluation/reverseMealProjection.js";
// Authored synthetic labels only. These do not mirror or read the real outcome-label file.
const id = (i: number) => `RM-${String(i).padStart(2, "0")}`;
const states: StateRow[] = Array.from({ length: 16 }, (_, index) => {
  const i = index + 1, shared = [3, 4, 13].includes(i) ? 3 : [6, 16].includes(i) ? 6 : i;
  return { case_id: id(i), producer_state: { detection_confidences: [0.71 + shared / 100, 0.8, 0.9], ranked_candidates: i <= 2 ? [] : [{ id: 100 + shared, confidence_score: 0.7 + shared / 100, matched_required: 3, total_required: i === 12 ? 6 : 3, missing_required_count: i === 12 ? 3 : 0 }] } };
});
const edits: Record<string, string[]> = { "RM-04": ["recipe_id"], "RM-10": ["servings"], "RM-13": ["servings"], "RM-16": ["portion_multiplier"] };
const labels: OutcomeLabel[] = states.map(s => {
  const i = Number(s.case_id.slice(3));
  const known = ![1, 2, 12, 15].includes(i);
  const group = [3, 4, 13].includes(i) ? "collision-a" : [6, 16].includes(i) ? "collision-b" : [8, 9, 10].includes(i) ? "gap-boundary" : `synthetic-${i}`;
  return { case_id: s.case_id, group_id: group, stratum: known ? "outcome" : i === 12 ? "guard_only" : i === 15 ? "evidence_required" : "absence", expected_hard_fail: i <= 2 ? "no_candidate" : i === 12 ? "missing_required" : null, original_proposal_correct: known ? !edits[s.case_id] : null, required_edit_fields: edits[s.case_id] ?? [] };
});
const predictions: Prediction[] = states.map(s => ({ case_id: s.case_id, status: "ok", mode: "exact" }));
const score = (ps = predictions) => scoreReverseMeal(states, ps, labels);
const override = (values: Record<string, Partial<Prediction>>) => predictions.map(p => ({ ...p, ...values[p.case_id] }));
test("v1 scorer rejects changed family denominators rather than silently dropping truth", () => {
  expect(() => validateV1Family(states, labels)).not.toThrow();
  expect(() => validateV1Family(states.slice(1), labels)).toThrow("RM-01 through RM-16");
  expect(() => validateV1Family(states, labels.slice(1))).toThrow("one label per state");
  const altered = labels.map(l => l.case_id === "RM-03" ? { ...l, stratum: "unknown", original_proposal_correct: null } : l);
  expect(() => validateV1Family(states, altered)).toThrow("12 known outcomes");
});
test("synthetic 12-row quality slice has explicit 8/4 and seven-group denominators", () => {
  const s = score();
  expect(s.conformance.attempts).toBe(16);
  expect(s.known_outcome.attempts).toBe(12);
  expect(s.known_outcome.correct_proposals).toBe(8);
  expect(s.known_outcome.incorrect_proposals).toBe(4);
  expect(s.known_outcome.scenario_groups).toBe(7);
  expect(s.known_outcome.false_one_tap_rate_among_valid_offers).toEqual({ numerator: 4, denominator: 12, rate: 1 / 3 });
  expect(s.known_outcome.offer_accept_coverage_over_all_attempts).toEqual({ numerator: 12, denominator: 12, rate: 1 });
  expect(s.guard_only_conformance.hard_failure_mode_violations.numerator).toBe(1);
  expect(s.conformance.hard_failure_mode_violations.numerator).toBe(3);
});
test("field-specific false opportunities preserve recipe, servings, and portion distinctions", () => {
  const fields = score().known_outcome.false_one_tap_fields;
  expect(fields.recipe_id!.among_false_offers.numerator).toBe(1);
  expect(fields.servings!.among_false_offers.numerator).toBe(2);
  expect(fields.portion_multiplier!.among_false_offers.numerator).toBe(1);
  expect(fields.servings!.among_false_offers.denominator).toBe(4);
  expect(fields.servings!.over_known_attempts.denominator).toBe(12);
});
test("raw modes and valid friction stay separate from contained failure burden", () => {
  const s = score(override({ "RM-05": { mode: "review_required" }, "RM-07": { mode: "estimate_only" }, "RM-06": { status: "timeout", mode: null }, "RM-04": { status: "invalid", mode: null }, "RM-13": { mode: "review_required" }, "RM-16": { mode: "estimate_only" } }));
  const correct = s.known_outcome.friction_on_correct, wrong = s.known_outcome.incorrect_dispositions;
  expect(correct.actions.check_prompt!.numerator).toBe(1);
  expect(correct.actions.manual_pick!.numerator).toBe(1);
  expect(correct.failure_induced_manual_pick).toEqual({ numerator: 1, denominator: 8, rate: 0.125 });
  expect(wrong.actions.check_prompt!.numerator).toBe(1);
  expect(wrong.actions.manual_pick!.numerator).toBe(1);
  expect(wrong.failure_induced_manual_pick.numerator).toBe(1);
  expect(s.projected_actions.find(r => r.case_id === "RM-06")).toMatchObject({ action: "manual_pick", failure_containment: true });
  expect(s.known_outcome.raw_modes.timeout).toBeUndefined();
  expect(s.known_outcome.raw_modes.failures.timeout!.numerator).toBe(1);
});
test("zero offer denominator is undefined, not perfect precision", () => {
  const s = score(predictions.map(p => ({ ...p, mode: "estimate_only" })));
  expect(s.known_outcome.false_one_tap_rate_among_valid_offers).toEqual({ numerator: 0, denominator: 0, rate: null });
});
test("collision groups expose trade-offs rather than require impossible perfect routing", () => {
  const groups = score().known_outcome.evidence_collision_tradeoffs;
  expect(groups).toHaveLength(2);
  expect(groups[0]!.case_ids).toEqual(["RM-03", "RM-04", "RM-13"]);
  expect(groups[0]!.dispositions_identical).toBe(true);
  expect(groups[0]!.correct.attempts).toBe(1);
  expect(groups[0]!.incorrect.attempts).toBe(2);
  expect(groups[0]!.false_one_tap_rate.rate).toBe(2 / 3);
  const altered = score(override({ "RM-04": { mode: "estimate_only" } }));
  expect(altered.known_outcome.evidence_collision_tradeoffs[0]!.dispositions_identical).toBe(false);
});
test("absence, unknown truth and RM-12 stay outside quality; raw invalid action remains visible", () => {
  const s = score();
  expect(s.absence_handling).toHaveLength(2);
  expect(s.absence_handling[0]).toMatchObject({ raw: { mode: "exact" }, action: "offer_accept", offer_accept_preconditions_valid: false });
  expect(s.evidence_required[0]!.case_id).toBe("RM-15");
  expect(s.defensive_guard[0]!.case_id).toBe("RM-12");
  expect(s.known_outcome.group_tradeoffs.flatMap(g => g.case_ids)).not.toContain("RM-12");
  expect(s.policy_invariants).toMatchObject({ explicit_confirmation_always_required: true, mode_changes_confirmed_amounts: false });
});
test.each(["provider_refusal", "refusal", "invalid", "timeout", "error"] as const)("non-ok %s is contained without successful-deferral credit", status => {
  const s = score(override({ "RM-04": { status, mode: null } }));
  expect(actionFor({ case_id: "test", status, mode: null })).toBe("manual_pick");
  expect(s.known_outcome.incorrect_dispositions.actions.manual_pick!.numerator).toBe(0);
  expect(s.known_outcome.incorrect_dispositions.failure_induced_manual_pick.numerator).toBe(1);
});
test("strict joins and normalized shapes reject missing/duplicate attempts and fabricated modes", () => {
  expect(() => scoreReverseMeal(states, predictions.slice(1), labels)).toThrow("one row");
  expect(() => parsePredictions('{"case_id":"x","status":"error","mode":"exact"}')).toThrow("failure requires null");
  expect(() => parsePredictions('{"case_id":"x","status":"ok","mode":null}')).toThrow();
  expect(() => parsePredictions('{"case_id":"x","status":"ok","mode":"exact","truth":true}')).toThrow();
  const p = JSON.stringify(predictions[0]);
  expect(() => parsePredictions(`${p}\n${p}`)).toThrow("duplicate");
  expect(() => parseLabels(JSON.stringify({ ...labels[0], original_proposal_correct: false }))).toThrow("non-outcome");
  expect(() => parseLabels(JSON.stringify({ ...labels[2], original_proposal_correct: false }))).toThrow("inconsistent");
  expect(() => parseLabels(JSON.stringify({ ...labels[14], stratum: "outcome", original_proposal_correct: true }))).toThrow("not a binary outcome");
  expect(parseLabels(JSON.stringify({ ...labels[14], required_edit_fields: undefined }))[0]!.required_edit_fields).toBeNull();
  expect(() => parseLabels(JSON.stringify({ ...labels[3], required_edit_fields: null }))).toThrow("invalid required_edit_fields");
});
test("optional synthetic parity reports score and mode denominators, guard separately", () => {
  const comparisons = states.map(s => ({ case_id: s.case_id, swift_candidate: "synthetic-arm", swift_mode: "exact", ts_mode: s.case_id === "RM-12" ? "estimate_only" : "exact", swift_score: 0.7, ts_score: s.case_id === "RM-12" ? 0.6 : 0.7 }));
  const parity = parseParity(JSON.stringify({ comparisons }), states);
  const result = scoreReverseMeal(states, predictions, labels, parity).swift_typescript_agreement;
  expect(result.status).toBe("supplied");
  expect(result.candidates![0]!.all_attempts.mode_agreement).toEqual({ numerator: 15, denominator: 16, rate: 15 / 16 });
  expect(result.candidates![0]!.guard_only.score_agreement).toEqual({ numerator: 0, denominator: 1, rate: 0 });
  expect(() => parseParity(JSON.stringify({ comparisons: comparisons.slice(1) }), states)).toThrow("incomplete arm");
  expect(() => parseParity(JSON.stringify({ comparisons: [...comparisons, comparisons[0]] }), states)).toThrow("duplicate");
});
test("all scorer caveats are verbatim passages of the read-only spec", () => {
  const spec = readFileSync("/Users/samgu/.t3/scratch/2026-10-07-all-right-i-want-you-f82246a0/fridgeluck-eval/reverse-meal-spec-v1.md", "utf8");
  for (const caveat of CAVEATS) expect(spec).toContain(caveat);
});
test("scorer executable accepts paths and scores authored synthetic data only", () => {
  mkdirSync("/tmp/fl-tc/reverse-meal", { recursive: true });
  const dir = mkdtempSync("/tmp/fl-tc/reverse-meal/scorer-synthetic-");
  const jsonl = (rows: unknown[]) => rows.map(row => JSON.stringify(row)).join("\n") + "\n";
  writeFileSync(`${dir}/states.jsonl`, jsonl(states));
  writeFileSync(`${dir}/labels-synthetic.jsonl`, jsonl(labels));
  writeFileSync(`${dir}/outputs.jsonl`, jsonl(predictions));
  const result = spawnSync("/usr/bin/env", ["-i", `PATH=${process.env.PATH ?? ""}`, `HOME=${process.env.HOME ?? ""}`, "bun", fileURLToPath(new URL("../evaluation/scoreReverseMeal.ts", import.meta.url)), "--states", `${dir}/states.jsonl`, "--outputs", `${dir}/outputs.jsonl`, "--labels", `${dir}/labels-synthetic.jsonl`], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: process.env.HOME } });
  expect(result.status).toBe(0);
  const output = JSON.parse(result.stdout);
  expect(output.results[0].known_outcome.attempts).toBe(12);
  expect(output.header.caveats).toEqual(CAVEATS);
});
