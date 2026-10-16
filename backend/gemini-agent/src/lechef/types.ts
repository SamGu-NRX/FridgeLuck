/**
 * LeChef tool layer — domain types.
 *
 * Ownership boundary (SPEC 2, §8): the phone is authoritative for pantry,
 * cook sessions and logs. This layer only ever READS bounded snapshot views
 * the phone hands out, and only ever PROPOSES typed actions. The phone
 * checks revision and approval, executes at most once, and returns a
 * receipt. Nothing in this directory executes an action on its own.
 *
 * Timestamps (SPEC §8.1, canonized): wire and contract-fixture timestamps
 * are ISO-8601 strings with millisecond precision ("2026-10-15T18:22:31.000Z").
 * EpochSeconds (integer seconds) is used ONLY for phone-owned deadline
 * arithmetic (ActiveTimer.deadline). Evaluation-layer artefacts (RunRecords,
 * session scripts) also use ISO-8601 strings.
 *
 * Wire shapes and payload kinds are pinned by docs/spec/lechef/contracts/
 * (proposal.schema.json, receipt.schema.json) — the machine-checked contract
 * this layer mirrors. requiredApproval and userInitiation are DERIVED audit
 * annotations: the model cannot write a claim of consent, and the phone
 * derives its own approval policy from its own evidence.
 */

/** Injected clock. Real hosts use the system clock; tests and fakes inject a controllable one. */
export interface Clock {
  nowMs(): number;
}

export const systemClock: Clock = { nowMs: () => Date.now() };

// ---------------------------------------------------------------------------
// Timestamps — ISO-8601 ms on the wire
// ---------------------------------------------------------------------------

/**
 * Canonical wire timestamp: ISO-8601 UTC with millisecond precision,
 * exactly the contract schemas' `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z` form.
 */
export function isoFromMs(ms: number): string {
  if (!Number.isFinite(ms)) throw new Error(`isoFromMs: not a finite number: ${ms}`);
  return new Date(ms).toISOString();
}

/** Parse an ISO-8601 ms timestamp to epoch ms; null when malformed or off the wire form. */
export function msFromIso(value: unknown): number | null {
  if (typeof value !== "string") return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(value)) return null;
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  // Reject calendar rollovers (2026-02-30 must not become March 2).
  const back = new Date(ms).toISOString();
  const [cal] = value.split(".");
  if (!back.startsWith(cal.slice(0, 10))) return null;
  return ms;
}

// ---------------------------------------------------------------------------
// Quantities and pantry
// ---------------------------------------------------------------------------

export type Quantity =
  | { readonly kind: "known"; readonly value: number; readonly unit: string }
  | { readonly kind: "unknown" };

/** A per-item confirmation source. Scans observe; receipts and manual entry add (SPEC 3.2). */
export type InventorySource = "scan" | "receipt" | "manual";

/**
 * Pantry line states, per SPEC 3.2. `assumed-staple` means a staple counted
 * as present on assumption, not on evidence; `needs-reconfirming` means the
 * evidence is stale.
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
  readonly source: InventorySource;
  readonly useSoon?: boolean;
}

/** A bounded pantry view the phone sends; read-only here, authoritative on the phone. */
export interface PantrySnapshot {
  readonly revision: number;
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

/** The wire RecipeRef (contract schemas' $defs/recipeRef). */
export type RecipeRefSource = "catalog" | "user" | "community" | "generated";

export interface RecipeRef {
  readonly source: RecipeRefSource;
  readonly id: string;
  readonly revision: number;
}

// ---------------------------------------------------------------------------
// Cook session
// ---------------------------------------------------------------------------

export interface Eater {
  readonly name?: string;
  /** Explicit restrictions only — allergies and diets; hard filters, never weakened (SPEC 3.3). */
  readonly restrictions: readonly string[];
}

declare const epochSecondsBrand: unique symbol;
/** Integer seconds since the Unix epoch — used ONLY for phone-owned timer deadlines. */
export type EpochSeconds = number & { readonly [epochSecondsBrand]: never };

export function epochSeconds(ms: number): EpochSeconds {
  if (!Number.isFinite(ms)) throw new Error(`epochSeconds: not a finite number: ${ms}`);
  return Math.floor(ms / 1000) as EpochSeconds;
}

/** A device timer row: the deadline is ABSOLUTE wall clock and survives kills (SPEC 4.2). */
export interface ActiveTimer {
  readonly timerId: string;
  readonly label: string;
  /** Phone-owned deadline in integer epoch seconds (SPEC §8.1: the one EpochSeconds use). */
  readonly deadline: EpochSeconds;
  readonly createdAt: string;
  readonly proposalId: string;
}

export type CookSessionState = "planning" | "cooking" | "paused" | "done";
export type CameraMode = "push-to-look" | "continuous";

export interface StepHistoryEntry {
  readonly stepIndex: number;
  readonly at: string;
  readonly action: "advanced" | "moved-back" | "restarted";
}

/**
 * A user command the DEVICE itself observed — a touch on a control, or a
 * voice command transcribed with the transcript toggle on. Device events are
 * phone-authored: the model cannot create, alter, or replay one. They are
 * how user initiation reaches the tool layer: a proposal may cite ONE, and
 * the phone accepts the citation only when the event still exists, is at the
 * current revision, names the same tool, and has not been consumed (one
 * event initiates one action) — SPEC §8.2.
 */
export interface DeviceEvent {
  readonly id: string;
  readonly kind: "user-command";
  /** The proposal tool this command initiates (e.g. proposeTimerStart). */
  readonly command: ProposalTool;
  /** How the device observed the command. A voice source never upgrades meal_log — explicit always. */
  readonly source: "voice" | "touch";
  /** Raw command text for audit, e.g. "start a two minute timer". */
  readonly detail?: string;
  readonly at: string;
  /** The snapshot revision at which the phone recorded the event. */
  readonly revision: number;
}

export interface CookSessionSnapshot {
  readonly recipeId?: string;
  readonly state: CookSessionState;
  readonly currentStepIndex: number;
  readonly eaters: readonly Eater[];
  readonly activeTimers: readonly ActiveTimer[];
  readonly cameraMode: CameraMode;
  /** Phone-side record of recent step moves, for getStepContext. */
  readonly stepHistory?: readonly StepHistoryEntry[];
  /**
   * Live device events the phone has recorded (phone-authored user commands).
   * Only events still valid — consumed events drop out — may be cited as
   * user initiation.
   */
  readonly deviceEvents?: readonly DeviceEvent[];
  readonly offline?: boolean;
}

// ---------------------------------------------------------------------------
// Camera — structurally incapable of a safety verdict (SPEC 3.1)
// ---------------------------------------------------------------------------

/**
 * What a camera look may report. The type has NO field that could carry a
 * safety verdict: a look describes what a picture can show and names what it
 * cannot assess. This holds in both camera modes (SPEC §8.3: cameraLint
 * fails closed on verdict-shaped free text).
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
// Proposals (SPEC §8.1 — the contract-schema envelope)
// ---------------------------------------------------------------------------

/** The nine registered payload kinds: #102's six plus the three spec-added application kinds. */
export type ProposalKind =
  | "timer_start"
  | "timer_adjust"
  | "step_advance"
  | "inventory_correction"
  | "meal_log"
  | "save_note"
  | "plan"
  | "swap"
  | "adaptation";

export const PROPOSAL_KINDS: readonly ProposalKind[] = [
  "timer_start",
  "timer_adjust",
  "step_advance",
  "inventory_correction",
  "meal_log",
  "save_note",
  "plan",
  "swap",
  "adaptation"
];

/** The proposal tools registered in dispatch (SPEC §8.3). One per kind, same suffix. */
export type ProposalTool =
  | "proposeTimerStart"
  | "proposeTimerAdjust"
  | "proposeStepAdvance"
  | "proposeInventoryCorrection"
  | "proposeMealLog"
  | "proposeSaveNote"
  | "proposePlan"
  | "proposeSwap"
  | "proposeAdaptation";

export const PROPOSAL_TOOLS: readonly ProposalTool[] = [
  "proposeTimerStart",
  "proposeTimerAdjust",
  "proposeStepAdvance",
  "proposeInventoryCorrection",
  "proposeMealLog",
  "proposeSaveNote",
  "proposePlan",
  "proposeSwap",
  "proposeAdaptation"
];

/** The eleven reviewed functional roles (contract schemas, substitution.schema.json). */
export type SwapRole =
  | "acid"
  | "aromatic"
  | "binder"
  | "fat"
  | "garnish"
  | "leavening"
  | "liquid"
  | "protein"
  | "sweetener"
  | "thickener"
  | "umami";

/**
 * Typed proposal payloads, per payload.schema.json's nine oneOf branches,
 * each pinned to its envelope kind. `save_note` carries ONLY the
 * confirmation prompt and a saved marker — the note's text never leaves the
 * phone (SPEC §8.3).
 */
export type ProposalPayload =
  | { readonly durationMinutes: number; readonly label?: string } // timer_start
  | { readonly timerId: string; readonly newDurationMinutes?: number } // timer_adjust
  | { readonly stepIndex: number } // step_advance
  | { readonly ingredientId: number; readonly correction: string } // inventory_correction
  | { readonly recipe: RecipeRef } // meal_log
  | { readonly prompt?: string; readonly noteSavedMarker?: boolean } // save_note
  | { readonly dinnerCount: number; readonly constraints?: readonly string[] } // plan
  | {
      readonly originalIngredientId: number;
      readonly substituteIngredientId: number;
      readonly role: SwapRole;
    } // swap
  | { readonly servings?: number; readonly change: string }; // adaptation

/**
 * Who must approve before the phone executes (SPEC §8.2, #102's RequiredApproval).
 * - `device-auto`: only for timer proposals whose cited DeviceEvent the phone
 *   validated (phone-recorded, unconsumed, current revision, same tool).
 * - `explicit`: executed only after an explicit user action on the device.
 * A voice transcript alone never authorizes a meal log — meal_log is ALWAYS
 * `explicit`. This field is a DERIVED audit annotation; the phone decides
 * approval from its own policy and evidence, never from this field's say-so.
 */
export type RequiredApproval = "explicit" | "device-auto";

/** The wire envelope, field-for-field the contract schema's required set. */
export interface ActionProposalWire {
  readonly proposalID: string;
  readonly createdAt: string; // ISO-8601 ms
  readonly expiresAt: string; // ISO-8601 ms; createdAt + TTL
  readonly payloadHash: string; // sha256:<64 hex> over compact canonical JSON of payload
  readonly kind: ProposalKind;
  readonly payload: ProposalPayload;
  readonly rationale: string; // <= 280 chars
  readonly requiredApproval: RequiredApproval;
}

/** TTL for every proposal: expiresAt = createdAt + 300 s, checked at approval time (SPEC §8.1). */
export const PROPOSAL_TTL_SECONDS = 300;

// ---------------------------------------------------------------------------
// Receipts (SPEC §8.2 — the contract-schema shape)
// ---------------------------------------------------------------------------

export type ReceiptState = "executed" | "rejected" | "expired" | "cancelled";

/** LeChef's additive audit extension on swap/adaptation receipts (SPEC §8.2; verdict per §6). */
export interface AllergenRecheck {
  readonly verdict: "verified" | "plausible" | "unknown" | "unsupported";
  readonly eaters: readonly string[];
  /** e.g. "Contains wheat via soy sauce" when blocked. */
  readonly blockedPath?: string | null;
}

export interface ActionReceiptWire {
  readonly proposalID: string;
  readonly payloadHash: string;
  readonly snapshotRevision: number; // >= 1
  readonly state: ReceiptState;
  readonly recordedAt: string; // ISO-8601 ms
  /** Additive failure/detail string: already_resolved, superseded, payload hash mismatch, expired... */
  readonly reason?: string;
  readonly allergenRecheck?: AllergenRecheck;
}

// ---------------------------------------------------------------------------
// Food safety
// ---------------------------------------------------------------------------

declare const celsiusBrand: unique symbol;
/** Degrees Celsius — doneness temperatures. Kept apart from plain numbers. */
export type Celsius = number & { readonly [celsiusBrand]: never };
export function celsius(value: number): Celsius {
  return value as Celsius;
}

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

export type SubstitutionAnswer =
  | {
      readonly kind: "reviewed-table";
      readonly to: string;
      /** Describes the difference — never promises "no change" (SPEC 3.1). */
      readonly differenceNote: string;
      readonly ratio?: string;
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

export interface SubstitutionSwap {
  readonly from: string;
  readonly to: string;
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

export interface RecipeCandidate {
  readonly recipeId: string;
  readonly revision: number;
  readonly title?: string;
  readonly fit: RecipeFit;
}
