import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import http from "node:http";
import type { AddressInfo } from "node:net";
import express from "express";
import { createWebhookRouter, KNOWN_TASK_TYPES } from "../api/webhooks.js";
import {
  WEBHOOK_ALLOWED_EMAILS_ENV,
  WEBHOOK_OIDC_AUDIENCE_ENV,
  WebhookAuthError,
  type WebhookIdentity,
  type WebhookOidcVerifier
} from "../api/webhookAuth.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { InventoryItem } from "../types/contracts.js";

/**
 * Route-level authorization tests. A fake verifier is injected through the
 * createWebhookRouter options seam, so these tests prove the ROUTING of
 * authorization decisions (503 on misconfiguration, 401 on rejection, and no
 * ledger/handler work on rejection). They deliberately do not prove
 * cryptography — that is webhookAuth.test.ts's job, against the real library.
 */

const CALLER_EMAIL = "scheduler@fridgeluck-test.iam.gserviceaccount.com";

interface FakeVerifier {
  verifier: WebhookOidcVerifier;
  state: { calls: number };
}

function fakeVerifier(options: { rejectWith?: WebhookAuthError } = {}): FakeVerifier {
  const state = { calls: 0 };
  const verifier: WebhookOidcVerifier = {
    async verifyBearerToken(authorizationHeader) {
      state.calls += 1;
      if (options.rejectWith) throw options.rejectWith;
      if (!authorizationHeader?.startsWith("Bearer ")) {
        throw new WebhookAuthError("missing_bearer_token");
      }
      return { email: CALLER_EMAIL };
    }
  };
  return { verifier, state };
}

function fakeLedger(snapshotImpl: () => InventoryItem[] = () => []) {
  const snapshot = mock(snapshotImpl);
  const ledger = { snapshot } as unknown as InventoryLedger;
  return { ledger, snapshot };
}

interface Harness {
  base: string;
  snapshot: ReturnType<typeof mock>;
  stop: () => Promise<void>;
}

async function startHarness(
  options: { verifier?: WebhookOidcVerifier; env?: Record<string, string | undefined>; snapshotImpl?: () => InventoryItem[] } = {}
): Promise<Harness> {
  const { ledger, snapshot } = fakeLedger(options.snapshotImpl);
  const app = express();
  app.use(express.json());
  app.use(
    "/v1/webhooks",
    createWebhookRouter(
      ledger,
      { restockThresholdDays: 3, restockBelowGrams: 50 },
      { verifier: options.verifier, env: options.env }
    )
  );

  const server = http.createServer(app);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    base: `http://127.0.0.1:${port}/v1/webhooks`,
    snapshot,
    stop: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      })
  };
}

function captureLogs() {
  const logs: string[] = [];
  const record = (...args: unknown[]) => logs.push(args.map((a) => String(a)).join(" "));
  const spies = [
    spyOn(console, "log").mockImplementation(record as never),
    spyOn(console, "warn").mockImplementation(record as never),
    spyOn(console, "error").mockImplementation(record as never)
  ];
  return {
    logs,
    restore: () => spies.forEach((spy) => spy.mockRestore())
  };
}

let harness: Harness | undefined;
let logs: ReturnType<typeof captureLogs> | undefined;

afterEach(async () => {
  logs?.restore();
  logs = undefined;
  await harness?.stop();
  harness = undefined;
});

async function withHarness(setup: { verifier?: WebhookOidcVerifier; env?: Record<string, string | undefined>; snapshotImpl?: () => InventoryItem[] }): Promise<Harness> {
  harness = await startHarness(setup);
  logs = captureLogs();
  return harness;
}

function loggedEntries(): { severity?: string; message?: string; [key: string]: unknown }[] {
  return (logs?.logs ?? [])
    .filter((line) => line.startsWith("{"))
    .map((line) => {
      try {
        return JSON.parse(line) as { severity?: string; message?: string };
      } catch {
        return {};
      }
    });
}

describe("webhook router authentication wiring", () => {
  const VALID_HEADERS = { "content-type": "application/json", authorization: `Bearer test-token` };

  it("absent OIDC configuration yields 503 on /scheduler and /tasks, even with an Authorization header", async () => {
    const h = await withHarness({ env: {} });

    for (const route of ["/scheduler", "/tasks"]) {
      const res = await fetch(`${h.base}${route}`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer whatever" },
        body: JSON.stringify({ taskType: "enrich_inventory" })
      });
      expect(res.status).toBe(503);
      const body = await res.json() as { error?: string };
      expect(body.error).toBeTruthy();
    }

    expect(h.snapshot.mock.calls.length).toBe(0);
    expect(loggedEntries().some((e) => e.message === "webhook_auth_misconfigured")).toBe(true);
    expect(loggedEntries().some((e) => e.message === "cloud_task_received")).toBe(false);
  });

  it("whitespace-only configuration also yields 503 (never accept)", async () => {
    const h = await withHarness({
      env: { [WEBHOOK_OIDC_AUDIENCE_ENV]: "   ", [WEBHOOK_ALLOWED_EMAILS_ENV]: CALLER_EMAIL }
    });
    const res = await fetch(`${h.base}/tasks`, { method: "POST", headers: VALID_HEADERS, body: "{}" });
    expect(res.status).toBe(503);
    expect(h.snapshot.mock.calls.length).toBe(0);
  });

  it("a rejected verifier yields 401 with NO ledger or handler work on /scheduler", async () => {
    const { verifier, state } = fakeVerifier({ rejectWith: new WebhookAuthError("invalid_token") });
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/scheduler`, { method: "POST", headers: VALID_HEADERS });
    expect(res.status).toBe(401);

    expect(state.calls).toBe(1);
    expect(h.snapshot.mock.calls.length).toBe(0);
    expect(loggedEntries().some((e) => e.message === "scheduler_restock_plan")).toBe(false);
    const rejection = loggedEntries().find((e) => e.message === "webhook_auth_rejected");
    expect(rejection).toBeTruthy();
    expect(rejection?.reason).toBe("invalid_token");
  });

  it("a rejected verifier yields 401 with NO handler work on /tasks", async () => {
    const { verifier, state } = fakeVerifier({ rejectWith: new WebhookAuthError("unauthorized_email") });
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/tasks`, {
      method: "POST",
      headers: VALID_HEADERS,
      body: JSON.stringify({ taskType: "enrich_inventory" })
    });
    expect(res.status).toBe(401);

    expect(state.calls).toBe(1);
    expect(loggedEntries().some((e) => e.message === "cloud_task_received")).toBe(false);
    expect(loggedEntries().some((e) => e.message === "unknown_task_type")).toBe(false);
  });

  it("misconfiguration (503) takes precedence over authentication (401)", async () => {
    const h = await withHarness({ env: {} });

    const res = await fetch(`${h.base}/tasks`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Basic garbage" },
      body: "{}"
    });
    expect(res.status).toBe(503);
  });

  it("an accepted verifier lets /scheduler run the restock plan", async () => {
    const { verifier, state } = fakeVerifier();
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/scheduler`, { method: "POST", headers: VALID_HEADERS });
    expect(res.status).toBe(200);
    const body = await res.json() as { ok?: boolean; plan?: unknown };
    expect(body.ok).toBe(true);
    expect(body.plan).toBeTruthy();

    expect(state.calls).toBe(1);
    expect(h.snapshot.mock.calls.length).toBe(1);
    expect(loggedEntries().some((e) => e.message === "scheduler_restock_plan")).toBe(true);
  });

  it("an accepted verifier lets /tasks run, and logs only allowlisted metadata", async () => {
    const { verifier, state } = fakeVerifier();
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/tasks`, {
      method: "POST",
      headers: VALID_HEADERS,
      body: JSON.stringify({ taskType: "enrich_inventory", sneakyField: "ARBITRARY_CLIENT_TEXT" })
    });
    expect(res.status).toBe(200);
    const body = await res.json() as { ok?: boolean; taskType?: string };
    expect(body.ok).toBe(true);
    expect(body.taskType).toBe("enrich_inventory");

    expect(state.calls).toBe(1);
    const received = loggedEntries().filter((e) => e.message === "cloud_task_received");
    expect(received.length).toBe(1);

    // Log hygiene: only the allowlisted keys, and never the raw body.
    expect(Object.keys(received[0]).sort()).toEqual(
      ["callerEmail", "message", "severity", "taskType"].sort()
    );
    expect(received[0].taskType).toBe("enrich_inventory");
    expect(received[0].callerEmail).toBe(CALLER_EMAIL);
    expect(logs?.logs.join("\n").includes("ARBITRARY_CLIENT_TEXT")).toBe(false);
    expect(logs?.logs.join("\n").includes("sneakyField")).toBe(false);
  });

  it("accepts every bounded task type", async () => {
    expect([...KNOWN_TASK_TYPES]).toEqual(["enrich_inventory", "send_spoilage_notification"]);

    const { verifier } = fakeVerifier();
    const h = await withHarness({ verifier });

    for (const taskType of KNOWN_TASK_TYPES) {
      const res = await fetch(`${h.base}/tasks`, {
        method: "POST",
        headers: VALID_HEADERS,
        body: JSON.stringify({ taskType })
      });
      expect(res.status).toBe(200);
      const body = await res.json() as { taskType?: string };
      expect(body.taskType).toBe(taskType);
    }
  });

  it("rejects unknown task types with 400 BEFORE any body logging", async () => {
    const { verifier, state } = fakeVerifier();
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/tasks`, {
      method: "POST",
      headers: VALID_HEADERS,
      body: JSON.stringify({ taskType: "nuke_the_fridge" })
    });
    expect(res.status).toBe(400);

    expect(state.calls).toBe(1);
    const rejection = loggedEntries().find((e) => e.message === "cloud_task_rejected");
    expect(rejection).toBeTruthy();
    expect(rejection?.reason).toBe("unknown_task_type");

    // The arbitrary client value must not reach any log line.
    expect(logs?.logs.join("\n").includes("nuke_the_fridge")).toBe(false);
    expect(loggedEntries().some((e) => e.message === "cloud_task_received")).toBe(false);
  });

  it("rejects a missing task type with 400 and logs nothing about the body", async () => {
    const { verifier } = fakeVerifier();
    const h = await withHarness({ verifier });

    const res = await fetch(`${h.base}/tasks`, { method: "POST", headers: VALID_HEADERS, body: "{}" });
    expect(res.status).toBe(400);
    expect(logs?.logs.join("\n")).not.toContain("cloud_task_received");
  });

  it("keeps the existing 500 path for handler failures after successful authentication", async () => {
    const { verifier } = fakeVerifier();
    const h = await withHarness({
      verifier,
      snapshotImpl: () => {
        throw new Error("synthetic ledger outage");
      }
    });

    const res = await fetch(`${h.base}/scheduler`, { method: "POST", headers: VALID_HEADERS });
    expect(res.status).toBe(500);
    const body = await res.json() as { error?: string };
    expect(body.error).toBe("synthetic ledger outage");
  });
});
