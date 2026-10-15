/**
 * Challenge document creation (SPEC §4.2: operator tooling or seed documents —
 * burst5 has no user-created challenge) and the contract response views.
 */

import type { DocumentStore } from "../../core/store/documentStore.js";
import { challengeIdShape } from "./ids.js";
import { validateTimes, type ChallengeStatus, type ChallengeTimes } from "./lifecycle.js";
import type { PackItemSnapshot } from "./packs.js";

export const CHALLENGES_COLLECTION = "challenges";
export const ENTRIES_COLLECTION = "challengeEntries";
export const VOTES_COLLECTION = "challengeVotes";

/** The stored challenge document. resolvedItems/packId are frozen at creation (§4.5). */
export interface ChallengeRecord {
  /** Document kind marker; the list route scans on it (the store has no list-all). */
  readonly kind: "challenge";
  readonly challengeId: string;
  readonly type: "battle" | "use-it-up" | "budget" | "seasonal" | "food-bank" | "campus";
  readonly name: string;
  readonly brief: string;
  readonly opensAt: string;
  readonly entryClosesAt: string;
  readonly votingClosesAt: string;
  readonly resolvedItems: readonly { fdcId: number; name: string; quantityText: string | null }[] | null;
  readonly packId: string | null;
  readonly scope: { readonly kind: "school"; readonly schoolKey?: string } | null;
}

/** The stored entry document. */
export interface EntryRecord {
  readonly entryId: string;
  readonly challengeId: string;
  readonly accountId: string;
  readonly publicationId: string;
  readonly recipeRef: { source: string; id: string; revision: number };
  readonly title: string;
  readonly note: string | null;
  readonly createdAt: string;
  /** §4.3.6 replacement tombstone: a replaced entry is dead and never renders. */
  readonly removed?: boolean;
  readonly replacedBy?: string;
}

/** Operator/seed creation: validates times and freezes the document. */
export async function createChallengeDocument(
  store: DocumentStore,
  input: {
    type: ChallengeRecord["type"];
    name: string;
    brief: string;
    opensAt: string;
    entryClosesAt: string;
    votingClosesAt: string;
    resolvedItems: PackItemSnapshot[] | null;
    packId: string | null;
    scope?: ChallengeRecord["scope"];
  },
): Promise<ChallengeRecord> {
  const times: ChallengeTimes = {
    opensAt: input.opensAt,
    entryClosesAt: input.entryClosesAt,
    votingClosesAt: input.votingClosesAt,
  };
  validateTimes(times);
  const record: ChallengeRecord = {
    kind: "challenge",
    challengeId: challengeIdShape.newId(),
    type: input.type,
    name: input.name,
    brief: input.brief,
    opensAt: input.opensAt,
    entryClosesAt: input.entryClosesAt,
    votingClosesAt: input.votingClosesAt,
    resolvedItems: input.resolvedItems,
    packId: input.packId,
    scope: input.scope ?? null,
  };
  await store.collection(CHALLENGES_COLLECTION).doc(record.challengeId).create({ ...record });
  return record;
}

/** contracts/challenge.schema.json for one viewer (myEntryId/myVoteEntryId are viewer-scoped). */
export function challengeView(
  record: ChallengeRecord,
  status: ChallengeStatus,
  entryCount: number,
  viewer: { myEntryId: string | null; myVoteEntryId: string | null },
): Record<string, unknown> {
  return {
    challengeId: record.challengeId,
    type: record.type,
    name: record.name,
    brief: record.brief,
    status,
    opensAt: record.opensAt,
    entryClosesAt: record.entryClosesAt,
    votingClosesAt: record.votingClosesAt,
    entryCount,
    resolvedItems: record.resolvedItems === null ? null : record.resolvedItems.map((i) => ({ ...i })),
    packId: record.packId,
    myEntryId: viewer.myEntryId,
    myVoteEntryId: viewer.myVoteEntryId,
    scope: record.scope,
  };
}

/**
 * contracts/challenge-entry.schema.json. authorDisplayName comes from the
 * caller's name lookup (accounts are not stored on the entry). voteCount is
 * null until votingClosesAt has passed (no live tallies, §4.3); state is
 * derived from the linked publication (in_review entries render only to their
 * author, §4.2).
 */
export function entryView(
  record: EntryRecord,
  authorDisplayName: string,
  state: "visible" | "in_review",
  voteCount: number | null,
): Record<string, unknown> {
  return {
    entryId: record.entryId,
    challengeId: record.challengeId,
    recipeRef: { ...record.recipeRef },
    title: record.title,
    authorDisplayName,
    note: record.note,
    createdAt: record.createdAt,
    state,
    voteCount,
  };
}
