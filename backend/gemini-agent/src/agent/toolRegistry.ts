import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { SessionLedgers } from "../inventory/sessionLedgers.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import type { InventoryMutationResponse } from "../types/contracts.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { startTrace, traceToolCall, traceConfidenceDecision } from "../observability/tracing.js";
import type { LiveSessionStore } from "../session/liveSessionStore.js";
import { assessLiveCookingScene } from "../services/liveContextService.js";
import { answerFoodSafetyQuestion } from "../services/groundingService.js";
import {
  MutationProposalError,
  validateProposalArgs,
  type MutationProposal,
  type MutationProposalStore
} from "../authority/mutationAuthority.js";

// Tool authority boundary.
//
// `mutate_inventory` used to execute ledger writes directly from model args,
// gated only by prompt text. It is now `propose_inventory_mutation`: the
// tool REGISTERS a validated, expiring proposal and returns it as pending.
// Nothing here executes a write. Execution happens only when the trusted
// client sends a confirm envelope on the session's own WebSocket (see
// liveSessionGateway.ts), using the proposal id as the ledger idempotency
// key so one approval applies at most once.

export interface ToolDeps {
  /** Model client; null when the deployment has no credentials (fail-safe). */
  ai: GoogleGenAI | null;
  config: AppConfig;
  /** Session-scoped inventory ledgers (replaces the process-wide ledger). */
  ledgers: SessionLedgers;
  confidenceService: ConfidenceService;
  sessionStore: LiveSessionStore;
  /** Pending mutation proposals, scoped per session. */
  proposals: MutationProposalStore;
}

/**
 * A tool error whose message is static, validator- or policy-generated text
 * safe to return to the model. Any OTHER error is collapsed to a generic
 * message by dispatchToolCall — service/provider internals never leak into
 * tool results.
 */
export class ToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ToolError";
  }
}

export type ToolHandler = (
  args: Record<string, unknown>,
  deps: ToolDeps,
  sessionId?: string
) => Promise<unknown>;

/**
 * Executes an approved proposal against the proposal's session ledger.
 * The idempotency key IS the proposal id: a retried confirm after a crash
 * re-applies as a no-op. This is the ONLY path from an approved proposal to
 * a ledger write, and it is called from exactly one place: the gateway's
 * confirm-envelope handler.
 */
export function applyApprovedProposal(
  proposal: MutationProposal,
  ledger: InventoryLedger
): InventoryMutationResponse {
  const req = {
    idempotencyKey: proposal.id,
    items: proposal.items.map((item) => ({
      ingredientName: item.ingredientName,
      quantityGrams: item.quantityGrams,
      ...(item.expiresAt !== undefined ? { expiresAt: item.expiresAt } : {}),
      ...(item.source !== undefined ? { source: item.source } : {})
    }))
  };

  if (proposal.operation === "add") {
    return ledger.addItems(req);
  }
  return ledger.decrementItems(req);
}

const handleGetRecipeContext: ToolHandler = async (_args, deps, sessionId) => {
  const tr = startTrace("get_recipe_context", sessionId);

  try {
    if (!sessionId) throw new ToolError("get_recipe_context requires a live sessionId.");
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
    if (!sessionId) throw new ToolError("assess_live_scene requires a live sessionId.");
    if (!deps.ai) throw new ToolError("model_unavailable: no model client is configured.");
    const session = await deps.sessionStore.getSession(sessionId);
    const result = await assessLiveCookingScene(deps.ai, deps.config, deps.confidenceService, {
      recipe: session.selectedRecipe,
      confirmedIngredients: session.confirmedIngredients,
      latestCameraFrame: session.latestCameraFrame,
      userQuestion: typeof args.userQuestion === "string" ? args.userQuestion : undefined
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
    const question = args.question;
    if (typeof question !== "string" || question.length === 0) {
      throw new ToolError("ground_food_safety requires a question.");
    }
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

/**
 * PROPOSE ONLY. Model args are validated and registered as a pending,
 * expiring proposal. Confirmation-shaped args — `confirmed`, `approved`,
 * `userConfirmation`, anything at all beyond operation/items — are dropped
 * by validateProposalArgs and can never cause a write.
 */
const handleProposeInventoryMutation: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("propose_inventory_mutation", sessionId, {
    itemCount: Array.isArray(args.items) ? args.items.length : undefined
  });

  try {
    if (!sessionId) {
      throw new ToolError("propose_inventory_mutation requires a live sessionId.");
    }

    const validated = validateProposalArgs(args);
    const { proposal, duplicate } = deps.proposals.create(sessionId, validated);

    traceToolCall(tr.build(true));

    return {
      status: "pending_user_confirmation",
      proposalId: proposal.id,
      expiresAt: new Date(proposal.expiresAtMs).toISOString(),
      operation: validated.operation,
      itemCount: validated.items.length,
      duplicate,
      note:
        "Nothing has changed yet. The user must approve this proposal in the app; it is applied only after that approval."
    };
  } catch (err) {
    traceToolCall(
      tr.build(false, {
        errorMessage:
          err instanceof Error ? err.message : "propose_inventory_mutation failed"
      })
    );
    throw err;
  }
};

const handleGetRestockPlan: ToolHandler = async (args, deps, sessionId) => {
  const tr = startTrace("get_restock_plan", sessionId, args);

  try {
    if (!sessionId) {
      throw new ToolError("get_restock_plan requires a live sessionId.");
    }

    const result = buildRestockPlan({
      // Session-scoped: a session sees only its own shadow inventory, never
      // another session's items and never an aggregate across users.
      inventorySnapshot: deps.ledgers.get(sessionId).snapshot(),
      thresholdDays:
        typeof args.thresholdDays === "number" && Number.isFinite(args.thresholdDays)
          ? args.thresholdDays
          : deps.config.restockThresholdDays,
      restockBelowGrams:
        typeof args.restockBelowGrams === "number" && Number.isFinite(args.restockBelowGrams)
          ? args.restockBelowGrams
          : deps.config.restockBelowGrams
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
  propose_inventory_mutation: handleProposeInventoryMutation,
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
    // Error-surface discipline: validator/policy messages are static text we
    // wrote — safe to return. Everything else may carry provider internals
    // (a JSON.parse message can embed a snippet of model output), so it is
    // collapsed to a generic line; the specific detail goes to server logs
    // only, never into tool results.
    if (err instanceof ToolError || err instanceof MutationProposalError) {
      return { result: null, error: err.message };
    }
    console.error(
      JSON.stringify({
        severity: "ERROR",
        message: `tool '${name}' failed internally.`,
        errorName: err instanceof Error ? err.name : typeof err,
        sessionId
      })
    );
    return { result: null, error: `Tool '${name}' failed internally.` };
  }
}
