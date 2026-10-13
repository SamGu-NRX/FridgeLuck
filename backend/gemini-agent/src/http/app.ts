import { randomUUID } from "node:crypto";
import express, {
  type Express,
  type NextFunction,
  type Request,
  type Response,
  type Router
} from "express";
import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import { generateRecipe } from "../services/recipeService.js";
import { rankReverseScanCandidates } from "../services/reverseScanService.js";
import { buildNotificationPlan } from "../notifications/notificationPlan.js";
import { createWebhookRouter } from "../api/webhooks.js";
import {
  classifyBodyParserError,
  PublicApiError,
  RequestValidationError,
  type StableErrorCode
} from "./errors.js";
import { logHttpRequest } from "./logger.js";
import { createIpRateLimiter, type IpRateLimiter } from "./rateLimit.js";
import {
  JSON_BODY_LIMIT_DEFAULT,
  JSON_BODY_LIMIT_PHOTO_ROUTES
} from "./limits.js";
import {
  parseConfidenceAssessRequest,
  parseConfidenceOutcomeRequest,
  parseNotificationPlanRequest,
  parseRecipeGenerationRequest,
  parseReverseScanRankRequest
} from "./validate.js";

// The testable HTTP application.
//
// `createApp(deps)` builds the Express app with injected dependencies; the
// production server (src/server.ts) wires the real services and starts it.
// Route handlers validate FIRST and only then call a service, so invalid
// input never reaches a service or a paid model.
//
// Response + log discipline:
//   400 invalid_json      — malformed JSON body (no echo of the body)
//   400 invalid_request   — schema validation failure (+ static field path)
//   413 payload_too_large — parser limit or photo-field limit exceeded
//   422 <public code>     — only the two recognized PublicApiError codes
//   429 rate_limited      — per-IP token bucket on paid-model routes
//   500 internal_error    — anything else (generic, with requestId)
//
// Debug routes (/v1/inventory, /v1/confidence/*) are process-wide OFF unless
// ENABLE_DEBUG_ROUTES is truthy at app creation.

export interface HttpServices {
  generateRecipe: typeof generateRecipe;
  rankReverseScanCandidates: typeof rankReverseScanCandidates;
}

export interface AppDeps {
  config: AppConfig;
  /**
   * Model client used by the paid-model routes; fakes are welcome here.
   * Null when the deployment has no model credentials: paid routes then
   * answer 503 model_unavailable (fail-safe boot) while free routes and
   * webhooks keep working.
   */
  ai: GoogleGenAI | null;
  /**
   * The webhook/debug ledger. Deliberately SEPARATE from live-session
   * inventory: live sessions use per-session ledgers (see
   * inventory/sessionLedgers.ts), so this global store no longer receives
   * live-session writes. It exists to preserve the webhook router's
   * calling interface and the debug route; in production it stays empty —
   * the phone owns the user's real ledger and the backend holds no
   * cross-session inventory.
   */
  ledger: InventoryLedger;
  confidenceService: ConfidenceService;
  /** Service functions; production defaults, replaceable in tests. */
  services?: Partial<HttpServices>;
  /**
   * Optional webhook verifier seam (packet 024): forwarded to
   * createWebhookRouter so tests can inject a permissive verifier without
   * env manipulation.
   */
  webhookOptions?: import("../api/webhooks.js").WebhookRouterOptions;
}

interface RouteLocals {
  requestId: string;
  route: string;
  errorCode?: StableErrorCode;
}

const DEBUG_ROUTES_ENV = "ENABLE_DEBUG_ROUTES";

function asBool(value: string | undefined): boolean {
  if (!value) return false;
  return value === "1" || value.toLowerCase() === "true";
}

function envInt(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.length === 0) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

/**
 * Bounded, expiring per-IP token buckets for the paid-model routes.
 * Per-instance cost containment only — not authentication. Forwarded headers
 * are deliberately ignored (see rateLimit.ts).
 */
function createPaidModelRateLimiter(): IpRateLimiter {
  return createIpRateLimiter({
    capacity: envInt("RATE_LIMIT_MAX_REQUESTS", 30, 1, 1_000_000),
    windowSeconds: envInt("RATE_LIMIT_WINDOW_SECONDS", 60, 1, 86_400),
    maxTrackedClients: envInt("RATE_LIMIT_MAX_TRACKED_CLIENTS", 10_000, 1, 1_000_000)
  });
}

function stampRoute(route: string): (req: Request, res: Response, next: NextFunction) => void {
  return (_req, res, next) => {
    (res.locals as unknown as RouteLocals).route = route;
    next();
  };
}

/** Express 4 does not catch promise rejections — forward them explicitly. */
function asyncHandler(
  fn: (req: Request, res: Response) => Promise<void>
): (req: Request, res: Response, next: NextFunction) => void {
  return (req, res, next) => {
    fn(req, res).catch(next);
  };
}

export function createApp(deps: AppDeps): Express {
  const services: HttpServices = {
    generateRecipe,
    rankReverseScanCandidates,
    ...deps.services
  };
  const rateLimiter = createPaidModelRateLimiter();
  const debugRoutesEnabled = asBool(process.env[DEBUG_ROUTES_ENV]);

  const app = express();
  app.disable("x-powered-by");

  // Request id + finish-hook logging. The log line carries ONLY allowlisted
  // fields (requestId, route, status, stable error code) — never errors,
  // headers, or bodies.
  app.use((req: Request, res: Response, next: NextFunction) => {
    const requestId = randomUUID();
    const locals = res.locals as unknown as RouteLocals;
    locals.requestId = requestId;
    locals.route = "unknown";
    res.setHeader("x-request-id", requestId);
    res.on("finish", () => {
      logHttpRequest({
        requestId,
        route: locals.route,
        status: res.statusCode,
        ...(locals.errorCode !== undefined ? { errorCode: locals.errorCode } : {})
      });
    });
    next();
  });

  const sendError = (
    res: Response,
    status: number,
    code: StableErrorCode,
    extra?: Record<string, unknown>
  ): void => {
    const locals = res.locals as unknown as RouteLocals;
    locals.errorCode = code;
    res.status(status).json({
      error: code,
      requestId: locals.requestId,
      ...(extra ?? {})
    });
  };

  // ─── Health ────────────────────────────────────────────────────────────────
  // Deliberately returns ok only: no model, provider, or inventory details.

  app.get("/healthz", stampRoute("/healthz"), (_req: Request, res: Response) => {
    res.json({ ok: true });
  });

  // ─── Paid-model routes: rate limit → bounded parse → validate → service ───

  const photoRouteParser = express.json({ limit: JSON_BODY_LIMIT_PHOTO_ROUTES });
  const defaultParser = express.json({ limit: JSON_BODY_LIMIT_DEFAULT });

  app.post(
    "/v1/recipes/generate",
    stampRoute("/v1/recipes/generate"),
    rateLimiter.middleware,
    photoRouteParser,
    asyncHandler(async (req, res) => {
      if (!deps.ai) {
        sendError(res, 503, "model_unavailable");
        return;
      }
      const payload = parseRecipeGenerationRequest(req.body);
      const result = await services.generateRecipe(deps.ai, deps.config, payload);
      res.json(result);
    })
  );

  app.post(
    "/v1/reverse-scan/rank",
    stampRoute("/v1/reverse-scan/rank"),
    rateLimiter.middleware,
    photoRouteParser,
    asyncHandler(async (req, res) => {
      if (!deps.ai) {
        sendError(res, 503, "model_unavailable");
        return;
      }
      const payload = parseReverseScanRankRequest(req.body);
      const result = await services.rankReverseScanCandidates(deps.ai, deps.config, payload);
      res.json(result);
    })
  );

  // ─── Non-model route ───────────────────────────────────────────────────────

  app.post(
    "/v1/notifications/plan",
    stampRoute("/v1/notifications/plan"),
    defaultParser,
    (req, res) => {
      const payload = parseNotificationPlanRequest(req.body);
      res.json(buildNotificationPlan(payload));
    }
  );

  // ─── Webhooks ──────────────────────────────────────────────────────────────
  // createWebhookRouter's calling interface is preserved exactly so an
  // optional verifier seam can be added independently (packet024).

  const webhookRouter: Router = createWebhookRouter(
    deps.ledger,
    deps.config,
    deps.webhookOptions
  );
  app.use(
    "/v1/webhooks",
    stampRoute("/v1/webhooks"),
    defaultParser,
    webhookRouter
  );

  // ─── Debug routes (off by default, process-wide) ───────────────────────────

  if (debugRoutesEnabled) {
    app.get("/v1/inventory", stampRoute("/v1/inventory"), (_req, res) => {
      res.json({ inventory: deps.ledger.snapshot() });
    });

    app.post(
      "/v1/confidence/assess",
      stampRoute("/v1/confidence/assess"),
      defaultParser,
      (req, res) => {
        const payload = parseConfidenceAssessRequest(req.body);
        res.json(deps.confidenceService.assess(payload));
      }
    );

    app.post(
      "/v1/confidence/outcome",
      stampRoute("/v1/confidence/outcome"),
      defaultParser,
      (req, res) => {
        const payload = parseConfidenceOutcomeRequest(req.body);
        deps.confidenceService.recordOutcome(payload);
        res.status(204).send();
      }
    );

    app.get(
      "/v1/confidence/snapshots",
      stampRoute("/v1/confidence/snapshots"),
      (_req, res) => {
        res.json({ snapshots: deps.confidenceService.calibrationSnapshots() });
      }
    );
  }

  // ─── Fallthrough + error handling ──────────────────────────────────────────

  app.use((_req: Request, res: Response) => {
    sendError(res, 404, "not_found");
  });

  // eslint-disable-next-line @typescript-eslint/no-unused-vars -- Express error middleware requires the 4-arg signature
  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (res.headersSent) {
      res.end();
      return;
    }

    // Recognized middleware failures first (safe codes, no messages echoed).
    const parserError = classifyBodyParserError(err);
    if (parserError) {
      sendError(res, parserError.status, parserError.code);
      return;
    }

    if (err instanceof RequestValidationError) {
      sendError(res, err.httpStatus, err.code, err.field ? { field: err.field } : undefined);
      return;
    }

    // The ONLY typed errors that reach a client with their own code — always
    // 422, always from the fixed allowlist. Arbitrary objects carrying a 4xx
    // status (e.g. provider SDK errors) do NOT get this treatment.
    if (err instanceof PublicApiError) {
      sendError(res, err.httpStatus, err.code);
      return;
    }

    // Anything else — provider failures, bugs, "4xx-shaped" strangers — is a
    // generic 500 plus request id. The message is never exposed or logged.
    sendError(res, 500, "internal_error");
  });

  return app;
}
