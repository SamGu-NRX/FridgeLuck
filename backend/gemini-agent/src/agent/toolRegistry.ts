import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { ConfidenceAssessRequest } from "../types/contracts.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import { generateRecipe } from "../services/recipeService.js";
import { rankReverseScanCandidates } from "../services/reverseScanService.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { startTrace, traceToolCall, traceConfidenceDecision } from "../observability/tracing.js";
import type { RecipeGenerationRequest, ReverseScanRankRequest } from "../types/contracts.js";

export interface ToolDeps {
  ai: GoogleGenAI;
  config: AppConfig;
  ledger: InventoryLedger;
  confidenceService: ConfidenceService;
}

export type ToolHandler = (
  args: Record<string, unknown>,
  deps: ToolDeps,
  sessionId?: string
) => Promise<unknown>;

const handleScanFridge: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("scan_fridge", sessionId, args);

  try {
    const req: RecipeGenerationRequest = {
      ingredientNames: (args.existingInventoryNames as string[] | undefined) ?? [],
      photoBase64JPEG: args.photoBase64JPEG as string | undefined
    };

    const hasPhoto = Boolean(req.photoBase64JPEG);
    const confidenceReq: ConfidenceAssessRequest = {
      signals: [
        {
          key: "vision.fridge_scan",
          rawScore: hasPhoto ? 0.78 : 0.42,
          weight: 0.6,
          reason: hasPhoto ? "Photo provided for scan" : "No photo — low confidence"
        }
      ],
      hardFailReasons: hasPhoto ? [] : ["No photo provided for fridge scan."]
    };

    const assessment = deps.confidenceService.assess(confidenceReq);
    traceConfidenceDecision(assessment, "scan_fridge", sessionId);
    traceToolCall(tr.build(true, { confidenceMode: assessment.mode, confidenceScore: assessment.overallScore }));

    return { detectedIngredients: req.ingredientNames, confidence_assessment: assessment };
  } catch (err) {
    traceToolCall(tr.build(false, { errorMessage: err instanceof Error ? err.message : "scan_fridge failed" }));
    throw err;
  }
};

const handleReverseScanMeal: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("reverse_scan_meal", sessionId, args);

  try {
    const req: ReverseScanRankRequest = {
      detections: [],
      candidates: [],
      photoBase64JPEG: args.photoBase64JPEG as string | undefined
    };

    const result = await rankReverseScanCandidates(deps.ai, deps.config, req);

    const topScore = result.rankings[0]?.confidenceScore ?? 0;
    const confidenceReq: ConfidenceAssessRequest = {
      signals: [
        {
          key: "reverse_scan.vision_detection",
          rawScore: args.photoBase64JPEG ? 0.75 : 0.3,
          weight: 0.4,
          reason: "Vision detection signal"
        },
        {
          key: "reverse_scan.recipe_match",
          rawScore: topScore,
          weight: 0.4,
          reason: "Top recipe match score"
        }
      ]
    };

    const assessment = deps.confidenceService.assess(confidenceReq);
    traceConfidenceDecision(assessment, "reverse_scan_meal", sessionId);
    traceToolCall(tr.build(true, { confidenceMode: assessment.mode, confidenceScore: assessment.overallScore }));

    return { ...result, confidence_assessment: assessment };
  } catch (err) {
    traceToolCall(tr.build(false, { errorMessage: err instanceof Error ? err.message : "reverse_scan_meal failed" }));
    throw err;
  }
};

const handleGenerateRecipe: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("generate_recipe", sessionId, args);

  try {
    const req: RecipeGenerationRequest = {
      ingredientNames: (args.ingredientNames as string[]) ?? [],
      dietaryRestrictions: (args.dietaryRestrictions as string[] | undefined) ?? [],
      scanConfidenceScore: (args.scanConfidenceScore as number | undefined) ?? 0,
      photoBase64JPEG: args.photoBase64JPEG as string | undefined
    };

    const result = await generateRecipe(deps.ai, deps.config, req);
    traceToolCall(tr.build(true));
    return result;
  } catch (err) {
    traceToolCall(tr.build(false, { errorMessage: err instanceof Error ? err.message : "generate_recipe failed" }));
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
    if (!Array.isArray(items) || items.length === 0) throw new Error("mutate_inventory: items must be a non-empty array.");

    const req = { idempotencyKey, items };
    let result;

    if (operation === "add") {
      result = deps.ledger.addItems(req);
    } else if (operation === "decrement") {
      result = deps.ledger.decrementItems(req);
    } else {
      throw new Error(`mutate_inventory: unknown operation '${operation}'. Use 'add' or 'decrement'.`);
    }

    traceToolCall(tr.build(true));
    return result;
  } catch (err) {
    traceToolCall(tr.build(false, { errorMessage: err instanceof Error ? err.message : "mutate_inventory failed" }));
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
    traceToolCall(tr.build(false, { errorMessage: err instanceof Error ? err.message : "get_restock_plan failed" }));
    throw err;
  }
};

const HANDLERS: Record<string, ToolHandler> = {
  scan_fridge: handleScanFridge,
  reverse_scan_meal: handleReverseScanMeal,
  generate_recipe: handleGenerateRecipe,
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
