/**
 * Tables (SPEC §6 item 4, §3.4): private groups of 2–8 who see each other's
 * shared cooks.
 *
 * SPEC §3.4 contract, implemented here:
 * - "Tables: invite by link, which the owner approves" — an owner mints an
 *   invite (a random link token, stored hashed like a refresh token); whoever
 *   holds the link can read what they are joining and redeem it, but the
 *   membership only becomes active when the owner approves. The owner can
 *   revoke invites (future redemptions fail) and remove members.
 * - "anyone can leave" — a member deletes their own membership; former
 *   members lose access immediately (membership reads filter on active).
 * - "private groups of 2–8" — the hard limit is the size ceiling at approval
 *   time (config.tableMaxSize). The size floor (tableMinSize) has no
 *   enforcement point that survives "anyone can leave": a table can fall
 *   below it when a member leaves, and forbidding that would trap owners in
 *   defunct tables. Recorded as an interpretation in the M4 handoff.
 * - "who see each other's shared cooks, with 'Cook tonight' on each card" —
 *   a shared cook carries the recipe reference (so the phone can offer Cook
 *   Tonight) and structured fields only per §3.4 (servings, swaps made,
 *   rating) plus an optional one-line note; no exact time beyond the UTC day,
 *   no photos, never pantry/health/taste data. Free text is limited to Table
 *   members because only active members of a live table can read its cooks.
 *
 * Blocks: membership-changing writes (redeem, approve) assert no block
 * between the candidate and the owner or any active member — a block forbids
 * co-presence, so no new shared surface may contain a blocked pair. Content
 * written inside an existing table is enforced at READ time instead
 * (filterVisible over the fan-out; a viewer always sees their own): a
 * write-time check would let whoever blocked first gag the other party in the
 * whole table, which is the monitoring effect review finding 3 warns about.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import { createHash, randomBytes } from "node:crypto";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errForbidden, errValidation } from "../shared/errors.js";
import {
  newInviteId,
  newSharedCookId,
  newTableId,
  type AccountId,
  type InviteId,
  type SharedCookId,
  type TableId,
} from "../shared/ids.js";

export interface TableRecord {
  readonly tableId: TableId;
  readonly name: string;
  readonly ownerAccountId: AccountId;
  readonly createdAtIso: string;
  /** Set when the table is dissolved (its owner left it or deleted their account). */
  readonly deletedAtIso: string | null;
}

export type TableRole = "owner" | "member";
export type MembershipStatus = "pending" | "active";

export interface MembershipRecord {
  readonly tableId: TableId;
  readonly accountId: AccountId;
  readonly role: TableRole;
  readonly status: MembershipStatus;
  readonly createdAtIso: string;
  readonly approvedAtIso: string | null;
}

export type InviteStatus = "active" | "revoked";

export interface TableInviteRecord {
  readonly inviteId: InviteId;
  readonly tableId: TableId;
  /** SHA-256 of the link token — the raw token is shown once at creation. */
  readonly tokenHash: string;
  readonly status: InviteStatus;
  readonly createdAtIso: string;
  readonly revokedAtIso: string | null;
}

export interface SharedCookRecord {
  readonly sharedCookId: SharedCookId;
  readonly tableId: TableId;
  readonly authorId: AccountId;
  readonly sourceRecipeId: string;
  readonly recipeRevision: string;
  readonly servings: number | null;
  readonly swapsMade: readonly string[];
  readonly rating: number | null;
  readonly note: string | null;
  /** UTC day the cook happened — never an exact time (SPEC 3.4). */
  readonly cookedOn: string;
  readonly createdAtIso: string;
  /** Tombstone (SPEC 3.4 deletion): set when the author's account is deleted. */
  readonly deletedAtIso: string | null;
}

/** Deps shared by operations that need no block check (dissolution). */
export interface TableCoreDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
}

export interface TablesDeps extends TableCoreDeps {
  /** Block enforcement at the seam — membership writes create co-presence. */
  readonly assertCanInteract: (a: AccountId, b: AccountId) => Promise<void>;
}

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
/** Versioned invite-link token: `flt1.` + base64url body (the minted form). */
export const INVITE_TOKEN_PATTERN = /^flt1\.[A-Za-z0-9_-]{40,128}$/;

export function hashInviteToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function membershipDocId(tableId: TableId, accountId: AccountId): string {
  return `${tableId}_${accountId}`;
}

function readStringField(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errValidation(`table record field ${field} is missing or malformed`);
  }
  return value;
}

function readStringOrNullField(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw errValidation(`table record field ${field} is malformed`);
  }
  return value;
}

function readIsoOrNull(data: Record<string, unknown>, field: string): string | null {
  const value = readStringOrNullField(data, field);
  if (value === null) {
    return null;
  }
  if (Number.isNaN(Date.parse(value))) {
    throw errValidation(`table record field ${field} is not an ISO timestamp`);
  }
  return value;
}

function readStringArrayField(data: Record<string, unknown>, field: string): string[] {
  const value = data[field];
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    throw errValidation(`table record field ${field} is malformed`);
  }
  return value as string[];
}

/** Validating read of a table document (README rule 5). */
export function parseTableDoc(snap: DocumentSnapshot): TableRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  return {
    tableId: snap.id as TableId,
    name: readStringField(data, "name"),
    ownerAccountId: readStringField(data, "ownerAccountId") as AccountId,
    createdAtIso: readStringField(data, "createdAtIso"),
    deletedAtIso: readIsoOrNull(data, "deletedAtIso"),
  };
}

export function parseMembershipDoc(snap: DocumentSnapshot): MembershipRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const role = readStringField(data, "role");
  const status = readStringField(data, "status");
  if (role !== "owner" && role !== "member") {
    throw errValidation("membership record field role is malformed");
  }
  if (status !== "pending" && status !== "active") {
    throw errValidation("membership record field status is malformed");
  }
  return {
    tableId: readStringField(data, "tableId") as TableId,
    accountId: readStringField(data, "accountId") as AccountId,
    role,
    status,
    createdAtIso: readStringField(data, "createdAtIso"),
    approvedAtIso: readIsoOrNull(data, "approvedAtIso"),
  };
}

export function parseInviteDoc(snap: DocumentSnapshot): TableInviteRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const status = readStringField(data, "status");
  if (status !== "active" && status !== "revoked") {
    throw errValidation("invite record field status is malformed");
  }
  return {
    inviteId: snap.id as InviteId,
    tableId: readStringField(data, "tableId") as TableId,
    tokenHash: readStringField(data, "tokenHash"),
    status,
    createdAtIso: readStringField(data, "createdAtIso"),
    revokedAtIso: readIsoOrNull(data, "revokedAtIso"),
  };
}

export function parseSharedCookDoc(snap: DocumentSnapshot): SharedCookRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const rating = data["rating"];
  const servings = data["servings"];
  return {
    sharedCookId: snap.id as SharedCookId,
    tableId: readStringField(data, "tableId") as TableId,
    authorId: readStringField(data, "authorId") as AccountId,
    sourceRecipeId: readStringField(data, "sourceRecipeId"),
    recipeRevision: readStringField(data, "recipeRevision"),
    servings: typeof servings === "number" ? servings : null,
    swapsMade: readStringArrayField(data, "swapsMade"),
    rating: typeof rating === "number" ? rating : null,
    note: readStringOrNullField(data, "note"),
    cookedOn: readStringField(data, "cookedOn"),
    createdAtIso: readStringField(data, "createdAtIso"),
    deletedAtIso: readStringOrNullField(data, "deletedAtIso"),
  };
}

// ---------------------------------------------------------------------------
// table lifecycle
// ---------------------------------------------------------------------------

export async function createTable(deps: TablesDeps, ownerAccountId: AccountId, name: string): Promise<TableRecord> {
  const tableId = newTableId();
  const nowIso = toIso(deps.clock.now());
  // One batch: a table must never exist without its owner membership — the
  // owner finds their tables through their memberships.
  const batch = deps.store.firestore.batch();
  batch.create(deps.store.tables.doc(tableId), {
    name,
    ownerAccountId,
    createdAtIso: nowIso,
    deletedAtIso: null,
  });
  batch.create(deps.store.tableMemberships.doc(membershipDocId(tableId, ownerAccountId)), {
    tableId,
    accountId: ownerAccountId,
    role: "owner",
    status: "active",
    createdAtIso: nowIso,
    approvedAtIso: nowIso,
  });
  await batch.commit();
  return { tableId, name, ownerAccountId, createdAtIso: nowIso, deletedAtIso: null };
}

export async function getTable(deps: TablesDeps, tableId: TableId): Promise<TableRecord | null> {
  return parseTableDoc(await deps.store.tables.doc(tableId).get());
}

/** The caller's tables with their membership, newest first. */
export async function listTablesForAccount(
  deps: TablesDeps,
  accountId: AccountId,
): Promise<Array<{ table: TableRecord; membership: MembershipRecord }>> {
  const snap = await deps.store.tableMemberships.where("accountId", "==", accountId).get();
  const entries: Array<{ table: TableRecord; membership: MembershipRecord }> = [];
  for (const doc of snap.docs) {
    const membership = parseMembershipDoc(doc);
    if (membership === null) {
      continue;
    }
    const table = await getTable(deps, membership.tableId);
    if (table === null || table.deletedAtIso !== null) {
      continue;
    }
    entries.push({ table, membership });
  }
  return entries.sort((a, b) => (a.table.createdAtIso < b.table.createdAtIso ? 1 : -1));
}

/** Active members of one table, owner first, join order next. */
export async function listActiveMembers(deps: TableCoreDeps, tableId: TableId): Promise<MembershipRecord[]> {
  const snap = await deps.store.tableMemberships.where("tableId", "==", tableId).get();
  return snap.docs
    .map((doc) => parseMembershipDoc(doc))
    .filter((m): m is MembershipRecord => m !== null && m.status === "active")
    .sort((a, b) => {
      if (a.role !== b.role) {
        return a.role === "owner" ? -1 : 1;
      }
      if (a.createdAtIso !== b.createdAtIso) {
        return a.createdAtIso < b.createdAtIso ? -1 : 1;
      }
      return a.accountId < b.accountId ? -1 : 1;
    });
}

export async function getMembership(deps: TablesDeps, tableId: TableId, accountId: AccountId): Promise<MembershipRecord | null> {
  return parseMembershipDoc(await deps.store.tableMemberships.doc(membershipDocId(tableId, accountId)).get());
}

// ---------------------------------------------------------------------------
// invites
// ---------------------------------------------------------------------------

export interface MintedInvite {
  readonly invite: TableInviteRecord;
  /** The raw link token, shown exactly once (only its hash is stored). */
  readonly token: string;
}

export async function createInvite(deps: TablesDeps, tableId: TableId): Promise<MintedInvite> {
  const inviteId = newInviteId();
  const token = `flt1.${randomBytes(32).toString("base64url")}`;
  const nowIso = toIso(deps.clock.now());
  const record: TableInviteRecord = {
    inviteId,
    tableId,
    tokenHash: hashInviteToken(token),
    status: "active",
    createdAtIso: nowIso,
    revokedAtIso: null,
  };
  await deps.store.tableInvites.doc(inviteId).create(record);
  return { invite: record, token };
}

export interface InviteWithTable {
  readonly invite: TableInviteRecord;
  readonly table: TableRecord;
}

/** Looks an invite up by its raw link token; returns null for unknown tokens. */
export async function findInviteByToken(deps: TablesDeps, token: string): Promise<InviteWithTable | null> {
  const snap = await deps.store.tableInvites.where("tokenHash", "==", hashInviteToken(token)).limit(1).get();
  const doc = snap.docs[0];
  if (doc === undefined) {
    return null;
  }
  const invite = parseInviteDoc(doc);
  if (invite === null) {
    return null;
  }
  const table = await getTable(deps, invite.tableId);
  if (table === null) {
    return null;
  }
  return { invite, table };
}

export type RevokeInviteOutcome = { readonly outcome: "ok" } | { readonly outcome: "missing" } | { readonly outcome: "forbidden" };

export async function revokeInvite(deps: TablesDeps, tableId: TableId, inviteId: InviteId, requesterId: AccountId): Promise<RevokeInviteOutcome> {
  const doc = deps.store.tableInvites.doc(inviteId);
  const invite = parseInviteDoc(await doc.get());
  if (invite === null || invite.tableId !== tableId) {
    return { outcome: "missing" };
  }
  const table = await getTable(deps, tableId);
  if (table === null || table.ownerAccountId !== requesterId) {
    return { outcome: "forbidden" };
  }
  if (invite.status !== "revoked") {
    await doc.update({ status: "revoked", revokedAtIso: toIso(deps.clock.now()) });
  }
  return { outcome: "ok" };
}

// ---------------------------------------------------------------------------
// membership changes
// ---------------------------------------------------------------------------

export type RedeemOutcome =
  | { readonly outcome: "ok"; readonly membership: MembershipRecord; readonly table: TableRecord }
  | { readonly outcome: "missing" }
  | { readonly outcome: "conflict" };

/**
 * Redeems an invite link: an existing membership converges (no-op); otherwise
 * a pending membership is created and the owner approves (SPEC §3.4).
 * Revoked invites and dissolved tables refuse redemption.
 */
export async function redeemInvite(deps: TablesDeps, token: string, accountId: AccountId): Promise<RedeemOutcome> {
  const found = await findInviteByToken(deps, token);
  if (found === null) {
    return { outcome: "missing" };
  }
  if (found.invite.status !== "active" || found.table.deletedAtIso !== null) {
    return { outcome: "conflict" };
  }
  const { table } = found;
  const existing = await getMembership(deps, table.tableId, accountId);
  if (existing !== null) {
    return { outcome: "ok", membership: existing, table };
  }
  // A block forbids co-presence (README rule 3): the candidate may not join
  // a table whose owner or active members they are blocked from. Checked
  // BEFORE the pending membership is written so a blocked redemption leaves
  // no directory entry behind.
  await deps.assertCanInteract(accountId, table.ownerAccountId);
  for (const member of await listActiveMembers(deps, table.tableId)) {
    if (member.accountId !== accountId) {
      await deps.assertCanInteract(accountId, member.accountId);
    }
  }
  const nowIso = toIso(deps.clock.now());
  const membership: MembershipRecord = {
    tableId: table.tableId,
    accountId,
    role: "member",
    status: "pending",
    createdAtIso: nowIso,
    approvedAtIso: null,
  };
  await deps.store.tableMemberships.doc(membershipDocId(table.tableId, accountId)).create(membership);
  return { outcome: "ok", membership, table };
}

export type ApproveOutcome =
  | { readonly outcome: "ok"; readonly membership: MembershipRecord }
  | { readonly outcome: "missing" }
  | { readonly outcome: "forbidden" }
  | { readonly outcome: "conflict"; readonly reason: "full" };

/** The owner turns a pending membership active, enforcing the size ceiling. */
export async function approveMember(
  deps: TablesDeps,
  tableId: TableId,
  ownerId: AccountId,
  candidateId: AccountId,
  maxSize: number,
): Promise<ApproveOutcome> {
  const table = await getTable(deps, tableId);
  if (table === null || table.deletedAtIso !== null) {
    return { outcome: "missing" };
  }
  if (table.ownerAccountId !== ownerId) {
    return { outcome: "forbidden" };
  }
  const pending = await getMembership(deps, tableId, candidateId);
  if (pending === null || pending.status !== "pending") {
    return { outcome: "missing" };
  }
  const active = await listActiveMembers(deps, tableId);
  if (active.length + 1 > maxSize) {
    return { outcome: "conflict", reason: "full" };
  }
  // Same co-presence rule as redemption: approval must not seat a blocked
  // pair at the table.
  await deps.assertCanInteract(candidateId, ownerId);
  for (const member of active) {
    if (member.accountId !== candidateId) {
      await deps.assertCanInteract(candidateId, member.accountId);
    }
  }
  const approvedAtIso = toIso(deps.clock.now());
  await deps.store.tableMemberships.doc(membershipDocId(tableId, candidateId)).update({ status: "active", approvedAtIso });
  return { outcome: "ok", membership: { ...pending, status: "active", approvedAtIso } };
}

export type LeaveOutcome =
  | { readonly outcome: "ok"; readonly dissolved: boolean }
  | { readonly outcome: "missing" };

/**
 * A member leaves, or the owner removes a member (SPEC §3.4: "anyone can
 * leave", "the owner can ... remove members"). Former members lose access
 * immediately: the membership document is deleted, not tombstoned — it is a
 * directory entry, not content.
 */
export async function removeMember(deps: TablesDeps, tableId: TableId, requesterId: AccountId, memberId: AccountId): Promise<LeaveOutcome> {
  const table = await getTable(deps, tableId);
  if (table === null || table.deletedAtIso !== null) {
    return { outcome: "missing" };
  }
  const membership = await getMembership(deps, tableId, memberId);
  if (membership === null) {
    return { outcome: "missing" };
  }
  const isSelf = requesterId === memberId;
  const isOwner = table.ownerAccountId === requesterId;
  if (!isSelf && !isOwner) {
    throw errForbidden("only the member or the table owner can remove a membership");
  }
  if (membership.role === "owner") {
    await dissolveTable(deps, tableId);
    return { outcome: "ok", dissolved: true };
  }
  await deps.store.tableMemberships.doc(membershipDocId(tableId, memberId)).delete();
  return { outcome: "ok", dissolved: false };
}

// ---------------------------------------------------------------------------
// shared cooks
// ---------------------------------------------------------------------------

export interface NewSharedCookInput {
  readonly sourceRecipeId: string;
  readonly recipeRevision: string;
  readonly servings: number | null;
  readonly swapsMade: readonly string[];
  readonly rating: number | null;
  readonly note: string | null;
  readonly cookedOn: string;
}

export async function createSharedCook(deps: TablesDeps, tableId: TableId, authorId: AccountId, input: NewSharedCookInput): Promise<SharedCookRecord> {
  if (!DAY_PATTERN.test(input.cookedOn)) {
    throw errValidation("cookedOn must be a UTC day (YYYY-MM-DD)");
  }
  const sharedCookId = newSharedCookId();
  const nowIso = toIso(deps.clock.now());
  const record: SharedCookRecord = {
    sharedCookId,
    tableId,
    authorId,
    sourceRecipeId: input.sourceRecipeId,
    recipeRevision: input.recipeRevision,
    servings: input.servings,
    swapsMade: input.swapsMade,
    rating: input.rating,
    note: input.note,
    cookedOn: input.cookedOn,
    createdAtIso: nowIso,
    deletedAtIso: null,
  };
  await deps.store.sharedCooks.doc(sharedCookId).create(record);
  return record;
}

/**
 * Dissolves a table: no one is left to approve invites or members. The
 * table doc and its invites are tombstoned, every membership is removed.
 * Shared-cook documents survive as records (the interpretation recorded in
 * the M4 handoff) but become unreachable — only active members of a live
 * table can read them.
 */
export async function dissolveTable(deps: TableCoreDeps, tableId: TableId): Promise<void> {
  const nowIso = toIso(deps.clock.now());
  const members = await listActiveMembers(deps, tableId);
  await deps.store.tables.doc(tableId).update({ deletedAtIso: nowIso });
  for (const member of members) {
    await deps.store.tableMemberships.doc(membershipDocId(tableId, member.accountId)).delete();
  }
  const invites = await deps.store.tableInvites.where("tableId", "==", tableId).get();
  for (const doc of invites.docs) {
    await doc.ref.update({ status: "revoked", revokedAtIso: nowIso });
  }
}

/** All shared cooks of one table, newest first; visibility filtering is the route's job. */
export async function listSharedCooks(deps: TablesDeps, tableId: TableId): Promise<SharedCookRecord[]> {
  const snap = await deps.store.sharedCooks.where("tableId", "==", tableId).get();
  return snap.docs
    .map((doc) => parseSharedCookDoc(doc))
    .filter((c): c is SharedCookRecord => c !== null)
    .filter((c) => c.deletedAtIso === null)
    .sort((a, b) => (a.createdAtIso < b.createdAtIso ? 1 : -1));
}
