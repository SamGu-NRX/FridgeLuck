import { loadConfig } from "./config.js";
import { createGenAIClient } from "./gemini/client.js";
import { createAgentServer } from "./agentServer.js";
import { ConfidenceService } from "./services/confidenceService.js";
import { InventoryLedger } from "./inventory/inventoryLedger.js";
import { createLiveSessionStore } from "./session/liveSessionStore.js";

const config = loadConfig();
const ai = createGenAIClient(config);
const confidenceService = new ConfidenceService();
const ledger = new InventoryLedger(config);
const sessionStore = createLiveSessionStore(config);

// The routes and the live gateway upgrade path live in agentServer.ts so the
// LeChef end-to-end boot can mount the same surface with the scripted fake
// model in Gemini's place (src/lechef/e2e/boot.ts — no API key, no paid calls).
const { server } = createAgentServer({
  ai,
  config,
  ledger,
  confidenceService,
  sessionStore,
});

server.listen(config.port, () => {
  console.log(
    `[gemini-agent] listening on :${config.port} (vertexAi=${config.useVertexAi}, liveModel=${config.liveModel}, sessionStore=${sessionStore.mode})`,
  );
});
