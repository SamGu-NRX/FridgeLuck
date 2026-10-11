/**
 * createLeChefRuntime — the single entry point the later integration task
 * will call from server.ts (which this task must not edit).
 *
 * The runtime owns no state: the phone owns state, the catalog supplies
 * candidates, the clock is injected. Tools are dispatched by name with
 * validated args; every dispatch returns a JSON-able result plus a status so
 * the evaluation layer can record exactly what happened.
 *
 * Dispatch status: ok | cancelled | duplicate | error. Duplicates never
 * create a second proposal (the proposal layer dedupes by call id, then
 * payload); cancelled calls abort before submission — nothing reaches the
 * phone.
 */

import type { Clock, PantryLineState, Quantity, NoteScope, SubstitutionSwap } from "./types.js";
import { createProposalLayer, noAbort, type AbortCheck, type PhoneExecutor, type ProposalLayer } from "./proposals.js";
import {
  getRecipeCandidates,
  getPantrySummary,
  getRecipeContext,
  getStepContext,
  requestCameraLook,
  type CameraDevice,
  type ReadDeps,
  type RecipeCatalog
} from "./reads.js";
import { createFoodSafetyTool, type FoodSafetyRulebook, type FoodSafetyTool } from "./foodSafety.js";
import { createSubstitutionTool, type SubstitutionTableLoader, type SubstitutionTool } from "./substitutions.js";
import { allergenViolations } from "./allergens.js";

export interface LeChefRuntimeDeps {
  readonly clock: Clock;
  readonly phone: PhoneExecutor;
  readonly catalog: RecipeCatalog;
  /** Device-mediated camera; omit when the session has no camera. */
  readonly camera?: CameraDevice;
  /** Rulebook override; defaults to the embedded FSIS table (see foodSafety.ts). */
  readonly foodSafetyRulebook?: FoodSafetyRulebook;
  /** Substitution table loader; defaults to absent (alpha) — see substitutions.ts. */
  readonly substitutionLoader?: SubstitutionTableLoader;
}

export type ToolCallStatus = "ok" | "cancelled" | "duplicate" | "error";

export interface DispatchResult {
  readonly id: string;
  readonly name: string;
  readonly args: Readonly<Record<string, unknown>>;
  readonly result: unknown;
  readonly status: ToolCallStatus;
  /** Set when status is "duplicate": the earlier proposal this call deduped onto. */
  readonly dupOf?: string;
}

export interface LeChefRuntime {
  readonly reads: ReadDeps;
  readonly proposals: ProposalLayer;
  readonly safety: FoodSafetyTool;
  readonly substitution: SubstitutionTool;
  /** Dispatch one model tool call by name; never throws — errors come back as status "error". */
  dispatch(call: { id: string; name: string; args?: Record<string, unknown> }, abort?: AbortCheck): DispatchResult;
}

// ---------------------------------------------------------------------------
// Argument validation — external input is unknown until checked here
// ---------------------------------------------------------------------------

function asString(args: Record<string, unknown>, key: string): string | undefined {
  const v = args[key];
  return typeof v === "string" ? v : undefined;
}

function asNumber(args: Record<string, unknown>, key: string): number | undefined {
  const v = args[key];
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function asBoolean(args: Record<string, unknown>, key: string): boolean | undefined {
  const v = args[key];
  return typeof v === "boolean" ? v : undefined;
}

/** Accepts {kind:"known",value,unit} | {kind:"unknown"} | undefined. */
function asQuantity(args: Record<string, unknown>, key: string): Quantity | undefined {
  const v = args[key];
  if (typeof v !== "object" || v === null) return undefined;
  const rec = v as Record<string, unknown>;
  if (rec["kind"] === "unknown") return { kind: "unknown" };
  if (rec["kind"] === "known" && typeof rec["value"] === "number" && typeof rec["unit"] === "string") {
    return { kind: "known", value: rec["value"], unit: rec["unit"] };
  }
  return undefined;
}

function asSwaps(args: Record<string, unknown>, key: string): SubstitutionSwap[] | undefined {
  const v = args[key];
  if (!Array.isArray(v)) return undefined;
  const swaps: SubstitutionSwap[] = [];
  for (const item of v) {
    if (typeof item !== "object" || item === null) continue;
    const rec = item as Record<string, unknown>;
    if (typeof rec["from"] === "string" && typeof rec["to"] === "string") {
      swaps.push({ from: rec["from"], to: rec["to"] });
    }
  }
  return swaps;
}

const PANTRY_STATES: readonly PantryLineState[] = [
  "sufficient",
  "short",
  "quantity-unknown",
  "assumed-staple",
  "needs-reconfirming"
];

export function createLeChefRuntime(deps: LeChefRuntimeDeps): LeChefRuntime {
  const proposals = createProposalLayer({ clock: deps.clock, phone: deps.phone });
  const safety = createFoodSafetyTool(deps.foodSafetyRulebook);
  const substitution = createSubstitutionTool(
    deps.substitutionLoader ? { loader: deps.substitutionLoader } : {}
  );

  const reads: ReadDeps = {
    pantry: () => deps.phone.pantrySnapshot(),
    session: () => deps.phone.sessionSnapshot(),
    catalog: deps.catalog,
    swapViolations: (to) => {
      // ALL eaters' restrictions, compound ingredients included (SPEC 3.1).
      return allergenViolations(to, deps.phone.sessionSnapshot().eaters);
    }
  };

  return {
    reads,
    proposals,
    safety,
    substitution,
    dispatch(call, abort) {
      const stop = abort ?? noAbort;
      const args: Record<string, unknown> = call.args ?? {};
      const base = { id: call.id, name: call.name, args };

      // A cancelled call aborts before anything happens — no proposal from it
      // ever reaches the phone.
      if (stop.aborted()) {
        return { ...base, result: { cancelled: true }, status: "cancelled" };
      }

      try {
        switch (call.name) {
          // -------------------------------------------------------------
          // Read tools
          // -------------------------------------------------------------
          case "getRecipeCandidates": {
            const goal = {
              text: asString(args, "goal") ?? "",
              ...(asSwaps(args, "acceptedSwaps") !== undefined ? { acceptedSwaps: asSwaps(args, "acceptedSwaps") } : {})
            };
            return { ...base, result: getRecipeCandidates(reads, goal), status: "ok" };
          }
          case "getPantrySummary":
            return { ...base, result: getPantrySummary(reads), status: "ok" };
          case "getRecipeContext":
            return { ...base, result: getRecipeContext(reads), status: "ok" };
          case "getStepContext":
            return { ...base, result: getStepContext(reads), status: "ok" };
          case "lookupSubstitution": {
            const ingredient = asString(args, "ingredient");
            if (!ingredient) return { ...base, result: { error: "lookupSubstitution needs an ingredient" }, status: "error" };
            const eaters = reads.session().eaters;
            const result = substitution.lookupSubstitution({
              ingredient,
              ...(asString(args, "context") !== undefined ? { context: asString(args, "context") } : {}),
              eaters
            });
            return { ...base, result, status: "ok" };
          }
          case "checkFoodSafety": {
            const product = asString(args, "product");
            if (!product) return { ...base, result: { error: "checkFoodSafety needs a product" }, status: "error" };
            const question = asString(args, "question");
            const answer = safety.checkFoodSafety({
              product,
              ...(question !== undefined ? { question } : {})
            });
            return { ...base, result: answer, status: "ok" };
          }
          case "requestCameraLook": {
            if (!deps.camera) {
              return {
                ...base,
                result: { error: "no camera is available in this session" },
                status: "error"
              };
            }
            const maxClip = asNumber(args, "maxClipSeconds") ?? 3;
            return { ...base, result: requestCameraLook(reads, deps.camera, { maxClipSeconds: maxClip }), status: "ok" };
          }

          // -------------------------------------------------------------
          // Proposal tools — create a proposal, never execute
          // -------------------------------------------------------------
          case "proposeTimerStart": {
            const label = asString(args, "label");
            const minutes = asNumber(args, "minutes");
            if (!label || minutes === undefined) {
              return { ...base, result: { error: "proposeTimerStart needs a label and minutes" }, status: "error" };
            }
            const userInitiated = asBoolean(args, "userInitiated") ?? false;
            const outcome = proposals.proposeTimerStart({ callId: call.id, label, minutes, userInitiated, abort: stop });
            return toDispatch(base, outcome);
          }
          case "proposeTimerAdjust": {
            const userInitiated = asBoolean(args, "userInitiated") ?? false;
            const outcome = proposals.proposeTimerAdjust({
              callId: call.id,
              ...(asString(args, "timerId") !== undefined ? { timerId: asString(args, "timerId") } : {}),
              ...(asString(args, "label") !== undefined ? { label: asString(args, "label") } : {}),
              ...(asNumber(args, "newMinutes") !== undefined ? { newMinutes: asNumber(args, "newMinutes") } : {}),
              ...(asNumber(args, "deltaMinutes") !== undefined ? { deltaMinutes: asNumber(args, "deltaMinutes") } : {}),
              userInitiated,
              abort: stop
            });
            return toDispatch(base, outcome);
          }
          case "proposeStepAdvance": {
            const stepIndex = asNumber(args, "stepIndex");
            if (stepIndex === undefined) {
              return { ...base, result: { error: "proposeStepAdvance needs a stepIndex" }, status: "error" };
            }
            return toDispatch(base, proposals.proposeStepAdvance({ callId: call.id, stepIndex, abort: stop }));
          }
          case "proposeInventoryCorrection": {
            const ingredientId = asString(args, "ingredientId");
            const name = asString(args, "name");
            const reason = asString(args, "reason");
            const observedQuantity = asQuantity(args, "observedQuantity");
            const observedStateRaw = asString(args, "observedState");
            const observedState = PANTRY_STATES.includes(observedStateRaw as never)
              ? (observedStateRaw as PantryLineState)
              : undefined;
            if (!ingredientId || !name || !reason || (observedQuantity === undefined && !observedState)) {
              return {
                ...base,
                result: { error: "proposeInventoryCorrection needs ingredientId, name, reason, and an observed quantity or state" },
                status: "error"
              };
            }
            return toDispatch(
              base,
              proposals.proposeInventoryCorrection({
                callId: call.id,
                ingredientId,
                name,
                ...(observedQuantity !== undefined ? { observedQuantity } : {}),
                ...(observedState !== undefined ? { observedState } : {}),
                reason,
                abort: stop
              })
            );
          }
          case "proposeMealLog": {
            const recipeId = asString(args, "recipeId");
            const revision = asNumber(args, "revision");
            const servings = asNumber(args, "servings");
            const sourcedFromRaw = asString(args, "sourcedFrom");
            const sourcedFrom = sourcedFromRaw === "voice" || sourcedFromRaw === "screen" ? sourcedFromRaw : undefined;
            if (!recipeId || revision === undefined || servings === undefined || !sourcedFrom) {
              return {
                ...base,
                result: { error: "proposeMealLog needs recipeId, revision, servings and sourcedFrom (voice|screen)" },
                status: "error"
              };
            }
            return toDispatch(
              base,
              proposals.proposeMealLog({
                callId: call.id,
                // mealLog is ALWAYS explicit — but whether this replayed a direct
                // user command is still a recorded fact about the request.
                userInitiated: asBoolean(args, "userInitiated") ?? false,
                recipeId,
                revision,
                servings,
                ...(asSwaps(args, "swaps") !== undefined ? { swaps: asSwaps(args, "swaps") } : {}),
                sourcedFrom,
                ...(asString(args, "note") !== undefined ? { note: asString(args, "note") } : {}),
                abort: stop
              })
            );
          }
          case "proposeSaveNote": {
            const text = asString(args, "text");
            const scopeRaw = asString(args, "scope");
            const scope: NoteScope | undefined = scopeRaw === "cook" || scopeRaw === "recipe" ? scopeRaw : undefined;
            if (!text || !scope) {
              return { ...base, result: { error: "proposeSaveNote needs text and scope (cook|recipe)" }, status: "error" };
            }
            return toDispatch(base, proposals.proposeSaveNote({ callId: call.id, text, scope, abort: stop }));
          }

          default:
            return { ...base, result: { error: `unknown tool "${call.name}"` }, status: "error" };
        }
      } catch (error: unknown) {
        // Never swallow: the error becomes the call's recorded result.
        const message = error instanceof Error ? error.message : String(error);
        return { ...base, result: { error: message }, status: "error" };
      }
    }
  };
}

function toDispatch(
  base: { id: string; name: string; args: Record<string, unknown> },
  outcome: ReturnType<ProposalLayer["proposeTimerStart"]>
): DispatchResult {
  if (outcome.duplicateOf !== undefined) {
    return {
      ...base,
      result: {
        proposalId: outcome.proposal?.id ?? null,
        state: outcome.state,
        note: outcome.note
      },
      status: "duplicate",
      dupOf: outcome.duplicateOf
    };
  }
  return {
    ...base,
    result: {
      proposalId: outcome.proposal?.id ?? null,
      state: outcome.state,
      requiredApproval: outcome.proposal?.requiredApproval,
      userInitiated: outcome.proposal?.userInitiated,
      receipt: outcome.receipt,
      note: outcome.note
    },
    status: "ok"
  };
}
