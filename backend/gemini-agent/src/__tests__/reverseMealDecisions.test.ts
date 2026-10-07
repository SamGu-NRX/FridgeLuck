import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildReverseMealDecisionsRequest, decideReverseMealMock, MockReverseMealTransport } from "../evaluation/reverseMealDecisions.js";
import { projectState } from "../evaluation/reverseMealProjection.js";
import { TransportTimeoutError, buildDecisionsRequest } from "../evaluation/decisionsAdapter.js";
const question = JSON.parse(readFileSync(fileURLToPath(new URL("../../evaluation-fixtures/reverse-meal-question-v1.json", import.meta.url)), "utf8"));
const request = projectState({ detection_confidences: [], ranked_candidates: [] });
const answer = (choice: unknown, name = "fridgeluck_reverse_meal_route") => ({ httpStatus: 200, body: { answers: [{ name, type: "choice", choice }] } });
test("new question has exactly model/input/questions, and input is derived request only", async () => {
  const transport = new MockReverseMealTransport([answer("estimate_only")]);
  const result = await decideReverseMealMock(request, question, transport, { timeoutMs: 400 });
  expect(result.status).toBe("ok");
  const body = transport.bodies[0]!;
  expect(Object.keys(body).sort()).toEqual(["input", "model", "questions"]);
  expect(body.model).toBe("gpt-6-luna");
  expect(body.questions).toEqual([question]);
  expect(JSON.parse(body.input)).toEqual(request);
  expect(Object.keys(JSON.parse(body.input)).sort()).toEqual(["hardFailReasons", "signals"]);
  expect(transport.options).toEqual([{ timeoutMs: 400 }]);
});
test.each(["exact", "review_required", "estimate_only"])("preserves raw %s, including hard-fail violations", async mode => {
  const result = await decideReverseMealMock(request, question, new MockReverseMealTransport([answer(mode)]), { timeoutMs: 1 });
  expect(result.mode).toBe(mode);
});
test("original adapter keeps its question boundary", () => {
  expect(() => buildDecisionsRequest(request, question)).toThrow("question.name");
  expect(() => buildReverseMealDecisionsRequest(request, { ...question, name: "fridgeluck_route" })).toThrow();
});
test.each([
  { case_id: "leak", ...request },
  { ...request, signals: [] },
  { ...request, signals: [...request.signals].reverse() },
  { ...request, signals: request.signals.map((s, i) => i === 0 ? { ...s, weight: 1 } : s) }
])("rejects evidence drift %#", bad => expect(() => buildReverseMealDecisionsRequest(bad, question)).toThrow());
test.each([
  [answer("dish"), "invalid"],
  [answer("exact", "fridgeluck_route"), "invalid"],
  [{ httpStatus: 200, body: { answers: [] } }, "invalid"],
  [{ httpStatus: 200, body: { answers: [answer("exact").body.answers[0], answer("exact").body.answers[0]] } }, "invalid"],
  [{ httpStatus: 200, body: { answers: [{ name: question.name, type: "refusal" }] } }, "provider_refusal"],
  [{ httpStatus: 500, body: {} }, "error"],
  [new TransportTimeoutError("test"), "timeout"],
  [new Error("test"), "error"]
] as const)("failures preserve null mode %#", async (response, status) => {
  const result = await decideReverseMealMock(request, question, new MockReverseMealTransport([response]), { timeoutMs: 1 });
  expect(result.status).toBe(status);
  expect(result.mode).toBeNull();
});
test("malformed probabilities never invalidate a valid choice or invent a probability", async () => {
  const result = await decideReverseMealMock(request, question, new MockReverseMealTransport([{ httpStatus: 200, body: { answers: [{ name: question.name, type: "choice", choice: "exact", probabilities: [{ value: "exact", probability: 1 }], confidence: 2 }] } }]), { timeoutMs: 1 });
  expect(result.mode).toBe("exact");
  expect(result.diagnostics.probabilitiesUsable).toBe(false);
  expect(result.diagnostics.confidence).toBeUndefined();
});
