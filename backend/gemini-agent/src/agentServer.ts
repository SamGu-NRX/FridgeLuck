import { createServer, type IncomingMessage, type Server } from "node:http";
import type { Socket } from "node:net";
import express, { type NextFunction, type Request, type Response } from "express";
import { WebSocketServer, type WebSocket } from "ws";
import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "./config.js";
import type { InventoryLedger } from "./inventory/inventoryLedger.js";
import type { LiveSessionStore } from "./session/liveSessionStore.js";
import { attachLiveSessionGateway } from "./services/liveSessionGateway.js";
import { ConfidenceService, parseConfidenceOutcome } from "./services/confidenceService.js";
import { InMemoryFrameHolder } from "./services/frameCache.js";
import { generateRecipe } from "./services/recipeService.js";
import { rankReverseScanCandidates } from "./services/reverseScanService.js";
import { createWebhookRouter } from "./api/webhooks.js";
import { buildNotificationPlan } from "./notifications/notificationPlan.js";
import type {
  ConfidenceAssessRequest,
  NotificationPlanRequest,
  RecipeGenerationRequest,
  ReverseScanRankRequest,
} from "./types/contracts.js";

// Bound text sent to paid models while allowing a large household scan. These
// exact counts and lengths have no production measurement behind them.
const MAX_SCAN_ITEMS = 100;
const MAX_INGREDIENT_CHARACTERS = 100;
// Restrictions are short labels; bound them separately so they cannot bypass the ingredient cap.
// The exact count and length have not been measured in production.
const MAX_RESTRICTIONS = 20;
const MAX_RESTRICTION_CHARACTERS = 100;
// Recipe titles can be longer than ingredient labels. This exact length is unmeasured.
const MAX_TITLE_CHARACTERS = 200;
// Allow one compressed scan photo without reopening a multi-megabyte prompt path.
// This exact base64 character limit has not been measured in production.
const MAX_PHOTO_CHARACTERS = 1_500_000;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUnitScore(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

function isBoundedStrings(value: unknown, count: number, length: number): value is string[] {
  return Array.isArray(value) && value.length <= count && value.every(
    (item: unknown) => typeof item === "string" && item.trim().length > 0 && item.length <= length,
  );
}

function isBoundedPhoto(value: unknown): value is string | undefined {
  return value === undefined || (typeof value === "string" && value.length <= MAX_PHOTO_CHARACTERS);
}

function isRecipeRequest(value: unknown): value is RecipeGenerationRequest {
  return isObject(value) &&
    isBoundedStrings(value.ingredientNames, MAX_SCAN_ITEMS, MAX_INGREDIENT_CHARACTERS) &&
    value.ingredientNames.length > 0 &&
    (value.dietaryRestrictions === undefined ||
      isBoundedStrings(value.dietaryRestrictions, MAX_RESTRICTIONS, MAX_RESTRICTION_CHARACTERS)) &&
    (value.scanConfidenceScore === undefined || isUnitScore(value.scanConfidenceScore)) &&
    isBoundedPhoto(value.photoBase64JPEG);
}

function isReverseScanRequest(value: unknown): value is ReverseScanRankRequest {
  return isObject(value) &&
    Array.isArray(value.detections) && value.detections.length <= MAX_SCAN_ITEMS &&
    value.detections.every((item: unknown) => isObject(item) &&
      isBoundedStrings([item.label], 1, MAX_INGREDIENT_CHARACTERS) && isUnitScore(item.confidence)) &&
    Array.isArray(value.candidates) && value.candidates.length <= MAX_SCAN_ITEMS &&
    value.candidates.every((item: unknown) => isObject(item) &&
      isBoundedStrings([item.title], 1, MAX_TITLE_CHARACTERS) &&
      typeof item.recipeId === "number" && Number.isSafeInteger(item.recipeId) && item.recipeId >= 0 &&
      isUnitScore(item.localConfidence) &&
      typeof item.missingRequiredCount === "number" && Number.isSafeInteger(item.missingRequiredCount) &&
      item.missingRequiredCount >= 0) &&
    isBoundedPhoto(value.photoBase64JPEG);
}

function isConfidenceAssessRequest(value: unknown): value is ConfidenceAssessRequest {
  return isObject(value) &&
    Array.isArray(value.signals) && value.signals.length <= MAX_SCAN_ITEMS &&
    value.signals.every((item: unknown) => isObject(item) &&
      isBoundedStrings([item.key], 1, MAX_INGREDIENT_CHARACTERS) &&
      isUnitScore(item.rawScore) &&
      (item.weight === undefined || typeof item.weight === "number") &&
      (item.reason === undefined || isBoundedStrings([item.reason], 1, MAX_INGREDIENT_CHARACTERS))) &&
    (value.hardFailReasons === undefined ||
      isBoundedStrings(value.hardFailReasons, MAX_SCAN_ITEMS, MAX_INGREDIENT_CHARACTERS));
}

/**
 * The agent's full HTTP + WebSocket surface, parameterized over its
 * dependencies. server.ts mounts this with the real Gemini client; the LeChef
 * end-to-end boot (src/lechef/e2e/boot.ts) mounts the SAME surface with the
 * scripted fake model from src/lechef/suite/scripts.ts in Gemini's place, so
 * the phone and the gateway meet over a real socket with no API key and no
 * network beyond localhost.
 */
export interface AgentServerDeps {
  readonly ai: GoogleGenAI;
  readonly config: AppConfig;
  readonly ledger: InventoryLedger;
  readonly confidenceService: ConfidenceService;
  readonly sessionStore: LiveSessionStore;
  /** Injectable for the e2e boot; production lets the gateway news its own. */
  readonly frames?: InMemoryFrameHolder;
}

export function createAgentServer(deps: AgentServerDeps): { server: Server } {
  const { ai, config, ledger, confidenceService, sessionStore } = deps;

  const app = express();
  // 2 MiB leaves room for one compressed scan photo and these small JSON payloads.
  // No production measurement supports this exact number yet.
  app.use(express.json({ limit: "2mb" }));

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
      const payload: unknown = req.body;
      if (!isRecipeRequest(payload)) {
        res.status(400).json({ error: "Invalid or oversized recipe generation input." });
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
      const payload: unknown = req.body;
      if (!isReverseScanRequest(payload)) {
        res.status(400).json({ error: "Invalid or oversized reverse-scan ranking input." });
        return;
      }

      const result = await rankReverseScanCandidates(ai, config, payload);
      res.json(result);
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Reverse-scan ranking failed.";
      res.status(500).json({ error: message });
    }
  });

  app.post("/v1/confidence/assess", (req: Request, res: Response) => {
    try {
      const payload: unknown = req.body;
      if (!isConfidenceAssessRequest(payload)) {
        res.status(400).json({ error: "Invalid or oversized confidence assess input." });
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
      const payload = parseConfidenceOutcome(req.body);
      confidenceService.recordOutcome(payload);
      res.status(204).send();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Confidence outcome failed.";
      res.status(400).json({ error: message });
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
          .json({
            error:
              "installationId, rules, and inventorySnapshot are required.",
          });
        return;
      }

      const plan = buildNotificationPlan(payload);
      res.json(plan);
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Notification planning failed.";
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
    deps.frames,
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

  app.use((error: unknown, _req: Request, res: Response, next: NextFunction) => {
    if (error instanceof Error && "status" in error && error.status === 413) {
      res.status(413).json({ error: "Request body is too large." });
      return;
    }
    if (error instanceof SyntaxError && "status" in error && error.status === 400) {
      res.status(400).json({ error: "Invalid JSON request body." });
      return;
    }
    next(error);
  });

  return { server };
}
