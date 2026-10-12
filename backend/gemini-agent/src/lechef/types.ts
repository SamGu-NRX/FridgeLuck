/**
 * LeChef shared tool layer — domain types.
 *
 * Ownership boundary: the phone is authoritative for pantry, cook sessions
 * and logs (SPEC 4). This module only ever READS bounded snapshot views the
 * phone hands out, and only ever PROPOSES typed actions. The phone checks
 * revision and approval, executes, and returns a receipt. Nothing in this
 * directory executes an action on its own.
 *
 * Timestamps: device/wire timestamps (proposal createdAt/expiresAt, receipt
 * recordedAt, pantry confirmations, timer deadlines) are integer epoch
 * SECONDS — that is what the FLDomain fixture contract on
 * origin/overhaul/core-foundation encodes (action-proposal.json carries
 * `813412800`, not an ISO string). Evaluation-layer timestamps (RunRecord
 * events, session scripts) are ISO 8601 strings. See lechef/README.md,
 * "Timestamps".
 */

declare const epochSecondsBrand: unique symbol;
/** Integer seconds since the Unix epoch — the FLDomain wire unit for dates. */
export type EpochSeconds = number & { readonly [epochSecondsBrand]: never };

/** Convert a millisecond clock reading to the wire's epoch-seconds unit. */
export function epochSeconds(ms: number): EpochSeconds {
  if (!Number.isFinite(ms)) throw new Error(`epochSeconds: not a finite number: ${ms}`);
  return Math.floor(ms / 1000) as EpochSeconds;
}

/**
 * Brand an integer that is ALREADY in epoch seconds — wire values from the
 * phone/fixtures. Distinct from {@link epochSeconds}, which converts a
 * millisecond clock reading; running a wire value through that one silently
 * divides it by 1000.
 */
export function epochSecondsFromWire(seconds: number): EpochSeconds {
  if (!Number.isInteger(seconds)) throw new Error(`epochSecondsFromWire: expected integer epoch seconds: ${seconds}`);
  return seconds as EpochSeconds;
}

declare const celsiusBrand: unique symbol;
/** Degrees Celsius — doneness temperatures. Kept apart from plain numbers. */
export type Celsius = number & { readonly [celsiusBrand]: never };
export function celsius(value: number): Celsius {
  return value as Celsius;
}

/** Injected clock. Real hosts use the system clock; tests and the fake phone inject a controllable one. */
export interface Clock {
  nowMs(): number;
}

export const systemClock: Clock = { nowMs: () => Date.now() };

// ---------------------------------------------------------------------------
// Quantities
// ---------------------------------------------------------------------------

export type Quantity =
  | { readonly kind: "known"; readonly value: number; readonly unit: string }
  | { readonly kind: "unknown" };

/** A per-item confirmation source. Scans observe; receipts and manual entry add (SPEC 3.2). */
export type InventorySource = "scan" | "receipt" | "manual";

/**
 * Pantry line states, per SPEC 3.2. `assumed-staple` means a staple (oil,
 * salt, ...) counted as present on assumption, not on evidence;
 * `needs-reconfirming` means the evidence is stale.
 */
export type PantryLineState =
  | "sufficient"
  | "short"
  | "quantity-unknown"
  | "assumed-staple"
  | "needs-reconfirming";

export interface PantryLine {
  readonly ingredientId: string;
  readonly name: string;
  readonly quantity: Quantity;
  readonly state: PantryLineState;
  /** Present when state is "short": the shortfall in the line's own unit. */
  readonly shortBy?: number;
  readonly lastConfirmedAt?: EpochSeconds;
  readonly source: InventorySource;
  readonly useSoon?: boolean;
  readonly expiresAt?: EpochSeconds;
}

/** A bounded pantry view the phone sends; the phone is authoritative, this is read-only. */
export interface PantrySnapshot {
  readonly revision: number;
  readonly capturedAt: EpochSeconds;
  readonly items: readonly PantryLine[];
}

// ---------------------------------------------------------------------------
// Recipe context
// ---------------------------------------------------------------------------

export interface RecipeBillLine {
  readonly ingredientId: string;
  readonly name: string;
  readonly quantity: Quantity;
  /** Optional garnish lines are computed separately and never block the fit line (SPEC 3.2). */
  readonly optional?: boolean;
}

export interface RecipeStep {
  readonly index: number;
  readonly text: string;
  readonly timerMinutes?: number;
  /** Doneness target named by the recipe (e.g. "chicken"), used by checkFoodSafety. */
  readonly safetyCheckTarget?: string;
}

export interface RecipeContext {
  readonly id: string;
  readonly revision: number;
  readonly title?: string;
  readonly servings: number;
  readonly ingredientBill: readonly RecipeBillLine[];
  readonly steps: readonly RecipeStep[];
}

// ---------------------------------------------------------------------------
// Cook session
// ---------------------------------------------------------------------------

export interface Eater {
  readonly name?: string;
  /** Explicit restrictions only — allergies and diets; hard filters, never weakened (SPEC 3.3). */
  readonly restrictions: readonly string[];
}

export interface ActiveTimer {
  readonly timerId: string;
  readonly label: string;
  readonly minutes: number;
  readonly createdAt: EpochSeconds;
  /** Device-owned deadline in epoch seconds; survives kills and session drops. */
  readonly deadline: EpochSeconds;
  readonly proposalId: string;
}

export type CookSessionState = "planning" | "cooking" | "paused" | "done";
export type CameraMode = "push-to-look" | "continuous";

export interface StepHistoryEntry {
  readonly stepIndex: number;
  readonly at: EpochSeconds;
  readonly action: "advanced" | "moved-back" | "restarted";
}

/**
 * A user command the DEVICE itself observed — a touch on a control, or a
 * voice command transcribed with the transcript toggle on. Device events are
 * phone-authored: the model cannot create, alter, or replay one. They are
 * how user initiation reaches the tool layer: a proposal is user-initiated
 * only when it cites a device event that still exists in the current
 * snapshot (SPEC 4 — the model cannot manufacture approval).
 */
export interface DeviceEvent {
  readonly id: string;
  readonly kind: "user-command";
  /** The proposal tool this command initiates (e.g. proposeTimerStart). */
  readonly command: ProposalTool;
  /** How the device observed the command. A voice source never upgrades mealLog — explicit always. */
  readonly source: "voice" | "touch";
  /** Raw command text for audit, e.g. "start a two minute timer". */
  readonly detail?: string;
  readonly at: EpochSeconds;
  /** The snapshot revision at which the phone recorded the event. */
  readonly revision: number;
}

export interface CookSessionSnapshot {
  /** The recipe this session cooks, when one is loaded (additive; phone-side). */
  readonly recipeId?: string;
  readonly state: CookSessionState;
  readonly currentStepIndex: number;
  readonly eaters: readonly Eater[];
  readonly activeTimers: readonly ActiveTimer[];
  readonly cameraMode: CameraMode;
  /** Phone-side record of recent step moves, for getStepContext. */
  readonly stepHistory?: readonly StepHistoryEntry[];
  /**
   * Live device events the phone has recorded (phone-authored user commands;
   * see DeviceEvent). Only events still valid — consumed events drop out —
   * and only these may be cited as user initiation.
   */
  readonly deviceEvents?: readonly DeviceEvent[];
}

// ---------------------------------------------------------------------------
// Camera — structurally incapable of a safety verdict (SPEC 3.1)
// ---------------------------------------------------------------------------

/**
 * What a camera look may report. The type has NO field that could carry a
 * safety verdict: a look describes what a picture can show and names what it
 * cannot assess. This holds in both camera modes.
 */
export interface CameraObservation {
  readonly observed: readonly string[];
  readonly cannotAssess: readonly string[];
  readonly framesSent: number;
  readonly clipSeconds: number;
}

// ---------------------------------------------------------------------------
// Evidence and the read-tool envelope
// ---------------------------------------------------------------------------

export type EvidenceKind =
  | "pantry-line"
  | "recipe-bill"
  | "fsis-table"
  | "substitution-table"
  | "absent-table"
  | "device-observation"
  | "session-state"
  | "acceptance-record";

export interface Evidence {
  readonly kind: EvidenceKind;
  /** What the evidence points at: an ingredientId, a source name, a revision... */
  readonly ref: string;
  readonly detail?: string;
}

/**
 * Every read tool returns its result fields PLUS this envelope. Unknowns are
 * explicit, never silent: if the layer does not know, it says so in `unknowns`.
 */
export interface ToolEnvelope {
  readonly evidence: readonly Evidence[];
  readonly unknowns: readonly string[];
}

export type ReadToolResult<T> = T & ToolEnvelope;

// ---------------------------------------------------------------------------
// Proposals and receipts (wire contract per FLDomain fixtures)
// ---------------------------------------------------------------------------

export type ProposalTool =
  | "proposeTimerStart"
  | "proposeTimerAdjust"
  | "proposeStepAdvance"
  | "proposeInventoryCorrection"
  | "proposeMealLog"
  | "proposeSaveNote";

export type TimerAdjustTarget =
  | { readonly kind: "set"; readonly newMinutes: number }
  | { readonly kind: "delta"; readonly deltaMinutes: number };

export type ProposalPayload =
  | { readonly kind: "timerStart"; readonly label: string; readonly minutes: number }
  | { readonly kind: "timerAdjust"; readonly timerId: string; readonly target: TimerAdjustTarget }
  | { readonly kind: "stepAdvance"; readonly stepIndex: number }
  | {
      readonly kind: "inventoryCorrection";
      readonly ingredientId: string;
      readonly name: string;
      readonly observed:
        | { readonly kind: "quantity"; readonly quantity: Quantity }
        | { readonly kind: "state"; readonly state: PantryLineState; readonly shortBy?: number };
      readonly reason: string;
    }
  | {
      readonly kind: "mealLog";
      readonly recipeId: string;
      readonly revision: number;
      readonly servings: number;
      readonly swaps: readonly SubstitutionSwap[];
      readonly sourcedFrom: "voice" | "screen";
      readonly note?: string;
    }
  | { readonly kind: "note"; readonly text: string; readonly scope: NoteScope };

export type NoteScope = "cook" | "recipe";

export interface SubstitutionSwap {
  readonly from: string;
  readonly to: string;
}

/**
 * Who must approve before the phone executes.
 * - `device-auto`: the phone's own timer rule may execute without a user tap
 *   (timers only). Everything else requires an explicit user action.
 * - `explicit`: executed only after a scripted/real user approval on the device.
 * A voice transcript alone never authorizes a meal log — mealLog is always
 * `explicit` (SPEC 4).
 */
export type RequiredApproval = "device-auto" | "explicit";

/** Lifecycle states recorded by the evaluation layer. */
export type ProposalState =
  | "proposed"
  | "approved"
  | "executed"
  | "rejected"
  | "cancelled"
  | "expired";

/**
 * The module's proposal record: the FLDomain wire shape plus additive fields
 * the phone needs (`requiredApproval`, `userInitiated`, `userInitiation`).
 * The wire serializer emits the additive fields only when present, so a
 * round-trip of the frozen fixtures stays byte-identical (see wire.ts).
 *
 * Authority note (SPEC 4): `requiredApproval` and `userInitiated` on this
 * record are CLAIMS for audit/display. Execution authority is decided by the
 * phone from its own policy and its own evidence — for device-auto, the
 * cited device event in `userInitiation`. The phone never executes on the
 * strength of these fields alone.
 */
export interface ActionProposal {
  readonly id: string;
  readonly tool: ProposalTool;
  readonly payload: ProposalPayload;
  readonly payloadHash: string;
  readonly snapshotRevision: number;
  readonly createdAt: EpochSeconds;
  readonly expiresAt: EpochSeconds;
  readonly requiredApproval: RequiredApproval;
  readonly userInitiated: boolean;
  /**
   * The device event cited as user initiation — present only when the
   * proposal was user-initiated through a device event the runtime validated
   * against the snapshot. A proposal without one is never device-auto.
   */
  readonly userInitiation?: { readonly eventId: string };
}

/** Receipt states, exactly as the FLDomain action-receipt.json fixture pins them. */
export type ReceiptState = "executed" | "rejected" | "expired" | "cancelled";

/** Wire receipt, field-for-field the action-receipt.json fixture (note `proposalID`). */
export interface ActionReceipt {
  readonly proposalID: string;
  readonly payloadHash: string;
  readonly snapshotRevision: number;
  readonly state: ReceiptState;
  readonly recordedAt: EpochSeconds;
  /**
   * Why a refusal happened (hash mismatch, superseded revision, replayed
   * approval, resubmitted consumed id). In-module refusals only — the wire
   * serializer emits the fixture's five fields, so this never crosses the wire.
   */
  readonly reason?: string;
}

/** Proposals whose TTL (expiresAt) has passed without execution die as `expired`. */
export const PROPOSAL_TTL_SECONDS = 300;

// ---------------------------------------------------------------------------
// Food safety
// ---------------------------------------------------------------------------

/** A checkable doneness test with a thermometer temperature from a named reviewed source. */
export interface SourcedCheck {
  readonly tool: "checkFoodSafety";
  readonly product: string;
  readonly test: string;
  readonly temperatureC: Celsius;
  readonly temperatureF: number;
  readonly restMinutes?: number;
  readonly source: string;
}

export type FoodSafetyAnswer =
  | { readonly kind: "sourced-check"; readonly check: SourcedCheck }
  | { readonly kind: "unknown"; readonly reason: string };

// ---------------------------------------------------------------------------
// Substitutions
// ---------------------------------------------------------------------------

export interface AllergenRecheck {
  readonly eatersChecked: number;
  /** Empty when every eater clears the substitution, compound ingredients included. */
  readonly violations: readonly string[];
}

export type SubstitutionAnswer =
  | {
      readonly kind: "reviewed-table";
      readonly to: string;
      /** Describes the difference — never promises "no change" (SPEC 3.1). */
      readonly differenceNote: string;
      readonly macroDelta?: string;
      readonly allergenRecheck: AllergenRecheck;
    }
  | {
      /** Table absent or no entry: any reasoning is beyond-table and labelled so (SPEC 3.5). */
      readonly kind: "beyond-table";
      readonly reason: string;
      readonly allergenRecheck: AllergenRecheck;
    };

// ---------------------------------------------------------------------------
// Fit (SPEC 3.2)
// ---------------------------------------------------------------------------

/** Fit-layer state for one recipe bill line, derived from pantry line states. */
export type FitLineState =
  | "sufficient"
  | "short"
  | "quantity-unknown"
  | "assumed-staple"
  | "needs-reconfirming"
  | "missing"
  | "swap-covered";

export interface FitLine {
  readonly ingredientId: string;
  readonly name: string;
  readonly state: FitLineState;
  readonly shortBy?: number;
  readonly swap?: SubstitutionSwap;
}

export interface RecipeFit {
  /** The honest fit line — never a percentage, never "you have everything" unless every line is sufficient. */
  readonly fitLine: string;
  readonly required: readonly FitLine[];
  readonly garnish: readonly FitLine[];
  readonly sufficientCount: number;
  readonly requiredCount: number;
  readonly swapCount: number;
  readonly allSufficient: boolean;
}

export type RecipeCandidateGoal = {
  readonly acceptedSwaps?: readonly SubstitutionSwap[];
};

export interface RecipeCandidate {
  readonly recipeId: string;
  readonly revision: number;
  readonly title?: string;
  readonly fit: RecipeFit;
}
