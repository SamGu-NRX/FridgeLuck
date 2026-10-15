/**
 * Challenge lifecycle and battle vote integrity (SPEC §4.2–§4.3).
 *
 * Lifecycle: draft → open → voting → closed. The three boundary instants are
 * explicit contract fields (opensAt, entryClosesAt, votingClosesAt); the
 * status is derived from them against the clock, so an operator can never
 * leave a challenge in a state its timestamps contradict.
 *
 * Vote integrity: one verified account, one vote (stored per account, movable
 * until votingClosesAt); self-votes are stored but never counted; tallies stay
 * hidden until votingClosesAt has passed (no live tallies).
 */

export type ChallengeStatus = "draft" | "open" | "voting" | "closed";

export interface ChallengeTimes {
  readonly opensAt: string;
  readonly entryClosesAt: string;
  readonly votingClosesAt: string;
}

export function deriveStatus(times: ChallengeTimes, nowMs: number): ChallengeStatus {
  if (nowMs < Date.parse(times.opensAt)) {
    return "draft";
  }
  if (nowMs < Date.parse(times.entryClosesAt)) {
    return "open";
  }
  if (nowMs < Date.parse(times.votingClosesAt)) {
    return "voting";
  }
  return "closed";
}

export function validateTimes(times: ChallengeTimes): void {
  const opens = Date.parse(times.opensAt);
  const entryCloses = Date.parse(times.entryClosesAt);
  const votingCloses = Date.parse(times.votingClosesAt);
  for (const [label, value] of [
    ["opensAt", opens],
    ["entryClosesAt", entryCloses],
    ["votingClosesAt", votingCloses],
  ] as const) {
    if (Number.isNaN(value)) {
      throw new Error(`${label} is not an ISO-8601 instant`);
    }
  }
  if (!(opens < entryCloses && entryCloses < votingCloses)) {
    throw new Error("challenge times must satisfy opensAt < entryClosesAt < votingClosesAt");
  }
}

/** A stored vote: one per account per challenge, keyed `${challengeId}__${accountId}`. */
export interface VoteRecord {
  readonly challengeId: string;
  readonly accountId: string;
  readonly entryId: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface TallyEntry {
  readonly entryId: string;
  readonly authorAccountId: string;
}

/**
 * The final tally (readable only after votingClosesAt). Self-votes are stored
 * on the wire but never counted (§4.2); each account's single vote counts once.
 */
export function computeTallies(entries: readonly TallyEntry[], votes: readonly VoteRecord[]): ReadonlyMap<string, number> {
  const counts = new Map<string, number>();
  for (const entry of entries) {
    counts.set(entry.entryId, 0);
  }
  for (const vote of votes) {
    const entry = entries.find((e) => e.entryId === vote.entryId);
    if (entry === undefined) {
      continue; // a vote for a replaced/removed entry no longer counts
    }
    if (vote.accountId === entry.authorAccountId) {
      continue; // self-vote: stored but never counted
    }
    counts.set(vote.entryId, (counts.get(vote.entryId) ?? 0) + 1);
  }
  return counts;
}

/** The "BattleService" seam the spec names (§11.3): the pure decision surface the routes call. */
export const BattleService = {
  deriveStatus,
  validateTimes,
  computeTallies,
};
