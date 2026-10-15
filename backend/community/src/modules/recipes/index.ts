/**
 * Recipes/publications module (SPEC §2): publish a frozen revision with its
 * rights declaration, list your own publications in their moderation states,
 * read a published revision, and withdraw your own.
 *
 * The publish decision is one write (PR #104): screening runs before the
 * record exists, and it lands directly in `published` or `queued` — never a
 * half-published state. Writes are idempotent on the client operationId
 * (SPEC §8.3): a replayed operation returns the original response.
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import { errNotFound, errConflict, errValidation, errForbidden } from "../../core/errors.js";
import { readObject, readString, requireAccount } from "../../core/http.js";
import { publicationIdShape } from "../../core/ids.js";
import { validateRecipeContent, validateRecipeRef, isUuid } from "../../core/validate.js";
import { assertScreeningAvailable } from "../../config.js";
import { consumeRate } from "../../core/rateLimit.js";
import { StorePublicationRepository, CASES_COLLECTION, OPERATIONS_COLLECTION } from "../../core/storeRepos.js";
import { publicationView } from "../../core/views.js";
import { caseIdShape } from "../../core/ids.js";

/** Publishes per account per UTC day; the contract reserves 429 for publish/report limits. */
const DAILY_PUBLISH_LIMIT = 20;

const recipesModule: ModuleDefinition = {
  name: "recipes",
  version: 1,
  routes: (ctx) => {
    const publications = new StorePublicationRepository({ store: ctx.store, clock: ctx.clock });
    return [
      {
        method: "POST",
        pattern: "/publications",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const body = readObject(req);

          const operationId = readString(body, "operationId");
          if (operationId === null || !isUuid(operationId)) {
            throw errValidation("validation", "field operationId must be a client-generated UUID");
          }
          // Idempotent replay (SPEC §8.3) answers before any rate limit or
          // validation so a retry after a 429 still returns the original.
          const operationSnap = await ctx.store.collection(OPERATIONS_COLLECTION).doc(operationId).get();
          if (operationSnap.data !== null) {
            if (operationSnap.data["accountId"] !== accountId) {
              throw errForbidden("this operationId belongs to another account");
            }
            return json(201, operationSnap.data["response"]);
          }

          assertScreeningAvailable(ctx.config);
          await consumeRate(ctx.store, "publish", accountId, DAILY_PUBLISH_LIMIT, ctx.clock);

          const declarationRaw = body["declaration"];
          if (typeof declarationRaw !== "object" || declarationRaw === null || Array.isArray(declarationRaw)) {
            throw errValidation("declarations_missing", "field declaration is required");
          }
          const declaration = declarationRaw as Record<string, unknown>;
          if (declaration["ownRights"] !== true || declaration["noPersonalData"] !== true) {
            throw errValidation("declarations_missing", "both ownRights and noPersonalData must be declared true");
          }
          const recipeRef = validateRecipeRef(body["recipeRef"]);
          const content = validateRecipeContent(body["content"]);
          const challengeIdRaw = body["challengeId"];
          const challengeId = challengeIdRaw === undefined || challengeIdRaw === null ? null : readString(body, "challengeId");
          const accountSnap = await ctx.store.collection("accounts").doc(accountId).get();
          const authorDisplayName =
            typeof accountSnap.data?.["displayName"] === "string" && accountSnap.data["displayName"].length > 0
              ? accountSnap.data["displayName"]
              : "Cook";

          const screening = ctx.screening.run(content);
          const record = await publications.create({
            authorId: accountId,
            authorDisplayName,
            recipeRef,
            content,
            declaration: { ownRights: true, noPersonalData: true },
            screening,
            challengeId,
          });

          if (screening.blocked) {
            // Straight to the human queue (SPEC §6.5); the case snapshot
            // carries the declaration and verdicts the operator reviews.
            const caseId = caseIdShape.newId();
            await ctx.store.collection(CASES_COLLECTION).doc(caseId).create({
              caseId,
                targetType: "recipe",
                targetId: record.publicationId,
                origin: "screening",
                state: "queued",
                createdAt: ctx.clock.now().toISOString(),
                declaration: { ownRights: true, noPersonalData: true },
                screening: screening.outcomes,
                reports: [],
                decision: null,
              });
          }

          const view = publicationView(record);
          await ctx.store.collection(OPERATIONS_COLLECTION).doc(operationId).create({
            accountId,
            publicationId: record.publicationId,
            createdAt: ctx.clock.now().toISOString(),
            response: view,
          });
          return json(201, view);
        },
      },
      {
        method: "GET",
        pattern: "/publications/mine",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const mine = await publications.listByAuthor(accountId);
          mine.sort((a, b) => b.createdAt.localeCompare(a.createdAt) || a.publicationId.localeCompare(b.publicationId));
          return json(200, { publications: mine.slice(0, 100).map(publicationView) });
        },
      },
      {
        method: "GET",
        pattern: "/publications/:publicationId",
        handler: async (req) => {
          const publicationId = publicationIdShape.validate(req.params["publicationId"]);
          const record = await publications.get(publicationId);
          if (record === null || record.state !== "published") {
            // Reader view: only published revisions resolve (SPEC §2.4).
            throw errNotFound("publication not found");
          }
          return json(200, publicationView(record));
        },
      },
      {
        method: "DELETE",
        pattern: "/publications/:publicationId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const publicationId = publicationIdShape.validate(req.params["publicationId"]);
          const record = await publications.get(publicationId);
          if (record === null || record.authorId !== accountId) {
            throw errNotFound("publication not found");
          }
          if (record.state === "withdrawn") {
            return { status: 204 }; // idempotent withdrawal
          }
          if (record.state === "rejected") {
            throw errConflict("conflict", "a rejected publication can no longer be withdrawn");
          }
          await publications.setState(publicationId, "withdrawn", ctx.clock.now().toISOString());
          return { status: 204 };
        },
      },
    ];
  },
};

export default recipesModule;
