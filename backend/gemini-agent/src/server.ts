import { createServer, type IncomingMessage } from "node:http";
import type { Socket } from "node:net";
import express, { type Request, type Response } from "express";
import { WebSocketServer, type WebSocket } from "ws";
import { loadConfig } from "./config.js";
import { createGenAIClient } from "./gemini/client.js";
import { ConfidenceService } from "./services/confidenceService.js";
import { generateRecipe } from "./services/recipeService.js";
import { rankReverseScanCandidates } from "./services/reverseScanService.js";
import { attachLiveSessionGateway } from "./services/liveSessionGateway.js";
import { InventoryLedger } from "./inventory/inventoryLedger.js";
import { createWebhookRouter } from "./api/webhooks.js";
import { createLiveSessionStore } from "./session/liveSessionStore.js";
import { buildNotificationPlan } from "./notifications/notificationPlan.js";
import type {
  ConfidenceAssessRequest,
  ConfidenceOutcomeRequest,
  NotificationPlanRequest,
  RecipeGenerationRequest,
  ReverseScanRankRequest,
} from "./types/contracts.js";

const config = loadConfig();
const ai = createGenAIClient(config);
const confidenceService = new ConfidenceService();
const ledger = new InventoryLedger(config);
const sessionStore = createLiveSessionStore(config);

const app = express();
app.use(express.json({ limit: "12mb" }));

app.get("/healthz", (_req: Request, res: Response) => {
  res.json({
    ok: true,
    model: config.liveModel,
    vertexAi: config.useVertexAi,
    inventoryCount: ledger.snapshot().length,
  });
});

app.post("/v1/recipes/generate", async (req: Request, res: Response) => {
  try {
    const payload = req.body as RecipeGenerationRequest;
    if (
      !Array.isArray(payload.ingredientNames) ||
      payload.ingredientNames.length === 0
    ) {
      res
        .status(400)
        .json({ error: "ingredientNames must be a non-empty array." });
      return;
    }

    const result = await generateRecipe(ai, config, payload);
    res.json(result);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Recipe generation failed.";
    res.status(500).json({ error: message });
  }
});

app.post("/v1/reverse-scan/rank", async (req: Request, res: Response) => {
  try {
    const payload = req.body as ReverseScanRankRequest;
    if (
      !Array.isArray(payload.detections) ||
      !Array.isArray(payload.candidates)
    ) {
      res
        .status(400)
        .json({ error: "detections and candidates must be arrays." });
      return;
    }

    const result = await rankReverseScanCandidates(ai, config, payload);
    res.json(result);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Reverse-scan ranking failed.";
    res.status(500).json({ error: message });
  }
});

app.post("/v1/confidence/assess", (req: Request, res: Response) => {
  try {
    const payload = req.body as ConfidenceAssessRequest;
    if (!Array.isArray(payload.signals)) {
      res.status(400).json({ error: "signals must be an array." });
      return;
    }

    const result = confidenceService.assess(payload);
    res.json(result);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Confidence assess failed.";
    res.status(500).json({ error: message });
  }
});

app.post("/v1/confidence/outcome", (req: Request, res: Response) => {
  try {
    const payload = req.body as ConfidenceOutcomeRequest;
    confidenceService.recordOutcome(payload);
    res.status(204).send();
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Confidence outcome failed.";
    res.status(500).json({ error: message });
  }
});

app.get("/v1/confidence/snapshots", (_req: Request, res: Response) => {
  res.json({ snapshots: confidenceService.calibrationSnapshots() });
});

app.get("/v1/inventory", (_req: Request, res: Response) => {
  res.json({ inventory: ledger.snapshot() });
});

app.post("/v1/notifications/plan", (req: Request, res: Response) => {
  try {
    const payload = req.body as NotificationPlanRequest;
    if (
      !payload.installationId ||
      !Array.isArray(payload.rules) ||
      !Array.isArray(payload.inventorySnapshot)
    ) {
      res
        .status(400)
        .json({ error: "installationId, rules, and inventorySnapshot are required." });
      return;
    }

    const plan = buildNotificationPlan(payload);
    res.json(plan);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Notification planning failed.";
    res.status(500).json({ error: message });
  }
});

app.use("/v1/webhooks", createWebhookRouter(ledger, config));

const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });
attachLiveSessionGateway(
  wss,
  ai,
  config,
  ledger,
  confidenceService,
  sessionStore,
);

server.on(
  "upgrade",
  (request: IncomingMessage, socket: Socket, head: Buffer) => {
    if (!request.url?.startsWith("/v1/live")) {
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws: WebSocket) => {
      wss.emit("connection", ws, request);
    });
  },
);

server.listen(config.port, () => {
  console.log(
    `[gemini-agent] listening on :${config.port} (vertexAi=${config.useVertexAi}, liveModel=${config.liveModel}, sessionStore=${sessionStore.mode})`,
  );
});
