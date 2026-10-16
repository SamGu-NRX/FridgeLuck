/**
 * Moderation module (SPEC §6.5–6.6): reports hide content immediately and
 * queue a human case; operators review the queue and decide. A report that
 * hides a *published* recipe stamps its case with `hiddenFrom: "published"`,
 * so `dismiss` can undo the hide — "dismiss → content returns" (SPEC §6.6).
 * Content the food-safety lint BLOCKED is different: no operator action here
 * re-publishes it (SPEC §2.3) — screening cases carry no `hiddenFrom` stamp,
 * and only the author's corrected revision re-publishes.
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import { errNotFound, errConflict, errValidation } from "../../core/errors.js";
import { readObject, readString, requireAccount, requireOperator } from "../../core/http.js";
import { caseIdShape, publicationIdShape } from "../../core/ids.js";
import { consumeRate } from "../../core/rateLimit.js";
import { StorePublicationRepository, CASES_COLLECTION, PUBLICATIONS_COLLECTION } from "../../core/storeRepos.js";
import { moderationCaseView, type ModerationCaseRecord } from "../../core/views.js";

const DAILY_REPORT_LIMIT = 10; // contracts/openapi.yaml: "10 reports per day limit"
const REPORT_REASONS = new Set(["food_safety", "rights", "personal_data", "spam", "harassment", "other"]);
const TARGET_TYPES = new Set(["recipe", "tableCard", "challengeEntry", "tableMember"]);
const DECISION_ACTIONS = new Set(["dismiss", "hide", "remove", "escalate_sam"]);

const moderationModule: ModuleDefinition = {
  name: "moderation",
  version: 1,
  routes: (ctx) => {
    const publications = new StorePublicationRepository({ store: ctx.store, clock: ctx.clock });
    const cases = ctx.store.collection(CASES_COLLECTION);
    return [
      {
        method: "POST",
        pattern: "/reports",
        handler: async (req) => {
          const accountId = requireAccount(req);
          await consumeRate(ctx.store, "report", accountId, DAILY_REPORT_LIMIT, ctx.clock);
          const body = readObject(req);
          const targetType = readString(body, "targetType");
          if (targetType === null || !TARGET_TYPES.has(targetType)) {
            throw errValidation("validation", "field targetType must be one of recipe|tableCard|challengeEntry|tableMember");
          }
          const targetId = readString(body, "targetId");
          if (targetId === null || targetId.length < 3 || targetId.length > 64) {
            throw errValidation("validation", "field targetId must be a string of 3-64 characters");
          }
          const reason = readString(body, "reason");
          if (reason === null || !REPORT_REASONS.has(reason)) {
            throw errValidation("validation", "field reason must be a contract report reason");
          }
          const detail = readString(body, "detail", { optional: true });
          if (detail !== null && detail.length > 280) {
            throw errValidation("validation", "field detail must be at most 280 characters");
          }

          let publicationState: string | null = null;
          let publicationAuthor: string | null = null;
          if (targetType === "recipe") {
            const publicationId = publicationIdShape.validate(targetId);
            const record = await publications.get(publicationId);
            if (record === null) {
              throw errNotFound("publication not found");
            }
            publicationState = record.state;
            publicationAuthor = record.authorId;
          }

          // The case is created or appended atomically so two simultaneous
          // reports cannot lose one another.
          await ctx.store.runTransaction(async (tx) => {
            const openCases = await tx.collection(CASES_COLLECTION).where("targetId", targetId).where("state", "queued").get();
            const existing = openCases[0];
            if (existing !== undefined && existing.data !== null) {
              const reports = [...(existing.data["reports"] as { reason: string; detail: string | null }[]), { reason, detail }];
              await tx.collection(CASES_COLLECTION).doc(existing.id).update({ reports });
              return;
            }
            let declaration: { ownRights: boolean; noPersonalData: boolean } | null = null;
            let screening: { check: string; verdict: string; detail: string | null }[] = [];
            if (targetType === "recipe" && publicationAuthor !== null && publicationIdShape.validate(targetId) !== undefined) {
              const record = await publications.get(publicationIdShape.validate(targetId));
              if (record !== null) {
                declaration = { ...record.declaration };
                screening = record.screening.map((s) => ({ ...s }));
              }
            }
            const newCaseId = caseIdShape.newId();
            await tx.collection(CASES_COLLECTION).doc(newCaseId).create({
              caseId: newCaseId,
              targetType,
              targetId,
              origin: "report",
              state: "queued",
              createdAt: ctx.clock.now().toISOString(),
              declaration,
              screening,
              reports: [{ reason, detail }],
              decision: null,
              // When this report is what hid a published recipe, `dismiss`
              // must be able to undo it (SPEC §6.6: "dismiss → content returns").
              ...(publicationState === "published" ? { hiddenFrom: "published" } : {}),
            });
          });

          // Content hides immediately (SPEC §6.5): a reported published recipe
          // leaves Explore while its case is queued. The author's own copy
          // reports the same state, so nothing is silently deleted.
          if (publicationState === "published") {
            await publications.setState(publicationIdShape.validate(targetId), "queued", ctx.clock.now().toISOString());
          }
          return { status: 202 };
        },
      },
      {
        method: "GET",
        pattern: "/moderation/queue",
        handler: async (req) => {
          requireOperator(req, ctx.isOperator);
          const queued = await cases.where("state", "queued").get();
          const records = queued.map((d) => d.data as unknown as ModerationCaseRecord);
          // Most-reported first, then oldest first (PR #104's queue order).
          records.sort((a, b) => b.reports.length - a.reports.length || a.createdAt.localeCompare(b.createdAt));
          return json(200, { cases: records.slice(0, 100).map(moderationCaseView) });
        },
      },
      {
        method: "POST",
        pattern: "/moderation/cases/:caseId/decision",
        handler: async (req) => {
          requireOperator(req, ctx.isOperator);
          const caseId = caseIdShape.validate(req.params["caseId"]);
          const body = readObject(req);
          const action = readString(body, "action");
          if (action === null || !DECISION_ACTIONS.has(action)) {
            throw errValidation("validation", "field action must be one of dismiss|hide|remove|escalate_sam");
          }
          const note = readString(body, "note", { optional: true });
          if (note !== null && note.length > 1000) {
            throw errValidation("validation", "field note must be at most 1000 characters");
          }

          const decidedAt = ctx.clock.now().toISOString();
          const updated = await ctx.store.runTransaction(async (tx) => {
            const caseSnap = await tx.collection(CASES_COLLECTION).doc(caseId).get();
            if (caseSnap.data === null) {
              throw errNotFound("case not found");
            }
            const record = caseSnap.data as unknown as ModerationCaseRecord;
            if (record.state === "resolved") {
              throw errConflict("conflict", "the case is already resolved");
            }
            if (record.targetType === "recipe" && (action === "hide" || action === "remove")) {
              const publicationSnap = await tx.collection(PUBLICATIONS_COLLECTION).doc(record.targetId).get();
              if (publicationSnap.data !== null) {
                // hide keeps it queued (hidden from Explore, reversible);
                // remove is terminal (SPEC §2.4 state machine).
                const nextState = action === "hide" ? "queued" : "rejected";
                await tx.collection(PUBLICATIONS_COLLECTION).doc(record.targetId).update({ state: nextState });
              }
            }
            if (action === "dismiss" && record.hiddenFrom === "published" && record.targetType === "recipe") {
              // This report hid a published recipe; dismissing the case undoes
              // the hide (SPEC §6.6: "dismiss → content returns"). The original
              // publishedAt is preserved — only the state ever changed.
              const publicationSnap = await tx.collection(PUBLICATIONS_COLLECTION).doc(record.targetId).get();
              if (publicationSnap.data !== null && publicationSnap.data["state"] === "queued") {
                await tx.collection(PUBLICATIONS_COLLECTION).doc(record.targetId).update({ state: "published" });
              }
            }
            const decision = { action, note, decidedAt };
            await tx.collection(CASES_COLLECTION).doc(caseId).update({ state: "resolved", decision });
            return { ...record, state: "resolved" as const, decision };
          });
          return json(200, moderationCaseView(updated));
        },
      },
    ];
  },
};

export default moderationModule;
