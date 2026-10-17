/**
 * Challenges (SPEC §6 item 3, finding 9): bounded, use-what-you-have
 * constraints that work alone.
 *
 * Scope as specified — and the narrowest reading of it:
 * - §6: "'Three ingredients, what can you make?', budget packs, use-it-up,
 *   time limits, seasonal ones. They work alone; you can send one as a link
 *   that reads without the app, and share your result."
 * - Finding 9: "restore a bounded use-what-you-have challenge that works
 *   alone (three ingredients or a reviewed low-budget pack, viable recipes,
 *   a private result, optionally invite a friend to the same constraint)."
 * - PLAN Goal 1 option A: "ingredient-constrained challenges and submissions";
 *   the §6 collection list adds votes only "for direction (b)" — battle
 *   voting is an unselected candidate direction, so there are no votes here.
 *
 * What this part owns: the challenge definition (a structured constraint),
 * created by any signed-in account, and the private entry (the result).
 *
 * - "send one as a link that reads without the app": GET
 *   /v1/community/challenges/:challengeId is open and returns the definition
 *   only — kind, title, constraint, creation day. No account ids, no entries.
 * - "a private result": an entry is readable by its author and no one else.
 *   There is no challenge feed and no entry list across accounts; sharing a
 *   result happens through the other sharing paths (publish to Explore, send
 *   to a Table, an opted-in cook occurrence) — never through this part.
 * - Entries are structured only (recipe reference + the constraint
 *   ingredients actually used). No free text: §3.4 limits shared free text
 *   to Table members, and an entry is not Table-scoped.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errValidation } from "../shared/errors.js";
import {
  newChallengeEntryId,
  newChallengeId,
  type AccountId,
  type ChallengeEntryId,
  type ChallengeId,
} from "../shared/ids.js";

export const CHALLENGE_KINDS = ["three-ingredients", "budget-pack", "use-it-up", "time-limit", "seasonal"] as const;
export type ChallengeKind = (typeof CHALLENGE_KINDS)[number];

export interface ChallengeRecord {
  readonly challengeId: ChallengeId;
  readonly kind: ChallengeKind;
  readonly title: string;
  /** The use-what-you-have constraint: the ingredients to cook from. */
  readonly ingredients: readonly string[];
  /** Optional time bound for time-limit challenges, in minutes. */
  readonly timeLimitMinutes: number | null;
  readonly createdByAccountId: AccountId;
  readonly createdAtIso: string;
}

export interface ChallengeEntryRecord {
  readonly entryId: ChallengeEntryId;
  readonly challengeId: ChallengeId;
  readonly accountId: AccountId;
  /** The recipe that answered the constraint (a cookbook reference, optional). */
  readonly sourceRecipeId: string | null;
  readonly recipeRevision: string | null;
  /** Which constraint ingredients the result used — structured, no prose. */
  readonly ingredientsUsed: readonly string[];
  readonly createdAtIso: string;
}

export interface ChallengeDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
}

function readStringField(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errValidation(`challenge record field ${field} is missing or malformed`);
  }
  return value;
}

function readStringOrNull(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw errValidation(`challenge record field ${field} is malformed`);
  }
  return value;
}

function readStringArrayField(data: Record<string, unknown>, field: string): string[] {
  const value = data[field];
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    throw errValidation(`challenge record field ${field} is missing or malformed`);
  }
  return value as string[];
}

/** Validating read of a challenge document (README rule 5). */
export function parseChallengeDoc(snap: DocumentSnapshot): ChallengeRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const kind = readStringField(data, "kind");
  if (!CHALLENGE_KINDS.includes(kind as ChallengeKind)) {
    throw errValidation(`challenge record field kind is malformed: ${kind}`);
  }
  const timeLimit = data["timeLimitMinutes"];
  return {
    challengeId: snap.id as ChallengeId,
    kind: kind as ChallengeKind,
    title: readStringField(data, "title"),
    ingredients: readStringArrayField(data, "ingredients"),
    timeLimitMinutes: typeof timeLimit === "number" ? timeLimit : null,
    createdByAccountId: readStringField(data, "createdByAccountId") as AccountId,
    createdAtIso: readStringField(data, "createdAtIso"),
  };
}

export function parseChallengeEntryDoc(snap: DocumentSnapshot): ChallengeEntryRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  return {
    entryId: snap.id as ChallengeEntryId,
    challengeId: readStringField(data, "challengeId") as ChallengeId,
    accountId: readStringField(data, "accountId") as AccountId,
    sourceRecipeId: readStringOrNull(data, "sourceRecipeId"),
    recipeRevision: readStringOrNull(data, "recipeRevision"),
    ingredientsUsed: readStringArrayField(data, "ingredientsUsed"),
    createdAtIso: readStringField(data, "createdAtIso"),
  };
}

export interface NewChallengeInput {
  readonly kind: ChallengeKind;
  readonly title: string;
  readonly ingredients: readonly string[];
  readonly timeLimitMinutes: number | null;
}

export async function createChallenge(deps: ChallengeDeps, createdByAccountId: AccountId, input: NewChallengeInput): Promise<ChallengeRecord> {
  if (input.kind === "three-ingredients" && input.ingredients.length !== 3) {
    // The named challenge is exactly what it says it is.
    throw errValidation("a three-ingredients challenge constrains exactly 3 ingredients");
  }
  const challengeId = newChallengeId();
  const record: ChallengeRecord = {
    challengeId,
    kind: input.kind,
    title: input.title,
    ingredients: input.ingredients,
    timeLimitMinutes: input.timeLimitMinutes,
    createdByAccountId,
    createdAtIso: toIso(deps.clock.now()),
  };
  await deps.store.challenges.doc(challengeId).create(record);
  return record;
}

export async function getChallenge(deps: ChallengeDeps, challengeId: ChallengeId): Promise<ChallengeRecord | null> {
  return parseChallengeDoc(await deps.store.challenges.doc(challengeId).get());
}

export interface NewChallengeEntryInput {
  readonly sourceRecipeId: string | null;
  readonly recipeRevision: string | null;
  readonly ingredientsUsed: readonly string[];
}

/**
 * Records the caller's result. Convergent: one entry per (account,
 * challenge) — a re-submission updates the author's result in place rather
 * than stacking duplicates.
 */
export async function createChallengeEntry(
  deps: ChallengeDeps,
  challenge: ChallengeRecord,
  accountId: AccountId,
  input: NewChallengeEntryInput,
): Promise<ChallengeEntryRecord> {
  const createdAtIso = toIso(deps.clock.now());
  const record: ChallengeEntryRecord = {
    entryId: newChallengeEntryId(),
    challengeId: challenge.challengeId,
    accountId,
    sourceRecipeId: input.sourceRecipeId,
    recipeRevision: input.recipeRevision,
    ingredientsUsed: input.ingredientsUsed,
    createdAtIso,
  };
  const prior = (await listOwnEntries(deps, challenge.challengeId, accountId))[0];
  if (prior !== undefined) {
    await deps.store.challengeEntries.doc(prior.entryId).set({
      challengeId: record.challengeId,
      accountId: record.accountId,
      sourceRecipeId: record.sourceRecipeId,
      recipeRevision: record.recipeRevision,
      ingredientsUsed: record.ingredientsUsed,
      createdAtIso: record.createdAtIso,
    });
    return { ...record, entryId: prior.entryId };
  }
  await deps.store.challengeEntries.doc(record.entryId).create(record);
  return record;
}

/**
 * The caller's own entries for one challenge, newest first. The author is
 * the only reader (finding 9: a private result) — the route enforces it by
 * construction, and this function never queries across accounts.
 */
export async function listOwnEntries(deps: ChallengeDeps, challengeId: ChallengeId, accountId: AccountId): Promise<ChallengeEntryRecord[]> {
  const snap = await deps.store.challengeEntries.where("challengeId", "==", challengeId).where("accountId", "==", accountId).get();
  return snap.docs
    .map((doc) => parseChallengeEntryDoc(doc))
    .filter((e): e is ChallengeEntryRecord => e !== null)
    .sort((a, b) => (a.createdAtIso < b.createdAtIso ? 1 : -1));
}

/**
 * Server-side removal of one account's challenge entries when their account
 * is deleted: tombstoned, not erased — entries keep their ids and challenge
 * references but lose their content links (records survive per §3.4).
 */
export async function tombstoneEntriesForAccount(deps: ChallengeDeps, accountId: AccountId, atIso: string): Promise<number> {
  const snap = await deps.store.challengeEntries.where("accountId", "==", accountId).get();
  let tombstoned = 0;
  for (const doc of snap.docs) {
    await doc.ref.update({ sourceRecipeId: null, recipeRevision: null, deletedAtIso: atIso });
    tombstoned += 1;
  }
  return tombstoned;
}
