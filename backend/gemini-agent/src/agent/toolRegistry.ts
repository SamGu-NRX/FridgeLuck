import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { startTrace, traceToolCall, traceConfidenceDecision } from "../observability/tracing.js";
import type { LiveSessionStore } from "../session/liveSessionStore.js";
import { assessLiveCookingScene } from "../services/liveContextService.js";
import { answerFoodSafetyQuestion } from "../services/groundingService.js";

export interface ToolDeps {
  ai: GoogleGenAI;
  config: AppConfig;
  ledger: InventoryLedger;
  confidenceService: ConfidenceService;
  sessionStore: LiveSessionStore;
}

export type ToolHandler = (
  args: Record<string, unknown>,
  deps: ToolDeps,
  sessionId?: string
) => Promise<unknown>;

const handleGetRecipeContext: ToolHandler = async (_args, deps, sessionId) => {
  const tr = startTrace("get_recipe_context", sessionId);

  try {
    if (!sessionId) throw new Error("get_recipe_context requires a live sessionId.");
    const session = await deps.sessionStore.getSession(sessionId);
    traceToolCall(tr.build(true));
    return {
      selectedRecipe: session.selectedRecipe ?? null,
      confirmedIngredients: session.confirmedIngredients,
      latestConfidence: session.latestConfidence ?? null,
      hasRecentCameraFrame: Boolean(session.latestCameraFrame),
      mutationAudit: session.mutationAudit
    };
  } catch (err) {
    traceToolCall(
      tr.build(false, { errorMessage: err instanceof Error ? err.message : "get_recipe_context failed" })
    );
    throw err;
  }
};

const handleAssessLiveScene: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("assess_live_scene", sessionId, args);

  try {
    if (!sessionId) throw new Error("assess_live_scene requires a live sessionId.");
    const session = await deps.sessionStore.getSession(sessionId);
    const result = await assessLiveCookingScene(deps.ai, deps.config, deps.confidenceService, {
      recipe: session.selectedRecipe,
      confirmedIngredients: session.confirmedIngredients,
      latestCameraFrame: session.latestCameraFrame,
      userQuestion: args.userQuestion as string | undefined
    });

    await deps.sessionStore.recordLatestConfidence(sessionId, result.confidence_assessment);
    traceConfidenceDecision(result.confidence_assessment, "assess_live_scene", sessionId);
    traceToolCall(
      tr.build(true, {
        confidenceMode: result.confidence_assessment.mode,
        confidenceScore: result.confidence_assessment.overallScore
      })
    );

    return result;
  } catch (err) {
    traceToolCall(
      tr.build(false, { errorMessage: err instanceof Error ? err.message : "assess_live_scene failed" })
    );
    throw err;
  }
};

const handleGroundFoodSafety: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("ground_food_safety", sessionId, args);

  try {
    const question = args.question as string | undefined;
    if (!question) throw new Error("ground_food_safety requires a question.");
    const result = await answerFoodSafetyQuestion(deps.ai, deps.config, question);
    traceToolCall(tr.build(true));
    return result;
  } catch (err) {
    traceToolCall(
      tr.build(false, { errorMessage: err instanceof Error ? err.message : "ground_food_safety failed" })
    );
    throw err;
  }
};

const handleMutateInventory: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("mutate_inventory", sessionId, args);

  try {
    const operation = args.operation as string;
    const idempotencyKey = args.idempotencyKey as string;
    const items = args.items as Array<{
      ingredientName: string;
      quantityGrams: number;
      expiresAt?: string;
      source?: "scan" | "manual" | "restock";
    }>;

    if (!idempotencyKey) throw new Error("mutate_inventory: idempotencyKey is required.");
    if (!Array.isArray(items) || items.length === 0) {
      throw new Error("mutate_inventory: items must be a non-empty array.");
    }

    const req = { idempotencyKey, items };
    let result;

    if (operation === "add") {
      result = deps.ledger.addItems(req);
    } else if (operation === "decrement") {
      result = deps.ledger.decrementItems(req);
    } else {
      throw new Error(`mutate_inventory: unknown operation '${operation}'. Use 'add' or 'decrement'.`);
    }

    if (sessionId) {
      await deps.sessionStore.appendMutationAudit(sessionId, {
        operation,
        idempotencyKey,
        itemCount: items.length,
        committed: result.committed,
        createdAt: new Date().toISOString()
      });
    }

    traceToolCall(tr.build(true));
    return result;
  } catch (err) {
    traceToolCall(
      tr.build(false, { errorMessage: err instanceof Error ? err.message : "mutate_inventory failed" })
    );
    throw err;
  }
};

const handleGetRestockPlan: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("get_restock_plan", sessionId, args);

  try {
    const result = buildRestockPlan({
      inventorySnapshot: deps.ledger.snapshot(),
      thresholdDays: (args.thresholdDays as number | undefined) ?? deps.config.restockThresholdDays,
      restockBelowGrams: (args.restockBelowGrams as number | undefined) ?? deps.config.restockBelowGrams
    });

    traceToolCall(tr.build(true));
    return result;
  } catch (err) {
    traceToolCall(
      tr.build(false, { errorMessage: err instanceof Error ? err.message : "get_restock_plan failed" })
    );
    throw err;
  }
};

const HANDLERS: Record<string, ToolHandler> = {
  get_recipe_context: handleGetRecipeContext,
  assess_live_scene: handleAssessLiveScene,
  ground_food_safety: handleGroundFoodSafety,
  mutate_inventory: handleMutateInventory,
  get_restock_plan: handleGetRestockPlan
};

export function buildToolRegistry(): Map<string, ToolHandler> {
  return new Map(Object.entries(HANDLERS));
}

export async function dispatchToolCall(
  name: string,
  args: Record<string, unknown>,
  registry: Map<string, ToolHandler>,
  deps: ToolDeps,
  sessionId?: string
): Promise<{ result: unknown; error?: string }> {
  const handler = registry.get(name);

  if (!handler) {
    const error = `Unknown tool: '${name}'. Available tools: ${[...registry.keys()].join(", ")}`;
    console.error(JSON.stringify({ severity: "WARNING", message: error, sessionId }));
    return { result: null, error };
  }

  try {
    const result = await handler(args, deps, sessionId);
    return { result };
  } catch (err) {
    const error = err instanceof Error ? err.message : `Tool '${name}' failed.`;
    return { result: null, error };
  }
}
