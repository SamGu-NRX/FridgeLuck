/**
 * LivePhoneExecutor — the backend-side PhoneExecutor for one live session.
 *
 * It is NOT the authority: it mirrors the phone. Its bounded reads come from
 * the snapshot the phone sent once per session over the socket (SPEC §9.6 —
 * trimmed to ids + coarse quantity text, never the pantry). Its proposal
 * submissions validate the wire contract defensively (hash, TTL, dedupe for
 * the session's lifetime) and then ROUTE the proposal to the phone over the
 * WebSocket as a `proposal` envelope; the phone — the real authority —
 * checks revision and approval, executes at most once, and its receipt comes
 * back as a `proposal_receipt` envelope.
 *
 * Everything here lives and dies with the session: when the socket closes
 * the gateway discards the executor, so no snapshot, pending proposal, or
 * receipt outlives the cook (SPEC §9).
 */

import type {
  ActionProposalWire,
  ActionReceiptWire,
  CameraObservation,
  CookSessionSnapshot,
  PantrySnapshot,
  RecipeContext,
  RequiredApproval
} from "../lechef/types.js";
import { isoFromMs } from "../lechef/types.js";
import { payloadHash } from "../lechef/wire.js";
import type { PhoneExecutor, SubmissionResult } from "../lechef/proposals.js";

/** The bounded snapshot the phone uploads once per session (SPEC §9.6). */
export interface BoundedSnapshot {
  readonly pantry: PantrySnapshot;
  readonly cookSession: CookSessionSnapshot;
  readonly recipes: readonly RecipeContext[];
  /** The snapshot revision the phone recorded when it uploaded this. */
  readonly revision: number;
}

const BLANK_SESSION: CookSessionSnapshot = {
  state: "planning",
  currentStepIndex: 0,
  eaters: [],
  activeTimers: [],
  cameraMode: "push-to-look"
};

export class LivePhoneExecutor implements PhoneExecutor {
  private snapshot: BoundedSnapshot | null = null;
  /** Why the last session_context was refused; null when none was. */
  private rejection: string | null = null;
  private readonly proposals = new Map<string, ActionProposalWire>();
  private readonly receipts = new Map<string, ActionReceiptWire>();
  private readonly waiters = new Map<
    string,
    { resolve: (receipt: ActionReceiptWire | null) => void; timer: ReturnType<typeof setTimeout> }
  >();
  private closed = false;

  constructor(private readonly sendToPhone: (envelope: Record<string, unknown>) => void) {}

  // -- bounded snapshot upload (once per session) ----------------------------

  setSnapshot(snapshot: BoundedSnapshot): void {
    this.snapshot = snapshot;
    this.rejection = null;
  }

  /**
   * The phone sent a snapshot the gateway refused. The earlier snapshot is
   * dropped too, because its eaters may no longer match the household, and
   * sessionSnapshot() throws until a valid one arrives: screening against no
   * eaters would treat the household as unrestricted.
   */
  rejectSnapshot(reason: string): void {
    this.snapshot = null;
    this.rejection = reason;
  }

  hasSnapshot(): boolean {
    return this.snapshot !== null;
  }

  // -- PhoneExecutor: bounded reads ------------------------------------------

  revision(): number {
    return this.snapshot?.revision ?? 1;
  }

  pantrySnapshot(): PantrySnapshot {
    return this.snapshot?.pantry ?? { revision: 0, items: [] };
  }

  sessionSnapshot(): CookSessionSnapshot {
    if (this.rejection !== null) {
      throw new Error(
        `session_context rejected (${this.rejection}); the cook session and its eaters are unknown until the phone sends a valid session_context`,
      );
    }
    return this.snapshot?.cookSession ?? BLANK_SESSION;
  }

  recipeCatalog(): readonly RecipeContext[] {
    return this.snapshot?.recipes ?? [];
  }

  /**
   * A device-mediated camera look (SPEC §8.3). The backend mediates but never
   * holds or inspects frames: the look is performed on the device, and from
   * the backend's side there are no frames to observe.
   */
  cameraLook(): CameraObservation {
    return {
      observed: [],
      cannotAssess: ["camera looks are performed on the device; the backend holds no frames"],
      framesSent: 0,
      clipSeconds: 0
    };
  }

  // -- proposal routing (the phone is the authority) -------------------------

  submitProposal(proposal: ActionProposalWire): SubmissionResult {
    if (this.closed) {
      return this.writeReceipt(proposal, "rejected", "session closed");
    }
    // Applied at most once within the session (SPEC §8.2); the phone's
    // persistent receipt log is the dedupe authority across restarts.
    const existing = this.receipts.get(proposal.proposalID);
    if (existing) return existing;
    // Defensive wire checks — the phone re-validates everything itself.
    if (payloadHash(proposal.payload) !== proposal.payloadHash) {
      return this.writeReceipt(proposal, "rejected", "payload hash mismatch");
    }
    if (Date.now() > Date.parse(proposal.expiresAt)) {
      return this.writeReceipt(proposal, "expired", "TTL elapsed before approval");
    }

    this.proposals.set(proposal.proposalID, proposal);
    // ROUTE to the phone. requiredApproval is the derived audit annotation;
    // the phone derives its own approval policy and executes on ITS terms.
    this.sendToPhone({
      type: "proposal",
      payload: { proposal }
    });
    return {
      pending: true,
      proposalID: proposal.proposalID,
      requiredApproval: proposal.requiredApproval as RequiredApproval,
      expiresAt: proposal.expiresAt
    };
  }

  /** The phone's receipt for a routed proposal (from a `proposal_receipt` envelope). */
  resolveProposal(receipt: ActionReceiptWire): void {
    if (this.receipts.has(receipt.proposalID)) return;
    this.receipts.set(receipt.proposalID, receipt);
    this.proposals.delete(receipt.proposalID);
    const waiter = this.waiters.get(receipt.proposalID);
    if (waiter) {
      clearTimeout(waiter.timer);
      this.waiters.delete(receipt.proposalID);
      waiter.resolve(receipt);
    }
  }

  /** Await the phone's receipt for a routed proposal; null when none arrives in time. */
  waitForReceipt(proposalID: string, timeoutMs: number): Promise<ActionReceiptWire | null> {
    const existing = this.receipts.get(proposalID);
    if (existing) return Promise.resolve(existing);
    if (this.closed) return Promise.resolve(null);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiters.delete(proposalID);
        resolve(null);
      }, timeoutMs);
      // A receipt that arrives first wins; the timer is cleared in resolveProposal.
      if (timer.unref) timer.unref();
      this.waiters.set(proposalID, { resolve, timer });
    });
  }

  /** Session ended: every pending waiter resolves with nothing; nothing is kept. */
  close(): void {
    this.closed = true;
    for (const [id, waiter] of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.resolve(null);
      this.waiters.delete(id);
    }
    this.proposals.clear();
    // Receipts die with the session too: the phone's `cook_receipt` log, not
    // the backend, is the dedupe authority across restarts (SPEC §8.1).
    this.receipts.clear();
    this.snapshot = null;
  }

  private writeReceipt(
    proposal: ActionProposalWire,
    state: ActionReceiptWire["state"],
    reason: string,
  ): ActionReceiptWire {
    const receipt: ActionReceiptWire = {
      proposalID: proposal.proposalID,
      payloadHash: proposal.payloadHash,
      snapshotRevision: this.revision(),
      state,
      recordedAt: isoFromMs(Date.now()),
      reason
    };
    this.receipts.set(proposal.proposalID, receipt);
    return receipt;
  }
}
