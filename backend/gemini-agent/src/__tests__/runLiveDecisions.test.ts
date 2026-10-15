import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chargedInputTokens, DEFAULT_SEED, parseLiveOptions, runLiveDecisions, seededOrder } from "../evaluation/runLiveDecisions.js";
import type { DecisionsFetch } from "../evaluation/liveDecisionsTransport.js";
import { MODES } from "../evaluation/routingInput.js";
import { canonicalJson } from "../evaluation/canonicalJson.js";

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const secret = "sk-offline-runner-SECRET-never-a-real-key";
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "live-run-test-")); dirs.push(dir);
  const states = Array.from({ length: 16 }, (_, i) => ({ case_id: `RM-${String(i + 1).padStart(2, "0")}`, producer_state: { detection_confidences: [0.9], ranked_candidates: [{ id: 1, confidence_score: 0.9, matched_required: 1, total_required: 1, missing_required_count: 0 }] } }));
  const inputs = Array.from({ length: 18 }, (_, i) => ({ case_id: `FLH-${String(i + 1).padStart(2, "0")}`, request: { signals: [], hardFailReasons: [] } }));
  const question = (name: string) => ({ name, type: "choice", instructions: "Choose from the supplied evidence", choices: MODES.map(value => ({ value, description: value })) });
  writeFileSync(join(dir, "reverse-meal-states-v1.jsonl"), states.map(value => JSON.stringify(value)).join("\n"));
  writeFileSync(join(dir, "heldout-inputs.jsonl"), inputs.map(value => JSON.stringify(value)).join("\n"));
  writeFileSync(join(dir, "reverse-meal-question-v1.json"), JSON.stringify(question("fridgeluck_reverse_meal_route")));
  writeFileSync(join(dir, "decision-question.json"), JSON.stringify(question("fridgeluck_route")));
  // Invalid label files prove the candidate runner never opens or parses them.
  writeFileSync(join(dir, "heldout-labels.jsonl"), "NOT JSON");
  writeFileSync(join(dir, "reverse-meal-labels-v1.jsonl"), "NOT JSON");
  const keyFile = join(dir, "key.env"); writeFileSync(keyFile, `OPENAI_API_KEY=${secret}\n`, { mode: 0o600 });
  const out = join(dir, "run-1");
  const args = ["--families", "reverse-meal-v1,heldout18", "--fixtures", dir, "--out", out, "--key-file", keyFile, "--spend-ceiling-usd", "1", "--confirm-live"];
  return { dir, out, args, states, inputs };
}
const success: DecisionsFetch = async (_, init) => {
  const body = JSON.parse(String(init.body));
  return Response.json({ answers: [{ name: body.questions[0].name, type: "choice", choice: "exact" }] });
};
const rows = (path: string) => readFileSync(path, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line));

function artifacts(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? artifacts(join(dir, entry.name)) : [join(dir, entry.name)]);
}
test("requires confirmation, ordered families and an explicit positive spend ceiling", () => {
  const { args } = fixture();
  expect(() => parseLiveOptions(args.filter(arg => arg !== "--confirm-live"))).toThrow("--confirm-live");
  expect(() => parseLiveOptions(args.filter((_, i) => ![8, 9].includes(i)))).toThrow("--spend-ceiling-usd");
  expect(() => parseLiveOptions(args.map(arg => arg === "reverse-meal-v1,heldout18" ? "heldout18,reverse-meal-v1" : arg))).toThrow("in that order");
  expect(parseLiveOptions(args).seed).toBe(DEFAULT_SEED);
  expect(parseLiveOptions(args).maxRequests).toBe(34);
  for (const value of ["0", "-1", "NaN", "Infinity"]) expect(() => parseLiveOptions([...args, "--timeout-ms", value])).toThrow("positive");
});
test("refuses missing confirmation before invoking fetch or creating output", async () => {
  const f = fixture(); let calls = 0;
  await expect(runLiveDecisions(f.args.slice(0, -1), { fetch: async () => { calls++; throw new Error(); } })).rejects.toThrow("confirm-live");
  expect(calls).toBe(0); expect(existsSync(f.out)).toBe(false);
});
test("34 is a hard cap and smaller caps refuse the full schedule before fetch", async () => {
  const f = fixture(); let calls = 0;
  const fetch: DecisionsFetch = async () => { calls++; throw new Error(); };
  await expect(runLiveDecisions([...f.args, "--max-requests", "35"], { fetch })).rejects.toThrow("maximum is 34");
  await expect(runLiveDecisions([...f.args, "--max-requests", "33"], { fetch })).rejects.toThrow("Scheduled attempts");
  expect(calls).toBe(0); expect(existsSync(f.out)).toBe(false);
});
test("preflight spend refusal produces no output and makes no requests", async () => {
  const f = fixture(); let calls = 0;
  const args = f.args.map(arg => arg === "1" ? "0.00000001" : arg);
  await expect(runLiveDecisions(args, { fetch: async () => { calls++; throw new Error(); } })).rejects.toThrow("Pre-run conservative");
  expect(calls).toBe(0); expect(existsSync(f.out)).toBe(false);
});
test("complete run makes exactly 34 sequential requests, locks hashes and scans all outputs for the key", async () => {
  const f = fixture(); let calls = 0, active = 0, maxActive = 0;
  const sentBytes: string[] = [];
  const manifest = await runLiveDecisions(f.args, { fetch: async (url, init) => {
    active++; maxActive = Math.max(active, maxActive); calls++; sentBytes.push(String(init.body));
    expect(url).toBe("https://api.openai.com/v1/decisions");
    const current = JSON.parse(readFileSync(join(f.out, "manifest.json"), "utf8"));
    expect(current.status).toBe("INCOMPLETE"); expect(current.ledger.request_count).toBe(calls); expect(current.in_flight.ordinal).toBe(calls);
    const body = JSON.parse(String(init.body)); expect(Object.keys(body).sort()).toEqual(["input", "model", "questions"]);
    expect(body.model).toBe("gpt-6-luna"); expect(Object.keys(JSON.parse(body.input)).sort()).toEqual(["hardFailReasons", "signals"]);
    active--;
    return Response.json({ model: "served-snapshot", usage: { input_tokens: 5, future: "preserve" }, echo: secret, answers: [{ name: body.questions[0].name, type: "choice", choice: "exact" }] }, { headers: { "x-request-id": "r", "openai-processing-ms": "3", Authorization: secret, "Set-Cookie": secret } });
  } });
  expect(calls).toBe(34); expect(maxActive).toBe(1); expect(manifest.status).toBe("COMPLETE");
  expect(manifest.ledger.measured_input_tokens).toBe(170); expect(manifest.ledger.unmeasured_attempts).toBe(0);
  expect(manifest.ledger.budget_charge_tokens).toBeGreaterThan(170);
  expect(manifest.config.price_modifiers_applied).toBe(false);
  for (const family of ["reverse-meal-v1", "heldout18"]) {
    const outputs = rows(join(f.out, family, "outputs.jsonl"));
    const raw = rows(join(f.out, family, "raw-responses.jsonl"));
    expect(outputs.length).toBe(family === "heldout18" ? 18 : 16);
    for (const value of outputs) expect(Object.keys(value).sort()).toEqual(["case_id", "mode", "status"]);
    for (const value of raw) {
      expect(value.request_body_bytes).toBe(sentBytes[value.attempt_ordinal - 1]);
      expect(JSON.parse(value.request_body_bytes)).toEqual(value.request_body);
      expect(value.request_body_sha256).toBe(createHash("sha256").update(value.request_body_bytes).digest("hex"));
      expect(value.headers).toEqual({ "x-request-id": "r", "openai-processing-ms": "3" });
      expect(value.usage).toEqual({ input_tokens: 5, future: "preserve" });
      expect(value.measured_input_tokens).toBe(5); expect(value.requested_model).toBe("gpt-6-luna"); expect(value.served_model).toBe("served-snapshot");
      expect(value.elapsed_ms).toBeGreaterThanOrEqual(0);
    }
  }
  for (const path of artifacts(f.out)) {
    const text = readFileSync(path, "utf8"); expect(text).not.toContain(secret);
    expect(text).not.toContain('"Authorization"'); expect(text).not.toContain('"Set-Cookie"');
  }
  for (const [path, hash] of Object.entries(manifest.output_sha256)) expect(createHash("sha256").update(readFileSync(path)).digest("hex")).toBe(hash);
  await expect(runLiveDecisions(f.args, { fetch: success })).rejects.toThrow("overwrite");
});
test("order and order hashes are reproducible and independent of fixture row order", async () => {
  const a = fixture(), b = fixture();
  writeFileSync(join(b.dir, "heldout-inputs.jsonl"), [...b.inputs].reverse().map(value => JSON.stringify(value)).join("\n"));
  const x = await runLiveDecisions(a.args, { fetch: success }), y = await runLiveDecisions(b.args, { fetch: success });
  for (const family of ["heldout18", "reverse-meal-v1"]) {
    expect(x.families[family]!.case_order).toEqual(y.families[family]!.case_order);
    expect(x.families[family]!.case_order_sha256).toBe(y.families[family]!.case_order_sha256);
    expect(x.families[family]!.case_order_sha256).toBe(createHash("sha256").update(canonicalJson(x.families[family]!.case_order)).digest("hex"));
  }
  expect(seededOrder(a.inputs, "1")).not.toEqual(seededOrder(a.inputs, "2"));
  expect(x.ledger.measured_input_tokens).toBeNull(); expect(x.ledger.measured_spend_usd).toBeNull(); expect(x.ledger.unmeasured_attempts).toBe(34);
});
for (const status of [401, 403, 404]) test(`HTTP ${status} stops both families after the first contract check`, async () => {
  const f = fixture();
  const result = await runLiveDecisions(f.args, { fetch: async () => Response.json({ error: "no access" }, { status }) });
  expect(result.status).toBe("INCOMPLETE"); expect(result.stop_reason).toBe(`http_${status}`); expect(result.ledger.request_count).toBe(1);
  expect(result.families["reverse-meal-v1"]!.attempted_ids.length).toBe(1); expect(result.families["reverse-meal-v1"]!.unattempted_ids.length).toBe(15);
  expect(result.families.heldout18!.attempted_ids).toEqual([]); expect(result.families.heldout18!.unattempted_ids.length).toBe(18);
  expect(rows(join(f.out, "heldout18", "outputs.jsonl"))).toEqual([]);
});
for (const error of [{ code: "unsupported_model" }, { message: "This endpoint is not supported" }]) test(`unsupported route stops without fallback: ${JSON.stringify(error)}`, async () => {
  const f = fixture(); const result = await runLiveDecisions(f.args, { fetch: async () => Response.json({ error }, { status: 400 }) });
  expect(result.stop_reason).toBe("unsupported_model_or_endpoint"); expect(result.ledger.request_count).toBe(1);
});
for (const body of ["not JSON", JSON.stringify({}), JSON.stringify({ answers: [{ name: "wrong", type: "choice", choice: "exact" }] })]) test(`systemic contract mismatch stops: ${body}`, async () => {
  const f = fixture(); const result = await runLiveDecisions(f.args, { fetch: async () => new Response(body) });
  expect(result.stop_reason).toBe("systemic_contract_mismatch"); expect(result.ledger.request_count).toBe(1);
  expect(rows(join(f.out, "reverse-meal-v1", "outputs.jsonl"))[0].status).toBe("invalid");
});
test("429 and 5xx are individual failures with no retries, refusal is preserved", async () => {
  const f = fixture(); let calls = 0;
  const result = await runLiveDecisions(f.args, { fetch: async (url, init) => {
    calls++;
    if (calls <= 2) return Response.json({}, { status: calls === 1 ? 429 : 500 });
    if (calls === 3) return Response.json({ answers: [{ name: "fridgeluck_reverse_meal_route", type: "refusal" }] });
    return success(url, init);
  } });
  expect(result.status).toBe("COMPLETE"); expect(calls).toBe(34);
  expect(rows(join(f.out, "reverse-meal-v1", "outputs.jsonl")).slice(0, 3).map(row => row.status)).toEqual(["error", "error", "provider_refusal"]);
});
test("three consecutive transport failures stop, including timeout; an isolated timeout does not", async () => {
  const f = fixture();
  const result = await runLiveDecisions([...f.args, "--timeout-ms", "2"], { fetch: async () => new Promise(() => {}) });
  expect(result.status).toBe("INCOMPLETE"); expect(result.stop_reason).toBe("three_consecutive_transport_failures"); expect(result.ledger.request_count).toBe(3);
  expect(rows(join(f.out, "reverse-meal-v1", "outputs.jsonl")).map(row => row.status)).toEqual(["timeout", "timeout", "timeout"]);
  const g = fixture(); let calls = 0;
  const complete = await runLiveDecisions([...g.args, "--timeout-ms", "5"], { fetch: async (url, init) => ++calls === 1 ? new Promise(() => {}) : success(url, init) });
  expect(complete.status).toBe("COMPLETE"); expect(calls).toBe(34);
});
test("consecutive failure counter spans the family boundary", async () => {
  const f = fixture(); let calls = 0;
  const result = await runLiveDecisions(f.args, { fetch: async (url, init) => { calls++; if (calls >= 15) throw new Error(secret); return success(url, init); } });
  expect(result.ledger.request_count).toBe(17); expect(result.stop_reason).toBe("three_consecutive_transport_failures");
  expect(result.families.heldout18!.attempted_ids.length).toBe(1);
});
test("measured usage can stop spending before the next request without fabricating unattempted rows", async () => {
  const f = fixture(); let calls = 0;
  const result = await runLiveDecisions(f.args, { fetch: async (url, init) => {
    calls++; const r = await success(url, init); const body = await r.json();
    return Response.json({ ...body, usage: { input_tokens: 10_000_000 } });
  } });
  expect(calls).toBe(1); expect(result.status).toBe("INCOMPLETE"); expect(result.stop_reason).toBe("spend_ceiling_before_next_request");
  expect(result.ledger.measured_input_tokens).toBe(10_000_000); expect(result.ledger.budget_charge_tokens).toBe(10_000_000);
  expect(rows(join(f.out, "reverse-meal-v1", "outputs.jsonl")).length).toBe(1);
});
test("usage accounting separates measured values, estimates, missing and unrecognized usage", () => {
  expect(chargedInputTokens(10, { input_tokens: 5 })).toMatchObject({ measured_input_tokens: 5, budget_charge_tokens: 10 });
  expect(chargedInputTokens(10, { input_tokens: 20 })).toMatchObject({ measured_input_tokens: 20, budget_charge_tokens: 20 });
  expect(chargedInputTokens(10, { input_tokens: 0 })).toMatchObject({ measured_input_tokens: 0, budget_charge_tokens: 10 });
  for (const usage of [null, {}, { input_tokens: -1 }, { input_tokens: NaN }, { input_tokens: Infinity }, { input_tokens: "20" }]) {
    expect(chargedInputTokens(10, usage)).toMatchObject({ measured_input_tokens: null, budget_charge_tokens: 10, measurement_reason: "unmeasured" });
  }
});
