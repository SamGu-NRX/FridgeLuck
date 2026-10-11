import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { ConfidenceService } from "../services/confidenceService.js";
import { assessCold, assessWarm, DEV_SEQUENCE, DEV_SEQUENCE_HASH } from "../evaluation/bayesRouting.js";
import { canonicalJson } from "../evaluation/canonicalJson.js";
import { assertOutputPathsAvailable, decodeStrict, evaluateRows, parseRoutingInputs, renderRun, validateCandidate } from "../evaluation/runRouting.js";
import { validateRoutingRow, type RoutingRequest, type RoutingRow } from "../evaluation/routingInput.js";

function request(key = "portion.visual", rawScore = 0.7): RoutingRequest {
  return { signals: [{ key, rawScore, weight: 1, reason: key }], hardFailReasons: [] };
}
const syntheticRows: RoutingRow[] = [
  { case_id: "synthetic-1", request: request() },
  { case_id: "synthetic-2", request: request("manual.scale", 0.98) },
  { case_id: "synthetic-3", request: request("ocr_exact.identity", 0.95) },
  { case_id: "synthetic-4", request: request("manual.count", 0.8) },
  { case_id: "synthetic-5", request: { signals: [], hardFailReasons: [] } }
];
function seededShuffle<T>(items: T[], seed: number): T[] {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const j = seed % (i + 1);
    [result[i], result[j]] = [result[j]!, result[i]!];
  }
  return result;
}

describe("Bayesian routing", () => {
  test("cold uses service mode and score with deterministic conformance", () => {
    const input = request("ocr_exact.identity", 0.99);
    const service = new ConfidenceService().assess(input);
    const result = assessCold(input);
    expect(result.status).toBe("ok"); expect(result.mode).toBe(service.mode);
    expect(result.diagnostics.overallScore).toBe(service.overallScore);
    expect(Number.isFinite(result.diagnostics.overallScore)).toBe(true);
    expect(result.diagnostics.overallScore).toBeGreaterThanOrEqual(0);
    expect(result.diagnostics.overallScore).toBeLessThanOrEqual(1);
    expect(service.deterministicReady).toBe(result.mode === "exact");
    expect(result.diagnostics.signals[0]!.adjustedScore).toBe(service.signals[0]!.adjustedScore);
  });
  test("empty signals and hard failures force estimate_only for both candidates", () => {
    for (const assess of [assessCold, assessWarm]) {
      expect(assess({ signals: [], hardFailReasons: [] }).mode).toBe("estimate_only");
      expect(assess({ ...request("manual.scale", 1), hardFailReasons: ["Missing provenance"] }).mode).toBe("estimate_only");
    }
  });
  test("portion development failures lower trust and adjusted score, changing a constructed route", () => {
    const cold = assessCold(request("portion.visual", 0.8)), warm = assessWarm(request("portion.visual", 0.8));
    expect(warm.diagnostics.signals[0]!.trustMean).toBeLessThan(cold.diagnostics.signals[0]!.trustMean);
    expect(warm.diagnostics.signals[0]!.adjustedScore).toBeLessThan(cold.diagnostics.signals[0]!.adjustedScore);
    expect(warm.mode).not.toBe(cold.mode);
  });
  test("warm reports exact key overlap, without substring matching", () => {
    const input = { signals: [request().signals[0]!, request("manual.count").signals[0]!, request().signals[0]!], hardFailReasons: [] };
    expect(assessWarm(input).diagnostics.warmedSignalKeys).toEqual(["portion.visual"]);
    expect(assessWarm(request("portion.other")).diagnostics.warmedSignalKeys).toEqual([]);
    expect(assessCold(input).diagnostics.warmedSignalKeys).toEqual([]);
  });
  test("sequence updates only exact keys, leaving unrelated prior trust unchanged", () => {
    expect(assessWarm(request("manual.count")).diagnostics.signals[0]!.trustMean).toBe(assessCold(request("manual.count")).diagnostics.signals[0]!.trustMean);
    for (const block of DEV_SEQUENCE) {
      expect(assessWarm(request(block.key)).diagnostics.signals[0]!.trustMean).not.toBe(assessCold(request(block.key)).diagnostics.signals[0]!.trustMean);
    }
  });
  test("development sequence and canonical hash are frozen", () => {
    expect(DEV_SEQUENCE.map(b => b.key)).toEqual(["vision.identity", "ocr_exact.identity", "ocr_fuzzy.identity", "portion.visual", "manual.scale", "gemini.live_scene"]);
    expect(DEV_SEQUENCE.flatMap(b => b.rewards)).toHaveLength(34);
    expect(DEV_SEQUENCE_HASH).toBe("cba95992aaf9c4996d9ca1b7b43f95bfbf9453980ec8cbcdb905e51d001f465f");
    expect(createHash("sha256").update(canonicalJson(DEV_SEQUENCE)).digest("hex")).toBe(DEV_SEQUENCE_HASH);
  });
  for (const candidate of ["bayes-cold", "bayes-warm"] as const) test(`${candidate} is independent of forward, reversed and fixed-seed shuffled order`, () => {
    const assess = candidate === "bayes-cold" ? assessCold : assessWarm;
    const perCase = (rows: RoutingRow[]) => Object.fromEntries(rows.map(row => {
      const r = assess(row.request);
      return [row.case_id, { mode: r.mode, overallScore: r.diagnostics.overallScore }];
    }));
    expect(perCase([...syntheticRows].reverse())).toEqual(perCase(syntheticRows));
    expect(perCase(seededShuffle(syntheticRows, 73))).toEqual(perCase(syntheticRows));
    expect(evaluateRows([...syntheticRows].reverse(), candidate)).toEqual(evaluateRows(syntheticRows, candidate));
  });
  test("two warm runs reproduce normalized bytes and diagnostics except UTC timestamp", () => {
    const a = renderRun(syntheticRows, "bayes-warm", { utcTime: "2026-10-07T00:00:00Z", sourceGitCommit: "synthetic" });
    const b = renderRun(syntheticRows, "bayes-warm", { utcTime: "2026-10-07T00:00:01Z", sourceGitCommit: "synthetic" });
    expect(a.out).toBe(b.out);
    const withoutTimestamp = (text: string) => text.trim().split("\n").map(line => {
      const value = JSON.parse(line); delete value.utcTime; return value;
    });
    expect(withoutTimestamp(a.diagnostics)).toEqual(withoutTimestamp(b.diagnostics));
    const header = JSON.parse(a.diagnostics.split("\n")[0]!);
    expect(header.candidate).toBe("A1-warm-dev-synthetic");
    expect(header.devSequenceSha256).toBe(DEV_SEQUENCE_HASH);
    expect(JSON.parse(renderRun(syntheticRows, "bayes-cold", {}).diagnostics.split("\n")[0]!).candidate).toBe("A0-cold-prior");
    for (const row of a.out.trim().split("\n").map(line => JSON.parse(line))) expect(Object.keys(row).sort()).toEqual(["case_id", "mode", "status"]);
  });
});

describe("runner input safeguards", () => {
  test("refuses existing output or diagnostics and colliding paths before reading", () => {
    expect(() => assertOutputPathsAvailable("/input", "/out", "/diag", p => p === "/out")).toThrow("Refusing to overwrite");
    expect(() => assertOutputPathsAvailable("/input", "/out", "/diag", p => p === "/diag")).toThrow("Refusing to overwrite");
    expect(() => assertOutputPathsAvailable("/input", "/out", "/out", () => false)).toThrow("distinct paths");
    expect(() => assertOutputPathsAvailable("/input", "/input", "/diag", () => false)).toThrow("distinct paths");
    expect(() => assertOutputPathsAvailable("/input", "/out", "/diag", () => false)).not.toThrow();
  });
  test("rejects Luna and unknown candidates", () => {
    expect(() => validateCandidate("luna")).toThrow("not authorized");
    expect(() => validateCandidate("other")).toThrow("expected bayes-cold or bayes-warm");
  });
  test("parses synthetic JSONL and rejects duplicate IDs and JSON keys", () => {
    expect(parseRoutingInputs(syntheticRows.map(canonicalJson).join("\n"))).toEqual(syntheticRows);
    expect(() => parseRoutingInputs([syntheticRows[0], syntheticRows[0]].map(canonicalJson).join("\n"))).toThrow("Duplicate case_id");
    expect(() => decodeStrict('{"a":1,"a":2}')).toThrow("Duplicate JSON key");
    expect(() => decodeStrict('{"a":[{"x":1,"\\u0078":2}]}')).toThrow("Duplicate JSON key: x");
    expect(decodeStrict('{"a":[],"b":{},"c":[1,2,{"d":"quoted \\\" {"}]}')).toEqual({ a: [], b: {}, c: [1, 2, { d: 'quoted " {' }] });
    expect(() => parseRoutingInputs("not-json")).toThrow("Input line 1");
    expect(() => parseRoutingInputs('{"case_id":"x","request":{"signals":[],"hardFailReasons":[],"signals":[]}}')).toThrow("Duplicate JSON key");
  });
  const valid = { case_id: "synthetic-invalid-check", request: request() };
  const malformed: Array<[string, unknown, string]> = [
    ["row metadata", { ...valid, label: "exact" }, "row: expected exactly fields"],
    ["empty ID", { ...valid, case_id: " " }, "row.case_id"],
    ["missing request", { case_id: "x" }, "exactly fields"],
    ["request metadata", { ...valid, request: { ...request(), extra: 1 } }, "request: expected exactly fields"],
    ["signals not array", { ...valid, request: { signals: {}, hardFailReasons: [] } }, "request.signals"],
    ["hardFailReasons not array", { ...valid, request: { signals: [], hardFailReasons: "x" } }, "request.hardFailReasons"],
    ["empty hard failure", { ...valid, request: { signals: [], hardFailReasons: [" "] } }, "hardFailReasons[0]"],
    ["extra signal field", { ...valid, request: { ...request(), signals: [{ ...request().signals[0], extra: 1 }] } }, "exactly fields"],
    ["empty key", { ...valid, request: { ...request(), signals: [{ ...request().signals[0], key: "" }] } }, ".key"],
    ["empty reason", { ...valid, request: { ...request(), signals: [{ ...request().signals[0], reason: " " }] } }, ".reason"]
  ];
  for (const [name, value, message] of malformed) test(`rejects ${name}`, () => expect(() => validateRoutingRow(value)).toThrow(message));
  for (const rawScore of [-0.1, 1.1, NaN, Infinity, true, "0.7"]) test(`rejects invalid rawScore ${String(rawScore)}`, () => {
    expect(() => validateRoutingRow({ ...valid, request: { ...request(), signals: [{ ...request().signals[0], rawScore }] } })).toThrow("rawScore: expected finite number in [0,1]");
  });
  for (const weight of [0, -1, NaN, Infinity, true, "1"]) test(`rejects invalid weight ${String(weight)}`, () => {
    expect(() => validateRoutingRow({ ...valid, request: { ...request(), signals: [{ ...request().signals[0], weight }] } })).toThrow("weight: expected finite number > 0");
  });
});
