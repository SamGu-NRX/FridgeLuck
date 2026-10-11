/**
 * Fake phone — the device executor for tests and the harness (SPEC 4).
 *
 * The phone is authoritative. This simulator owns:
 * - pantry snapshots with a revision counter (bounded views are handed out;
 *   mutations bump the revision);
 * - a timer table with DEVICE-OWNED absolute deadlines on an injected clock;
 * - cook-session step state and history;
 * - the approval policy: explicit approvals come only from scripted user
 *   actions (userApproves/userRejects); device-auto applies only to the
 *   phone's own timer rule.
 *
 * The ONLY execution path is an approval reaching this phone. A proposal can
 * never execute itself: submitProposal files it; execution happens in
 * executeApproved(), which only the phone's approval flow calls.
 *
 * Kill-app: timer deadlines are absolute epoch seconds and survive the kill;
 * unexecuted pending proposals expire per expiresAt or are re-presented on
 * resume. Offline: an unreachable phone rejects submissions and snapshot
 * reads; after reconnect(), callers re-read bounded snapshots at the new
 * revision.
 */

import type {
  ActionProposal,
  ActionReceipt,
  ActiveTimer,
  CookSessionSnapshot,
  EpochSeconds,
  Eater,
  PantryLine,
  PantrySnapshot,
  ProposalState,
  ReceiptState,
  StepHistoryEntry
} from "./types.js";

/** Thrown when the phone is offline (unreachable) — never silently swallowed. */
export class PhoneOfflineError extends Error {
  constructor() {
    super("phone is offline (unreachable)");
    this.name = "PhoneOfflineError";
  }
}

interface TimerRecord {
  readonly timerId: string;
  readonly label: string;
  readonly proposalId: string;
  readonly createdAt: EpochSeconds;
  /** Absolute device-owned deadline in epoch seconds — survives kills. */
  deadline: EpochSeconds;
  minutes: number;
  firedAt?: EpochSeconds;
  /** True when the timer existed at the most recent killApp and kept its deadline. */
  survivedKill: boolean;
}

interface MealLogRecord {
  readonly recipeId: string;
  readonly revision: number;
  readonly servings: number;
  readonly swaps: readonly { from: string; to: string }[];
  readonly sourcedFrom: "voice" | "screen";
  readonly note?: string;
  readonly at: EpochSeconds;
}

export interface CookNoteRecord {
  readonly text: string;
  readonly scope: "cook" | "recipe";
  readonly at: EpochSeconds;
}

export interface PhoneEvents {
  readonly kind: "proposal-submitted" | "executed" | "rejected" | "expired" | "timer-fired" | "revision-bumped" | "kill" | "resume" | "offline" | "reconnect";
  readonly at: EpochSeconds;
  readonly detail: string;
}

export interface FakePhoneClock {
  nowMs(): number;
}

export interface FakePhoneOptions {
  clock: FakePhoneClock;
  pantry?: readonly PantryLine[];
  session?: Partial<
    Pick<CookSessionSnapshot, "recipeId" | "state" | "currentStepIndex" | "eaters" | "cameraMode">
  >;
  /** Proposal TTL grace: re-present pending proposals instead of expiring them when true. */
  rePresentPendingOnKill?: boolean;
}

export class FakePhone {
  private clock: FakePhoneClock;
  private revisionCounter: number;
  private pantryItems: PantryLine[];
  private sessionState: CookSessionSnapshot["state"];
  private currentStep: number;
  private readonly sessionRecipeId?: string;
  private readonly eaters: readonly Eater[];
  private camera: CookSessionSnapshot["cameraMode"];
  private readonly stepHistory: StepHistoryEntry[] = [];
  private readonly timers = new Map<string, TimerRecord>();
  private readonly mealLogs: MealLogRecord[] = [];
  private readonly notes: CookNoteRecord[] = [];
  /** Live proposals awaiting approval, keyed by proposal id. */
  private readonly pending = new Map<string, ActionProposal>();
  private readonly receiptLog: ActionReceipt[] = [];
  private readonly eventLog: PhoneEvents[] = [];
  private online = true;
  private killed = false;
  private timerSeq = 0;
  private readonly rePresentPendingOnKill: boolean;

  constructor(options: FakePhoneOptions) {
    this.clock = options.clock;
    this.revisionCounter = 1;
    this.pantryItems = [...(options.pantry ?? [])];
    this.sessionState = options.session?.state ?? "planning";
    this.currentStep = options.session?.currentStepIndex ?? 0;
    this.sessionRecipeId = options.session?.recipeId;
    this.eaters = options.session?.eaters ?? [];
    this.camera = options.session?.cameraMode ?? "push-to-look";
    this.rePresentPendingOnKill = options.rePresentPendingOnKill ?? false;
  }

  // -------------------------------------------------------------------------
  // Clock and revision
  // -------------------------------------------------------------------------

  private now(): EpochSeconds {
    return Math.floor(this.clock.nowMs() / 1000) as EpochSeconds;
  }

  revision(): number {
    this.expirePending();
    return this.revisionCounter;
  }

  // -------------------------------------------------------------------------
  // Bounded snapshot reads (phone-authoritative; read-only views)
  // -------------------------------------------------------------------------

  pantrySnapshot(): PantrySnapshot {
    if (!this.online) throw new PhoneOfflineError();
    this.expirePending();
    return {
      revision: this.revisionCounter,
      capturedAt: this.now(),
      items: this.pantryItems.map((line) => ({ ...line }))
    };
  }

  sessionSnapshot(): CookSessionSnapshot {
    if (!this.online) throw new PhoneOfflineError();
    this.expirePending();
    return {
      ...(this.sessionRecipeId !== undefined ? { recipeId: this.sessionRecipeId } : {}),
      state: this.sessionState,
      currentStepIndex: this.currentStep,
      eaters: this.eaters.map((e) => ({ ...e, restrictions: [...e.restrictions] })),
      activeTimers: this.activeTimers(),
      cameraMode: this.camera,
      stepHistory: this.stepHistory.map((h) => ({ ...h }))
    };
  }

  activeTimers(): readonly ActiveTimer[] {
    return [...this.timers.values()]
      .filter((t) => t.firedAt === undefined)
      .map((t) => ({
        timerId: t.timerId,
        label: t.label,
        minutes: t.minutes,
        createdAt: t.createdAt,
        deadline: t.deadline,
        proposalId: t.proposalId
      }));
  }

  // -------------------------------------------------------------------------
  // Proposal intake and the approval policy
  // -------------------------------------------------------------------------

  /**
   * File a proposal with the phone. Nothing executes here. device-auto
   * proposals (the phone's timer rule) are approved by the phone itself and
   * executed immediately; explicit proposals wait for a scripted user action.
   */
  submitProposal(proposal: ActionProposal): void {
    if (!this.online) throw new PhoneOfflineError();
    this.expirePending();
    if (proposal.expiresAt <= this.now()) {
      this.recordReceipt(proposal, "expired");
      this.eventLog.push({ kind: "expired", at: this.now(), detail: `${proposal.id} arrived past expiry` });
      return;
    }
    this.pending.set(proposal.id, proposal);
    this.eventLog.push({ kind: "proposal-submitted", at: this.now(), detail: `${proposal.id} (${proposal.tool})` });
    if (proposal.requiredApproval === "device-auto") {
      // The phone's timer rule: device-auto proposals execute without a tap.
      this.approve(proposal.id, "device-auto");
    }
  }

  /** Scripted user action: approve a pending explicit proposal. */
  userApproves(proposalId: string): void {
    this.approve(proposalId, "explicit-user");
  }

  /** Scripted user action: reject a pending proposal. */
  userRejects(proposalId: string): void {
    const proposal = this.pending.get(proposalId);
    if (!proposal) return;
    this.pending.delete(proposalId);
    this.recordReceipt(proposal, "rejected");
    this.eventLog.push({ kind: "rejected", at: this.now(), detail: proposalId });
  }

  private approve(proposalId: string, by: "device-auto" | "explicit-user"): void {
    const proposal = this.pending.get(proposalId);
    if (!proposal) return;
    this.pending.delete(proposalId);
    // Expiry is checked at approval time: a stale approval cannot execute.
    if (proposal.expiresAt <= this.now()) {
      this.recordReceipt(proposal, "expired");
      return;
    }
    this.executeApproved(proposal);
  }

  /**
   * The single execution path. Only approve() calls this — a proposal can
   * never reach execution on its own.
   */
  private executeApproved(proposal: ActionProposal): void {
    const p = proposal.payload;
    switch (p.kind) {
      case "timerStart": {
        this.timerSeq += 1;
        const timerId = `timer-${String(this.timerSeq).padStart(4, "0")}`;
        const createdAt = this.now();
        this.timers.set(timerId, {
          timerId,
          label: p.label,
          minutes: p.minutes,
          proposalId: proposal.id,
          createdAt,
          deadline: (createdAt + Math.round(p.minutes * 60)) as EpochSeconds,
          survivedKill: false
        });
        this.revisionCounter += 1;
        break;
      }
      case "timerAdjust": {
        const timer = this.timers.get(p.timerId);
        if (!timer || timer.firedAt !== undefined) {
          this.recordReceipt(proposal, "rejected"); // no such live timer
          return;
        }
        const now = this.now();
        timer.minutes =
          p.target.kind === "set" ? p.target.newMinutes : Math.max(0, timer.minutes + p.target.deltaMinutes);
        timer.deadline = (
          p.target.kind === "set" ? now + Math.round(p.target.newMinutes * 60) : now + Math.round(timer.minutes * 60)
        ) as EpochSeconds;
        this.revisionCounter += 1;
        break;
      }
      case "stepAdvance": {
        const previous = this.currentStep;
        this.currentStep = p.stepIndex;
        if (this.sessionState === "planning") this.sessionState = "cooking";
        if (this.sessionState === "paused") this.sessionState = "cooking";
        this.stepHistory.push({ stepIndex: previous, at: this.now(), action: "advanced" });
        this.revisionCounter += 1;
        break;
      }
      case "inventoryCorrection": {
        const observed = p.observed;
        this.pantryItems = this.pantryItems.map((line) => {
          if (line.ingredientId !== p.ingredientId) return line;
          if (observed.kind === "quantity") {
            return { ...line, quantity: observed.quantity, state: observed.quantity.kind === "known" ? "sufficient" : "quantity-unknown" };
          }
          return { ...line, state: observed.state, ...(observed.shortBy !== undefined ? { shortBy: observed.shortBy } : {}) };
        });
        this.revisionCounter += 1;
        break;
      }
      case "mealLog": {
        this.mealLogs.push({
          recipeId: p.recipeId,
          revision: p.revision,
          servings: p.servings,
          swaps: p.swaps.map((s) => ({ from: s.from, to: s.to })),
          sourcedFrom: p.sourcedFrom,
          ...(p.note !== undefined ? { note: p.note } : {}),
          at: this.now()
        });
        this.revisionCounter += 1;
        break;
      }
      case "note": {
        this.notes.push({ text: p.text, scope: p.scope, at: this.now() });
        this.revisionCounter += 1;
        break;
      }
    }
    this.recordReceipt(proposal, "executed");
    this.eventLog.push({ kind: "executed", at: this.now(), detail: `${proposal.id} ${p.kind}` });
    this.eventLog.push({ kind: "revision-bumped", at: this.now(), detail: `revision=${this.revisionCounter}` });
  }

  private recordReceipt(proposal: ActionProposal, state: ReceiptState): void {
    const receipt: ActionReceipt = {
      proposalID: proposal.id,
      payloadHash: proposal.payloadHash,
      snapshotRevision: this.revisionCounter,
      state,
      recordedAt: this.now()
    };
    this.receiptLog.push(receipt);
  }

  /** Lazily expire pending proposals whose TTL passed. */
  private expirePending(): void {
    const now = this.now();
    for (const [id, proposal] of this.pending) {
      if (proposal.expiresAt <= now) {
        this.pending.delete(id);
        this.recordReceipt(proposal, "expired");
        this.eventLog.push({ kind: "expired", at: now, detail: id });
      }
    }
  }

  // -------------------------------------------------------------------------
  // Timer ticking (device-owned deadlines)
  // -------------------------------------------------------------------------

  /** Fire every timer whose absolute deadline has passed. Returns ids fired now. */
  tickTimers(): readonly string[] {
    const now = this.now();
    const fired: string[] = [];
    for (const timer of this.timers.values()) {
      if (timer.firedAt === undefined && timer.deadline <= now) {
        timer.firedAt = timer.deadline; // the device owns the deadline, not the tick time
        fired.push(timer.timerId);
        this.eventLog.push({ kind: "timer-fired", at: timer.firedAt, detail: timer.timerId });
      }
    }
    return fired;
  }

  timerRecords(): readonly TimerRecord[] {
    return [...this.timers.values()].map((t) => ({ ...t }));
  }

  // -------------------------------------------------------------------------
  // Kill-app and offline simulation
  // -------------------------------------------------------------------------

  /** Simulate the app being killed: pending proposals expire or are re-presented; timers persist. */
  killApp(): void {
    this.killed = true;
    this.eventLog.push({ kind: "kill", at: this.now(), detail: "app killed" });
    for (const timer of this.timers.values()) {
      if (timer.firedAt === undefined) timer.survivedKill = true;
    }
    this.expirePending();
    // Re-presentation: unexecuted proposals that are still within their TTL are
    // re-shown after the kill instead of being dropped (their state stays
    // proposed; the event log records the re-presentation).
    if (this.rePresentPendingOnKill) {
      for (const [id] of this.pending) {
        this.eventLog.push({ kind: "proposal-submitted", at: this.now(), detail: `${id} re-presented` });
      }
    }
  }

  /** Resume after a kill: timers whose deadline passed fire with their original deadlines. */
  resumeApp(): void {
    this.killed = false;
    this.eventLog.push({ kind: "resume", at: this.now(), detail: "app resumed" });
    this.tickTimers();
  }

  goOffline(): void {
    this.online = false;
    this.eventLog.push({ kind: "offline", at: this.now(), detail: "phone unreachable" });
  }

  /** Reconnect: callers re-read bounded snapshots at the (possibly advanced) revision. */
  reconnect(): void {
    this.online = true;
    this.eventLog.push({ kind: "reconnect", at: this.now(), detail: "phone reachable" });
  }

  // -------------------------------------------------------------------------
  // Introspection for tests and the harness
  // -------------------------------------------------------------------------

  receipts(): readonly ActionReceipt[] {
    return [...this.receiptLog];
  }

  receiptFor(proposalId: string): ActionReceipt | undefined {
    return this.receiptLog.find((r) => r.proposalID === proposalId);
  }

  pendingProposalIds(): readonly string[] {
    this.expirePending();
    return [...this.pending.keys()];
  }

  proposalState(proposalId: string): ProposalState | undefined {
    // Lazy expiry first: a state query past the TTL must not answer "proposed".
    this.expirePending();
    const receipt = this.receiptFor(proposalId);
    if (receipt) return receipt.state;
    if (this.pending.has(proposalId)) return "proposed";
    return undefined; // an id the phone never saw has no state here
  }

  mealLogRecords(): readonly MealLogRecord[] {
    return [...this.mealLogs];
  }

  noteRecords(): readonly CookNoteRecord[] {
    return [...this.notes];
  }

  events(): readonly PhoneEvents[] {
    return [...this.eventLog];
  }
}
