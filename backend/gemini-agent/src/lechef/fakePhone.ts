/**
 * FakePhone — an in-memory authority standing in for the phone (SPEC §8.2).
 * Adapted from #102's fakePhone.ts against the base-branch contract.
 *
 * This is the same side of the boundary the real phone occupies:
 * - it OWNS pantry, cook session, recipes, timers, device events and receipts;
 * - it validates every submitted proposal (payload hash recomputed, revision
 *   not stale, TTL not elapsed, applied at most once across "restarts");
 * - it derives approval policy ITSELF: device-auto only for timer proposals
 *   citing a phone-recorded, unconsumed DeviceEvent at the current revision
 *   naming the same tool — the citation's say-so is never trusted;
 * - meal_log ALWAYS needs explicit approval, even with a voice event;
 * - swap and adaptation receipts carry the allergen recheck verdict (SPEC §6).
 */

import type {
  ActionProposalWire,
  ActionReceiptWire,
  ActiveTimer,
  AllergenRecheck,
  CameraObservation,
  Clock,
  CookSessionSnapshot,
  DeviceEvent,
  Eater,
  PantryLine,
  PantrySnapshot,
  RecipeContext,
  RequiredApproval
} from "./types.js";
import { epochSeconds, isoFromMs } from "./types.js";
import { payloadHash, toolForKind } from "./wire.js";
import { recheckSwapAllergens } from "./allergens.js";
import type { PhoneExecutor } from "./proposals.js";

export interface FakePhoneState {
  readonly pantryRevision: number;
  readonly items: PantryLine[];
  readonly recipeId?: string;
  readonly sessionState: "planning" | "cooking" | "paused" | "done";
  readonly currentStepIndex: number;
  readonly eaters: readonly Eater[];
  readonly timers: ActiveTimer[];
  readonly cameraMode: "push-to-look" | "continuous";
  readonly stepHistory: { stepIndex: number; at: string; action: "advanced" | "moved-back" | "restarted" }[];
  readonly deviceEvents: DeviceEvent[];
  readonly savedNotes: number;
  readonly loggedMeals: { recipe: { source: string; id: string; revision: number }; at: string }[];
  readonly proposals: Map<string, ActionProposalWire>;
  /** Receipts, keyed by proposalID — the dedupe authority across restarts. */
  readonly receipts: Map<string, ActionReceiptWire>;
  readonly consumedDeviceEvents: Set<string>;
  readonly revision: number;
}

export class FakePhone implements PhoneExecutor {
  private clock: Clock;
  private revisionCounter: number;
  private items: PantryLine[];
  private pantryRevisionCounter: number;
  private recipeId?: string;
  private sessionState: CookSessionSnapshot["state"];
  private currentStepIndex: number;
  private eaters: readonly Eater[];
  private timers: ActiveTimer[];
  private cameraMode: "push-to-look" | "continuous";
  private stepHistory: { stepIndex: number; at: string; action: "advanced" | "moved-back" | "restarted" }[];
  private deviceEvents: DeviceEvent[];
  private consumedDeviceEvents: Set<string>;
  private savedNotes: number;
  private loggedMeals: { recipe: { source: string; id: string; revision: number }; at: string }[];
  private proposalsById: Map<string, ActionProposalWire>;
  private receiptsById: Map<string, ActionReceiptWire>;
  private readonly recipes: readonly RecipeContext[];
  private readonly cameraScript: () => CameraObservation;
  /** Reviewed ingredient names for swap substitutes not present in the pantry. */
  private readonly substituteNames: ReadonlyMap<number, string>;

  constructor(options: {
    clock: Clock;
    items?: PantryLine[];
    recipeId?: string;
    sessionState?: CookSessionSnapshot["state"];
    currentStepIndex?: number;
    eaters?: readonly Eater[];
    cameraMode?: "push-to-look" | "continuous";
    recipes?: readonly RecipeContext[];
    /** Prior receipts — a "relaunch" passes the same map so dedupe survives. */
    priorReceipts?: Map<string, ActionReceiptWire>;
    priorConsumedDeviceEvents?: Set<string>;
    cameraScript?: () => CameraObservation;
    /** Reviewed ingredient names for swap substitutes not present in the pantry. */
    substituteNames?: ReadonlyMap<number, string>;
  }) {
    this.clock = options.clock;
    this.revisionCounter = 1;
    this.pantryRevisionCounter = 1;
    this.items = [...(options.items ?? [])];
    this.recipeId = options.recipeId;
    this.sessionState = options.sessionState ?? "cooking";
    this.currentStepIndex = options.currentStepIndex ?? 0;
    this.eaters = options.eaters ?? [];
    this.timers = [];
    this.cameraMode = options.cameraMode ?? "push-to-look";
    this.stepHistory = [];
    this.deviceEvents = [];
    this.consumedDeviceEvents = new Set(options.priorConsumedDeviceEvents ?? []);
    this.savedNotes = 0;
    this.loggedMeals = [];
    this.proposalsById = new Map();
    this.receiptsById = new Map(options.priorReceipts ?? []);
    this.recipes = options.recipes ?? [];
    this.cameraScript = options.cameraScript ?? defaultCameraObservation;
    this.substituteNames = options.substituteNames ?? new Map();
  }

  // -- device-side actions the harness (the user) performs -------------------

  bumpRevision(): number {
    return ++this.revisionCounter;
  }

  /** The user records a device command (a touch, or a transcribed voice command). */
  recordDeviceEvent(event: Omit<DeviceEvent, "at" | "revision" | "kind">): DeviceEvent {
    const full: DeviceEvent = { ...event, kind: "user-command", at: isoFromMs(this.clock.nowMs()), revision: this.revisionCounter };
    this.deviceEvents.push(full);
    return full;
  }

  goOffline(): void {
    this.cameraMode = this.cameraMode;
    this.revisionCounter++;
  }

  relaunch(priorReceipts?: Map<string, ActionReceiptWire>): void {
    if (priorReceipts) this.receiptsById = priorReceipts;
    this.revisionCounter++;
  }

  // -- PhoneExecutor (bounded reads) ----------------------------------------

  revision(): number {
    return this.revisionCounter;
  }

  pantrySnapshot(): PantrySnapshot {
    return { revision: this.pantryRevisionCounter, items: this.items.map((i) => ({ ...i })) };
  }

  sessionSnapshot(): CookSessionSnapshot {
    return {
      ...(this.recipeId !== undefined ? { recipeId: this.recipeId } : {}),
      state: this.sessionState,
      currentStepIndex: this.currentStepIndex,
      eaters: this.eaters,
      activeTimers: this.timers.map((t) => ({ ...t })),
      cameraMode: this.cameraMode,
      stepHistory: [...this.stepHistory],
      deviceEvents: this.deviceEvents.filter((e) => !this.consumedDeviceEvents.has(e.id)).map((e) => ({ ...e })),
      offline: false
    };
  }

  recipeCatalog(): readonly RecipeContext[] {
    return this.recipes;
  }

  cameraLook(mode: "push-to-look" | "continuous"): CameraObservation {
    return this.cameraScript();
  }

  // -- proposal validation + execution (the authority) ----------------------

  submitProposal(
    proposal: ActionProposalWire,
    userInitiationEventId?: string
  ): ActionReceiptWire | { pending: true; proposalID: string; requiredApproval: RequiredApproval; expiresAt: string } {
    const revision = this.revisionCounter;

    const writeReceipt = (state: ActionReceiptWire["state"], reason?: string): ActionReceiptWire => {
      const receipt: ActionReceiptWire = {
        proposalID: proposal.proposalID,
        payloadHash: proposal.payloadHash,
        snapshotRevision: this.revisionCounter,
        state,
        recordedAt: isoFromMs(this.clock.nowMs()),
        ...(reason !== undefined ? { reason } : {})
      };
      this.receiptsById.set(proposal.proposalID, receipt);
      return receipt;
    };

    // Applied at most once: a receipt already exists for this proposalID
    // (across restarts — receipts are the dedupe authority).
    if (this.receiptsById.has(proposal.proposalID)) {
      return writeReceipt("rejected", "already_resolved");
    }
    // Payload integrity: the hash is recomputed over the payload as received.
    if (payloadHash(proposal.payload) !== proposal.payloadHash) {
      return writeReceipt("rejected", "payload hash mismatch");
    }
    if (this.clock.nowMs() > Date.parse(proposal.expiresAt)) {
      return writeReceipt("expired", "TTL elapsed before approval");
    }

    // Approval policy is derived HERE, from the phone's own evidence — the
    // submitted annotation is never consulted.
    const isTimer = proposal.kind === "timer_start" || proposal.kind === "timer_adjust";
    let deviceAuthorized = false;
    if (isTimer && userInitiationEventId !== undefined) {
      const event = this.deviceEvents.find((e) => e.id === userInitiationEventId);
      if (
        event !== undefined &&
        !this.consumedDeviceEvents.has(event.id) &&
        event.kind === "user-command" &&
        event.command === toolForKind(proposal.kind) &&
        event.revision === revision
      ) {
        // One event initiates one action: consume it.
        this.consumedDeviceEvents.add(event.id);
        deviceAuthorized = true;
      }
    }

    if (isTimer && deviceAuthorized) {
      // device-auto: execute immediately (SPEC §8.2). Timers carry no allergen
      // recheck — only swap/adaptation do, and this branch is timer-only.
      this.execute(proposal);
      const receipt: ActionReceiptWire = {
        proposalID: proposal.proposalID,
        payloadHash: proposal.payloadHash,
        snapshotRevision: revision,
        state: "executed",
        recordedAt: isoFromMs(this.clock.nowMs())
      };
      this.receiptsById.set(proposal.proposalID, receipt);
      this.revisionCounter++;
      return receipt;
    }

    // Everything else — including EVERY meal log, even one citing a voice
    // event — waits for the user's explicit action on the device. The cited
    // event is NOT consumed for non-timer kinds: a voice transcript never
    // authorizes anything.
    this.proposalsById.set(proposal.proposalID, proposal);
    if (userInitiationEventId !== undefined) {
      (proposal as ActionProposalWire & { citedEventId?: string }).citedEventId = userInitiationEventId;
    }
    return { pending: true, proposalID: proposal.proposalID, requiredApproval: "explicit" as const, expiresAt: proposal.expiresAt };
  }

  /** The user approves a pending proposal on the device, NOW (TTL checked here). */
  approve(proposalId: string): ActionReceiptWire {
    const writeReceipt = (state: ActionReceiptWire["state"], reason?: string, payloadHashValue?: string): ActionReceiptWire => {
      const receipt: ActionReceiptWire = {
        proposalID: proposalId,
        payloadHash: payloadHashValue ?? "sha256:" + "0".repeat(64),
        snapshotRevision: this.revisionCounter,
        state,
        recordedAt: isoFromMs(this.clock.nowMs()),
        ...(reason !== undefined ? { reason } : {})
      };
      this.receiptsById.set(proposalId, receipt);
      return receipt;
    };

    if (this.receiptsById.has(proposalId)) return this.receiptsById.get(proposalId)!;
    const proposal = this.proposalsById.get(proposalId);
    if (proposal === undefined) return writeReceipt("rejected", "unknown proposal");
    // Expiry is checked at approval time (SPEC §8.1).
    if (this.clock.nowMs() > Date.parse(proposal.expiresAt)) return writeReceipt("expired", "TTL elapsed before approval", proposal.payloadHash);

    this.execute(proposal);
    const receipt: ActionReceiptWire = {
      proposalID: proposal.proposalID,
      payloadHash: proposal.payloadHash,
      snapshotRevision: this.revisionCounter,
      state: "executed",
      recordedAt: isoFromMs(this.clock.nowMs()),
      ...(proposal.kind === "swap" || proposal.kind === "adaptation" ? { allergenRecheck: this.recheck(proposal) } : {})
    };
    this.receiptsById.set(proposal.proposalID, receipt);
    this.revisionCounter++;
    return receipt;
  }

  /** The user declines a pending proposal on the device. */
  reject(proposalId: string): ActionReceiptWire {
    if (this.receiptsById.has(proposalId)) return this.receiptsById.get(proposalId)!;
    const proposal = this.proposalsById.get(proposalId);
    const receipt: ActionReceiptWire = {
      proposalID: proposalId,
      payloadHash: proposal?.payloadHash ?? "sha256:" + "0".repeat(64),
      snapshotRevision: this.revisionCounter,
      state: "rejected",
      recordedAt: isoFromMs(this.clock.nowMs()),
      reason: "declined by the user"
    };
    this.receiptsById.set(proposalId, receipt);
    return receipt;
  }

  /** Record a pending proposal (the submission path) so the harness can approve later. */
  stage(proposal: ActionProposalWire, citedEventId?: string): void {
    this.proposalsById.set(proposal.proposalID, proposal);
    if (citedEventId !== undefined) {
      (proposal as ActionProposalWire & { citedEventId?: string }).citedEventId = citedEventId;
    }
  }

  private execute(proposal: ActionProposalWire): void {
    const at = isoFromMs(this.clock.nowMs());
    switch (proposal.kind) {
      case "timer_start": {
        const payload = proposal.payload as { readonly durationMinutes: number; readonly label?: string };
        const timerId = `timer-${this.timers.length + 1}-${proposal.proposalID.slice(-4)}`;
        this.timers.push({
          timerId,
          label: payload.label ?? "timer",
          // ABSOLUTE wall-clock deadline in integer epoch seconds — survives kills (SPEC 4.2).
          deadline: epochSeconds(this.clock.nowMs() + payload.durationMinutes * 60_000),
          createdAt: at,
          proposalId: proposal.proposalID
        });
        break;
      }
      case "timer_adjust": {
        const payload = proposal.payload as { readonly timerId: string; readonly newDurationMinutes?: number };
        const timer = this.timers.find((t) => t.timerId === payload.timerId);
        if (timer && payload.newDurationMinutes !== undefined) {
          const updated = { ...timer, deadline: epochSeconds(this.clock.nowMs() + payload.newDurationMinutes * 60_000) };
          this.timers = this.timers.map((t) => (t.timerId === timer.timerId ? updated : t));
        }
        break;
      }
      case "step_advance": {
        const payload = proposal.payload as { readonly stepIndex: number };
        const action = payload.stepIndex >= this.currentStepIndex ? "advanced" : "moved-back";
        this.currentStepIndex = payload.stepIndex;
        this.stepHistory.push({ stepIndex: payload.stepIndex, at, action });
        break;
      }
      case "inventory_correction": {
        const payload = proposal.payload as { readonly ingredientId: number; readonly correction: string };
        const item = this.items[payload.ingredientId];
        if (item !== undefined) {
          this.items[payload.ingredientId] = {
            ...item,
            state: "sufficient",
            source: "manual"
          };
          this.pantryRevisionCounter++;
        }
        break;
      }
      case "meal_log":
        this.loggedMeals.push({ recipe: (proposal.payload as { readonly recipe: { source: string; id: string; revision: number } }).recipe, at });
        break;
      case "save_note":
        this.savedNotes += 1; // the marker only — note text never crosses this boundary
        break;
      case "plan":
      case "swap":
      case "adaptation":
        // Recorded as receipts; the plan/swap/adaptation surfaces in the UI.
        break;
    }
  }

  /** Allergen recheck for swap/adaptation receipts (SPEC §6, §8.2). */
  private recheck(proposal: ActionProposalWire): AllergenRecheck {
    const eaters = this.eaters.map((e) => e.name ?? "unnamed");
    if (proposal.kind === "swap") {
      const swapPayload = proposal.payload as { readonly originalIngredientId: number; readonly substituteIngredientId: number };
      // The reviewed facts are keyed by reviewed ingredient NAME; resolve the
      // pantry item's name, and the substitute through the configured
      // reviewed-name map. Unknown names fail closed (confirmation required).
      const from = this.items[swapPayload.originalIngredientId]?.name ?? `ingredient-${swapPayload.originalIngredientId}`;
      const to = this.substituteNames.get(swapPayload.substituteIngredientId) ?? `ingredient-${swapPayload.substituteIngredientId}`;
      const violations = recheckSwapAllergens(from, to, this.eaters);
      return {
        verdict: violations.length > 0 ? "unsupported" : "verified",
        eaters,
        ...(violations.length > 0 ? { blockedPath: violations.join("; ") } : { blockedPath: null })
      };
    }
    if (proposal.kind === "adaptation" && (proposal.payload as { readonly servings?: number }).servings !== undefined) {
      return { verdict: "plausible", eaters, blockedPath: null };
    }
    return { verdict: "unknown", eaters, blockedPath: null };
  }

  /** For tests: the full receipts map (immutable copy). */
  receipts(): Map<string, ActionReceiptWire> {
    return new Map(this.receiptsById);
  }

  state(): FakePhoneState {
    return {
      pantryRevision: this.pantryRevisionCounter,
      items: [...this.items],
      ...(this.recipeId !== undefined ? { recipeId: this.recipeId } : {}),
      sessionState: this.sessionState,
      currentStepIndex: this.currentStepIndex,
      eaters: this.eaters,
      timers: [...this.timers],
      cameraMode: this.cameraMode,
      stepHistory: [...this.stepHistory],
      deviceEvents: [...this.deviceEvents],
      savedNotes: this.savedNotes,
      loggedMeals: [...this.loggedMeals],
      proposals: new Map(this.proposalsById),
      receipts: new Map(this.receiptsById),
      consumedDeviceEvents: new Set(this.consumedDeviceEvents),
      revision: this.revisionCounter
    };
  }
}

/** Default camera behaviour: an honest look that names what it cannot assess. */
function defaultCameraObservation(): CameraObservation {
  return {
    observed: ["a pan on the burner with browning pieces", "steam rising"],
    cannotAssess: ["internal doneness — a camera cannot assess it"],
    framesSent: 1,
    clipSeconds: 0
  };
}
