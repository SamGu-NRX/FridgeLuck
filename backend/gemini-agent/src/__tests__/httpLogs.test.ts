import { describe, expect, it } from "bun:test";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createApp, type AppDeps, type HttpServices } from "../http/app.js";
import { PublicApiError } from "../http/errors.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { AppConfig } from "../types/contracts.js";

// Log-hygiene and leak-prevention tests. They run the REAL middleware chain,
// logger, parsers, and error mapping against a loopback server with fake
// services, planting sentinels in the places secrets actually travel:
//   - photo bytes (base64 JPEG payloads),
//   - raw malformed JSON bodies,
//   - provider error messages (including nested `cause` payloads),
//   - ordinary request fields.
// Every sentinel must be absent from ALL captured console output AND from
// every response body, and every http_request log line must carry only the
// allowlisted fields.

const testConfig: AppConfig = {
  port: 0,
  useVertexAi: false,
  recipeModel: "test-recipe-model",
  rankingModel: "test-ranking-model",
  liveModel: "test-live-model",
  restockThresholdDays: 3,
  idempotencyTtlSeconds: 3600,
  restockBelowGrams: 50,
  sessionStoreMode: "memory",
  firestoreCollection: "liveSessions",
  groundingEnabled: true
};

const ALLOWED_LOG_KEYS = new Set([
  "severity",
  "message",
  "requestId",
  "route",
  "status",
  "errorCode"
]);

function captureConsoleLogs(): { lines: string[]; stop: () => void } {
  const lines: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;
  const originalWarn = console.warn;
  console.log = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  console.error = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  console.warn = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  return {
    lines,
    stop: () => {
      console.log = originalLog;
      console.error = originalError;
      console.warn = originalWarn;
    }
  };
}

function parseLines(lines: string[]): Array<Record<string, unknown>> {
  return lines.map((line) => {
    try {
      return JSON.parse(line) as Record<string, unknown>;
    } catch {
      return { __unparsed: line };
    }
  });
}

async function drainTimers(ms = 25): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function startApp(app: ReturnType<typeof createApp>): Promise<{
  url: string;
  close: () => Promise<void>;
}> {
  const server: Server = createServer(app);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
      })
  };
}

function depsWith(overrides?: Partial<HttpServices>): AppDeps {
  return {
    config: testConfig,
    ai: {} as AppDeps["ai"],
    ledger: new InventoryLedger({ idempotencyTtlSeconds: 3600 }),
    confidenceService: new ConfidenceService(),
    services: overrides
  };
}

/** Valid JPEG-shaped base64 (SOI head + filler) with the sentinel spliced in. */
function jpegPhotoWith(sentinel: string, sizeChars = 256): string {
  const head = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).toString("base64");
  const filler = Buffer.alloc(Math.ceil(((sizeChars - head.length) * 3) / 4), 0x41).toString("base64");
  const base = (head + filler).slice(0, sizeChars - sentinel.length);
  return base + sentinel;
}

describe("log allowlist and sentinel hygiene", () => {
  it("never logs request data: sentinels in photos, bodies, and errors stay out of logs and responses", async () => {
    // base64-charset sentinel (no quotes/backslashes so it can ride in JSON).
    const PHOTO_SENTINEL = "U0VDUkVUX1BIT1RFX1NFTlRJTkVM";
    const KEY_SENTINEL = "SECRET_API_KEY_SENTINEL_XYZ";
    const BODY_SENTINEL = "SECRET_BODY_SENTINEL_ABC";
    const PROVIDER_SENTINEL = "PROVIDER_NESTED_SECRET_QQ7";

    let serviceCalls = 0;
    const services: Partial<HttpServices> = {
      // Call 1 = the valid photo request (must succeed so the sentinel rides
      // through a real 200); call 2 = the provider-error request. The
      // malformed-JSON request between them never reaches the service.
      generateRecipe: async () => {
        serviceCalls += 1;
        if (serviceCalls === 1) {
          return {
            title: "Test Recipe",
            timeMinutes: 10,
            servings: 2,
            instructions: "Mix and cook.",
            estimatedCaloriesPerServing: 300
          };
        }
        const err = new Error(`provider rejected request with ${KEY_SENTINEL}`);
        // Nested cause with provider-shaped secrets, as SDK errors often carry.
        (err as Error & { cause?: unknown }).cause = {
          providerMessage: PROVIDER_SENTINEL,
          details: { apiKey: KEY_SENTINEL }
        };
        throw err;
      }
    };

    const capture = captureConsoleLogs();
    const server = await startApp(createApp(depsWith(services)));
    try {
      // 1. Photo sentinel inside a VALID request (200 path).
      const okResponse = await fetch(`${server.url}/v1/recipes/generate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          ingredientNames: [BODY_SENTINEL],
          photoBase64JPEG: jpegPhotoWith(PHOTO_SENTINEL)
        })
      });
      expect(okResponse.status).toBe(200);
      const okBody = await okResponse.text();

      // 2. Photo + key sentinels inside MALFORMED JSON (400 path).
      const malformed = await fetch(`${server.url}/v1/recipes/generate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: `{"photoBase64JPEG": "${PHOTO_SENTINEL}", "apiKey": "${KEY_SENTINEL}",`
      });
      expect(malformed.status).toBe(400);
      const malformedBody = await malformed.text();

      // 3. Provider error path (500) carrying nested secrets.
      const failing = await fetch(`${server.url}/v1/recipes/generate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ingredientNames: [BODY_SENTINEL] })
      });
      expect(failing.status).toBe(500);
      const failingBody = await failing.text();

      await drainTimers();

      // ── Responses never carry sentinels ──
      for (const body of [okBody, malformedBody, failingBody]) {
        expect(body.includes(PHOTO_SENTINEL)).toBeFalse();
        expect(body.includes(KEY_SENTINEL)).toBeFalse();
        expect(body.includes(BODY_SENTINEL)).toBeFalse();
        expect(body.includes(PROVIDER_SENTINEL)).toBeFalse();
      }
      expect(JSON.parse(failingBody).error).toBe("internal_error");

      // ── Logs never carry sentinels ──
      const joinedLogs = capture.lines.join("\n");
      expect(joinedLogs.includes(PHOTO_SENTINEL)).toBeFalse();
      expect(joinedLogs.includes(KEY_SENTINEL)).toBeFalse();
      expect(joinedLogs.includes(BODY_SENTINEL)).toBeFalse();
      expect(joinedLogs.includes(PROVIDER_SENTINEL)).toBeFalse();
      // Nested error payloads were never serialized.
      expect(joinedLogs.includes("providerMessage")).toBeFalse();
      expect(joinedLogs.includes("apiKey")).toBeFalse();
    } finally {
      capture.stop();
      await server.close();
    }
  });

  it("http_request log lines carry exactly the allowlisted fields", async () => {
    const services: Partial<HttpServices> = {
      generateRecipe: async () => {
        throw new PublicApiError("uses_avoided_ingredient");
      }
    };
    const capture = captureConsoleLogs();
    const server = await startApp(createApp(depsWith(services)));
    try {
      const bad = await fetch(`${server.url}/v1/recipes/generate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ingredientNames: ["peanuts"] })
      });
      expect(bad.status).toBe(422);
      await bad.text();

      const good = await fetch(`${server.url}/v1/notifications/plan`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          installationId: "install-1",
          timezone: "UTC",
          locale: "en_US",
          generatedAt: "2026-10-09T15:00:00Z",
          rules: [],
          inventorySnapshot: []
        })
      });
      expect(good.status).toBe(200);
      await good.text();

      const missing = await fetch(`${server.url}/v1/recipes/generate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "not json"
      });
      expect(missing.status).toBe(400);
      await missing.text();

      await drainTimers();

      const httpLines = parseLines(capture.lines).filter(
        (line) => line.message === "http_request"
      );
      expect(httpLines.length).toBeGreaterThanOrEqual(3);

      for (const line of httpLines) {
        for (const key of Object.keys(line)) {
          expect(ALLOWED_LOG_KEYS.has(key)).toBeTrue();
        }
        expect(typeof line.requestId).toBe("string");
        expect(typeof line.route).toBe("string");
        expect(typeof line.status).toBe("number");
      }

      const routes = httpLines.map((line) => line.route);
      expect(routes).toContain("/v1/recipes/generate");
      expect(routes).toContain("/v1/notifications/plan");
      expect(routes).not.toContain("unknown");

      const codes = httpLines.map((line) => line.errorCode);
      expect(codes).toContain("uses_avoided_ingredient");
      expect(codes).toContain("invalid_json");

      const errorLine = httpLines.find((line) => line.status === 422);
      expect(errorLine!.severity).toBe("INFO"); // 422 is a handled client outcome
      expect(httpLines.find((line) => line.status === 500)).toBeUndefined();
    } finally {
      capture.stop();
      await server.close();
    }
  });

  it("logs 500s with only the generic code — provider messages never reach logs", async () => {
    const SENTINEL = "LOG_ONLY_SENTINEL_KK5";
    const services: Partial<HttpServices> = {
      rankReverseScanCandidates: async () => {
        throw new Error(`upstream said ${SENTINEL}`);
      }
    };
    const capture = captureConsoleLogs();
    const server = await startApp(createApp(depsWith(services)));
    try {
      const response = await fetch(`${server.url}/v1/reverse-scan/rank`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ detections: [], candidates: [] })
      });
      expect(response.status).toBe(500);
      const body = (await response.json()) as { error: string; requestId: string };
      expect(body.error).toBe("internal_error");
      await drainTimers();

      const joinedLogs = capture.lines.join("\n");
      expect(joinedLogs.includes(SENTINEL)).toBeFalse();
      expect(joinedLogs.includes("upstream said")).toBeFalse();

      const lines = parseLines(capture.lines).filter((line) => line.message === "http_request");
      expect(lines.length).toBe(1);
      expect(lines[0]!.status).toBe(500);
      expect(lines[0]!.errorCode).toBe("internal_error");
      expect(lines[0]!.route).toBe("/v1/reverse-scan/rank");
      expect(lines[0]!.severity).toBe("ERROR");
      expect(body.requestId).toBe(lines[0]!.requestId);
    } finally {
      capture.stop();
      await server.close();
    }
  });
});
