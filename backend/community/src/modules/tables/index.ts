/**
 * Tables module (SPEC §5): private groups of 2–8 who see each other's shared
 * cooks. Invites are by code/link and need owner approval; the owner controls
 * membership; anyone can leave; departed members' cards stay in history but
 * render without their content or name (§5.1). The module also owns the
 * block endpoints (§6.3) — the base slice declared them in the contract but
 * left them unimplemented, and this slice's scope is where they land.
 *
 * Shared cooks carry exactly the fields shared-cook.schema.json allows (§5.2).
 * Reports work through the moderation module's POST /reports (targetType
 * tableCard|tableMember); this module derives card hiding from queued cases,
 * so the report path needs no change (§5.3).
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import {
  errConflict,
  errForbidden,
  errNotFound,
  errValidation,
  CommunityError,
} from "../../core/errors.js";
import { readObject, readString, requireAccount } from "../../core/http.js";
import { accountIdShape, blockPairId } from "../../core/ids.js";
import { isUuid } from "../../core/validate.js";
import { consumeRate } from "../../core/rateLimit.js";
import { BLOCKS_COLLECTION, CASES_COLLECTION, OPERATIONS_COLLECTION, PUBLICATIONS_COLLECTION } from "../../core/storeRepos.js";
import {
  cardIdShape,
  inviteIdShape,
  joinCodeHash,
  newJoinCode,
  tableIdShape,
  validateJoinCode,
} from "./ids.js";
import {
  blockListView,
  cardView,
  inviteView,
  MAX_TABLE_MEMBERS,
  tableView,
  validateSharedCook,
  type CardRecord,
  type InviteRecord,
  type TableMemberRow,
  type TableRecord,
} from "./views.js";

const TABLES_COLLECTION = "tables";
const INVITES_COLLECTION = "tableInvites";
const CARDS_COLLECTION = "tableCards";

/** Share writes per account per UTC day; the contract reserves 429 for write bursts. */
const DAILY_SHARE_LIMIT = 40;
const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // SPEC §5.1: invites expire after 7 days

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DocDataLike = any;

function parseTable(id: string, data: DocDataLike): TableRecord {
  return data as TableRecord;
}

function parseInvite(id: string, data: DocDataLike): InviteRecord {
  return data as InviteRecord;
}

function parseCard(id: string, data: DocDataLike): CardRecord {
  return data as CardRecord;
}

const tablesModule: ModuleDefinition = {
  name: "tables",
  version: 1,
  schema: (registry) => {
    registry.collection(TABLES_COLLECTION, "tables");
    registry.collection(INVITES_COLLECTION, "tables");
    registry.collection(CARDS_COLLECTION, "tables");
    registry.collection(BLOCKS_COLLECTION, "tables");
  },
  routes: (ctx) => {
    const tables = ctx.store.collection(TABLES_COLLECTION);
    const invites = ctx.store.collection(INVITES_COLLECTION);
    const cards = ctx.store.collection(CARDS_COLLECTION);
    const blocks = ctx.store.collection(BLOCKS_COLLECTION);
    const accounts = ctx.store.collection("accounts");

    async function displayName(accountId: string): Promise<string> {
      const snap = await accounts.doc(accountId).get();
      const raw = snap.data?.["displayName"];
      return typeof raw === "string" && raw.length > 0 ? raw : "Cook";
    }

    async function nameMap(accountIds: readonly string[]): Promise<Map<string, string>> {
      const out = new Map<string, string>();
      for (const id of accountIds) {
        out.set(id, await displayName(id));
      }
      return out;
    }

    /** True when a mutual block exists between the two accounts (§6.3). */
    async function areBlocked(a: string, b: string): Promise<boolean> {
      if (a === b) {
        return false;
      }
      const snap = await blocks.doc(blockPairId(a, b)).get();
      return snap.data !== null && snap.data["removedAt"] === undefined;
    }

    async function activeMemberIds(record: TableRecord): Promise<string[]> {
      return record.members.filter((m) => m.departedAt === null).map((m) => m.accountId);
    }

    async function requireActiveMembership(record: TableRecord, accountId: string): Promise<void> {
      const member = record.members.find((m) => m.accountId === accountId);
      if (member === undefined || member.departedAt !== null) {
        // Former members lose access (§5.1); non-members learn nothing either way.
        throw errNotFound("table not found");
      }
    }

    async function requireTable(tableId: string): Promise<TableRecord> {
      const snap = await tables.doc(tableId).get();
      if (snap.data === null) {
        throw errNotFound("table not found");
      }
      return parseTable(tableId, snap.data);
    }

    /** Lazy expiry: a pending invite past its TTL reads as expired (§5.1). */
    function effectiveInvite(record: InviteRecord, nowMs: number): InviteRecord {
      if (record.state === "pending" && Date.parse(record.expiresAt) <= nowMs) {
        return { ...record, state: "expired" as const };
      }
      return record;
    }

    /** Card feed with the visibility rules of §5.1/§5.3 applied for one viewer. */
    async function feedFor(record: TableRecord, viewerAccountId: string): Promise<Record<string, unknown>[]> {
      const memberIds = new Set(await activeMemberIds(record));
      const docs = await cards.where("tableId", record.tableId).get();
      const all = docs.map((d) => parseCard(d.id, d.data));
      all.sort((a, b) => b.createdAt.localeCompare(a.createdAt) || a.cardId.localeCompare(b.cardId));
      const out: Record<string, unknown>[] = [];
      for (const card of all) {
        if (card.deletedAt !== undefined && card.deletedAt !== null) {
          continue; // the author removed their own card (§5.2)
        }
        // A reported card hides from all members while its case is queued (§5.3).
        const openCases = await ctx.store.collection(CASES_COLLECTION).where("targetId", card.cardId).where("state", "queued").get();
        if (openCases.length > 0) {
          continue;
        }
        const authorIsActive = memberIds.has(card.authorAccountId);
        if (authorIsActive && card.authorAccountId !== viewerAccountId && (await areBlocked(viewerAccountId, card.authorAccountId))) {
          continue; // a blocked pair's cards are filtered from each other's view (§5.1/§6.3)
        }
        out.push(cardView(card, viewerAccountId, !authorIsActive));
      }
      return out;
    }

    return [
      {
        method: "POST",
        pattern: "/tables",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const body = readObject(req);
          const name = readString(body, "name");
          if (name === null || name.length < 1 || name.length > 60) {
            throw errValidation("validation", "field name must be a string of 1-60 characters");
          }
          const nowIso = ctx.clock.now().toISOString();
          const record: TableRecord = {
            tableId: tableIdShape.newId(),
            name,
            createdAt: nowIso,
            members: [{ accountId, role: "owner", joinedAt: nowIso, departedAt: null }],
          };
          await tables.doc(record.tableId).create({ ...record });
          const names = await nameMap([accountId]);
          return json(201, tableView(record, names, [], true));
        },
      },
      {
        method: "GET",
        pattern: "/tables/:tableId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireTable(tableIdShape.validate(req.params["tableId"]));
          await requireActiveMembership(record, accountId);
          const pendingDocs = await invites.where("tableId", record.tableId).where("state", "pending").get();
          const pending = pendingDocs.map((d) => parseInvite(d.id, d.data)).filter((i) => Date.parse(i.expiresAt) > ctx.clock.now().getTime());
          const names = await nameMap([...record.members.map((m) => m.accountId), ...pending.map((p) => p.requestedByAccountId).filter((id): id is string => id !== null)]);
          return json(200, tableView(record, names, pending, record.members.find((m) => m.accountId === accountId)?.role === "owner"));
        },
      },
      {
        method: "POST",
        pattern: "/tables/:tableId/invites",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireTable(tableIdShape.validate(req.params["tableId"]));
          const owner = record.members.find((m) => m.accountId === accountId);
          if (owner === undefined || owner.departedAt !== null || owner.role !== "owner") {
            throw errForbidden("only the table owner can mint invites");
          }
          const activeCount = (await activeMemberIds(record)).length;
          if (activeCount >= MAX_TABLE_MEMBERS) {
            throw new CommunityError(409, "conflict", "the table is full; someone has to leave first", "table_full");
          }
          const now = ctx.clock.now();
          const code = newJoinCode();
          const inviteRecord: InviteRecord = {
            inviteId: inviteIdShape.newId(),
            tableId: record.tableId,
            codeHash: await joinCodeHash(code),
            state: "pending",
            createdAt: now.toISOString(),
            expiresAt: new Date(now.getTime() + INVITE_TTL_MS).toISOString(),
            requestedByAccountId: null,
            requestedByDisplayName: null,
          };
          await invites.doc(inviteRecord.inviteId).create({ ...inviteRecord });
          return json(201, inviteView(inviteRecord, code));
        },
      },
      {
        method: "POST",
        pattern: "/tables/:tableId/invites/:inviteId/approve",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const tableId = tableIdShape.validate(req.params["tableId"]);
          const inviteId = inviteIdShape.validate(req.params["inviteId"]);
          const updated = await ctx.store.runTransaction(async (tx) => {
            const tableSnap = await tx.collection(TABLES_COLLECTION).doc(tableId).get();
            if (tableSnap.data === null) {
              throw errNotFound("table not found");
            }
            const record = parseTable(tableId, tableSnap.data);
            const owner = record.members.find((m) => m.accountId === accountId);
            if (owner === undefined || owner.departedAt !== null || owner.role !== "owner") {
              throw errForbidden("only the table owner can approve join requests");
            }
            const inviteSnap = await tx.collection(INVITES_COLLECTION).doc(inviteId).get();
            if (inviteSnap.data === null) {
              throw errNotFound("invite not found");
            }
            const invite = effectiveInvite(parseInvite(inviteId, inviteSnap.data), ctx.clock.now().getTime());
            if (invite.tableId !== tableId) {
              throw errNotFound("invite not found");
            }
            if (invite.state !== "pending" || invite.requestedByAccountId === null) {
              throw errConflict("conflict", `the invite is ${invite.state}, not pending`);
            }
            const joinerId = accountIdShape.validate(invite.requestedByAccountId);
            const joinerAccount = await tx.collection("accounts").doc(joinerId).get();
            if (joinerAccount.data === null) {
              throw errNotFound("the requester no longer has an account");
            }
            const activeMembers = record.members.filter((m) => m.departedAt === null);
            if (activeMembers.length >= MAX_TABLE_MEMBERS) {
              throw new CommunityError(409, "conflict", "the table is full; someone has to leave first", "table_full");
            }
            if (activeMembers.some((m) => m.accountId === joinerId)) {
              throw errConflict("conflict", "the requester is already a member");
            }
            for (const member of activeMembers) {
              if (await areBlocked(member.accountId, joinerId)) {
                throw errForbidden("a block in the table prevents this join");
              }
            }
            const joinedAt = ctx.clock.now().toISOString();
            const memberRow: TableMemberRow = { accountId: joinerId, role: "member", joinedAt, departedAt: null };
            const members = [...record.members, memberRow];
            await tx.collection(TABLES_COLLECTION).doc(tableId).update({ members });
            await tx.collection(INVITES_COLLECTION).doc(inviteId).update({ state: "approved" });
            return { invite: { ...invite, state: "approved" as const }, names: new Map<string, string>() };
          });
          const names = await nameMap([accountId, updated.invite.requestedByAccountId ?? accountId]);
          return json(200, { ...inviteView(updated.invite), requestedByDisplayName: names.get(updated.invite.requestedByAccountId ?? accountId) ?? null });
        },
      },
      {
        method: "DELETE",
        pattern: "/tables/:tableId/invites/:inviteId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const tableId = tableIdShape.validate(req.params["tableId"]);
          const inviteId = inviteIdShape.validate(req.params["inviteId"]);
          const record = await requireTable(tableId);
          const owner = record.members.find((m) => m.accountId === accountId);
          if (owner === undefined || owner.departedAt !== null || owner.role !== "owner") {
            throw errForbidden("only the table owner can revoke invites");
          }
          const inviteSnap = await invites.doc(inviteId).get();
          if (inviteSnap.data === null || (inviteSnap.data as DocDataLike).tableId !== tableId) {
            throw errNotFound("invite not found");
          }
          // Revoking invalidates the code immediately; a former code is never reusable.
          await invites.doc(inviteId).update({ state: "revoked" });
          return { status: 204 };
        },
      },
      {
        method: "POST",
        pattern: "/invites/:code/join",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const code = validateJoinCode(req.params["code"]);
          const hash = await joinCodeHash(code);
          const matches = await invites.where("codeHash", hash).get();
          const doc = matches[0];
          if (doc === undefined || doc.data === null) {
            throw errNotFound("invite not found");
          }
          const invite = effectiveInvite(parseInvite(doc.id, doc.data), ctx.clock.now().getTime());
          const tableRecord = await requireTable(invite.tableId);
          // Blocked pairs never meet in a table (§6.3): the join is refused
          // silently, 404 to the blocked joiner (§9.6).
          for (const member of await activeMemberIds(tableRecord)) {
            if (await areBlocked(member, accountId)) {
              throw errNotFound("invite not found");
            }
          }
          if (invite.state !== "pending" || Date.parse(invite.expiresAt) <= ctx.clock.now().getTime()) {
            throw errNotFound("invite not found");
          }
          const alreadyMember = tableRecord.members.some((m) => m.accountId === accountId && m.departedAt === null);
          if (alreadyMember) {
            throw errConflict("conflict", "you are already a member of this table");
          }
          const requesterName = await displayName(accountId);
          // Idempotent asking: the same joiner re-presenting the code keeps the
          // original request; a different account on a claimed code is refused.
          if (invite.requestedByAccountId !== null && invite.requestedByAccountId !== accountId) {
            throw errConflict("conflict", "someone has already asked to join with this code");
          }
          if (invite.requestedByAccountId === null) {
            await invites.doc(invite.inviteId).update({ requestedByAccountId: accountId, requestedByDisplayName: requesterName });
          }
          // Presenting a code asks; it does not add (202 Accepted, contract joinTable).
          return json(202, { inviteId: invite.inviteId, tableId: tableRecord.tableId, tableName: tableRecord.name, state: "pending" });
        },
      },
      {
        method: "DELETE",
        pattern: "/tables/:tableId/members/:accountId",
        handler: async (req) => {
          const ownerAccountId = requireAccount(req);
          const tableId = tableIdShape.validate(req.params["tableId"]);
          const targetId = accountIdShape.validate(req.params["accountId"]);
          const updated = await ctx.store.runTransaction(async (tx) => {
            const tableSnap = await tx.collection(TABLES_COLLECTION).doc(tableId).get();
            if (tableSnap.data === null) {
              throw errNotFound("table not found");
            }
            const record = parseTable(tableId, tableSnap.data);
            const owner = record.members.find((m) => m.accountId === ownerAccountId);
            if (owner === undefined || owner.departedAt !== null || owner.role !== "owner") {
              throw errForbidden("only the table owner can remove members");
            }
            if (targetId === ownerAccountId) {
              throw errConflict("conflict", "the owner cannot remove themselves");
            }
            const target = record.members.find((m) => m.accountId === targetId);
            if (target === undefined || target.departedAt !== null) {
              throw errNotFound("member not found");
            }
            const members = record.members.map((m) => (m.accountId === targetId ? { ...m, departedAt: ctx.clock.now().toISOString() } : m));
            await tx.collection(TABLES_COLLECTION).doc(tableId).update({ members });
            return { ...record, members };
          });
          // Removal takes effect immediately: the former member loses access;
          // their past cards stay in history, redacted in every feed view (§5.1).
          void updated;
          return { status: 204 };
        },
      },
      {
        method: "POST",
        pattern: "/tables/:tableId/leave",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const tableId = tableIdShape.validate(req.params["tableId"]);
          await ctx.store.runTransaction(async (tx) => {
            const tableSnap = await tx.collection(TABLES_COLLECTION).doc(tableId).get();
            if (tableSnap.data === null) {
              throw errNotFound("table not found");
            }
            const record = parseTable(tableId, tableSnap.data);
            const member = record.members.find((m) => m.accountId === accountId);
            if (member === undefined || member.departedAt !== null) {
              throw errNotFound("table not found");
            }
            if (member.role === "owner") {
              // The contract has no delete-table endpoint; the owner deletes
              // the table instead of leaving it (§5.1 roles). Assumption recorded in the PR.
              throw errConflict("conflict", "the owner cannot leave; delete the table instead");
            }
            const members = record.members.map((m) => (m.accountId === accountId ? { ...m, departedAt: ctx.clock.now().toISOString() } : m));
            await tx.collection(TABLES_COLLECTION).doc(tableId).update({ members });
          });
          return { status: 204 };
        },
      },
      {
        method: "POST",
        pattern: "/tables/:tableId/cards",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireTable(tableIdShape.validate(req.params["tableId"]));
          await requireActiveMembership(record, accountId);
          await consumeRate(ctx.store, "share-cook", accountId, DAILY_SHARE_LIMIT, ctx.clock);
          const body = readObject(req);
          const operationId = readString(body, "operationId");
          if (operationId === null || !isUuid(operationId)) {
            throw errValidation("validation", "field operationId must be a client-generated UUID");
          }
          const operationSnap = await ctx.store.collection(OPERATIONS_COLLECTION).doc(operationId).get();
          if (operationSnap.data !== null) {
            if (operationSnap.data["accountId"] !== accountId) {
              throw errForbidden("this operationId belongs to another account");
            }
            return json(201, operationSnap.data["response"]);
          }

          // Sharing anything requires the 18+ account (§6.2): sharing to a
          // Table is sharing.
          const accountSnap = await accounts.doc(accountId).get();
          const accountData = accountSnap.data;
          const attested = typeof accountData?.["attested18PlusAtIso"] === "string";
          const birthYear = accountData?.["birthYear"];
          const currentYear = ctx.clock.now().getUTCFullYear();
          if (!attested || typeof birthYear !== "number" || currentYear - birthYear < 18) {
            throw errForbidden("sharing is 18+", "not_adult");
          }
          const authorDisplayName = await displayName(accountId);
          const cook = validateSharedCook(body["cook"], authorDisplayName);

          // Content rides the payload only when the revision was never
          // published (§5.2): a published revision is fetchable, so the server
          // strips the duplicate copy.
          const mine = await ctx.store.collection(PUBLICATIONS_COLLECTION).where("authorId", accountId).get();
          const publishedMatching = mine
            .map((d) => d.data as DocDataLike)
            .some(
              (p) =>
                p["state"] === "published" &&
                p["recipeRef"]?.["id"] === cook.recipeRef.id &&
                p["recipeRef"]?.["revision"] === cook.recipeRef.revision,
            );
          const storedCook = publishedMatching ? { ...cook, content: null } : cook;

          const cardRecord: CardRecord = {
            cardId: cardIdShape.newId(),
            tableId: record.tableId,
            authorAccountId: accountId,
            cook: storedCook,
            createdAt: ctx.clock.now().toISOString(),
          };
          await cards.doc(cardRecord.cardId).create({ ...cardRecord });
          const response = cardView(cardRecord, accountId, false);
          await ctx.store.collection(OPERATIONS_COLLECTION).doc(operationId).create({
            accountId,
            createdAt: cardRecord.createdAt,
            response,
          });
          return json(201, response);
        },
      },
      {
        method: "GET",
        pattern: "/tables/:tableId/cards",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireTable(tableIdShape.validate(req.params["tableId"]));
          await requireActiveMembership(record, accountId);
          return json(200, { cards: await feedFor(record, accountId) });
        },
      },
      {
        method: "DELETE",
        pattern: "/tables/:tableId/cards/:cardId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireTable(tableIdShape.validate(req.params["tableId"]));
          await requireActiveMembership(record, accountId);
          const cardId = cardIdShape.validate(req.params["cardId"]);
          const cardSnap = await cards.doc(cardId).get();
          if (cardSnap.data === null) {
            throw errNotFound("card not found");
          }
          const card = parseCard(cardId, cardSnap.data);
          if (card.tableId !== record.tableId || card.authorAccountId !== accountId) {
            throw errNotFound("card not found");
          }
          await cards.doc(cardId).set({ ...card, deletedAt: ctx.clock.now().toISOString() });
          return { status: 204 };
        },
      },
      {
        method: "PUT",
        pattern: "/blocks/:accountId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const target = accountIdShape.validate(req.params["accountId"]);
          if (target === accountId) {
            throw errValidation("validation", "you cannot block yourself");
          }
          const id = blockPairId(accountId, target);
          const snap = await blocks.doc(id).get();
          // Idempotent re-block: still 204, still one row (a tombstone from a
          // past unblock is overwritten, not stacked).
          if (snap.data === null || snap.data["removedAt"] !== undefined) {
            await blocks.doc(id).set({
              accountA: [accountId, target].sort()[0],
              accountB: [accountId, target].sort()[1],
              createdBy: accountId,
              createdAt: ctx.clock.now().toISOString(),
            });
          }
          return { status: 204 };
        },
      },
      {
        method: "DELETE",
        pattern: "/blocks/:accountId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const target = accountIdShape.validate(req.params["accountId"]);
          if (target === accountId) {
            throw errValidation("validation", "you cannot unblock yourself");
          }
          await blocks.doc(blockPairId(accountId, target)).set({ accountA: [accountId, target].sort()[0], accountB: [accountId, target].sort()[1], removedAt: ctx.clock.now().toISOString() });
          return { status: 204 };
        },
      },
      {
        method: "GET",
        pattern: "/blocks",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const asA = await blocks.where("accountA", accountId).get();
          const asB = await blocks.where("accountB", accountId).get();
          const rows: { accountId: string; displayName: string | null; createdAt: string }[] = [];
          const seen = new Set<string>();
          for (const doc of [...asA, ...asB]) {
            if (doc.data === null || doc.data["removedAt"] !== undefined) {
              continue;
            }
            const other = doc.data["accountA"] === accountId ? (doc.data["accountB"] as string) : (doc.data["accountA"] as string);
            if (seen.has(other)) {
              continue;
            }
            seen.add(other);
            rows.push({
              accountId: other,
              displayName: await displayName(other),
              createdAt: doc.data["createdAt"] as string,
            });
          }
          rows.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
          return json(200, blockListView(rows));
        },
      },
    ];
  },
};

export default tablesModule;

// Re-exported for the tests' repository-level assertions and future operator tools.
export { TABLES_COLLECTION, INVITES_COLLECTION, CARDS_COLLECTION };
