import { Router, type Request, type Response } from "express";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { traceToolCall, startTrace } from "../observability/tracing.js";
import type { AppConfig } from "../config.js";
import {
  createWebhookOidcVerifier,
  parseWebhookOidcConfig,
  WebhookAuthError,
  WebhookOidcConfigError,
  type WebhookIdentity,
  type WebhookOidcVerifier
} from "./webhookAuth.js";

/** Bounded set of task types the /tasks webhook accepts. */
export const KNOWN_TASK_TYPES = [
  "enrich_inventory",
  "send_spoilage_notification"
] as const;

export type WebhookTaskType = (typeof KNOWN_TASK_TYPES)[number];

export function isKnownTaskType(value: unknown): value is WebhookTaskType {
  return (
    typeof value === "string" &&
    (KNOWN_TASK_TYPES as readonly string[]).includes(value)
  );
}

export interface WebhookRouterOptions {
  /**
   * Optional OIDC verifier override. Existing createWebhookRouter(ledger,
   * config) callers are unaffected: without this option the router builds the
   * real google-auth-library verifier from WEBHOOK_OIDC_AUDIENCE and
   * WEBHOOK_ALLOWED_EMAILS. Tests inject fakes here.
   */
  verifier?: WebhookOidcVerifier;
  /** Optional environment source for OIDC settings; defaults to process.env. */
  env?: Record<string, string | undefined>;
}

export function createWebhookRouter(
  ledger: InventoryLedger,
  config: Pick<AppConfig, "restockThresholdDays" | "restockBelowGrams">,
  options?: WebhookRouterOptions
): Router {
  const router = Router();
  const injectedVerifier = options?.verifier;
  const envSource = options?.env ?? process.env;
  let verifierCache: WebhookOidcVerifier | undefined;

  function getVerifier(): WebhookOidcVerifier {
    if (injectedVerifier) return injectedVerifier;
    verifierCache ??= createWebhookOidcVerifier(
      parseWebhookOidcConfig(envSource)
    );
    return verifierCache;
  }

  /**
   * Authenticates the request or sends the error response itself and returns
   * undefined. Misconfiguration is 503 (the route never falls open); missing
   * or invalid credentials are 401.
   */
  async function authorizeRequest(
    req: Request,
    res: Response
  ): Promise<WebhookIdentity | undefined> {
    try {
      return await getVerifier().verifyBearerToken(req.headers.authorization);
    } catch (err) {
      if (err instanceof WebhookOidcConfigError) {
        // Absent/empty effective configuration must never be treated as
        // "accept". errorMessage is code-generated text, never client input.
        console.error(
          JSON.stringify({
            severity: "ERROR",
            message: "webhook_auth_misconfigured",
            errorMessage: err.message
          })
        );
        res
          .status(503)
          .json({ error: "Webhook authentication is not configured." });
        return undefined;
      }

      if (err instanceof WebhookAuthError) {
        console.warn(
          JSON.stringify({
            severity: "WARNING",
            message: "webhook_auth_rejected",
            reason: err.reason
          })
        );
        res.status(401).json({ error: "Unauthorized." });
        return undefined;
      }

      throw err;
    }
  }

  router.post("/scheduler", async (req: Request, res: Response) => {
    const tr = startTrace("webhook.scheduler");

    try {
      const identity = await authorizeRequest(req, res);
      if (!identity) return;

      const snapshot = ledger.snapshot();
      const plan = buildRestockPlan({
        inventorySnapshot: snapshot,
        thresholdDays: config.restockThresholdDays,
        restockBelowGrams: config.restockBelowGrams
      });

      console.log(
        JSON.stringify({
          severity: "INFO",
          message: "scheduler_restock_plan",
          inventoryItemCount: snapshot.length,
          useSoonCount: plan.useSoonAlerts.length,
          restockCount: plan.restockList.length,
          generatedAt: plan.generatedAt
        })
      );

      traceToolCall(tr.build(true, { args: { useSoonCount: plan.useSoonAlerts.length } }));
      res.status(200).json({ ok: true, plan });
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : "Scheduler job failed.";
      traceToolCall(tr.build(false, { errorMessage }));
      res.status(500).json({ error: errorMessage });
    }
  });

  router.post("/tasks", async (req: Request, res: Response) => {
    const tr = startTrace("webhook.task");

    try {
      const identity = await authorizeRequest(req, res);
      if (!identity) return;

      const body = (req.body ?? {}) as Record<string, unknown>;
      const taskType: unknown = body.taskType;

      // Validate taskType to a bounded known value BEFORE logging: the
      // request body is arbitrary client text and must never reach logs
      // verbatim.
      if (!isKnownTaskType(taskType)) {
        console.warn(
          JSON.stringify({
            severity: "WARNING",
            message: "cloud_task_rejected",
            reason: "unknown_task_type"
          })
        );
        traceToolCall(tr.build(false, { args: { reason: "unknown_task_type" } }));
        res.status(400).json({
          error: `taskType must be one of: ${KNOWN_TASK_TYPES.join(", ")}`
        });
        return;
      }

      // taskType is now one of KNOWN_TASK_TYPES and email is the verified,
      // allowlisted identity — both safe to log. The raw body is not logged.
      console.log(
        JSON.stringify({
          severity: "INFO",
          message: "cloud_task_received",
          taskType,
          callerEmail: identity.email
        })
      );

      traceToolCall(tr.build(true, { args: { taskType } }));
      res.status(200).json({ ok: true, taskType });
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : "Task handler failed.";
      traceToolCall(tr.build(false, { errorMessage }));
      res.status(500).json({ error: errorMessage });
    }
  });

  return router;
}
