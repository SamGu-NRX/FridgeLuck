import type { GoogleGenAI } from "@google/genai";
import type { AppConfig } from "../config.js";
import type { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { ConfidenceService } from "../services/confidenceService.js";
import { buildRestockPlan } from "../automation/restockJob.js";
import { startTrace, traceToolCall, traceConfidenceDecision } from "../observability/tracing.js";
import type { LiveSessionStore } from "../session/liveSessionStore.js";
import { assessLiveCookingScene } from "../services/liveContextService.js";
import { answerFoodSafetyQuestion } from "../services/groundingService.js";
import type { InMemoryFrameHolder } from "../services/frameCache.js";
import type { LeChefRuntime } from "../lechef/runtime.js";
import { REGISTERED_TOOLS } from "../lechef/runtime.js";
import { PROPOSAL_TTL_SECONDS } from "../lechef/types.js";
import type { LivePhoneExecutor } from "../services/livePhoneExecutor.js";

/**
 * Tool registry — the Gemini-visible tool surface.
 *
 * SPEC §8.3 inverts the authority: the LeChef tools READ bounded snapshots
 * the phone handed out and PROPOSE typed actions routed to the phone; the
 * phone checks revision and approval, executes at most once, and returns a
 * receipt. The old server-memory mutation tool (`mutate_inventory`) is
 * REMOVED, not wrapped — the backend is no longer a write authority for the
 * pantry (SPEC D2; the burst5 tools slice's done-when: mutate_inventory gone).
 *
 * Camera frames reach tools only through the in-process frame cache
 * (ToolDeps.frames) — never through the session store (SPEC §9.2–9.3).
 */

export interface ToolDeps {
  ai: GoogleGenAI;
  config: AppConfig;
  ledger: InventoryLedger;
  confidenceService: ConfidenceService;
  sessionStore: LiveSessionStore;
  /** In-process frame cache; frames never come from the store (SPEC §9). */
  frames: InMemoryFrameHolder;
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
      // The model learns a frame EXISTS, never sees one through the store (SPEC §9.4).
      hasRecentCameraFrame: deps.frames.hasRecentFrame(sessionId)
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
    // The frame comes from the in-memory cache via ToolDeps, never from the
    // store (SPEC §9.3): the frame TTL (2 min from server receipt) bounds
    // what the tool can reach.
    const frame = deps.frames.get(sessionId);
    const result = await assessLiveCookingScene(deps.ai, deps.config, deps.confidenceService, {
      recipe: session.selectedRecipe,
      confirmedIngredients: session.confirmedIngredients,
      latestCameraFrame: frame ?? undefined,
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

const LEGACY_HANDLERS: Record<string, ToolHandler> = {
  get_recipe_context: handleGetRecipeContext,
  assess_live_scene: handleAssessLiveScene,
  ground_food_safety: handleGroundFoodSafety,
  get_restock_plan: handleGetRestockPlan
};

/**
 * Build the session-independent part of the registry: the four legacy read
 * tools. The LeChef tools are per-session (their phone executor is bound to
 * the live socket) — overlay them per connection with overlayLeChefTools.
 */
export function buildToolRegistry(): Map<string, ToolHandler> {
  return new Map(Object.entries(LEGACY_HANDLERS));
}

/** A pending proposal outcome from the LeChef runtime's proposal tools. */
interface PendingProposalOutcome {
  submitted: boolean;
  proposalID: string;
  status: "pending_explicit_approval" | "resolved";
  expiresAt?: string;
}

function isPendingProposalOutcome(value: unknown): value is PendingProposalOutcome {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as PendingProposalOutcome).submitted === true &&
    (value as PendingProposalOutcome).status === "pending_explicit_approval" &&
    typeof (value as PendingProposalOutcome).proposalID === "string"
  );
}

/**
 * Overlay the 15 registered LeChef tools (SPEC §8.3) onto a per-connection
 * registry. Proposal tools ROUTE to the phone over the live socket and await
 * the receipt: the tool result the model sees carries the phone's receipt —
 * executed, rejected, or expired — never a claimed success (SPEC §8.1–8.2).
 */
export function overlayLeChefTools(
  registry: Map<string, ToolHandler>,
  runtime: LeChefRuntime,
  phone: LivePhoneExecutor,
): void {
  for (const tool of REGISTERED_TOOLS) {
    registry.set(tool, async (args) => {
      const outcome = runtime.dispatch(tool, args) as unknown;
      if (!isPendingProposalOutcome(outcome)) return outcome;

      // Pending explicit approval: the proposal is already routed to the
      // phone by submitProposal. Await the phone's receipt within the
      // proposal TTL; a receipt that never arrives leaves the outcome
      // pending with its expiry — the model never claims an execution.
      const receipt = await phone.waitForReceipt(
        outcome.proposalID,
        PROPOSAL_TTL_SECONDS * 1000,
      );
      // No receipt within the TTL: the outcome stays pending with its expiry —
      // the model never claims an execution the phone did not confirm.
      if (!receipt) return outcome;
      return {
        ...(outcome as unknown as Record<string, unknown>),
        status: "resolved",
        receipt,
      };
    });
  }
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
    // SPEC §8.3: unknown tool names are a typed error result, never a throw.
    const error = `unknown tool "${name}"; registered: ${[...registry.keys()].join(", ")}`;
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
