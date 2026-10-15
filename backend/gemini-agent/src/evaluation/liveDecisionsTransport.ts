import { closeSync, fstatSync, openSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { TransportTimeoutError, type DecisionsRequest, type DecisionsTransport } from "./decisionsAdapter.js";
import type { ReverseMealDecisionsRequest } from "./reverseMealDecisions.js";

export const DEFAULT_KEY_FILE = join(homedir(), ".config/fridgeluck/openai-decisions.env");
export const DEFAULT_TIMEOUT_MS = 30_000;
export type DecisionsFetch = (url: string, init: RequestInit) => Promise<Response>;
export interface LiveCapture {
  httpStatus: number | null;
  body: unknown;
  headers: Record<string, string>;
  elapsed_ms: number;
  served_model: unknown;
  usage: unknown;
}

export function loadDecisionsKey(path = DEFAULT_KEY_FILE, variable = "OPENAI_API_KEY"): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(variable)) throw new Error("key-var: expected a variable name");
  let fd: number;
  try { fd = openSync(path, "r"); }
  catch { throw new Error("key-file: cannot open the specified file"); }
  let text: string;
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) throw new Error("key-file: expected a regular file");
    if (stat.mode & 0o044) throw new Error("key-file: must not be group- or world-readable; use mode 0600");
    text = readFileSync(fd, "utf8");
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("key-file:")) throw error;
    throw new Error("key-file: cannot read the specified file");
  } finally { closeSync(fd); }
  const values = text.split(/\r?\n/).flatMap(line => {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/.exec(line);
    return match?.[1] === variable ? [match[2]!.trim()] : [];
  });
  if (values.length !== 1 || !values[0]) throw new Error("key-file: requested variable must occur exactly once with a nonempty value");
  // KEY=value is literal, not shell or dotenv syntax. Reject quotes/control bytes
  // rather than silently changing the credential or permitting header injection.
  if (/[\s"'\x00-\x1f\x7f]/.test(values[0])) throw new Error("key-file: requested variable must be an unquoted, whitespace-free value");
  return values[0];
}

export class LiveDecisionsTransport implements DecisionsTransport {
  readonly #key: string;
  private readonly fetch: DecisionsFetch;
  lastCapture: LiveCapture | null = null;
  constructor(options: { fetch: DecisionsFetch; keyFile?: string; keyVar?: string }) {
    this.#key = loadDecisionsKey(options.keyFile, options.keyVar);
    this.fetch = options.fetch;
  }
  redactText(text: string): string {
    return text.split(this.#key).join("[REDACTED]").split(JSON.stringify(this.#key).slice(1, -1)).join("[REDACTED]");
  }
  private redact(value: unknown): unknown {
    if (typeof value === "string") return this.redactText(value);
    if (Array.isArray(value)) return value.map(v => this.redact(v));
    if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).filter(([key]) => key.toLowerCase() !== "authorization").map(([key, v]) => [this.redactText(key), this.redact(v)]));
    return value;
  }
  async send(body: DecisionsRequest | ReverseMealDecisionsRequest, opts = { timeoutMs: DEFAULT_TIMEOUT_MS }) {
    if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error("timeoutMs: expected finite number > 0");
    const start = performance.now();
    const capture: LiveCapture = { httpStatus: null, body: null, headers: {}, elapsed_ms: 0, served_model: null, usage: null };
    this.lastCapture = capture;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const bytes = JSON.stringify(body);
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new TransportTimeoutError("Decisions request timed out"));
        }, opts.timeoutMs);
      });
      const exchange = async () => {
        const response = await this.fetch("https://api.openai.com/v1/decisions", {
          method: "POST", headers: { Authorization: `Bearer ${this.#key}`, "Content-Type": "application/json" },
          body: bytes, signal: controller.signal,
          // Do not follow a redirect to a different endpoint or send credentials there.
          redirect: "error",
        });
        if (controller.signal.aborted) throw new TransportTimeoutError("Decisions request timed out");
        capture.httpStatus = response.status;
        for (const name of ["x-request-id", "openai-processing-ms"]) {
          const value = response.headers.get(name);
          if (value !== null) capture.headers[name] = this.redactText(value);
        }
        const text = await response.text();
        if (controller.signal.aborted) throw new TransportTimeoutError("Decisions request timed out");
        let decoded: unknown;
        try { decoded = JSON.parse(text); } catch { decoded = text; }
        capture.body = this.redact(decoded);
        if (capture.body !== null && typeof capture.body === "object" && !Array.isArray(capture.body)) {
          capture.served_model = "model" in capture.body ? capture.body.model ?? null : null;
          capture.usage = "usage" in capture.body ? capture.body.usage ?? null : null;
        }
        return { httpStatus: response.status, body: capture.body };
      };
      return await Promise.race([exchange(), timeout]);
    } catch (error) {
      if (error instanceof TransportTimeoutError) throw new TransportTimeoutError("Decisions request timed out");
      // Fetch and response-reader errors can contain headers or echoed credentials.
      throw new Error("Decisions transport failed");
    } finally {
      clearTimeout(timer);
      capture.elapsed_ms = performance.now() - start;
    }
  }
}
