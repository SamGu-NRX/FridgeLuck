import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildDecisionsRequest, decide, TransportTimeoutError, type DecisionQuestion } from "../evaluation/decisionsAdapter.js";
import { DEFAULT_KEY_FILE, LiveDecisionsTransport, loadDecisionsKey, type DecisionsFetch } from "../evaluation/liveDecisionsTransport.js";
import { MODES } from "../evaluation/routingInput.js";

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const key = "sk-offline-SENTINEL-secret-not-a-credential";
const request = { signals: [], hardFailReasons: [] };
const question: DecisionQuestion = { name: "fridgeluck_route", type: "choice", instructions: "Choose", choices: MODES.map(value => ({ value, description: value })) };
const body = buildDecisionsRequest(request, question);
function file(text = `OPENAI_API_KEY=${key}\n`, mode = 0o600) {
  const dir = mkdtempSync(join(tmpdir(), "decisions-key-test-")); dirs.push(dir);
  const path = join(dir, "key.env"); writeFileSync(path, text, { mode }); return path;
}
function transport(fetch: DecisionsFetch) { return new LiveDecisionsTransport({ keyFile: file(), fetch }); }

test("default key path is a string only; no real config file access", () => {
  expect(DEFAULT_KEY_FILE.endsWith("/.config/fridgeluck/openai-decisions.env")).toBe(true);
});
test("loads only the specified variable in the supplied file", () => {
  expect(loadDecisionsKey(file(`# comment\nOTHER=no\nCUSTOM=${key}\n`), "CUSTOM")).toBe(key);
  expect(() => loadDecisionsKey(file("OTHER=no\n"))).toThrow("requested variable");
});
test("missing file has a specific safe error", () => {
  expect(() => loadDecisionsKey(join(file(), "missing"))).toThrow("key-file: cannot open");
});
for (const mode of [0o640, 0o604, 0o644]) test(`rejects readable mode ${mode.toString(8)}`, () => {
  const path = file(); chmodSync(path, mode);
  expect(() => loadDecisionsKey(path)).toThrow("group- or world-readable");
});
for (const value of ["", "'secret'", '"secret"', "secret value", "secret\x00"]) test(`rejects malformed key ${JSON.stringify(value)}`, () => {
  expect(() => loadDecisionsKey(file(`OPENAI_API_KEY=${value}\n`))).toThrow("key-file:");
});
test("rejects duplicate variable and invalid variable name", () => {
  expect(() => loadDecisionsKey(file(`OPENAI_API_KEY=${key}\nOPENAI_API_KEY=${key}\n`))).toThrow("exactly once");
  expect(() => loadDecisionsKey(file(), "bad-name")).toThrow("key-var:");
});
test("sends exact URL, method, headers, builder bytes and blocks redirects", async () => {
  let calls = 0;
  const t = transport(async (url, init) => {
    calls++;
    expect(url).toBe("https://api.openai.com/v1/decisions");
    expect(init.method).toBe("POST");
    expect(init.headers).toEqual({ Authorization: `Bearer ${key}`, "Content-Type": "application/json" });
    expect(init.body).toBe(JSON.stringify(body));
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(init.redirect).toBe("error");
    return Response.json({ answers: [] });
  });
  expect(await t.send(body)).toEqual({ httpStatus: 200, body: { answers: [] } });
  expect(calls).toBe(1);
});
test("captures model, unknown usage, allowed headers and monotonic timing", async () => {
  const usage = { mystery_tokens: 12, details: { future: true } };
  const t = transport(async () => Response.json({ model: "served-snapshot", usage, future: [1] }, { headers: { "x-request-id": "req-123", "openai-processing-ms": "17.5", authorization: "forbidden", "set-cookie": "ignored" } }));
  await t.send(body);
  expect(t.lastCapture).toMatchObject({ httpStatus: 200, body: { future: [1] }, headers: { "x-request-id": "req-123", "openai-processing-ms": "17.5" }, served_model: "served-snapshot", usage });
  expect(t.lastCapture!.elapsed_ms).toBeGreaterThanOrEqual(0);
});
test("absent serving model and usage are null, not invented or zero", async () => {
  const t = transport(async () => Response.json({ answers: [] }));
  await t.send(body);
  expect(t.lastCapture!.served_model).toBeNull();
  expect(t.lastCapture!.usage).toBeNull();
});
test("non-JSON response remains a string and maps to invalid", async () => {
  const t = transport(async () => new Response("not JSON"));
  const result = await decide(request, question, t, { timeoutMs: 100 });
  expect(result.status).toBe("invalid"); expect(result.mode).toBeNull();
  expect(t.lastCapture!.body).toBe("not JSON");
});
for (const status of [401, 429, 500]) test(`HTTP ${status} is error without retry`, async () => {
  let calls = 0;
  const t = transport(async () => { calls++; return Response.json({ error: "offline" }, { status }); });
  const result = await decide(request, question, t, { timeoutMs: 100 });
  expect(result.status).toBe("error"); expect(result.mode).toBeNull(); expect(calls).toBe(1);
  expect(t.lastCapture!.httpStatus).toBe(status);
});
test("timeout aborts even an injected fetch that ignores its signal", async () => {
  let signal: AbortSignal | null | undefined;
  const t = transport(async (_, init) => { signal = init.signal; return new Promise(() => {}); });
  await expect(t.send(body, { timeoutMs: 5 })).rejects.toBeInstanceOf(TransportTimeoutError);
  expect(signal!.aborted).toBe(true);
});
test("timeout covers response body consumption", async () => {
  const t = transport(async () => new Response(new ReadableStream({ start() {} })));
  expect((await decide(request, question, t, { timeoutMs: 5 })).status).toBe("timeout");
  expect(t.lastCapture!.httpStatus).toBe(200);
});
test("invalid timeout is rejected before fetch", async () => {
  const t = transport(async () => { throw new Error("must not call"); });
  for (const timeoutMs of [0, -1, NaN, Infinity]) await expect(t.send(body, { timeoutMs })).rejects.toThrow("timeoutMs:");
});
test("echoed key is redacted from all metadata, body keys, and plain text", async () => {
  const t = transport(async () => Response.json({ model: key, usage: { [key]: key }, authorization: `Bearer ${key}`, echo: key }, { headers: { "x-request-id": key } }));
  const result = await t.send(body);
  expect(JSON.stringify([result, t.lastCapture])).not.toContain(key);
  expect(JSON.stringify(result)).not.toContain("authorization");
  expect(JSON.stringify(t)).not.toContain(key);
  const plain = transport(async () => new Response(key));
  const plainResult = await plain.send(body);
  expect(JSON.stringify(plainResult)).not.toContain(key);
  const artifacts = mkdtempSync(join(tmpdir(), "decisions-artifacts-test-")); dirs.push(artifacts);
  writeFileSync(join(artifacts, "response.json"), JSON.stringify(result));
  writeFileSync(join(artifacts, "capture.json"), JSON.stringify(t.lastCapture));
  writeFileSync(join(artifacts, "raw-text.json"), JSON.stringify(plainResult));
  // Scan every emitted artifact; credential fixtures are in separate directories.
  for (const name of readdirSync(artifacts)) expect(readFileSync(join(artifacts, name), "utf8").includes(key)).toBe(false);
});
test("fetch errors never expose a key and are not retried", async () => {
  let calls = 0;
  const t = transport(async () => { calls++; throw new Error(`Authorization: Bearer ${key}`); });
  await expect(t.send(body)).rejects.toThrow("Decisions transport failed");
  expect(calls).toBe(1);
  expect(JSON.stringify(t.lastCapture)).not.toContain(key);
});
