import { describe, expect, test } from "bun:test";
import { buildDecisionsRequest, decide, MockDecisionsTransport, TransportTimeoutError, validateQuestion, type DecisionQuestion } from "../evaluation/decisionsAdapter.js";
import { MODES, type RoutingRequest } from "../evaluation/routingInput.js";

const request: RoutingRequest = { signals: [{ key: "synthetic.scale", rawScore: 0.9, weight: 1, reason: "Measured claim" }], hardFailReasons: [] };
const question: DecisionQuestion = { type: "choice", name: "fridgeluck_route", instructions: "Choose a route using this synthetic evidence.", choices: MODES.map(value => ({ value, description: value })) };
const distribution = [ { value: "exact", probability: 0.2 }, { value: "review_required", probability: 0.3 }, { value: "estimate_only", probability: 0.5 } ];
const answer = { name: "fridgeluck_route", type: "choice", choice: "exact" };
function run(body: unknown, httpStatus = 200) {
  return decide(request, question, new MockDecisionsTransport([{ httpStatus, body }]), { timeoutMs: 100 });
}

describe("Decisions request", () => {
  test("uses only model, canonical evidence string, and frozen question with decoded parity", () => {
    const body = buildDecisionsRequest(request, question);
    expect(Object.keys(body).sort()).toEqual(["input", "model", "questions"]);
    expect(body.model).toBe("gpt-6-luna");
    expect(body.questions).toEqual([question]);
    expect(JSON.parse(body.input)).toEqual(request);
    expect(body.input).toBe('{"hardFailReasons":[],"signals":[{"key":"synthetic.scale","rawScore":0.9,"reason":"Measured claim","weight":1}]}');
    expect(() => buildDecisionsRequest({ ...request, case_id: "leak" } as RoutingRequest, question)).toThrow("exactly fields");
  });
  const cases: Array<[string, unknown, string]> = [
    ["nonobject", null, "plain object"],
    ["extra field", { ...question, examples: [] }, "exactly fields"],
    ["wrong type", { ...question, type: "score" }, "question.type"],
    ["wrong name", { ...question, name: "other" }, "question.name"],
    ["empty instructions", { ...question, instructions: " " }, "question.instructions"],
    ["not array", { ...question, choices: {} }, "three choices"],
    ["missing option", { ...question, choices: question.choices.slice(1) }, "three choices"],
    ["wrong order", { ...question, choices: [...question.choices].reverse() }, "choices[0].value"],
    ["extra choice field", { ...question, choices: question.choices.map(c => ({ ...c, label: "x" })) }, "exactly fields"],
    ["empty description", { ...question, choices: question.choices.map(c => ({ ...c, description: "" })) }, "description"]
  ];
  for (const [name, value, reason] of cases) test(`rejects question ${name}`, () => expect(() => validateQuestion(value)).toThrow(reason));
});

describe("Decisions parsing", () => {
  for (const choice of MODES) test(`accepts ${choice}`, async () => {
    const result = await run({ answers: [{ ...answer, choice }] });
    expect(result.status).toBe("ok"); expect(result.mode).toBe(choice);
    expect(result.diagnostics.httpStatus).toBe(200);
  });
  test("probabilities and separate confidence are preserved without equating them", async () => {
    const result = await run({ answers: [{ ...answer, probabilities: [...distribution].reverse(), confidence: 0.91 }] });
    expect(result.diagnostics.probabilitiesUsable).toBe(true);
    expect(result.diagnostics.probabilities).toEqual([...distribution].reverse());
    expect(result.diagnostics.confidence).toBe(0.91);
  });
  const unusable = [
    ["absent", undefined], ["sum off", distribution.map(p => ({ ...p, probability: 0.2 }))],
    ["missing option", distribution.slice(1)], ["duplicate option", [distribution[0], distribution[0], distribution[2]]],
    ["NaN", distribution.map((p, i) => ({ ...p, probability: i === 0 ? NaN : p.probability }))],
    ["Infinity", distribution.map((p, i) => ({ ...p, probability: i === 0 ? Infinity : p.probability }))],
    ["out of range", distribution.map((p, i) => ({ ...p, probability: i === 0 ? -0.1 : p.probability }))],
    ["unknown option", distribution.map((p, i) => ({ ...p, value: i === 0 ? "unknown" : p.value }))],
    ["not array", {}]
  ] as const;
  for (const [name, probabilities] of unusable) test(`unusable probabilities ${name} do not override valid choice`, async () => {
    const result = await run({ answers: [{ ...answer, probabilities }] });
    expect(result.status).toBe("ok"); expect(result.mode).toBe("exact");
    expect(result.diagnostics.probabilitiesUsable).toBe(false);
    expect(result.diagnostics.probabilities).toBeUndefined();
  });
  test("probability sum tolerance is inclusive of small rounding error", async () => {
    const result = await run({ answers: [{ ...answer, probabilities: distribution.map((p, i) => ({ ...p, probability: p.probability + (i === 0 ? 0.0000005 : 0) })) }] });
    expect(result.diagnostics.probabilitiesUsable).toBe(true);
  });
  test("matching refusal has no mode", async () => {
    const result = await run({ answers: [{ name: "fridgeluck_route", type: "refusal" }] });
    expect(result.status).toBe("provider_refusal"); expect(result.mode).toBeNull();
    expect(result.diagnostics.reason).toBe("provider_refusal");
  });
  const invalid: Array<[string, unknown, string]> = [
    ["unknown name", { answers: [{ ...answer, name: "other" }] }, "unknown_answer_name"],
    ["unknown answer alongside matching answer", { answers: [{ ...answer, name: "other" }, answer] }, "unknown_answer_name"],
    ["missing name", { answers: [{ type: "choice", choice: "exact" }] }, "unknown_answer_name"],
    ["missing answer", { answers: [] }, "missing_answer"],
    ["duplicate answers", { answers: [answer, answer] }, "duplicate_answers"],
    ["wrong type", { answers: [{ ...answer, type: "score" }] }, "wrong_answer_type"],
    ["out-of-set", { answers: [{ ...answer, choice: "maybe" }] }, "out_of_set_choice"],
    ["answers not array", { answers: {} }, "answers_not_array"],
    ["malformed raw JSON", "{not JSON", "answers_not_array"],
    ["JSON primitive", 7, "answers_not_array"],
    ["JSON array", [], "answers_not_array"],
    ["null body", null, "answers_not_array"]
  ];
  for (const [name, body, reason] of invalid) test(`invalid ${name}`, async () => {
    const result = await run(body); expect(result.status).toBe("invalid"); expect(result.mode).toBeNull(); expect(result.diagnostics.reason).toBe(reason);
  });
  test("non-2xx maps to error before response parsing", async () => {
    const result = await run({ answers: [answer] }, 503);
    expect(result.status).toBe("error"); expect(result.mode).toBeNull(); expect(result.diagnostics.httpStatus).toBe(503);
  });
  test("timeout and generic error are distinct, and do not retry", async () => {
    const transport = new MockDecisionsTransport([new TransportTimeoutError("slow"), new Error("broken")]);
    const timeout = await decide(request, question, transport, { timeoutMs: 12 });
    expect(timeout.status).toBe("timeout"); expect(timeout.mode).toBeNull(); expect(timeout.diagnostics.httpStatus).toBeNull();
    expect(transport.bodies).toHaveLength(1);
    const error = await decide(request, question, transport, { timeoutMs: 13 });
    expect(error.status).toBe("error"); expect(error.mode).toBeNull();
    expect(transport.bodies).toEqual([buildDecisionsRequest(request, question), buildDecisionsRequest(request, question)]);
    expect(transport.options).toEqual([{ timeoutMs: 12 }, { timeoutMs: 13 }]);
  });
  test("extra provider metadata is accepted and retained separately", async () => {
    const body = { id: "synthetic-id", usage: { tokens: 4 }, answers: [answer] };
    const result = await run(body); expect(result.status).toBe("ok"); expect(result.diagnostics.rawBody).toEqual(body);
  });
});
