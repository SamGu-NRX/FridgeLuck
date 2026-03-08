import { Router, type Request, type Response } from "express";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { traceToolCall, startTrace } from "../observability/tracing.js";
import type { AppConfig } from "../config.js";

export function createWebhookRouter(
  ledger: InventoryLedger,
  config: Pick<AppConfig, "restockThresholdDays" | "restockBelowGrams">
): Router {
  const router = Router();

  router.post("/scheduler", (_req: Request, res: Response) => {
    const tr = startTrace("webhook.scheduler");

    try {
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

  router.post("/tasks", (req: Request, res: Response) => {
    const tr = startTrace("webhook.task");

    try {
      const body = req.body as Record<string, unknown>;
      const taskType = body.taskType as string | undefined;

      if (!taskType) {
        res.status(400).json({ error: "taskType is required." });
        return;
      }

      console.log(JSON.stringify({ severity: "INFO", message: "cloud_task_received", taskType, body }));

      switch (taskType) {
        case "enrich_inventory":
        case "send_spoilage_notification":
          break;
        default:
          console.warn(JSON.stringify({ severity: "WARNING", message: `Unknown taskType: ${taskType}` }));
      }

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
