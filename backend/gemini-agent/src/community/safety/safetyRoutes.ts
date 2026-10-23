/**
 * Safety routes (part: safety).
 *
 * POST   /v1/community/blocks                              block an account
 * GET    /v1/community/blocks                              the caller's blocks
 * DELETE /v1/community/blocks/:accountId                   unblock (blocker only)
 * POST   /v1/community/publications/:publicationId/reports report a publication
 * POST   /v1/community/account/deletion                    delete this account
 *
 * Reporting hides the publication before the queue item exists (the
 * ModerationQueue submission path — reports never leave a live publication
 * behind). Deletion is the coordinated run from ./deletion.ts: sessions
 * revoked first, every part tombstones its records, the account doc keeps
 * only non-PII survival fields.
 */
import { Router, type Router as ExpressRouter } from "express";
import type { CommunityDeps } from "../index.js";
import type { CommunityRuntime } from "../index.js";
import { errConflict, errNotFound, errRateLimited, errValidation } from "../shared/errors.js";
import { expectOneOf, expectOptionalString, expectString } from "../shared/parse.js";
import { mustCommunity, route } from "../shared/http.js";
import { parseAccountId } from "../shared/ids.js";
import { blockAccount, listBlocksForAccount, unblockAccount, type UnblockOutcome } from "./blocks.js";
import { REPORT_REASONS, submitReport, type ReportReason } from "./reports.js";
import type { AccountDeletionService } from "./deletion.js";

function expectRecord(raw: unknown, field: string): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw errValidation(`${field} must be an object`);
  }
  return raw as Record<string, unknown>;
}

function unblockStatus(outcome: UnblockOutcome): number {
  if (outcome.outcome === "ok") {
    return 204;
  }
  if (outcome.outcome === "missing") {
    return 404;
  }
  return 403;
}

export function createSafetyRoutes(deps: CommunityDeps, runtime: CommunityRuntime, deletion: AccountDeletionService): ExpressRouter {
  const router = Router();
  const blockDeps = { store: deps.store, clock: deps.clock };
  const reportDeps = {
    store: deps.store,
    clock: deps.clock,
    moderation: deps.moderation,
    reportLimitPerDay: deps.config.reportLimitPerDay,
  };

  router.post(
    "/v1/community/blocks",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const body = expectRecord(req.body ?? {}, "body");
      const blockedId = parseAccountId.parse(expectString(body["accountId"], "accountId", { min: 1, max: 128 }), "accountId");
      const target = await deps.store.accounts.doc(blockedId).get();
      if (!target.exists) {
        throw errNotFound("account not found");
      }
      await blockAccount(blockDeps, ctx.accountId, blockedId);
      res.status(201).json({ blockedAccountId: blockedId });
    }),
  );

  router.get(
    "/v1/community/blocks",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const records = await listBlocksForAccount(blockDeps, ctx.accountId);
      res.status(200).json({
        items: records.map((record) => ({
          accountId: pairOther(record, ctx.accountId),
          createdAtIso: record.createdAtIso,
        })),
      });
    }),
  );

  router.delete(
    "/v1/community/blocks/:accountId",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const blockedId = parseAccountId.parse(req.params["accountId"] ?? "", "account path id");
      const outcome = await unblockAccount(blockDeps, ctx.accountId, blockedId);
      if (outcome.outcome !== "ok") {
        res.status(unblockStatus(outcome)).json({ error: outcome.outcome === "forbidden" ? "only the blocker can unblock" : "no block exists" });
        return;
      }
      res.status(204).send();
    }),
  );

  router.post(
    "/v1/community/publications/:publicationId/reports",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const body = expectRecord(req.body ?? {}, "body");
      const reason = expectOneOf<ReportReason>(body["reason"], "reason", REPORT_REASONS);
      const note = expectOptionalString(body["note"], "note", { min: 1, max: 500 }) ?? null;
      const outcome = await submitReport(reportDeps, req.params["publicationId"] ?? "", ctx.accountId, reason, note);
      if (outcome.outcome === "missing") {
        throw errNotFound("publication not found");
      }
      if (outcome.outcome === "conflict" && outcome.reason === "not-live") {
        throw errConflict("only a live publication can be reported");
      }
      if (outcome.outcome === "conflict" && outcome.reason === "limit") {
        throw errRateLimited("too many reports today");
      }
      res.status(201).json({ reportId: outcome.report.reportId });
    }),
  );

  router.post(
    "/v1/community/account/deletion",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const record = await deletion.run(ctx.accountId);
      res.status(200).json({
        deletionRunId: record.deletionRunId,
        sessionsRevoked: record.sessionsRevoked,
        contributions: record.contributions,
        finishedAtIso: record.finishedAtIso,
      });
    }),
  );

  return router;
}

/** The other side of a block pair from the viewer. */
function pairOther(record: { a: string; b: string }, viewer: string): string {
  return record.a === viewer ? record.b : record.a;
}
