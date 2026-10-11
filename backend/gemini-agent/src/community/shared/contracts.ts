/**
 * The seams between community parts. Parts own their own directories and
 * program against these interfaces; the router factory (src/community/index.ts)
 * wires the real implementations. Tests inject the fixtures from
 * shared/testing/stubs.ts. No part imports another part's internals.
 */
import type { AccountId, ModerationItemId, PublicationId, RecipeRevisionId } from "./ids.js";

/** Identifies one immutable revision of a user-published recipe. */
export interface PublicationRef {
  readonly publicationId: PublicationId;
  readonly revisionId: RecipeRevisionId;
}

/**
 * Block enforcement, implemented by the safety part. A blocked pair means
 * "blocked users see nothing of each other": no reads, no shares, no invites,
 * no co-presence in any community surface — in either direction.
 */
export interface BlockDirectory {
  /** Throws ForbiddenError when a block exists between the two accounts. */
  assertCanInteract(a: AccountId, b: AccountId): Promise<void>;
  /** Bulk variant used when one surface would fan out to many accounts. */
  filterVisible(viewer: AccountId, candidates: readonly AccountId[]): Promise<AccountId[]>;
}

/** Why an item entered the moderation queue. */
export type ModerationSubmitReason = "automated-screening" | "user-report" | "author-appeal";

export type ModerationDecisionKind = "approved" | "rejected";

/**
 * The human moderation queue, implemented by the safety part. No LLM decides
 * moderation: decisions are made by a human moderator role through a
 * server-held endpoint and are stored server-side only.
 */
export interface ModerationQueue {
  submit(target: PublicationRef, submitter: AccountId | null, reason: ModerationSubmitReason, note: string | null): Promise<ModerationItemId>;
  /**
   * Registers the handler fired exactly once per decision. The recipes part
   * registers the publication state-machine transition at wiring time.
   */
  registerDecisionHandler(handler: (target: PublicationRef, decision: ModerationDecisionKind, note: string) => Promise<void>): void;
}

/**
 * One stage of automated screening for a publication. The recipes part owns
 * the pipeline that runs stages; the food-safety linter (data/food-safety,
 * when present) plugs in as a stage, as do allergen tagging and text checks.
 */
export type ScreeningVerdict =
  | { readonly outcome: "pass"; readonly stage: string; readonly tags: readonly string[] }
  | { readonly outcome: "fail"; readonly stage: string; readonly reasons: readonly string[] };

export interface ScreenablePublication {
  readonly title: string;
  readonly summary: string | null;
  readonly ingredientLines: readonly string[];
  readonly steps: readonly string[];
}

export interface ScreeningStage {
  readonly name: string;
  run(publication: ScreenablePublication): Promise<ScreeningVerdict>;
}
