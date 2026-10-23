import { afterEach, describe, expect, it } from "bun:test";
import type { GoogleGenAI } from "@google/genai";
import { createAgentServer } from "../agentServer.js";
import type { AppConfig } from "../config.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { createLiveSessionStore } from "../session/liveSessionStore.js";

const config: AppConfig = {
  port: 0,
  useVertexAi: false,
  apiKey: "test",
  recipeModel: "recipe",
  rankingModel: "ranking",
  liveModel: "live",
  restockThresholdDays: 3,
  idempotencyTtlSeconds: 60,
  restockBelowGrams: 50,
  sessionStoreMode: "memory",
  firestoreCollection: "liveSessions",
  groundingEnabled: false
};

const servers: ReturnType<typeof createAgentServer>["server"][] = [];

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

function start() {
  let modelCalls = 0;
  const ai = {
    models: { generateContent: async () => { modelCalls += 1; return { text: "{}" }; } }
  } as unknown as GoogleGenAI;
  const { server } = createAgentServer({
    ai,
    config,
    ledger: new InventoryLedger(config),
    confidenceService: new ConfidenceService(),
    sessionStore: createLiveSessionStore(config)
  });
  servers.push(server);
  return new Promise<{ url: string; calls: () => number }>((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as { port: number };
      resolve({ url: `http://127.0.0.1:${address.port}`, calls: () => modelCalls });
    });
  });
}

describe("paid-model HTTP input bounds", () => {
  it("rejects 50,000 recipe ingredients before calling Gemini", async () => {
    const app = await start();
    const response = await fetch(`${app.url}/v1/recipes/generate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ingredientNames: Array.from({ length: 50_000 }, () => "x") })
    });
    expect([400, 413]).toContain(response.status);
    expect(app.calls()).toBe(0);
  });

  it("rejects 101 reverse-scan candidates before calling Gemini", async () => {
    const app = await start();
    const response = await fetch(`${app.url}/v1/reverse-scan/rank`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ detections: [], candidates: Array.from({ length: 101 }, (_, recipeId) => ({ recipeId, title: "x", localConfidence: 0.5, missingRequiredCount: 0 })) })
    });
    expect(response.status).toBe(400);
    expect(app.calls()).toBe(0);
  });

  it("rejects 101 confidence signals", async () => {
    const app = await start();
    const response = await fetch(`${app.url}/v1/confidence/assess`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signals: Array.from({ length: 101 }, () => ({ key: "x", rawScore: 0.5 })) })
    });
    expect(response.status).toBe(400);
  });

  it("rejects an over-long confidence signal string", async () => {
    const app = await start();
    const response = await fetch(`${app.url}/v1/confidence/assess`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signals: [{ key: "x".repeat(101), rawScore: 0.5 }] })
    });
    expect(response.status).toBe(400);
  });
});
