import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { projectState, parseStates, parseReplay, SIGNAL_KEYS, SIGNAL_WEIGHTS, SIGNAL_REASONS, HARD_FAILS, type ProducerState } from "../evaluation/reverseMealProjection.js";
import { decodeStrict } from "../evaluation/runRouting.js";
import { canonicalJson } from "../evaluation/canonicalJson.js";
const fixtures = "/Users/samgu/.t3/scratch/2026-10-07-all-right-i-want-you-f82246a0/fridgeluck-eval";
const rows = parseStates(readFileSync(`${fixtures}/reverse-meal-states-v1.jsonl`, "utf8"));
const state = (id: string) => rows.find(r => r.case_id === id)!.producer_state;
const empty: ProducerState = { detection_confidences: [], ranked_candidates: [] };
describe("reverse-meal source projection", () => {
  test("empty scans still emit all four source signals", () => {
    const r = projectState(empty);
    expect(r.signals.map(s => s.key)).toEqual([...SIGNAL_KEYS]);
    expect(r.signals.map(s => s.weight)).toEqual([...SIGNAL_WEIGHTS]);
    expect(r.signals.map(s => s.reason)).toEqual([...SIGNAL_REASONS]);
    expect(r.signals.map(s => s.rawScore)).toEqual([0, 0, 0, 0]);
    expect(r.hardFailReasons).toEqual([HARD_FAILS.no_candidate]);
  });
  test("detections round to binary32 before ordered accumulation; candidates remain binary64", () => {
    const s = state("RM-03"), r = projectState(s);
    expect(r.signals[0]!.rawScore).toBe(s.detection_confidences.reduce((a, b) => a + Math.fround(b), 0) / 3);
    expect(r.signals[0]!.rawScore).not.toBe(0.98);
    expect(r.signals[1]!.rawScore).toBe(0.96);
    expect(r.signals[1]!.rawScore).not.toBe(Math.fround(0.96));
    expect(r.signals[2]!.rawScore).toBe(1);
    expect(r.signals[3]!.rawScore).toBe(0.82);
  });
  test("strict gap comparisons preserve binary64 RM-10", () => {
    expect(projectState(state("RM-08")).hardFailReasons).toEqual([HARD_FAILS.ambiguity]);
    expect(projectState(state("RM-09")).hardFailReasons).toEqual([]);
    expect(0.86 - 0.80).toBeLessThan(0.06);
    expect(projectState(state("RM-10")).hardFailReasons).toEqual([HARD_FAILS.ambiguity]);
  });
  test("missing-required guard has first-match precedence, two missing do not hard fail", () => {
    expect(projectState(state("RM-11")).hardFailReasons).toEqual([]);
    expect(projectState(state("RM-12")).hardFailReasons).toEqual([HARD_FAILS.missing_required]);
  });
  test("margin clamps at one and ties preserve supplied order", () => {
    expect(projectState(state("RM-06")).signals[3]!.rawScore).toBe(1);
    const tie = structuredClone(state("RM-06"));
    tie.ranked_candidates[1]!.confidence_score = tie.ranked_candidates[0]!.confidence_score;
    expect(projectState(tie).signals[3]!.rawScore).toBe(0.5);
    expect(tie.ranked_candidates.map(c => c.id)).toEqual([601, 602]);
  });
  test("six hard failures and exact evidence collisions, without labels", () => {
    expect(rows.filter(r => projectState(r.producer_state).hardFailReasons.length)).toHaveLength(6);
    expect(canonicalJson(projectState(state("RM-03")))).toBe(canonicalJson(projectState(state("RM-04"))));
    expect(canonicalJson(projectState(state("RM-03")))).toBe(canonicalJson(projectState(state("RM-13"))));
    expect(canonicalJson(projectState(state("RM-06")))).toBe(canonicalJson(projectState(state("RM-16"))));
  });
  test("case order does not alter projection", () => {
    const forward = Object.fromEntries(rows.map(r => [r.case_id, canonicalJson(projectState(r.producer_state))]));
    const reverse = Object.fromEntries([...rows].reverse().map(r => [r.case_id, canonicalJson(projectState(r.producer_state))]));
    expect(forward).toEqual(reverse);
  });
  test("replay uses all exact keys, 12 episodes, and no evaluation requests", () => {
    const replay = parseReplay(readFileSync(`${fixtures}/reverse-meal-replay-v1.json`, "utf8"), rows);
    expect(replay.episodes).toHaveLength(12);
    expect(replay.episodes.reduce((sum, e) => sum + e.truth_reward, 0)).toBe(6);
    expect(replay.episodes.some(e => e.proxy_reward === 0.72)).toBe(false);
    for (const s of Object.values(replay.states)) expect(projectState(s).signals.map(s => s.key)).toEqual([...SIGNAL_KEYS]);
  });
  const malformed = [
    { ...empty, label: true },
    { ...empty, detection_confidences: [NaN] },
    { ...empty, detection_confidences: [Infinity] },
    { ...empty, detection_confidences: [true] },
    { ...empty, detection_confidences: [-0.1] },
    { ...empty, detection_confidences: [1.1] },
    { ...empty, ranked_candidates: [{ ...state("RM-03").ranked_candidates[0], matched_required: 2.5 }] },
    { ...state("RM-03"), ranked_candidates: [{ ...state("RM-03").ranked_candidates[0], missing_required_count: 1 }] },
    { ...state("RM-03"), detection_confidences: [0.9] },
    { ...state("RM-06"), ranked_candidates: [...state("RM-06").ranked_candidates].reverse() },
    { ...state("RM-03"), ranked_candidates: [state("RM-03").ranked_candidates[0], state("RM-03").ranked_candidates[0]] }
  ];
  test.each(malformed.map((v, i) => [i, v] as const))("rejects malformed state %i", (_, value) => expect(() => projectState(value as ProducerState)).toThrow());
  test.each(['{"a":1,"a":2}', '{"a":{"b":1,"b":2}}', '{"a":NaN}'])("rejects malformed JSON %s", text => expect(() => decodeStrict(text)).toThrow());
  test("rejects duplicate state IDs and replay reward drift", () => {
    const line = JSON.stringify(rows[0]);
    expect(() => parseStates(`${line}\n${line}`)).toThrow("Duplicate case_id");
    const replay = JSON.parse(readFileSync(`${fixtures}/reverse-meal-replay-v1.json`, "utf8"));
    replay.episodes[0].proxy_reward = 0.72;
    expect(() => parseReplay(JSON.stringify(replay), rows)).toThrow("reward mismatch");
  });
  test("portable original runner resolution does not use Bun-only metadata", () => {
    const text = readFileSync(fileURLToPath(new URL("../evaluation/runRouting.ts", import.meta.url)), "utf8");
    expect(text).not.toContain("import.meta.dir");
    expect(text).not.toContain("import.meta.main");
    expect(text).toContain('fileURLToPath(new URL(".", import.meta.url))');
  });
});
