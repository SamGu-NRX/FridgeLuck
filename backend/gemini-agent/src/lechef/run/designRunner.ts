/**
 * Design runner — policy-gates a session script through a LeChefDesign and
 * replays it, emitting the same raw RunRecord the plain harness emits.
 *
 * Parent-owned join infrastructure (fl-lechef-f1): the three design tasks
 * implement LeChefDesign configs; this runner owns the mechanics.
 *
 * Gating semantics:
 * - PROACTIVE assistant turn = speaks without a preceding user turn in the
 *   SOURCE script. Suppressing one turn never re-labels later turns.
 * - TURN BUDGET: at most maxUnpromptedTurns proactive assistant turns per
 *   session, with at least minGapTurns EMITTED turns (any role) between
 *   two — adjacent unprompted turns violate any positive gap, and a user
 *   turn between two assistant turns makes the later one prompted, so the
 *   gap binds inside consecutive proactive runs and across them.
 * - TOOL POLICY: deny-list. A denied call comes back as status "error" with
 *   a typed policy result and never reaches the tool layer — the denial is
 *   recorded, not hidden.
 * - THIRD-REJECTION SILENCE: after two user rejections of a suggestion
 *   type, further suggestions of that type are suppressed for the session
 *   (SPEC 4). Rejections only accrue to suggestions the design actually
 *   emitted — you cannot reject a suppressed suggestion.
 * - Suppression stays VISIBLE: the scorer compares the record's turns
 *   against the source script. The RunRecord shape is unchanged (pinned).
 * - Actions attached to a suppressed turn (`afterTurn`) move to the next
 *   kept turn; with none, the action is dropped and reported.
 */

import type { SessionScript, ScriptTurn, ScriptUserAction } from "../fakeModel.js";
import type { LeChefRuntime } from "../runtime.js";
import { buildSessionWorld, runSession, type RunRecord, type SessionWorld } from "./harness.js";
import { defaultIsRejection, type LeChefDesign } from "../designs/contract.js";

export interface GateResult {
  readonly script: SessionScript;
  readonly suppressed: readonly { readonly turn: number; readonly because: string }[];
  readonly remappedActions: readonly { readonly from: number; readonly to: number }[];
  readonly droppedActions: readonly { readonly afterTurn: number; readonly action: ScriptUserAction }[];
}

/** Pure turn/action gate — runDesignSession applies it before replay. */
export function gateScript(source: SessionScript, design: LeChefDesign): GateResult {
  const isRejection = design.isRejection ?? defaultIsRejection;
  const turns: ScriptTurn[] = [];
  const suppressed: { turn: number; because: string }[] = [];
  const remappedActions: { from: number; to: number }[] = [];
  const droppedActions: { afterTurn: number; action: ScriptUserAction }[] = [];

  let unpromptedKept = 0;
  let turnsSinceUnprompted = Number.POSITIVE_INFINITY;
  let sourcePrevRole: "user" | "assistant" | null = null;
  let lastSuggestion: string | null = null;
  const rejections = new Map<string, number>();

  const sorted = [...source.turns].sort((a, b) => a.i - b.i);
  for (const turn of sorted) {
    const proactive = turn.role === "assistant" && (turn.proactive ?? sourcePrevRole !== "user");

    if (turn.role === "user") {
      if (lastSuggestion !== null && isRejection(turn)) {
        rejections.set(lastSuggestion, (rejections.get(lastSuggestion) ?? 0) + 1);
      }
      lastSuggestion = null;
      if (turnsSinceUnprompted !== Number.POSITIVE_INFINITY) turnsSinceUnprompted += 1;
      turns.push(turn);
      sourcePrevRole = "user";
      continue;
    }

    const suggestion = design.suggestionType?.(turn) ?? null;
    let suppressBecause: string | null = null;
    if (suggestion !== null && (rejections.get(suggestion) ?? 0) >= 2) {
      suppressBecause = "suggestion-type-silenced";
    } else if (proactive) {
      if (unpromptedKept >= design.turnBudget.maxUnpromptedTurns) {
        suppressBecause = "budget-exhausted";
      } else if (turnsSinceUnprompted < design.turnBudget.minGapTurns) {
        suppressBecause = "min-gap";
      }
    }

    if (suppressBecause !== null) {
      suppressed.push({ turn: turn.i, because: suppressBecause });
      lastSuggestion = null;
      sourcePrevRole = "assistant";
      continue;
    }

    if (proactive) {
      unpromptedKept += 1;
      turnsSinceUnprompted = 0;
    } else if (turnsSinceUnprompted !== Number.POSITIVE_INFINITY) {
      turnsSinceUnprompted += 1;
    }
    turns.push(proactive ? { ...turn, proactive: true } : turn);
    lastSuggestion = suggestion;
    sourcePrevRole = "assistant";
  }

  const keptIdx = new Set(turns.map((t) => t.i));
  const userActions: { afterTurn: number; action: ScriptUserAction }[] = [];
  for (const ua of source.userActions ?? []) {
    if (keptIdx.has(ua.afterTurn)) {
      userActions.push(ua);
      continue;
    }
    const next = turns
      .map((t) => t.i)
      .filter((i) => i > ua.afterTurn)
      .sort((a, b) => a - b)[0];
    if (next === undefined) {
      droppedActions.push({ afterTurn: ua.afterTurn, action: ua.action });
      continue;
    }
    remappedActions.push({ from: ua.afterTurn, to: next });
    userActions.push({ afterTurn: next, action: ua.action });
  }

  const script: SessionScript = {
    ...source,
    design: design.id,
    turns,
    ...(userActions.length > 0 ? { userActions } : {})
  };
  return { script, suppressed, remappedActions, droppedActions };
}

function policyDenial(design: LeChefDesign, name: string, proactive: boolean): string | null {
  for (const rule of design.toolPolicy) {
    const toolMatch = rule.tools === "*" || rule.tools.includes(name);
    const whenMatch = rule.when === "any" || (rule.when === "proactive" ? proactive : !proactive);
    if (toolMatch && whenMatch) return rule.reason;
  }
  return null;
}

/** Wraps a base runtime: denied calls error at the dispatch boundary, everything else passes through. */
export function wrapWithPolicy(base: LeChefRuntime, design: LeChefDesign): LeChefRuntime {
  let proactive = false;
  return {
    reads: base.reads,
    proposals: base.proposals,
    safety: base.safety,
    substitution: base.substitution,
    onTurnStart: (turn) => {
      proactive = turn.proactive;
    },
    dispatch: (call, abort) => {
      const denial = policyDenial(design, call.name, proactive);
      if (denial !== null) {
        return {
          id: call.id,
          name: call.name,
          args: call.args ?? {},
          result: { error: "policy-denied", deniedBy: design.id, reason: denial },
          status: "error"
        };
      }
      return base.dispatch(call, abort);
    }
  };
}

/** Gate a script through a design and replay it on its own deterministic world. */
export function runDesignSession(source: SessionScript, design: LeChefDesign): RunRecord {
  const gated = gateScript(source, design);
  const world = buildSessionWorld(gated.script);
  const runtime = wrapWithPolicy(world.runtime, design);
  const gatedWorld: SessionWorld = {
    clock: world.clock,
    phone: world.phone,
    ...(world.camera !== undefined ? { camera: world.camera } : {}),
    runtime
  };
  return runSession(gated.script, gatedWorld);
}
