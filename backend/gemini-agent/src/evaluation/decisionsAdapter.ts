import { canonicalJson } from "./canonicalJson.js";
import { exactObject, MODES, nonemptyString, validateRequest, type Mode, type RoutingRequest } from "./routingInput.js";

export interface DecisionQuestion {
  type: "choice";
  name: "fridgeluck_route";
  instructions: string;
  choices: Array<{ value: Mode; description: string }>;
}
export function validateQuestion(value: unknown): asserts value is DecisionQuestion {
  const q = exactObject(value, ["type", "name", "instructions", "choices"], "question");
  if (q.type !== "choice") throw new Error('question.type: expected "choice"');
  if (q.name !== "fridgeluck_route") throw new Error('question.name: expected "fridgeluck_route"');
  nonemptyString(q.instructions, "question.instructions");
  if (!Array.isArray(q.choices) || q.choices.length !== MODES.length) throw new Error("question.choices: expected three choices");
  q.choices.forEach((value, i) => {
    const c = exactObject(value, ["value", "description"], `question.choices[${i}]`);
    if (c.value !== MODES[i]) throw new Error(`question.choices[${i}].value: expected ${MODES[i]}`);
    nonemptyString(c.description, `question.choices[${i}].description`);
  });
}
export function buildDecisionsRequest(request: RoutingRequest, question: unknown) {
  validateRequest(request);
  validateQuestion(question);
  return { model: "gpt-6-luna" as const, input: canonicalJson(request), questions: [question] };
}
export type DecisionsRequest = ReturnType<typeof buildDecisionsRequest>;
export interface DecisionsTransport {
  send(body: DecisionsRequest, opts: { timeoutMs: number }): Promise<{ httpStatus: number; body: unknown }>;
}
export class TransportTimeoutError extends Error {}
export interface DecisionDiagnostics {
  httpStatus: number | null;
  reason?: string;
  probabilitiesUsable?: boolean;
  probabilities?: Array<{ value: Mode; probability: number }>;
  confidence?: number;
  rawBody?: unknown;
}
export interface DecisionResult {
  status: "ok" | "provider_refusal" | "invalid" | "timeout" | "error";
  mode: Mode | null;
  diagnostics: DecisionDiagnostics;
}
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function mode(value: unknown): value is Mode {
  return MODES.includes(value as Mode);
}
function probabilities(value: unknown): value is Array<{ value: Mode; probability: number }> {
  if (!Array.isArray(value) || value.length !== MODES.length) return false;
  const seen = new Set<Mode>();
  let sum = 0;
  for (const entry of value) {
    if (!object(entry) || !mode(entry.value) || seen.has(entry.value) ||
        typeof entry.probability !== "number" || !Number.isFinite(entry.probability) || entry.probability < 0 || entry.probability > 1) return false;
    seen.add(entry.value);
    sum += entry.probability;
  }
  return Math.abs(sum - 1) <= 1e-6;
}
export async function decide(request: RoutingRequest, question: unknown, transport: DecisionsTransport, opts: { timeoutMs: number }): Promise<DecisionResult> {
  const body = buildDecisionsRequest(request, question);
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error("timeoutMs: expected finite number > 0");
  const diagnostics: DecisionDiagnostics = { httpStatus: null };
  const failure = (status: DecisionResult["status"], reason: string): DecisionResult => ({ status, mode: null, diagnostics: { ...diagnostics, reason } });
  let response;
  try {
    response = await transport.send(body, opts);
  } catch (error) {
    return error instanceof TransportTimeoutError ? failure("timeout", "transport_timeout") : failure("error", "transport_error");
  }
  diagnostics.httpStatus = response.httpStatus;
  diagnostics.rawBody = response.body;
  if (!Number.isInteger(response.httpStatus) || response.httpStatus < 200 || response.httpStatus >= 300) return failure("error", "http_status");
  if (!object(response.body) || !Array.isArray(response.body.answers)) return failure("invalid", "answers_not_array");
  const answers = response.body.answers;
  if (answers.some(a => !object(a) || a.name !== "fridgeluck_route")) return failure("invalid", "unknown_answer_name");
  const matches = answers.filter(a => object(a) && a.name === "fridgeluck_route");
  if (matches.length !== 1) return failure("invalid", matches.length ? "duplicate_answers" : "missing_answer");
  const answer = matches[0] as Record<string, unknown>;
  if (answer.type === "refusal") return failure("provider_refusal", "provider_refusal");
  if (answer.type !== "choice") return failure("invalid", "wrong_answer_type");
  if (!mode(answer.choice)) return failure("invalid", "out_of_set_choice");
  diagnostics.probabilitiesUsable = probabilities(answer.probabilities);
  if (diagnostics.probabilitiesUsable) diagnostics.probabilities = answer.probabilities as DecisionDiagnostics["probabilities"];
  if (typeof answer.confidence === "number" && Number.isFinite(answer.confidence) && answer.confidence >= 0 && answer.confidence <= 1) diagnostics.confidence = answer.confidence;
  return { status: "ok", mode: answer.choice, diagnostics };
}
export class MockDecisionsTransport implements DecisionsTransport {
  readonly bodies: DecisionsRequest[] = [];
  readonly options: Array<{ timeoutMs: number }> = [];
  private index = 0;
  constructor(private readonly script: Array<{ httpStatus: number; body: unknown } | Error>) {}
  async send(body: DecisionsRequest, opts: { timeoutMs: number }) {
    this.bodies.push(structuredClone(body));
    this.options.push({ ...opts });
    const next = this.script[this.index++];
    if (!next) throw new Error("Mock Decisions script exhausted");
    if (next instanceof Error) throw next;
    return next;
  }
}
