/**
 * Proposal tools — the ONLY way this layer asks the phone to change anything
 * (SPEC 4). Each propose* tool creates an ActionProposal in state `proposed`
 * and nothing else. Proposing never executes; the only execution path is the
 * phone executor receiving an approval (device-auto per the phone's timer
 * rule, or a scripted/real explicit user action).
 *
 * Rules implemented here:
 * - mealLog ALWAYS requires `explicit` — a voice transcript alone never
 *   authorizes a meal log.
 * - Timer proposals are `device-auto` only when they replay a direct user
 *   command the device recorded (a cited device event); anything the model does on its own
 *   initiative is `explicit`.
 * - payloadHash = sha256 over canonical JSON of the payload (wire.ts).
 * - Idempotency: duplicate tool-call ids, or identical payloads, never
 *   produce a second live proposal — dedupe by call id first, then by
 *   (tool, payloadHash).
 * - A cancelled call never reaches the phone: the abort is checked right
 *   before submission.
 */

import type {
  ActionProposal,
  ActionReceipt,
  Clock,
  CookSessionSnapshot,
  NoteScope,
  PantrySnapshot,
  PantryLineState,
  ProposalPayload,
  ProposalTool,
  Quantity,
  RequiredApproval,
  SubstitutionSwap
} from "./types.js";
import { PROPOSAL_TTL_SECONDS, epochSeconds } from "./types.js";
import { payloadHash } from "./wire.js";

/** The phone surface the proposal layer needs. FakePhone implements it; the real client will too. */
export interface PhoneExecutor {
  revision(): number;
  pantrySnapshot(): PantrySnapshot;
  sessionSnapshot(): CookSessionSnapshot;
  submitProposal(proposal: ActionProposal): void;
  receiptFor(proposalId: string): ActionReceipt | undefined;
}

/** Cancellation probe checked before a proposal is submitted (cancelled calls never reach the phone). */
export interface AbortCheck {
  aborted(): boolean;
}

export const noAbort: AbortCheck = { aborted: () => false };

export interface ProposalOutcome {
  readonly proposal: ActionProposal | null;
  /** Current lifecycle state of the proposal (or of the original for duplicates). */
  readonly state: "proposed" | "approved" | "executed" | "rejected" | "cancelled" | "expired";
  readonly receipt?: ActionReceipt;
  /** Set when this call was deduplicated onto an earlier proposal. */
  readonly duplicateOf?: string;
  /** Machine-readable note for the model/harness (why nothing was proposed, etc.). */
  readonly note?: string;
}

export interface ProposalLayer {
  proposeTimerStart(input: {
    callId: string;
    label: string;
    minutes: number;
    /** Device event the runtime validated as user initiation — never an asserted flag. */
    userInitiation?: { eventId: string };
    abort?: AbortCheck;
  }): ProposalOutcome;
  proposeTimerAdjust(input: {
    callId: string;
    timerId?: string;
    label?: string;
    newMinutes?: number;
    deltaMinutes?: number;
    /** Device event the runtime validated as user initiation — never an asserted flag. */
    userInitiation?: { eventId: string };
    abort?: AbortCheck;
  }): ProposalOutcome;
  proposeStepAdvance(input: { callId: string; stepIndex: number; abort?: AbortCheck }): ProposalOutcome;
  proposeInventoryCorrection(input: {
    callId: string;
    ingredientId: string;
    name: string;
    observedQuantity?: Quantity;
    observedState?: PantryLineState;
    reason: string;
    abort?: AbortCheck;
  }): ProposalOutcome;
  proposeMealLog(input: {
    callId: string;
    /** Device event the runtime validated (a "log this meal" command) — recorded fact, never authority. */
    userInitiation?: { eventId: string };
    recipeId: string;
    revision: number;
    servings: number;
    swaps?: readonly SubstitutionSwap[];
    sourcedFrom: "voice" | "screen";
    note?: string;
    abort?: AbortCheck;
  }): ProposalOutcome;
  proposeSaveNote(input: {
    callId: string;
    text: string;
    scope: NoteScope;
    abort?: AbortCheck;
  }): ProposalOutcome;
  /** All proposals created this session, in creation order. */
  proposals(): readonly ActionProposal[];
  /** Latest known state for a proposal id. */
  stateOf(proposalId: string): ProposalOutcome["state"];
}

export interface ProposalLayerOptions {
  clock: Clock;
  phone: PhoneExecutor;
  /** Proposal id prefix (tests pass a fixed prefix for deterministic ids). */
  idPrefix?: string;
}

export function createProposalLayer(options: ProposalLayerOptions): ProposalLayer {
  const { clock, phone } = options;
  const idPrefix = options.idPrefix ?? "proposal";
  let seq = 0;
  const created: ActionProposal[] = [];
  /** callId → proposal id, for call-id dedupe. */
  const byCallId = new Map<string, string>();
  /** (tool, payloadHash) → proposal id, for payload dedupe (call id checked first). */
  const byPayload = new Map<string, string>();
  /**
   * Dedupe scope disclosure (review fix 2): these maps are in-memory per
   * proposal-layer session — a layer restart forgets them. The authority
   * against re-execution is the phone: it refuses replayed approvals and
   * resubmitted consumed proposal ids with receipts (approve/submitProposal),
   * and a real phone client persists its receipt log across sessions, so a
   * replayed id is refused at the phone even when the layer's maps reset.
   */
  /** proposal id → last known state. */
  const states = new Map<string, ProposalOutcome["state"]>();

  /**
   * Advisory only: what the built proposal CLAIMS. The phone decides approval
   * from its own policy and its own evidence (the cited device event), and
   * never executes on this field's say-so. userInitiated here is derived from
   * a validated device-event citation, not from tool arguments.
   */
  function approvalFor(tool: ProposalTool, payload: ProposalPayload, userInitiated: boolean): RequiredApproval {
    if (payload.kind === "mealLog") return "explicit"; // a voice transcript alone never authorizes a meal log
    if (payload.kind === "timerStart" || payload.kind === "timerAdjust") {
      // device-auto applies only to the phone's timer rule replaying a direct user command.
      return userInitiated ? "device-auto" : "explicit";
    }
    return "explicit";
  }

  function setState(id: string, state: ProposalOutcome["state"]): void {
    states.set(id, state);
  }

  function refreshFromReceipt(id: string): ProposalOutcome["state"] | undefined {
    const receipt = phone.receiptFor(id);
    if (receipt) {
      setState(id, receipt.state);
      return receipt.state;
    }
    return undefined;
  }

  function buildProposal(
    tool: ProposalTool,
    payload: ProposalPayload,
    userInitiation?: { eventId: string }
  ): ActionProposal {
    const nowS = epochSeconds(clock.nowMs());
    return {
      id: `${idPrefix}-${String(++seq).padStart(4, "0")}`,
      tool,
      payload,
      payloadHash: payloadHash(payload),
      snapshotRevision: phone.revision(),
      createdAt: nowS,
      expiresAt: epochSeconds(clock.nowMs() + PROPOSAL_TTL_SECONDS * 1000),
      requiredApproval: approvalFor(tool, payload, userInitiation !== undefined),
      userInitiated: userInitiation !== undefined,
      ...(userInitiation !== undefined ? { userInitiation } : {})
    };
  }

  /**
   * Shared path for every propose* tool: dedupe → entry abort check → build →
   * pre-submit abort check → submit → report state. A cancelled call never
   * reaches the phone and leaves no dedupe trace, so a retry of the same call
   * id may propose fresh.
   */
  function propose(
    tool: ProposalTool,
    payload: ProposalPayload,
    args: { callId: string; userInitiation?: { eventId: string }; abort?: AbortCheck }
  ): ProposalOutcome {
    const { callId, userInitiation } = args;

    // 1. Dedupe by tool-call id: this exact call already produced a proposal.
    const sameCall = byCallId.get(callId);
    if (sameCall) {
      refreshFromReceipt(sameCall);
      const original = created.find((p) => p.id === sameCall) ?? null;
      const state = states.get(sameCall) ?? "proposed";
      return {
        proposal: original,
        state,
        ...(original && phone.receiptFor(sameCall) ? { receipt: phone.receiptFor(sameCall) } : {}),
        duplicateOf: sameCall,
        note: "duplicate tool call id — the earlier proposal stands, no second proposal was created"
      };
    }

    // 2. Dedupe by (tool, payloadHash): an identical payload never becomes a second live proposal.
    const h = payloadHash(payload);
    const payloadKey = `${tool}:${h}`;
    const samePayload = byPayload.get(payloadKey);
    if (samePayload) {
      refreshFromReceipt(samePayload);
      const original = created.find((p) => p.id === samePayload) ?? null;
      const state = states.get(samePayload) ?? "proposed";
      byCallId.set(callId, samePayload);
      return {
        proposal: original,
        state,
        ...(original && phone.receiptFor(samePayload) ? { receipt: phone.receiptFor(samePayload) } : {}),
        duplicateOf: samePayload,
        note: "identical payload already proposed — no second proposal was created"
      };
    }

    // 3. Cancellation at entry: the call was aborted before anything was built.
    if (args.abort?.aborted()) {
      return {
        proposal: null,
        state: "cancelled",
        note: "call cancelled — no proposal was created and nothing reached the phone"
      };
    }

    const proposal = buildProposal(tool, payload, userInitiation);

    // 4. Cancellation at the point of no return: after hashing, before submit.
    if (args.abort?.aborted()) {
      return {
        proposal: null,
        state: "cancelled",
        note: "call cancelled before submission — no proposal was created and nothing reached the phone"
      };
    }

    // 5. Submit. The phone files it; execution happens only via approval there.
    phone.submitProposal(proposal);
    created.push(proposal);
    byCallId.set(callId, proposal.id);
    byPayload.set(payloadKey, proposal.id);
    const receipt = phone.receiptFor(proposal.id);
    const state = receipt ? receipt.state : "proposed";
    setState(proposal.id, state);
    return { proposal, state, ...(receipt ? { receipt } : {}) };
  }

  function requireTimerId(input: { timerId?: string; label?: string }): { timerId: string } | { error: ProposalOutcome } {
    if (input.timerId) return { timerId: input.timerId };
    if (input.label) {
      const match = phone
        .sessionSnapshot()
        .activeTimers.find((t) => t.label.toLowerCase() === input.label!.toLowerCase());
      if (match) return { timerId: match.timerId };
      return {
        error: {
          proposal: null,
          state: "cancelled",
          note: `no active timer labeled "${input.label}" — name an active timer or pass its id`
        }
      };
    }
    return {
      error: {
        proposal: null,
        state: "cancelled",
        note: "proposeTimerAdjust needs a timerId (or the label of an active timer)"
      }
    };
  }

  return {
    proposeTimerStart(input) {
      if (!Number.isFinite(input.minutes) || input.minutes <= 0) {
        return {
          proposal: null,
          state: "cancelled",
          note: `timer minutes must be a positive number, got ${input.minutes}`
        };
      }
      return propose("proposeTimerStart", { kind: "timerStart", label: input.label, minutes: input.minutes }, {
        callId: input.callId,
        userInitiation: input.userInitiation,
        ...(input.abort ? { abort: input.abort } : {})
      });
    },
    proposeTimerAdjust(input) {
      const resolved = requireTimerId(input);
      if ("error" in resolved) return resolved.error;
      const target =
        input.newMinutes !== undefined
          ? ({ kind: "set", newMinutes: input.newMinutes } as const)
          : ({ kind: "delta", deltaMinutes: input.deltaMinutes ?? 0 } as const);
      return propose(
        "proposeTimerAdjust",
        { kind: "timerAdjust", timerId: resolved.timerId, target },
        { callId: input.callId, userInitiation: input.userInitiation, ...(input.abort ? { abort: input.abort } : {}) }
      );
    },
    proposeStepAdvance(input) {
      return propose("proposeStepAdvance", { kind: "stepAdvance", stepIndex: input.stepIndex }, {
        callId: input.callId,
        userInitiation: undefined,
        ...(input.abort ? { abort: input.abort } : {})
      });
    },
    proposeInventoryCorrection(input) {
      const observed =
        input.observedQuantity !== undefined
          ? ({ kind: "quantity", quantity: input.observedQuantity } as const)
          : ({ kind: "state", state: input.observedState ?? "quantity-unknown" } as const);
      return propose(
        "proposeInventoryCorrection",
        {
          kind: "inventoryCorrection",
          ingredientId: input.ingredientId,
          name: input.name,
          observed,
          reason: input.reason
        },
        { callId: input.callId, userInitiation: undefined, ...(input.abort ? { abort: input.abort } : {}) }
      );
    },
    proposeMealLog(input) {
      return propose(
        "proposeMealLog",
        {
          kind: "mealLog",
          recipeId: input.recipeId,
          revision: input.revision,
          servings: input.servings,
          swaps: input.swaps ?? [],
          sourcedFrom: input.sourcedFrom,
          ...(input.note !== undefined ? { note: input.note } : {})
        },
        { callId: input.callId, userInitiation: input.userInitiation, ...(input.abort ? { abort: input.abort } : {}) }
      );
    },
    proposeSaveNote(input) {
      return propose("proposeSaveNote", { kind: "note", text: input.text, scope: input.scope }, {
        callId: input.callId,
        userInitiation: undefined,
        ...(input.abort ? { abort: input.abort } : {})
      });
    },
    proposals() {
      return [...created];
    },
    stateOf(proposalId) {
      refreshFromReceipt(proposalId);
      return states.get(proposalId) ?? "cancelled";
    }
  };
}
