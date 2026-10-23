import type { GoogleGenAI } from "@google/genai";
import { createAgentServer } from "../../agentServer.js";
import type { AppConfig } from "../../config.js";
import { InventoryLedger } from "../../inventory/inventoryLedger.js";
import { ConfidenceService } from "../../services/confidenceService.js";
import { createLiveSessionStore } from "../../session/liveSessionStore.js";

export async function startAgentHttp() {
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
    groundingEnabled: false,
  };
  const prompts: unknown[] = [];
  const ai = {
    models: {
      generateContent: async (request: unknown) => {
        prompts.push(request);
        return {
          text: JSON.stringify({
            title: "Test soup",
            instructions: "Simmer the ingredients.",
            timeMinutes: 15,
            servings: 2,
            estimatedCaloriesPerServing: 150,
            rankings: [{ recipeId: 1, confidenceScore: 0.8, reason: "Test match" }],
          }),
        };
      },
    },
  } as unknown as GoogleGenAI;
  const confidenceService = new ConfidenceService();
  const { server } = createAgentServer({
    ai,
    config,
    ledger: new InventoryLedger(config),
    confidenceService,
    sessionStore: createLiveSessionStore(config),
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Expected a TCP test server.");
  const url = `http://127.0.0.1:${address.port}`;
  return {
    url,
    prompts,
    confidenceService,
    post: (path: string, body: unknown) => fetch(`${url}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    close: () => new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
      server.closeIdleConnections();
    }),
  };
}
