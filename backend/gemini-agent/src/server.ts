import { WebSocketServer } from "ws";
import { createApp } from "./http/app.js";
import {
  attachTransportFrameCap,
  createLiveUpgradeHandler,
  WS_MAX_PAYLOAD_BYTES,
} from "./http/liveUpgrade.js";
import { attachLiveSessionGateway } from "./services/liveSessionGateway.js";
import { loadConfig } from "./config.js";
import { createGenAIClient } from "./gemini/client.js";
import { ConfidenceService } from "./services/confidenceService.js";
import { InventoryLedger } from "./inventory/inventoryLedger.js";
import { SessionLedgers } from "./inventory/sessionLedgers.js";
import { createLiveSessionStore } from "./session/liveSessionStore.js";
import { MutationProposalStore } from "./authority/mutationAuthority.js";

// Production wiring only: build the real dependencies, hand them to the
// testable HTTP app (src/http/app.ts), and own the websocket transport.
// All request validation, error mapping, and logging lives in the app.
const config = loadConfig();
const ai = createGenAIClient(config);
const confidenceService = new ConfidenceService();
const ledger = new InventoryLedger(config);
const sessionStore = createLiveSessionStore(config);

// Live-session authority state. Inventory is session-scoped; the global
// `ledger` above no longer receives live-session writes and stays empty in
// production (webhook/debug surface only). Pending mutation proposals are
// in-memory by design — an unconfirmed proposal is a draft, and forgetting
// drafts on restart is the safe direction.
const ledgers = new SessionLedgers(config.idempotencyTtlSeconds);
const proposals = new MutationProposalStore();

const app = createApp({
  config,
  ai,
  ledger,
  confidenceService,
  webhookOptions: {
    env: process.env
  }
});

// Transport ceiling for live-session frames: 8 MiB, enforced HERE at the
// WebSocketServer plus an explicit frame cap (Bun's ws runtime ignores
// maxPayload on received frames — attachTransportFrameCap makes the ceiling
// real under this repo's runtime). Semantic message caps (smaller, per
// envelope type) are owned by packet025. Upgrade routing is preserved from
// the original wiring.
const wss = new WebSocketServer({
  noServer: true,
  maxPayload: WS_MAX_PAYLOAD_BYTES
});
attachTransportFrameCap(wss);
attachLiveSessionGateway(wss, {
  ai,
  config,
  confidenceService,
  sessionStore,
  ledgers,
  proposals
});

const server = app.listen(config.port, () => {
  console.log(
    `[gemini-agent] listening on :${config.port} (vertexAi=${config.useVertexAi}, liveModel=${config.liveModel}, sessionStore=${sessionStore.mode})`
  );
});

server.on("upgrade", createLiveUpgradeHandler(wss));
