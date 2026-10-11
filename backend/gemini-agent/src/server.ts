import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { loadConfig } from "./config.js";
import { createGenAIClient } from "./gemini/client.js";
import { ConfidenceService } from "./services/confidenceService.js";
import { attachLiveSessionGateway } from "./services/liveSessionGateway.js";
import { InventoryLedger } from "./inventory/inventoryLedger.js";
import { createLiveSessionStore } from "./session/liveSessionStore.js";
import { createApp } from "./http/app.js";
import {
  attachTransportFrameCap,
  createLiveUpgradeHandler,
  WS_MAX_PAYLOAD_BYTES
} from "./http/liveUpgrade.js";

// Production wiring only: build the real dependencies, hand them to the
// testable HTTP app (src/http/app.ts), and own the websocket transport.
// All request validation, error mapping, and logging lives in the app.

const config = loadConfig();
const ai = createGenAIClient(config);
const confidenceService = new ConfidenceService();
const ledger = new InventoryLedger(config);
const sessionStore = createLiveSessionStore(config);

const app = createApp({ config, ai, ledger, confidenceService });

const server = createServer(app);

// Transport ceiling for live-session frames: 8 MiB, enforced HERE at the
// WebSocketServer plus an explicit frame cap (Bun's ws runtime ignores
// maxPayload on received frames — attachTransportFrameCap makes the ceiling
// real under this repo's runtime). Semantic message caps (smaller, per
// envelope type) are owned by packet025. Upgrade routing is preserved from
// the original wiring.
const wss = new WebSocketServer({ noServer: true, maxPayload: WS_MAX_PAYLOAD_BYTES });
attachTransportFrameCap(wss);
attachLiveSessionGateway(wss, ai, config, ledger, confidenceService, sessionStore);

server.on("upgrade", createLiveUpgradeHandler(wss));

server.listen(config.port, () => {
  console.log(
    `[gemini-agent] listening on :${config.port} (vertexAi=${config.useVertexAi}, liveModel=${config.liveModel}, sessionStore=${sessionStore.mode})`
  );
});
