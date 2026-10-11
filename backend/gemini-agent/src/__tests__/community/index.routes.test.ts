/**
 * The account boundary over HTTP: healthz is open, whoami answers from the
 * verified session, everything without a bearer token is 401, unknown
 * community routes are a structured 404. Runs the real router factory
 * against the Firestore emulator.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { stubBlockDirectory, stubModerationQueue } from "../../community/shared/testing/stubs.js";

let harness: CommunityTestHarness;
let baseUrl: string;
let server: Server;

beforeAll(async () => {
  harness = await makeHarness();
  const deps: CommunityDeps = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks: stubBlockDirectory(),
    moderation: stubModerationQueue(),
    screeningStages: [],
    foodSafetyGate: fixtureFoodSafetyGate(),
  };
  const app = express();
  app.use(createCommunityRouter(deps));
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("test server did not bind");
  }
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  server.close();
  await harness.close();
});

describe("community router", () => {
  test("healthz is open", async () => {
    const res = await fetch(`${baseUrl}/v1/community/healthz`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, module: "community" });
  });

  test("whoami without a token is 401 with the module error envelope", async () => {
    const res = await fetch(`${baseUrl}/v1/community/whoami`);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("unauthorized");
  });

  test("whoami answers from the verified session, not the caller", async () => {
    const account = (await import("../../community/shared/ids.js")).newAccountId();
    const issued = await harness.sessions.issue(account, harness.clock);
    const res = await fetch(`${baseUrl}/v1/community/whoami`, {
      headers: { authorization: `Bearer ${issued.accessToken}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { accountId: string; sessionId: string };
    expect(body.accountId).toBe(account);
    expect(body.sessionId).toBe(issued.sessionId);
  });

  test("a lying client-side account id never authorizes anything", async () => {
    const res = await fetch(`${baseUrl}/v1/community/whoami`, {
      headers: { "x-account-id": "acct_someoneElse", authorization: "Bearer not-a-token" },
    });
    expect(res.status).toBe(401);
  });

  test("unknown community routes get the structured 404", async () => {
    const res = await fetch(`${baseUrl}/v1/community/definitely-not-a-route`);
    expect(res.status).toBe(404);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("not_found");
  });
});
