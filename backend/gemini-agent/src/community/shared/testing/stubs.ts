/**
 * Fixture implementations of the seam contracts, for one part's tests to use
 * while the owning part's real implementation is elsewhere. The full
 * composition is proven only by suite E against the real wiring.
 */
import { errForbidden } from "../errors.js";
import type {
  BlockDirectory,
  ModerationDecisionKind,
  ModerationQueue,
  ModerationSubmitReason,
  PublicationRef,
  ScreeningStage,
  ScreeningVerdict,
} from "../contracts.js";
import type { AccountId, ModerationItemId, PublicationId, RecipeRevisionId } from "../ids.js";
import { newModerationItemId } from "../ids.js";

export interface BlockDirectoryStub extends BlockDirectory {
  /** Test control: record a block between two accounts (direction is stored, effect is mutual). */
  block(a: AccountId, b: AccountId): void;
  /** Test control: clears all blocks. */
  reset(): void;
}

export function stubBlockDirectory(): BlockDirectoryStub {
  const blockedPairs = new Set<string>();
  const key = (a: AccountId, b: AccountId): string => [a, b].sort().join("|");
  return {
    async assertCanInteract(a, b): Promise<void> {
      if (blockedPairs.has(key(a, b))) {
        throw errForbidden("a block exists between these accounts");
      }
    },
    async filterVisible(viewer, candidates): Promise<AccountId[]> {
      return candidates.filter((c) => c !== viewer && !blockedPairs.has(key(viewer, c)));
    },
    block(a, b): void {
      blockedPairs.add(key(a, b));
    },
    reset(): void {
      blockedPairs.clear();
    },
  };
}

export interface ModerationQueueStub extends ModerationQueue {
  readonly submitted: Array<{
    target: { publicationId: PublicationId; revisionId: RecipeRevisionId };
    submitter: AccountId | null;
    reason: ModerationSubmitReason;
    note: string | null;
    itemId: ModerationItemId;
  }>;
  /** The handler registered via registerDecisionHandler, exposed for assertions. */
  decisionHandler: ((target: PublicationRef, decision: ModerationDecisionKind, note: string) => Promise<void>) | null;
  /** Test control: act as the human moderator deciding a queued item. */
  decide(publicationId: PublicationId, revisionId: RecipeRevisionId, decision: ModerationDecisionKind, note: string): Promise<void>;
}

export function stubModerationQueue(): ModerationQueueStub {
  const stub: ModerationQueueStub = {
    submitted: [],
    async submit(target, submitter, reason, note): Promise<ModerationItemId> {
      const itemId = newModerationItemId();
      stub.submitted.push({ target, submitter, reason, note, itemId });
      return itemId;
    },
    async decide(publicationId, revisionId, decision, note): Promise<void> {
      if (stub.decisionHandler === null) {
        throw new Error("no decision handler registered");
      }
      await stub.decisionHandler({ publicationId, revisionId }, decision, note);
    },
    registerDecisionHandler(handler): void {
      stub.decisionHandler = handler;
    },
    decisionHandler: null,
  };
  return stub;
}

export function stubScreeningPass(stage = "stub-pass"): ScreeningStage {
  return {
    name: stage,
    async run(): Promise<ScreeningVerdict> {
      return { outcome: "pass", stage, tags: [] };
    },
  };
}

export function stubScreeningFail(reasons: readonly string[], stage = "stub-fail"): ScreeningStage {
  return {
    name: stage,
    async run(): Promise<ScreeningVerdict> {
      return { outcome: "fail", stage, reasons };
    },
  };
}
