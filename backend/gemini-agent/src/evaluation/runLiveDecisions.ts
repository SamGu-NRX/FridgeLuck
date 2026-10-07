import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson } from "./canonicalJson.js";
import { buildDecisionsRequest, decide, MockDecisionsTransport, TransportTimeoutError, type DecisionResult } from "./decisionsAdapter.js";
import { buildReverseMealDecisionsRequest, decideReverseMealMock, MockReverseMealTransport } from "./reverseMealDecisions.js";
import { parseStates, projectState } from "./reverseMealProjection.js";
import { decodeStrict, parseRoutingInputs } from "./runRouting.js";
import { DEFAULT_KEY_FILE, DEFAULT_TIMEOUT_MS, LiveDecisionsTransport, type DecisionsFetch } from "./liveDecisionsTransport.js";

export const FAMILIES = ["reverse-meal-v1", "heldout18"] as const;
type Family = typeof FAMILIES[number];
export const DEFAULT_SEED = "7265766572736531";
export const HARD_REQUEST_CAP = 34;
const SOURCE_DIR = fileURLToPath(new URL(".", import.meta.url));
const sha = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
export const SHUFFLE_NAME = "sorted-case-id Fisher-Yates, SHA256(seed:counter) uint32 fraction v1";

export function seededOrder<T extends { case_id: string }>(rows: T[], seed: string): T[] {
  const ordered = [...rows].sort((a, b) => a.case_id < b.case_id ? -1 : a.case_id > b.case_id ? 1 : 0);
  let counter = 0;
  for (let i = ordered.length - 1; i > 0; i--) {
    const fraction = createHash("sha256").update(`${seed}:${counter++}`).digest().readUInt32BE(0) / 0x100000000;
    const j = Math.floor(fraction * (i + 1));
    [ordered[i], ordered[j]] = [ordered[j]!, ordered[i]!];
  }
  return ordered;
}

interface Options {
  fixtures: string; out: string; keyFile: string; keyVar: string;
  seed: string; timeoutMs: number; maxRequests: number; spendCeilingUsd: number; inputUsdPerMillion: number;
}
export function parseLiveOptions(args: string[]): Options {
  const values = new Map<string, string>();
  let confirmed = false;
  const names = ["--families", "--fixtures", "--out", "--key-file", "--key-var", "--timeout-ms", "--seed", "--max-requests", "--spend-ceiling-usd", "--input-usd-per-million"];
  for (let i = 0; i < args.length; i++) {
    const name = args[i]!;
    if (name === "--confirm-live") {
      if (confirmed) throw new Error("Duplicate --confirm-live");
      confirmed = true; continue;
    }
    const value = args[++i];
    if (!names.includes(name) || values.has(name) || !value || value.startsWith("--")) throw new Error("Invalid, duplicate, or missing CLI option");
    values.set(name, value);
  }
  if (!confirmed) throw new Error("Refusing live run without --confirm-live");
  if (values.get("--families") !== FAMILIES.join(",")) throw new Error("--families must be reverse-meal-v1,heldout18 in that order");
  for (const name of ["--fixtures", "--out", "--spend-ceiling-usd"]) if (!values.has(name)) throw new Error(`Required option: ${name}`);
  const number = (name: string, fallback?: number) => {
    const value = values.has(name) ? Number(values.get(name)) : fallback;
    if (value === undefined || !Number.isFinite(value) || value <= 0) throw new Error(`${name}: expected a finite positive number`);
    return value;
  };
  const maxRequests = number("--max-requests", HARD_REQUEST_CAP);
  if (!Number.isSafeInteger(maxRequests) || maxRequests > HARD_REQUEST_CAP) throw new Error("--max-requests: maximum is 34 outbound attempts");
  const seed = values.get("--seed") ?? DEFAULT_SEED;
  if (!/^\d+$/.test(seed)) throw new Error("--seed: expected decimal digits, retained as a string");
  return {
    fixtures: resolve(values.get("--fixtures")!), out: resolve(values.get("--out")!),
    keyFile: values.get("--key-file") ?? DEFAULT_KEY_FILE, keyVar: values.get("--key-var") ?? "OPENAI_API_KEY",
    seed, timeoutMs: number("--timeout-ms", DEFAULT_TIMEOUT_MS), maxRequests,
    spendCeilingUsd: number("--spend-ceiling-usd"), inputUsdPerMillion: number("--input-usd-per-million", 0.10),
  };
}

export function chargedInputTokens(estimate: number, usage: unknown) {
  if (usage !== null && typeof usage === "object" && !Array.isArray(usage) && "input_tokens" in usage &&
      typeof usage.input_tokens === "number" && Number.isFinite(usage.input_tokens) && usage.input_tokens >= 0) {
    return { budget_charge_tokens: Math.max(estimate, usage.input_tokens), measured_input_tokens: usage.input_tokens, measurement_reason: "returned_usage.input_tokens",
      budget_charge_reason: usage.input_tokens > estimate ? "returned_input_tokens" : "conservative_estimate_at_least_returned_usage" };
  }
  return { budget_charge_tokens: estimate, measured_input_tokens: null, measurement_reason: "unmeasured", budget_charge_reason: usage === null ? "usage_absent" : "usage_input_tokens_unrecognized" };
}

function unsupported(body: unknown): boolean {
  const description = typeof body === "string" ? body : body !== null && typeof body === "object" && "error" in body ? JSON.stringify(body.error) : undefined;
  if (!description) return false;
  const error = description.toLowerCase();
  return /model_not_found|unsupported_model|model_not_supported|unsupported_endpoint|endpoint_not_found/.test(error) ||
    /(?:model|endpoint).{0,100}(?:not supported|unsupported|does not exist|not found)/.test(error) ||
    /(?:unsupported|unknown).{0,40}(?:model|endpoint)/.test(error);
}

export async function runLiveDecisions(args: string[], dependencies: { fetch: DecisionsFetch }) {
  const options = parseLiveOptions(args);
  if (existsSync(options.out)) throw new Error("Refusing to overwrite an existing run output directory");
  const inputHashes: Record<string, string> = {};
  const read = (name: string) => {
    const path = resolve(options.fixtures, name), bytes = readFileSync(path);
    inputHashes[path] = sha(bytes); return bytes.toString("utf8");
  };
  const plans = FAMILIES.map(family => {
    const questionFile = family === "reverse-meal-v1" ? "reverse-meal-question-v1.json" : "decision-question.json";
    const inputFile = family === "reverse-meal-v1" ? "reverse-meal-states-v1.jsonl" : "heldout-inputs.jsonl";
    const question = decodeStrict(read(questionFile));
    const text = read(inputFile);
    const rows = family === "reverse-meal-v1" ? parseStates(text).map(row => ({ case_id: row.case_id, request: projectState(row.producer_state) })) : parseRoutingInputs(text);
    const count = family === "reverse-meal-v1" ? 16 : 18;
    const prefix = family === "reverse-meal-v1" ? "RM" : "FLH";
    const expectedIds = new Set(Array.from({ length: count }, (_, i) => `${prefix}-${String(i + 1).padStart(2, "0")}`));
    if (rows.length !== count || rows.some(row => !expectedIds.has(row.case_id))) throw new Error("Expected exactly the declared 16 and 18 case corpora");
    const cases = seededOrder(rows, options.seed).map(row => {
      const body = family === "reverse-meal-v1" ? buildReverseMealDecisionsRequest(row.request, question) : buildDecisionsRequest(row.request, question);
      const bytes = JSON.stringify(body);
      return { ...row, body, bytes, body_sha256: sha(bytes), estimated_input_tokens: Math.ceil(Buffer.byteLength(bytes, "utf8") / 3) };
    });
    const order = cases.map(row => row.case_id);
    return { family, question, cases, order, order_sha256: sha(canonicalJson(order)), question_sha256: inputHashes[resolve(options.fixtures, questionFile)]!, input_sha256: inputHashes[resolve(options.fixtures, inputFile)]! };
  });
  const scheduled = plans.reduce((sum, plan) => sum + plan.cases.length, 0);
  if (scheduled > options.maxRequests) throw new Error("Scheduled attempts exceed --max-requests cap");
  const estimatedTokens = plans.reduce((sum, plan) => sum + plan.cases.reduce((s, row) => s + row.estimated_input_tokens, 0), 0);
  const maxRequestEstimate = Math.max(...plans.flatMap(plan => plan.cases.map(row => row.estimated_input_tokens)));
  const usd = (tokens: number) => tokens / 1_000_000 * options.inputUsdPerMillion;
  if (usd(estimatedTokens) > options.spendCeilingUsd) throw new Error("Pre-run conservative estimate exceeds --spend-ceiling-usd");
  const transport = new LiveDecisionsTransport({ fetch: dependencies.fetch, keyFile: options.keyFile, keyVar: options.keyVar });
  const sourceHashes = Object.fromEntries(readdirSync(SOURCE_DIR).filter(name => name.endsWith(".ts")).sort().map(name => {
    const path = resolve(SOURCE_DIR, name); return [path, sha(readFileSync(path))];
  }));
  const attempted: Record<Family, string[]> = { "reverse-meal-v1": [], heldout18: [] };
  const manifest = {
    status: "INCOMPLETE", stop_reason: null as string | null, utc_start: new Date().toISOString(), utc_end: null as string | null,
    config: { families: [...FAMILIES], endpoint: "https://api.openai.com/v1/decisions", requested_model: "gpt-6-luna", seed: options.seed,
      timeout_ms: options.timeoutMs, max_requests: options.maxRequests, spend_ceiling_usd: options.spendCeilingUsd,
      input_usd_per_million: options.inputUsdPerMillion, rate_date: "2026-10-07", rate_source: "Decisions guide, inspected 2026-10-07",
      concurrency: 1, attempts_per_case: 1, retries: 0, labels_accessed: false,
      shuffle: { name: SHUFFLE_NAME, source_sha256: sourceHashes[fileURLToPath(import.meta.url)] },
      price_modifiers_applied: false, price_caveat: "Regional and long-context modifiers are not applied; measured spend uses the recorded base rate only.",
      preflight_bound: { scheduled_attempts: scheduled, scheduled_estimate_tokens: estimatedTokens, scheduled_estimate_usd: usd(estimatedTokens),
        hard_cap: HARD_REQUEST_CAP, max_request_estimate_tokens: maxRequestEstimate,
        hard_cap_times_max_estimate_tokens: HARD_REQUEST_CAP * maxRequestEstimate,
        hard_cap_times_max_estimate_usd: usd(HARD_REQUEST_CAP * maxRequestEstimate) },
      input_sha256: inputHashes, source_sha256: sourceHashes },
    families: Object.fromEntries(plans.map(plan => [plan.family, { question_sha256: plan.question_sha256, input_sha256: plan.input_sha256,
      case_order: plan.order, case_order_sha256: plan.order_sha256, attempted_ids: attempted[plan.family], unattempted_ids: [...plan.order] }])),
    ledger: { request_count: 0, budget_charge_tokens: 0, budget_charge_usd: 0, measured_input_tokens: null as number | null,
      measured_spend_usd: null as number | null, usage_returned_attempts: 0, measured_attempts: 0, unmeasured_attempts: 0, consecutive_transport_failures: 0 },
    output_sha256: {} as Record<string, string>,
    in_flight: null as { ordinal: number; family: Family; case_id: string } | null,
  };
  const serialize = (value: unknown) => transport.redactText(canonicalJson(value)) + "\n";
  const saveManifest = () => {
    for (const plan of plans) {
      manifest.families[plan.family]!.unattempted_ids = plan.order.filter(id => !attempted[plan.family].includes(id));
      for (const name of ["outputs.jsonl", "raw-responses.jsonl", "order.json"]) {
        const path = resolve(options.out, plan.family, name); manifest.output_sha256[path] = sha(readFileSync(path));
      }
    }
    const temporary = resolve(options.out, "manifest.json.tmp");
    writeFileSync(temporary, serialize(manifest), { mode: 0o600 });
    renameSync(temporary, resolve(options.out, "manifest.json"));
  };
  mkdirSync(dirname(options.out), { recursive: true });
  mkdirSync(options.out); // Exclusive creation, including when two processes race.
  for (const plan of plans) {
    const directory = resolve(options.out, plan.family); mkdirSync(directory);
    writeFileSync(resolve(directory, "outputs.jsonl"), "", { flag: "wx", mode: 0o600 });
    writeFileSync(resolve(directory, "raw-responses.jsonl"), "", { flag: "wx", mode: 0o600 });
    writeFileSync(resolve(directory, "order.json"), serialize({ seed: options.seed, shuffle: manifest.config.shuffle, case_order: plan.order, case_order_sha256: plan.order_sha256 }), { flag: "wx", mode: 0o600 });
  }
  saveManifest();
  outer: for (const plan of plans) {
    for (const row of plan.cases) {
      if (usd(manifest.ledger.budget_charge_tokens + row.estimated_input_tokens) > options.spendCeilingUsd) {
        manifest.stop_reason = "spend_ceiling_before_next_request"; break outer;
      }
      if (manifest.ledger.request_count >= options.maxRequests) { manifest.stop_reason = "request_cap"; break outer; }
      const ordinal = manifest.ledger.request_count + 1;
      // A crash cannot establish whether an in-flight request reached the provider.
      // Reserve it durably as attempted and leave INCOMPLETE, never resume it.
      attempted[plan.family].push(row.case_id); manifest.ledger.request_count++;
      manifest.in_flight = { ordinal, family: plan.family, case_id: row.case_id }; saveManifest();
      const start = performance.now();
      let response: { httpStatus: number; body: unknown } | Error;
      try { response = await transport.send(row.body, { timeoutMs: options.timeoutMs }); }
      catch (error) { response = error instanceof TransportTimeoutError ? error : new Error("Decisions transport failed"); }
      let result: DecisionResult;
      if (plan.family === "reverse-meal-v1") result = await decideReverseMealMock(row.request, plan.question, new MockReverseMealTransport([response]), { timeoutMs: options.timeoutMs });
      else result = await decide(row.request, plan.question, new MockDecisionsTransport([response]), { timeoutMs: options.timeoutMs });
      const elapsed = performance.now() - start;
      const capture = transport.lastCapture!;
      const charged = chargedInputTokens(row.estimated_input_tokens, capture.usage);
      manifest.ledger.budget_charge_tokens += charged.budget_charge_tokens;
      manifest.ledger.budget_charge_usd = usd(manifest.ledger.budget_charge_tokens);
      if (capture.usage !== null) manifest.ledger.usage_returned_attempts++;
      if (charged.measured_input_tokens !== null) {
        manifest.ledger.measured_attempts++;
        manifest.ledger.measured_input_tokens = (manifest.ledger.measured_input_tokens ?? 0) + charged.measured_input_tokens;
        manifest.ledger.measured_spend_usd = usd(manifest.ledger.measured_input_tokens);
      } else manifest.ledger.unmeasured_attempts++;
      manifest.ledger.consecutive_transport_failures = response instanceof Error ? manifest.ledger.consecutive_transport_failures + 1 : 0;
      const normalized = { case_id: row.case_id, status: result.status, mode: result.mode };
      const record = { attempt_ordinal: ordinal, case_id: row.case_id, family: plan.family, request_body: row.body,
        request_body_bytes: row.bytes, request_body_sha256: row.body_sha256, http_status: capture.httpStatus,
        headers: capture.headers, elapsed_ms: elapsed, body: capture.body, requested_model: row.body.model,
        served_model: capture.served_model, usage: capture.usage, estimated_input_tokens: row.estimated_input_tokens,
        budget_charge_tokens: charged.budget_charge_tokens, budget_charge_usd: usd(charged.budget_charge_tokens), budget_charge_reason: charged.budget_charge_reason,
        measured_input_tokens: charged.measured_input_tokens, measured_spend_usd: charged.measured_input_tokens === null ? null : usd(charged.measured_input_tokens),
        measurement_reason: charged.measurement_reason, normalized_result: normalized, diagnostics: result.diagnostics };
      appendFileSync(resolve(options.out, plan.family, "raw-responses.jsonl"), serialize(record));
      appendFileSync(resolve(options.out, plan.family, "outputs.jsonl"), serialize(normalized));
      manifest.in_flight = null;
      if ([401, 403, 404].includes(capture.httpStatus ?? 0)) manifest.stop_reason = `http_${capture.httpStatus}`;
      else if (unsupported(capture.body)) manifest.stop_reason = "unsupported_model_or_endpoint";
      else if (result.status === "invalid") manifest.stop_reason = "systemic_contract_mismatch";
      else if (manifest.ledger.consecutive_transport_failures >= 3) manifest.stop_reason = "three_consecutive_transport_failures";
      saveManifest();
      if (manifest.stop_reason) break outer;
    }
  }
  if (!manifest.stop_reason && manifest.ledger.request_count === scheduled) manifest.status = "COMPLETE";
  manifest.utc_end = new Date().toISOString(); saveManifest();
  return manifest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // Refuse proxy-bearing invocations rather than silently changing the route.
  if (["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"].some(name => process.env[name])) {
    console.error("Refusing live CLI with proxy environment variables; use env -i"); process.exitCode = 1;
  } else {
    try {
      const manifest = await runLiveDecisions(process.argv.slice(2), { fetch: (url, init) => fetch(url, init) });
      console.log(JSON.stringify({ status: manifest.status, request_count: manifest.ledger.request_count, stop_reason: manifest.stop_reason }));
      if (manifest.status !== "COMPLETE") process.exitCode = 1;
    } catch (error) {
      // Only fixed option/key errors are safe to print. Fixture and platform
      // errors can contain untrusted input, paths, or credentials.
      const message = error instanceof Error ? error.message : "";
      console.error(/^(key-file:|key-var:|Refusing |--|Required option:|Invalid, duplicate|Duplicate --|Scheduled attempts|Pre-run conservative)/.test(message)
        ? message : "Live Decisions run failed; no resume is permitted. Inspect the run manifest if created."); process.exitCode = 1;
    }
  }
}
