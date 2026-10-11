import { canonicalJson } from "./canonicalJson.js";
import { exactObject, MODES, nonemptyString, validateRequest, type Mode, type RoutingRequest } from "./routingInput.js";
import { TransportTimeoutError, type DecisionResult } from "./decisionsAdapter.js";
import { SIGNAL_KEYS, SIGNAL_WEIGHTS, SIGNAL_REASONS } from "./reverseMealProjection.js";

export interface ReverseMealQuestion {
  type: "choice";
  name: "fridgeluck_reverse_meal_route";
  instructions: string;
  choices: Array<{ value: Mode; description: string }>;
}
export function validateReverseMealQuestion(value: unknown): asserts value is ReverseMealQuestion {
  const q = exactObject(value, ["type", "name", "instructions", "choices"], "question");
  if (q.type !== "choice" || q.name !== "fridgeluck_reverse_meal_route") throw new Error("question: expected reverse-meal choice question");
  nonemptyString(q.instructions, "question.instructions");
  if (!Array.isArray(q.choices) || q.choices.length !== 3) throw new Error("question.choices: expected three choices");
  q.choices.forEach((value, i) => {
    const c = exactObject(value, ["value", "description"], `question.choices[${i}]`);
    if (c.value !== MODES[i]) throw new Error(`question.choices[${i}]: wrong mode/order`);
    nonemptyString(c.description, "choice.description");
  });
}
export function buildReverseMealDecisionsRequest(request: RoutingRequest, question: unknown) {
  validateRequest(request);
  validateReverseMealQuestion(question);
  if (request.signals.length !== 4 || request.signals.some((s, i) => s.key !== SIGNAL_KEYS[i] || s.weight !== SIGNAL_WEIGHTS[i] || s.reason !== SIGNAL_REASONS[i])) throw new Error("request: expected four ordered source signals with exact weights/reasons");
  return { model: "gpt-6-luna" as const, input: canonicalJson(request), questions: [question] };
}
export type ReverseMealDecisionsRequest = ReturnType<typeof buildReverseMealDecisionsRequest>;
// No live transport implementation or environment access in this diagnostic.
export class MockReverseMealTransport {
  readonly bodies: ReverseMealDecisionsRequest[] = [];
  readonly options: Array<{ timeoutMs: number }> = [];
  private index = 0;
  constructor(private readonly script: Array<{ httpStatus: number; body: unknown } | Error>) {}
  async send(body: ReverseMealDecisionsRequest, options: { timeoutMs: number }) {
    this.bodies.push(structuredClone(body));
    this.options.push({ ...options });
    const next = this.script[this.index++];
    if (!next) throw new Error("Mock Decisions script exhausted");
    if (next instanceof Error) throw next;
    return next;
  }
}
export async function decideReverseMealMock(request: RoutingRequest, question: unknown, transport: MockReverseMealTransport, opts: { timeoutMs: number }): Promise<DecisionResult> {
  const body = buildReverseMealDecisionsRequest(request, question);
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error("timeoutMs: expected finite number > 0");
  const diagnostics: DecisionResult["diagnostics"] = { httpStatus: null };
  const failure = (status: DecisionResult["status"], reason: string): DecisionResult => ({ status, mode: null, diagnostics: { ...diagnostics, reason } });
  let response;
  try { response = await transport.send(body, opts); }
  catch (e) { return failure(e instanceof TransportTimeoutError ? "timeout" : "error", e instanceof TransportTimeoutError ? "transport_timeout" : "transport_error"); }
  diagnostics.httpStatus = response.httpStatus;
  diagnostics.rawBody = response.body;
  if (!Number.isInteger(response.httpStatus) || response.httpStatus < 200 || response.httpStatus >= 300) return failure("error", "http_status");
  const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
  const mode = (v: unknown): v is Mode => MODES.includes(v as Mode);
  if (!object(response.body) || !Array.isArray(response.body.answers)) return failure("invalid", "answers_not_array");
  const answers = response.body.answers;
  if (answers.some(a => !object(a) || a.name !== "fridgeluck_reverse_meal_route")) return failure("invalid", "unknown_answer_name");
  if (answers.length !== 1) return failure("invalid", answers.length ? "duplicate_answers" : "missing_answer");
  const answer = answers[0] as Record<string, unknown>;
  if (answer.type === "refusal") return failure("provider_refusal", "provider_refusal");
  if (answer.type !== "choice") return failure("invalid", "wrong_answer_type");
  if (!mode(answer.choice)) return failure("invalid", "out_of_set_choice");
  const ps = answer.probabilities;
  const usable = Array.isArray(ps) && ps.length === 3 && ps.every(p => object(p) && mode(p.value) && typeof p.probability === "number" && Number.isFinite(p.probability) && p.probability >= 0 && p.probability <= 1) && new Set(ps.map(p => p.value)).size === 3 && Math.abs(ps.reduce((sum, p) => sum + p.probability, 0) - 1) <= 1e-6;
  diagnostics.probabilitiesUsable = usable;
  if (usable) diagnostics.probabilities = ps as NonNullable<typeof diagnostics.probabilities>;
  if (typeof answer.confidence === "number" && Number.isFinite(answer.confidence) && answer.confidence >= 0 && answer.confidence <= 1) diagnostics.confidence = answer.confidence;
  return { status: "ok", mode: answer.choice, diagnostics };
}
