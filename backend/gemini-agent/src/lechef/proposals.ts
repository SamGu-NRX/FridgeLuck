/**
 * Proposal tools (SPEC §8.3) — re-cut from #102's proposals.ts against the
 * base-branch contract. Nine registered proposal tools, one per payload kind:
 * the six #102 kinds plus the three spec-added application kinds (proposePlan,
 * proposeSwap, proposeAdaptation).
 *
 * Every tool builds a TYPED payload, hashes it (sha256 over compact canonical
 * JSON), wraps it in the contract envelope, and hands it to the phone. The
 * tool NEVER executes anything and NEVER claims consent:
 *
 * - `requiredApproval` is a derived audit annotation. It is "device-auto"
 *   only for timer proposals where the caller cites a device event that — as
 *   far as the tool layer can see — is a phone-recorded user command naming
 *   the same tool at the current revision. The PHONE re-validates the
 *   citation against its own event log at approval time and consumes the
 *   event; the tool's annotation is never authoritative.
 * - meal_log is ALWAYS "explicit": a voice transcript never authorizes a
 *   meal log (SPEC §8.2).
 * - rationale is required and capped at 280 chars (contract schema).
 * - TTL: expiresAt = createdAt + 300 s, pinned (SPEC §8.1).
 *
 * Rejections come back as `submitted: false` with an `issues` list, never as
 * a thrown error across the model boundary.
 */

import type {
  ActionProposalWire,
  ActionReceiptWire,
  Clock,
  CookSessionSnapshot,
  DeviceEvent,
  PantrySnapshot,
  ProposalKind,
  ProposalPayload,
  ProposalTool,
  ReadToolResult,
  RecipeContext,
  RequiredApproval
} from "./types.js";
import { PROPOSAL_TTL_SECONDS, isoFromMs } from "./types.js";
import { kindForTool, payloadIssues, payloadHash, serializeProposal } from "./wire.js";

export type SubmissionResult =
  | ActionReceiptWire
  | { pending: true; proposalID: string; requiredApproval: RequiredApproval; expiresAt: string };

/** The phone executor the tools submit through: bounded reads + proposal submission. */
export interface PhoneExecutor {
  revision(): number;
  pantrySnapshot(): PantrySnapshot;
  sessionSnapshot(): CookSessionSnapshot;
  recipeCatalog(): readonly RecipeContext[];
  /**
   * The phone validates the proposal (hash, TTL, its own approval policy) and
   * either executes it immediately (device-auto) or stages it as pending,
   * awaiting the user's explicit action — the receipt arrives at resolution.
   */
  submitProposal(proposal: ActionProposalWire, userInitiationEventId?: string): SubmissionResult;
  /** A device-mediated camera look; offline the phone returns framesSent: 0. */
  cameraLook(mode: "push-to-look" | "continuous"): {
    readonly observed: readonly string[];
    readonly cannotAssess: readonly string[];
    readonly framesSent: number;
    readonly clipSeconds: number;
  };
}

/** Arguments every proposal tool accepts: the payload fields, a rationale, and an optional device-event citation. */
export interface ProposalArgs {
  readonly rationale?: unknown;
  /** ID of a phone-recorded DeviceEvent the caller cites as user initiation (timer kinds only). */
  readonly userInitiationEventId?: unknown;
  readonly [field: string]: unknown;
}

export type ProposalToolOutcome = ReadToolResult<{
  submitted: boolean;
  proposalID?: string;
  requiredApproval?: RequiredApproval;
  expiresAt?: string;
  /** "pending_explicit_approval" until the user acts; "resolved" carries the receipt. */
  status?: "pending_explicit_approval" | "resolved";
  receipt?: ActionReceiptWire;
  /** Client-side rejection reasons (invalid payload, missing rationale, bad citation). */
  issues?: readonly string[];
}>;

// ---------------------------------------------------------------------------
// Payload builders — kind → typed payload from tool args
// ---------------------------------------------------------------------------

function isFiniteNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function optString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

/**
 * Build the payload for a tool call, or return the client-side issues.
 * The builders coerce nothing silently: wrong types become issues.
 */
function buildPayload(tool: ProposalTool, args: ProposalArgs): { payload?: ProposalPayload; issues: readonly string[] } {
  const issues: string[] = [];
  const kind = kindForTool(tool);
  switch (kind) {
    case "timer_start": {
      const durationMinutes = args["durationMinutes"];
      if (!isFiniteNumber(durationMinutes)) issues.push("durationMinutes: expected a number of minutes (0 < m <= 180)");
      const label = optString(args["label"]);
      return {
        payload: { durationMinutes: durationMinutes as number, ...(label !== undefined ? { label } : {}) },
        issues
      };
    }
    case "timer_adjust": {
      const timerId = optString(args["timerId"]);
      if (timerId === undefined) issues.push("timerId: expected the id of the timer to adjust");
      const newDurationMinutes = args["newDurationMinutes"];
      if (newDurationMinutes !== undefined && !isFiniteNumber(newDurationMinutes)) {
        issues.push("newDurationMinutes: expected a number of minutes (0 < m <= 180)");
      }
      return {
        payload: {
          timerId: timerId as string,
          ...(newDurationMinutes !== undefined ? { newDurationMinutes: newDurationMinutes as number } : {})
        },
        issues
      };
    }
    case "step_advance": {
      const stepIndex = args["stepIndex"];
      if (typeof stepIndex !== "number" || !Number.isInteger(stepIndex) || stepIndex < 0) {
        issues.push("stepIndex: expected a non-negative integer");
      }
      return { payload: { stepIndex: stepIndex as number }, issues };
    }
    case "inventory_correction": {
      const ingredientId = args["ingredientId"];
      if (typeof ingredientId !== "number" || !Number.isInteger(ingredientId)) {
        issues.push("ingredientId: expected the integer id of the pantry line to correct");
      }
      const correction = optString(args["correction"]);
      if (correction === undefined) issues.push("correction: expected a short correction note (<= 120 chars)");
      return { payload: { ingredientId: ingredientId as number, correction: correction as string }, issues };
    }
    case "meal_log": {
      const recipe = args["recipe"];
      if (typeof recipe !== "object" || recipe === null) {
        issues.push("recipe: expected { source, id, revision }");
        return { issues };
      }
      const r = recipe as Record<string, unknown>;
      if (
        typeof r["source"] !== "string" ||
        !["catalog", "user", "community", "generated"].includes(r["source"]) ||
        typeof r["id"] !== "string" ||
        typeof r["revision"] !== "number" ||
        !Number.isInteger(r["revision"]) ||
        (r["revision"] as number) < 1
      ) {
        issues.push("recipe: expected { source: catalog|user|community|generated, id: string, revision: integer >= 1 }");
        return { issues };
      }
      return { payload: { recipe: r as unknown as ProposalPayload extends { recipe: infer R } ? R : never }, issues };
    }
    case "save_note": {
      // The note's TEXT never arrives here and never leaves the phone: the
      // phone saved the note itself; this proposal only confirms it (SPEC §8.3).
      const prompt = optString(args["prompt"]);
      const noteSavedMarker = args["noteSavedMarker"];
      if (noteSavedMarker !== undefined && typeof noteSavedMarker !== "boolean") {
        issues.push("noteSavedMarker: expected a boolean");
      }
      return {
        payload: {
          ...(prompt !== undefined ? { prompt } : {}),
          ...(typeof noteSavedMarker === "boolean" ? { noteSavedMarker } : {})
        },
        issues
      };
    }
    case "plan": {
      const dinnerCount = args["dinnerCount"];
      if (typeof dinnerCount !== "number" || !Number.isInteger(dinnerCount) || dinnerCount < 1 || dinnerCount > 7) {
        issues.push("dinnerCount: expected an integer 1..7");
      }
      const constraints = args["constraints"];
      if (constraints !== undefined && (!Array.isArray(constraints) || constraints.some((c) => typeof c !== "string"))) {
        issues.push("constraints: expected an array of strings");
      }
      return {
        payload: {
          dinnerCount: dinnerCount as number,
          ...(Array.isArray(constraints) ? { constraints: constraints as string[] } : {})
        },
        issues
      };
    }
    case "swap": {
      const originalIngredientId = args["originalIngredientId"];
      const substituteIngredientId = args["substituteIngredientId"];
      const role = args["role"];
      if (typeof originalIngredientId !== "number" || !Number.isInteger(originalIngredientId)) {
        issues.push("originalIngredientId: expected the integer id of the ingredient being swapped out");
      }
      if (typeof substituteIngredientId !== "number" || !Number.isInteger(substituteIngredientId)) {
        issues.push("substituteIngredientId: expected the integer id of the substitute");
      }
      if (typeof role !== "string") {
        issues.push("role: expected one of the eleven reviewed functional roles");
      }
      return {
        payload: {
          originalIngredientId: originalIngredientId as number,
          substituteIngredientId: substituteIngredientId as number,
          role: role as never
        },
        issues
      };
    }
    case "adaptation": {
      const servings = args["servings"];
      const change = optString(args["change"]);
      if (servings !== undefined && (typeof servings !== "number" || !Number.isInteger(servings) || servings < 1 || servings > 12)) {
        issues.push("servings: expected an integer 1..12");
      }
      if (change === undefined) issues.push("change: expected a short description of the adaptation (<= 120 chars)");
      return {
        payload: {
          ...(typeof servings === "number" ? { servings } : {}),
          change: change as string
        },
        issues
      };
    }
  }
}

// ---------------------------------------------------------------------------
// Derived approval annotation
// ---------------------------------------------------------------------------

const TIMER_TOOLS: readonly ProposalTool[] = ["proposeTimerStart", "proposeTimerAdjust"];

/**
 * Find the cited device event, as far as the tool layer can see: it must be a
 * phone-recorded user command naming the same tool, recorded at the current
 * revision, and still live (unconsumed events drop out of the snapshot).
 * The phone re-validates all of this against its own log at approval time.
 */
function citedDeviceEvent(
  session: CookSessionSnapshot,
  tool: ProposalTool,
  eventId: unknown
): DeviceEvent | null {
  if (typeof eventId !== "string" || eventId === "") return null;
  const event = (session.deviceEvents ?? []).find((e) => e.id === eventId);
  if (!event) return null;
  if (event.command !== tool) return null;
  return event;
}

/**
 * The derived audit annotation. device-auto ONLY for timer proposals with a
 * visible, tool-matching, current-revision device event; everything else —
 * including EVERY meal log, voice-initiated or not — is explicit.
 */
function deriveRequiredApproval(
  tool: ProposalTool,
  session: CookSessionSnapshot,
  currentRevision: number,
  event: DeviceEvent | null
): RequiredApproval {
  if (TIMER_TOOLS.includes(tool) && event !== null && event.revision === currentRevision) {
    return "device-auto";
  }
  return "explicit";
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

function newProposalId(nowMs: number, counter: number): string {
  // Content-derived: base36 clock time + per-runtime sequence. Deterministic
  // under the ManualClock (replayable suite records), unique across sessions.
  return `prop_${(nowMs.toString(36) + counter.toString(36)).padStart(12, "0").slice(-12)}`;
}

export type ProposalTools = Readonly<Record<ProposalTool, (args: ProposalArgs) => ProposalToolOutcome>>;

/** Build the nine registered proposal tools over a phone executor and clock. */
export function createProposalTools(deps: { phone: PhoneExecutor; clock: Clock }): ProposalTools {
  const { phone, clock } = deps;
  let idCounter = 0;

  const submit = (tool: ProposalTool, args: ProposalArgs): ProposalToolOutcome => {
    const issues: string[] = [];
    const rationale = typeof args.rationale === "string" ? args.rationale.trim() : "";
    if (rationale.length === 0) issues.push("rationale: required — say briefly why this action is proposed");
    else if (rationale.length > 280) issues.push(`rationale: ${rationale.length} chars, the wire contract caps it at 280`);

    const built = buildPayload(tool, args);
    issues.push(...built.issues);

    const kind = kindForTool(tool);
    if (built.payload !== undefined) {
      issues.push(...payloadIssues(kind, built.payload));
    }

    const session = phone.sessionSnapshot();
    const revision = phone.revision();
    const event = citedDeviceEvent(session, tool, args.userInitiationEventId);
    if (typeof args.userInitiationEventId === "string" && args.userInitiationEventId !== "" && event === null) {
      issues.push(
        "userInitiationEventId: the cited device event is not visible in the session snapshot — proposals without a valid device-event citation need explicit approval"
      );
    }
    const requiredApproval = deriveRequiredApproval(tool, session, revision, event);

    if (issues.length > 0 || built.payload === undefined) {
      return {
        submitted: false,
        issues,
        evidence: [],
        unknowns: []
      };
    }

    const nowMs = clock.nowMs();
    const proposal: ActionProposalWire = {
      proposalID: newProposalId(nowMs, ++idCounter),
      createdAt: isoFromMs(nowMs),
      expiresAt: isoFromMs(nowMs + PROPOSAL_TTL_SECONDS * 1000),
      payloadHash: payloadHash(built.payload),
      kind,
      payload: built.payload,
      rationale,
      requiredApproval
    };

    // The phone is the authority: it re-checks the hash, the TTL, its own
    // approval policy, and (for device-auto) its own event log. An explicit
    // proposal stays pending until the user acts on the device; the receipt
    // arrives at resolution.
    const submission = phone.submitProposal(proposal, event !== null ? event.id : undefined);
    const receipt = "state" in submission ? submission : undefined;
    return {
      submitted: true,
      proposalID: proposal.proposalID,
      requiredApproval,
      expiresAt: proposal.expiresAt,
      ...("pending" in submission && submission.pending === true
        ? { status: "pending_explicit_approval" as const }
        : { status: "resolved" as const, receipt }),
      evidence: [
        { kind: "acceptance-record", ref: proposal.proposalID, detail: serializeProposal(proposal) }
      ],
      unknowns: []
    };
  };

  return Object.fromEntries(
    (
      [
        "proposeTimerStart",
        "proposeTimerAdjust",
        "proposeStepAdvance",
        "proposeInventoryCorrection",
        "proposeMealLog",
        "proposeSaveNote",
        "proposePlan",
        "proposeSwap",
        "proposeAdaptation"
      ] as ProposalTool[]
    ).map((tool) => [tool, (args: ProposalArgs) => submit(tool, args)])
  ) as ProposalTools;
}
