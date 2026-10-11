/**
 * Table routes (part: tables).
 *
 * POST   /v1/community/tables                                    create a table (caller owns it)
 * GET    /v1/community/tables                                    the caller's tables
 * GET    /v1/community/tables/:tableId                           member: roster (owner also sees pending)
 * POST   /v1/community/tables/:tableId/invites                   owner: mint an invite link token
 * POST   /v1/community/tables/:tableId/invites/:inviteId/revoke  owner: revoke an invite
 * GET    /v1/community/invites/:token                            open: what the link points at (finding 9)
 * POST   /v1/community/invites/:token/redeem                     redeem an invite → pending membership
 * POST   /v1/community/tables/:tableId/members/:memberId/approve owner: approve a pending member
 * DELETE /v1/community/tables/:tableId/members/:memberId         leave (self) or owner-removal
 * POST   /v1/community/tables/:tableId/cooks                     member: share a cook (structured fields only)
 * GET    /v1/community/tables/:tableId/cooks                     member: the table's shared cooks, block-aware
 *
 * The account boundary is requireAccount everywhere except the invite-link
 * read the spec asks to work as a link; it returns table name and state
 * only — no account ids, no membership data.
 */
import { Router, type Router as ExpressRouter } from "express";
import type { CommunityDeps } from "../index.js";
import type { CommunityRuntime } from "../index.js";
import { errConflict, errForbidden, errNotFound, errValidation } from "../shared/errors.js";
import { expectOptionalInt, expectOptionalString, expectString, expectArray } from "../shared/parse.js";
import { mustCommunity, route } from "../shared/http.js";
import {
  parseAccountId,
  parseInviteId,
  parseTableId,
  type AccountId,
} from "../shared/ids.js";
import { toDay } from "../shared/time.js";
import {
  approveMember,
  createInvite,
  createSharedCook,
  createTable,
  findInviteByToken,
  getMembership,
  getTable,
  INVITE_TOKEN_PATTERN,
  listActiveMembers,
  listSharedCooks,
  listTablesForAccount,
  parseMembershipDoc,
  redeemInvite,
  removeMember,
  revokeInvite,
  type MembershipRecord,
  type SharedCookRecord,
  type TableRecord,
  type TablesDeps,
} from "./tables.js";

function expectRecord(raw: unknown, field: string): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw errValidation(`${field} must be an object`);
  }
  return raw as Record<string, unknown>;
}

function parseInviteToken(raw: unknown, field: string): string {
  const token = expectString(raw, field, { min: 40, max: 128 });
  if (!INVITE_TOKEN_PATTERN.test(token)) {
    throw errValidation(`${field} must be an invite link token`);
  }
  return token;
}

function tables(deps: CommunityDeps): TablesDeps {
  return { store: deps.store, clock: deps.clock, assertCanInteract: deps.blocks.assertCanInteract };
}

async function accountDisplayName(deps: CommunityDeps, accountId: AccountId): Promise<string | null> {
  const snap = await deps.store.accounts.doc(accountId).get();
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  return expectOptionalString(data["displayName"], "displayName", { max: 64 }) ?? null;
}

function tableView(table: TableRecord, membership: MembershipRecord): Record<string, unknown> {
  return {
    tableId: table.tableId,
    name: table.name,
    createdAtIso: table.createdAtIso,
    your: { role: membership.role, status: membership.status },
  };
}

function cookView(cook: SharedCookRecord, authorDisplayName: string | null): Record<string, unknown> {
  // SPEC 3.4 day-only: a shared-cook response carries the UTC day the cook
  // happened and never the record's exact share time — table members learn
  // what was cooked and on which day, not the moment it was shared. The
  // exact createdAtIso stays in storage (ordering) and out of this view.
  return {
    sharedCookId: cook.sharedCookId,
    tableId: cook.tableId,
    authorAccountId: cook.authorId,
    authorDisplayName,
    source: { recipeId: cook.sourceRecipeId, recipeRevision: cook.recipeRevision },
    servings: cook.servings,
    swapsMade: cook.swapsMade,
    rating: cook.rating,
    note: cook.note,
    cookedOn: cook.cookedOn,
  };
}

export function createTableRoutes(deps: CommunityDeps, runtime: CommunityRuntime): ExpressRouter {
  const router = Router();

  router.post(
    "/v1/community/tables",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const body = expectRecord(req.body ?? {}, "body");
      const name = expectString(body["name"], "name", { min: 1, max: 64 });
      const table = await createTable(tables(deps), ctx.accountId, name);
      res.status(201).json({
        ...tableView(table, {
          tableId: table.tableId,
          accountId: ctx.accountId,
          role: "owner",
          status: "active",
          createdAtIso: table.createdAtIso,
          approvedAtIso: table.createdAtIso,
        }),
        ownerAccountId: table.ownerAccountId,
        members: [],
      });
    }),
  );

  router.get(
    "/v1/community/tables",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const entries = await listTablesForAccount(tables(deps), ctx.accountId);
      res.status(200).json({ tables: entries.map(({ table, membership }) => tableView(table, membership)) });
    }),
  );

  router.get(
    "/v1/community/tables/:tableId",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const table = await getTable(tables(deps), tableId);
      if (table === null || table.deletedAtIso !== null) {
        throw errNotFound("table not found");
      }
      const own = await getMembership(tables(deps), tableId, ctx.accountId);
      if (own === null) {
        throw errForbidden("only members can see a table");
      }
      const isOwner = table.ownerAccountId === ctx.accountId;
      const members = await listActiveMembers(tables(deps), tableId);
      // Pending candidates are visible to the owner only — they are the ones
      // who must approve, and a pending member is not yet part of the group.
      const pending: MembershipRecord[] = isOwner
        ? (await deps.store.tableMemberships.where("tableId", "==", tableId).get()).docs
            .map((doc) => parseMembershipDoc(doc))
            .filter((m): m is MembershipRecord => m !== null && m.status === "pending")
        : [];
      // Blocked pairs have no co-presence, even on the roster — but a viewer
      // always sees their own entry. Pending candidates go through the same
      // filter (the owner must see who to approve, minus anyone blocked).
      const candidateIds = [...members, ...(isOwner ? pending : [])]
        .filter((m) => m.accountId !== ctx.accountId)
        .map((m) => m.accountId);
      const visibleOthers = new Set(await deps.blocks.filterVisible(ctx.accountId, candidateIds));
      const roster = [...members, ...pending].filter((m) => m.accountId === ctx.accountId || visibleOthers.has(m.accountId));
      const withNames = await Promise.all(
        roster.map(async (m) => ({
          accountId: m.accountId,
          role: m.role,
          status: m.status,
          displayName: await accountDisplayName(deps, m.accountId),
        })),
      );
      res.status(200).json({
        ...tableView(table, own),
        ownerAccountId: table.ownerAccountId,
        members: withNames,
      });
    }),
  );

  router.post(
    "/v1/community/tables/:tableId/invites",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const table = await getTable(tables(deps), tableId);
      if (table === null || table.deletedAtIso !== null) {
        throw errNotFound("table not found");
      }
      if (table.ownerAccountId !== ctx.accountId) {
        throw errForbidden("only the table owner can invite");
      }
      const { invite, token } = await createInvite(tables(deps), tableId);
      res.status(201).json({ inviteId: invite.inviteId, token, createdAtIso: invite.createdAtIso });
    }),
  );

  router.post(
    "/v1/community/tables/:tableId/invites/:inviteId/revoke",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const inviteId = parseInviteId.parse(req.params["inviteId"], "invite path id");
      const table = await getTable(tables(deps), tableId);
      if (table === null || table.deletedAtIso !== null) {
        throw errNotFound("table not found");
      }
      const outcome = await revokeInvite(tables(deps), tableId, inviteId, ctx.accountId);
      if (outcome.outcome === "missing") {
        throw errNotFound("invite not found");
      }
      if (outcome.outcome === "forbidden") {
        throw errForbidden("only the table owner can revoke an invite");
      }
      res.status(204).send();
    }),
  );

  // Open by design (finding 9: the invitation carries a useful object
  // readable without the app). It names the table and its state — nothing
  // about accounts or membership.
  router.get(
    "/v1/community/invites/:token",
    route(async (req, res) => {
      const token = parseInviteToken(req.params["token"], "token");
      const found = await findInviteByToken(tables(deps), token);
      if (found === null) {
        throw errNotFound("invite not found");
      }
      res.status(200).json({
        tableName: found.table.name,
        state: found.table.deletedAtIso !== null ? "dissolved" : found.invite.status,
      });
    }),
  );

  router.post(
    "/v1/community/invites/:token/redeem",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const token = parseInviteToken(req.params["token"], "token");
      expectRecord(req.body ?? {}, "body");
      // redeemInvite performs the co-presence block checks (candidate vs
      // owner and active members) before any membership is written.
      const outcome = await redeemInvite(tables(deps), token, ctx.accountId);
      if (outcome.outcome === "missing") {
        throw errNotFound("invite not found");
      }
      if (outcome.outcome === "conflict") {
        throw errConflict("this invite is no longer redeemable");
      }
      res.status(200).json({
        tableId: outcome.table.tableId,
        tableName: outcome.table.name,
        status: outcome.membership.status,
      });
    }),
  );

  router.post(
    "/v1/community/tables/:tableId/members/:memberId/approve",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const memberId = parseAccountId.parse(req.params["memberId"], "member path id");
      const outcome = await approveMember(tables(deps), tableId, ctx.accountId, memberId, deps.config.tableMaxSize);
      if (outcome.outcome === "missing") {
        throw errNotFound("pending membership not found");
      }
      if (outcome.outcome === "forbidden") {
        throw errForbidden("only the table owner can approve members");
      }
      if (outcome.outcome === "conflict") {
        throw errConflict("the table is full");
      }
      res.status(200).json({ accountId: memberId, status: outcome.membership.status });
    }),
  );

  router.delete(
    "/v1/community/tables/:tableId/members/:memberId",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const memberId = parseAccountId.parse(req.params["memberId"], "member path id");
      const outcome = await removeMember(tables(deps), tableId, ctx.accountId, memberId);
      if (outcome.outcome === "missing") {
        throw errNotFound("membership not found");
      }
      res.status(204).send();
    }),
  );

  router.post(
    "/v1/community/tables/:tableId/cooks",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const table = await getTable(tables(deps), tableId);
      if (table === null || table.deletedAtIso !== null) {
        throw errNotFound("table not found");
      }
      const membership = await getMembership(tables(deps), tableId, ctx.accountId);
      if (membership === null || membership.status !== "active") {
        throw errForbidden("only active members can share cooks");
      }
      const body = expectRecord(req.body ?? {}, "body");
      const source = expectRecord(body["source"], "source");
      const cookedOn = expectOptionalString(body["cookedOn"], "cookedOn", { min: 10, max: 10 }) ?? toDay(deps.clock.now());
      if (cookedOn > toDay(deps.clock.now())) {
        // A cook in the future is caller error, not data to store.
        throw errValidation("cookedOn cannot be in the future");
      }
      const created = await createSharedCook(tables(deps), tableId, ctx.accountId, {
        sourceRecipeId: expectString(source["recipeId"], "source.recipeId", { min: 1, max: 128 }),
        recipeRevision: expectString(source["recipeRevision"], "source.recipeRevision", { min: 1, max: 128 }),
        servings: expectOptionalInt(body["servings"], "servings", { min: 1, max: 12 }) ?? null,
        swapsMade:
          body["swapsMade"] === undefined
            ? []
            : expectArray(body["swapsMade"], "swapsMade", { max: 8 }).map((s, i) =>
                expectString(s, `swapsMade[${i}]`, { min: 1, max: 120 }),
              ),
        rating: expectOptionalInt(body["rating"], "rating", { min: 1, max: 5 }) ?? null,
        note: expectOptionalString(body["note"], "note", { min: 1, max: 280 }) ?? null,
        cookedOn,
      });
      res.status(201).json(cookView(created, null));
    }),
  );

  router.get(
    "/v1/community/tables/:tableId/cooks",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const tableId = parseTableId.parse(req.params["tableId"], "table path id");
      const table = await getTable(tables(deps), tableId);
      if (table === null || table.deletedAtIso !== null) {
        throw errNotFound("table not found");
      }
      const membership = await getMembership(tables(deps), tableId, ctx.accountId);
      if (membership === null || membership.status !== "active") {
        throw errForbidden("only active members can see a table's shared cooks");
      }
      const cooks = await listSharedCooks(tables(deps), tableId);
      // Blocks apply at read time; a viewer always sees their own cooks.
      const otherIds = [...new Set(cooks.filter((c) => c.authorId !== ctx.accountId).map((c) => c.authorId))];
      const visibleOthers = new Set(await deps.blocks.filterVisible(ctx.accountId, otherIds));
      const visible = cooks.filter((c) => c.authorId === ctx.accountId || visibleOthers.has(c.authorId));
      const names = new Map<AccountId, string | null>();
      for (const cook of visible) {
        if (!names.has(cook.authorId)) {
          names.set(cook.authorId, await accountDisplayName(deps, cook.authorId));
        }
      }
      res.status(200).json({ items: visible.map((cook) => cookView(cook, names.get(cook.authorId) ?? null)) });
    }),
  );

  return router;
}
