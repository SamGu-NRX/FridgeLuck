/**
 * Publication, Explore, and moderation routes (part: explore).
 *
 * POST   /v1/community/publications                    publish a recipe revision (18+, declarations required)
 * GET    /v1/community/publications/mine               the author's publications, any status
 * GET    /v1/community/publications/:publicationId     author sees any status; others only published
 * DELETE /v1/community/publications/:publicationId     author withdrawal (tombstone)
 * GET    /v1/community/explore/:campus                 the feed, cookability- and taste-ranked (SPEC §6)
 * GET    /v1/community/moderation/queue                moderator: the human queue
 * POST   /v1/community/moderation/items/:itemId/resolve  moderator: decide with audit
 *
 * The account boundary is requireAccount: no route reads an owner id from the
 * body or query. Publication is adult-only (SPEC 3.4) and requires the
 * author's rights + no-personal-data declarations. Automated screening (text
 * hygiene always, optional stages via deps) runs before visibility; failing
 * stages enqueue the publication for a human moderator — no LLM anywhere.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import { Router, type Router as ExpressRouter } from "express";
import type { CommunityDeps } from "../index.js";
import type { CommunityRuntime } from "../index.js";
import type { ModerationQueueStatus } from "../shared/contracts.js";
import { errConflict, errForbidden, errNotFound, errServiceUnavailable, errValidation } from "../shared/errors.js";
import { expectInt, expectOneOf, expectOptionalString, expectString, expectArray, expectBoolean } from "../shared/parse.js";
import { mustCommunity, route } from "../shared/http.js";
import { parsePublicationId, type AccountId } from "../shared/ids.js";
import { parseItemIdParam } from "./moderationQueue.js";
import {
  createPublication,
  getPublication,
  listOwnPublications,
  listPublishedByCampus,
  parsePublicationDoc,
  publicationVisibility,
  transitionOnDecision,
  withdrawPublication,
  type PublicationDeps,
  type PublicationRecord,
} from "./publications.js";
import { campusCookedThisWeek, cookedByCountAboveFloor, parseTokenList, rankPublications, type RankView } from "./ranking.js";
import { recordCookOccurrence } from "./cooks.js";

const FEED_DEFAULT_LIMIT = 25;
const FEED_MAX_LIMIT = 100;
const MAX_HAVE_TOKENS = 100;
const MAX_TASTE_TOKENS = 16;

const TAG_PATTERN = /^[a-z0-9][a-z0-9-]{0,31}$/;
const CAMPUS_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;

function expectRecord(raw: unknown, field: string): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw errValidation(`${field} must be an object`);
  }
  return raw as Record<string, unknown>;
}

function parseTagList(raw: unknown, field: string): string[] {
  const entries = expectArray(raw, field, { max: 8 });
  return entries.map((entry, i) => {
    const tag = expectString(entry, `${field}[${i}]`, { min: 1, max: 32 }).toLowerCase();
    if (!TAG_PATTERN.test(tag)) {
      throw errValidation(`${field}[${i}] must be a lowercase slug`);
    }
    return tag;
  });
}

function parseNote(raw: unknown, field: string): string | null {
  const note = expectOptionalString(raw, field, { min: 1, max: 280 });
  if (note !== undefined && /\r|\n/.test(note)) {
    throw errValidation(`${field} must be a single line`);
  }
  return note ?? null;
}

/** The states a source's right can be declared in (SPEC 3.5 rights vocabulary). */
type SourceRightState = "permitted" | "forbidden" | "unknown";

/**
 * The source-rights block of the declaration: what the recipe's source
 * permits for exactly the things community publication does — it
 * redistributes the recipe's text, and carries the source's attribution
 * when the source requires it (SPEC 3.5; the iOS RecipeExportGate's license
 * model speaks the same axes).
 */
export interface SourceRightsDeclaration {
  readonly textRedistribution: SourceRightState;
  readonly attributionRequired: boolean;
  readonly attribution: string | null;
}

function parseSourceRights(raw: Record<string, unknown>): SourceRightsDeclaration {
  const textRedistribution = expectOneOf(
    raw["textRedistribution"],
    "declarations.sourceRights.textRedistribution",
    ["permitted", "forbidden", "unknown"] as const,
  );
  const attributionRequired = expectBoolean(raw["attributionRequired"], "declarations.sourceRights.attributionRequired");
  const attribution = attributionRequired
    ? expectString(raw["attribution"], "declarations.sourceRights.attribution", { min: 1, max: 500 })
    : (expectOptionalString(raw["attribution"], "declarations.sourceRights.attribution", { min: 1, max: 500 }) ?? null);
  return { textRedistribution, attributionRequired, attribution };
}

const DECLARATION_MAX_CHARS = 4000;

function isScalar(value: unknown): boolean {
  return value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean";
}

/**
 * Bounds the verbatim declaration kept on the publication document: scalar
 * leaves at most two levels deep (the source-rights map plus any extra
 * rights the author declared, for future exports to honor). The bound is
 * part of the contract, not hostility — the declaration rides on the same
 * document as the recipe, so unbounded client shapes would get to size the
 * publication record itself.
 */
function verbatimDeclarationOrThrow(value: unknown, field: string): Record<string, unknown> {
  const record = expectRecord(value, field);
  for (const [key, top] of Object.entries(record)) {
    if (isScalar(top)) {
      continue;
    }
    for (const [innerKey, inner] of Object.entries(expectRecord(top, `${field}.${key}`))) {
      if (!isScalar(inner)) {
        throw errValidation(`${field}.${key}.${innerKey} must be a scalar value`);
      }
    }
  }
  const serialized = JSON.stringify(record);
  if (serialized === undefined || serialized.length > DECLARATION_MAX_CHARS) {
    throw errValidation(`${field} must serialize to at most ${DECLARATION_MAX_CHARS} characters`);
  }
  return record;
}

/**
 * What community publication does with the recipe decides what the source
 * must permit (SPEC 3.5: rights apply to user recipes exactly as to the
 * catalog, and unknown rights mean quarantine). Publication redistributes
 * the recipe's text and carries the source's attribution, so a source that
 * forbids redistribution — or whose redistribution right is unknown —
 * cannot be published, and a required attribution must actually be carried.
 * Returns null when the declared rights permit publication.
 */
export function publicationRightsRefusal(sourceRights: SourceRightsDeclaration): string | null {
  if (sourceRights.textRedistribution === "forbidden") {
    return "the source's rights declare text redistribution forbidden, and community publication redistributes the recipe text";
  }
  if (sourceRights.textRedistribution === "unknown") {
    return "the source's text-redistribution right is unknown, and unknown rights mean quarantine; record the rights before publishing";
  }
  if (sourceRights.attributionRequired && (sourceRights.attribution ?? "").trim().length === 0) {
    return "the source's rights require attribution, and the submission carries none";
  }
  return null;
}

/**
 * The verbatim declaration stored on a publication document (blocker 4).
 * Absent — a record from before declarations were kept, or a store write
 * that did not complete — reads as null: rights unknown, honored as such
 * (fail closed), never fabricated into a clearance. A present-but-malformed
 * field is invalid like any other malformed field.
 */
function readStoredDeclarations(snap: DocumentSnapshot): Record<string, unknown> | null {
  const stored = snap.get("declarations");
  if (stored === undefined) {
    return null;
  }
  return verbatimDeclarationOrThrow(stored, "declarations");
}

interface PublishBody {
  readonly sourceRecipeId: string;
  readonly sourceRecipeRevision: string;
  readonly title: string;
  readonly summary: string | null;
  readonly ingredientLines: string[];
  readonly steps: string[];
  readonly tags: string[];
  readonly campus: string | null;
  readonly note: string | null;
  readonly sourceRights: SourceRightsDeclaration;
  /** The declaration exactly as submitted, kept verbatim on the record. */
  readonly declarations: Record<string, unknown>;
}

function parsePublishBody(raw: Record<string, unknown>): PublishBody {
  const source = expectRecord(raw["source"], "source");
  const recipe = expectRecord(raw["recipe"], "recipe");
  const declarations = expectRecord(raw["declarations"], "declarations");
  if (!expectBoolean(declarations["ownRights"], "declarations.ownRights")) {
    throw errValidation("declarations.ownRights must be true: you declare the recipe is your own or you have the right to share it");
  }
  if (!expectBoolean(declarations["noPersonalData"], "declarations.noPersonalData")) {
    throw errValidation("declarations.noPersonalData must be true: the publication confirms it holds no personal data");
  }
  const sourceRights = parseSourceRights(expectRecord(declarations["sourceRights"], "declarations.sourceRights"));
  const verbatimDeclarations = verbatimDeclarationOrThrow(declarations, "declarations");
  const campusRaw = expectOptionalString(raw["campus"], "campus", { min: 1, max: 64 });
  const campus = campusRaw === undefined ? null : campusRaw.toLowerCase();
  if (campus !== null && !CAMPUS_PATTERN.test(campus)) {
    throw errValidation("campus must be a lowercase slug");
  }
  const ingredientLines = expectArray(recipe["ingredientLines"], "recipe.ingredientLines", { max: 50 }).map((line, i) =>
    expectString(line, `recipe.ingredientLines[${i}]`, { min: 1, max: 200 }),
  );
  if (ingredientLines.length === 0) {
    throw errValidation("recipe.ingredientLines must have at least 1 item");
  }
  const steps = expectArray(recipe["steps"], "recipe.steps", { max: 100 }).map((step, i) =>
    expectString(step, `recipe.steps[${i}]`, { min: 1, max: 1000 }),
  );
  if (steps.length === 0) {
    throw errValidation("recipe.steps must have at least 1 item");
  }
  return {
    sourceRecipeId: expectString(source["recipeId"], "source.recipeId", { min: 1, max: 128 }),
    sourceRecipeRevision: expectString(source["recipeRevision"], "source.recipeRevision", { min: 1, max: 128 }),
    title: expectString(recipe["title"], "recipe.title", { min: 1, max: 200 }),
    summary: expectOptionalString(recipe["summary"], "recipe.summary", { min: 1, max: 500 }) ?? null,
    ingredientLines,
    steps,
    tags: raw["tags"] === undefined ? [] : parseTagList(raw["tags"], "tags"),
    campus,
    note: parseNote(raw["note"], "note"),
    sourceRights,
    declarations: verbatimDeclarations,
  };
}

async function accountField(deps: CommunityDeps, accountId: AccountId, field: string): Promise<unknown> {
  const snap = await deps.store.accounts.doc(accountId).get();
  const data = snap.data();
  if (data === undefined) {
    return undefined;
  }
  return data[field];
}

/** SPEC 3.4: sharing is adult-only (18+); the attestation is server-recorded at sign-in. */
async function requireAttested18Plus(deps: CommunityDeps, accountId: AccountId): Promise<void> {
  const attestedAt = await accountField(deps, accountId, "attested18PlusAt");
  if (typeof attestedAt !== "string") {
    throw errForbidden("sharing requires an 18+ attestation");
  }
}

/** Engineering plan Goal 1: moderator permissions come from server-owned roles. */
async function requireModeratorRole(deps: CommunityDeps, accountId: AccountId): Promise<void> {
  const role = await accountField(deps, accountId, "role");
  if (role !== "moderator") {
    throw errForbidden("a moderator role is required");
  }
}

function authorDisplayName(name: unknown): string | null {
  return expectOptionalString(name, "displayName", { max: 64 }) ?? null;
}

function selfView(record: PublicationRecord, declarations: Record<string, unknown> | null): Record<string, unknown> {
  return {
    publicationId: record.publicationId,
    revisionId: record.revisionId,
    status: record.status,
    sourceRecipeId: record.sourceRecipeId,
    sourceRecipeRevision: record.sourceRecipeRevision,
    title: record.title,
    summary: record.summary,
    note: record.note,
    ingredientLines: record.ingredientLines,
    steps: record.steps,
    tags: record.tags,
    allergenTags: record.allergenTags,
    campus: record.campus,
    screeningFailures: record.screeningFailures,
    createdAtIso: record.createdAtIso,
    publishedAtIso: record.publishedAtIso,
    // The rights declaration the record was published under, verbatim.
    // Null on records that predate it — rights unknown, never fabricated
    // into a clearance.
    declarations,
  };
}

function publicView(record: PublicationRecord, authorDisplayName: string | null, rank: RankView | null, cookedByCount: number | undefined): Record<string, unknown> {
  return {
    publicationId: record.publicationId,
    revisionId: record.revisionId,
    title: record.title,
    summary: record.summary,
    note: record.note,
    ingredientLines: record.ingredientLines,
    steps: record.steps,
    tags: record.tags,
    campus: record.campus,
    authorDisplayName,
    publishedAtIso: record.publishedAtIso,
    allergenTags: record.allergenTags,
    ...(rank !== null ? { rank } : {}),
    ...(cookedByCount !== undefined ? { cookedByCount } : {}),
  };
}

function parseCampusParam(raw: unknown): string {
  const campus = expectString(raw, "campus", { min: 1, max: 64 }).toLowerCase();
  if (!CAMPUS_PATTERN.test(campus)) {
    throw errValidation("campus must be a lowercase slug");
  }
  return campus;
}

function queryInt(raw: unknown, field: string, bounds: { min: number; max: number }): number | undefined {
  if (raw === undefined) {
    return undefined;
  }
  if (Array.isArray(raw) || typeof raw !== "string") {
    throw errValidation(`${field} must appear exactly once`);
  }
  return expectInt(Number(raw), field, bounds);
}

function queryTokenList(raw: unknown, field: string, maxTokens: number): string[] {
  if (raw === undefined) {
    return [];
  }
  const parts = (Array.isArray(raw) ? raw : [raw]).map((entry, i) => {
    if (typeof entry !== "string") {
      throw errValidation(`${field}[${i}] must be a string`);
    }
    return entry;
  });
  // Repeated params accumulate (`?have=rice&have=tomatoes`) and single values
  // may be comma-separated (`?have=rice,tomatoes`) — both become one list.
  const joined = parts.join(",");
  if (joined.trim().length === 0) {
    return [];
  }
  return parseTokenList(joined, maxTokens);
}

export function createExploreRoutes(deps: CommunityDeps, runtime: CommunityRuntime): ExpressRouter {
  const pubDeps: PublicationDeps = { publications: deps.store.publications, clock: deps.clock };
  const router = Router();

  // The queue's decision handler is the publication state machine (wiring-time
  // registration, per the contract).
  deps.moderation.registerDecisionHandler((target, decision) => transitionOnDecision(pubDeps, target, decision));

  router.post(
    "/v1/community/publications",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      // Fail closed: with the canon/ingredient-facts packages not loaded,
      // publication cannot be safety-evaluated, so it is refused outright —
      // error envelope, nothing persisted, nothing enters moderation.
      const safetyStages = deps.foodSafetyGate.requiredStages;
      if (safetyStages === null) {
        throw errServiceUnavailable(
          `publishing is unavailable: the food-safety gate is closed (${deps.foodSafetyGate.closedReason ?? "canon/facts not loaded"})`,
        );
      }
      await requireAttested18Plus(deps, ctx.accountId);
      const body = parsePublishBody(expectRecord(req.body ?? {}, "body"));
      // Blocker 4: enforce what the source permits BEFORE anything is
      // persisted — publication redistributes the recipe text, so the
      // declaration must actually permit that. Fail closed on "forbidden"
      // and on "unknown" (quarantine), with the reason naming the
      // restriction.
      const rightsRefusal = publicationRightsRefusal(body.sourceRights);
      if (rightsRefusal !== null) {
        throw errForbidden(`publication refused: ${rightsRefusal}`);
      }
      const created = await createPublication(pubDeps, {
        authorId: ctx.accountId,
        sourceRecipeId: body.sourceRecipeId,
        sourceRecipeRevision: body.sourceRecipeRevision,
        title: body.title,
        summary: body.summary,
        note: body.note,
        ingredientLines: body.ingredientLines,
        steps: body.steps,
        tags: body.tags,
        campus: body.campus,
        screeningStages: [...deps.screeningStages, ...safetyStages],
      });
      // Blocker 4: the rights declaration is kept WITH the revision —
      // written verbatim onto the publication document at submission,
      // before the record can reach moderation, so approval/moderation and
      // future exports can honor it. publications.ts is untouched (its
      // record shape and single-write semantics are owned by review
      // blockers 1-3): the declaration is an additional field its parser
      // ignores, and a record found without one is rights-unknown, honored
      // fail-closed, never rights-clear.
      await pubDeps.publications.doc(created.record.publicationId).update({ declarations: body.declarations });
      if (created.outcome === "queued") {
        await deps.moderation.submit(
          { publicationId: created.record.publicationId, revisionId: created.record.revisionId },
          null,
          "automated-screening",
          created.failures.map((f) => `${f.stage}: ${f.reasons.join("; ")}`).join(" | "),
        );
      }
      res.status(201).json(selfView(created.record, body.declarations));
    }),
  );

  router.get(
    "/v1/community/publications/mine",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const mine = await listOwnPublications(pubDeps, ctx.accountId);
      // listOwnPublications returns parsed records only; the verbatim
      // declaration lives on the raw document and publications.ts' read
      // semantics are not ours to change (review blockers 1-3 own that
      // file), so the declarations come from one bounded second query
      // keyed by id.
      const declarationSnaps = await pubDeps.publications.where("authorId", "==", ctx.accountId).get();
      const declarationsById = new Map<string, Record<string, unknown> | null>();
      for (const doc of declarationSnaps.docs) {
        declarationsById.set(doc.id, readStoredDeclarations(doc));
      }
      res.status(200).json({ items: mine.map((record) => selfView(record, declarationsById.get(record.publicationId) ?? null)) });
    }),
  );

  router.get(
    "/v1/community/publications/:publicationId",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const publicationId = parsePublicationId.parse(req.params["publicationId"], "publication path id");
      // One read carries both the parsed record and the verbatim declaration
      // stored beside it (blocker 4); publications.ts' parser stays the only
      // reader of its record shape.
      const snap = await pubDeps.publications.doc(publicationId).get();
      const record = parsePublicationDoc(snap);
      if (record === null) {
        throw errNotFound("publication not found");
      }
      const declarations = readStoredDeclarations(snap);
      const visibility = publicationVisibility(record.status);
      if (record.authorId === ctx.accountId) {
        // SPEC 3.4: the author sees their own record whatever its moderation
        // state — that answer comes from the same derivation as everyone
        // else's, not from a route-side bypass.
        if (!visibility.visibleToAuthor) {
          throw errNotFound("publication not found");
        }
        res.status(200).json(selfView(record, declarations));
        return;
      }
      await deps.blocks.assertCanInteract(ctx.accountId, record.authorId);
      if (!visibility.visibleToReaders) {
        throw errNotFound("publication not found");
      }
      const name = await accountField(deps, record.authorId, "displayName");
      res.status(200).json(publicView(record, authorDisplayName(name), null, cookedByCountAboveFloor(record.optedInCooks, deps.config.minCookedCountFloor)));
    }),
  );

  router.delete(
    "/v1/community/publications/:publicationId",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const publicationId = parsePublicationId.parse(req.params["publicationId"], "publication path id");
      const outcome = await withdrawPublication(pubDeps, publicationId, ctx.accountId);
      if (outcome.outcome === "missing") {
        throw errNotFound("publication not found");
      }
      if (outcome.outcome === "forbidden") {
        throw errForbidden("only the author can withdraw a publication");
      }
      res.status(204).send();
    }),
  );

  // The cook-occurrence write path (SPEC §6 "cooked by N people"): the act of
  // calling it IS the cook's separate opt-in to aggregate statistics, and the
  // cook id comes from the verified session — a client-supplied cook id would
  // let one account fabricate another's contribution. Blocks are checked
  // before the write (README rule 3); the count floors stay read-time-only.
  router.post(
    "/v1/community/publications/:publicationId/cooks",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const publicationId = parsePublicationId.parse(req.params["publicationId"], "publication path id");
      expectRecord(req.body ?? {}, "body");
      const record = await getPublication(pubDeps, publicationId);
      if (record === null) {
        throw errNotFound("publication not found");
      }
      if (record.authorId !== ctx.accountId) {
        await deps.blocks.assertCanInteract(ctx.accountId, record.authorId);
      }
      const outcome = await recordCookOccurrence(pubDeps, publicationId, ctx.accountId);
      if (outcome.outcome === "missing") {
        throw errNotFound("publication not found");
      }
      if (outcome.outcome === "not-live") {
        throw errConflict("publication is not live");
      }
      res.status(204).send();
    }),
  );

  router.get(
    "/v1/community/explore/:campus",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const campus = parseCampusParam(req.params["campus"]);
      const have = queryTokenList(req.query["have"], "have", MAX_HAVE_TOKENS);
      const tastes = queryTokenList(req.query["tastes"], "tastes", MAX_TASTE_TOKENS);
      const limit = queryInt(req.query["limit"], "limit", { min: 1, max: FEED_MAX_LIMIT }) ?? FEED_DEFAULT_LIMIT;

      const candidates = await listPublishedByCampus(pubDeps, campus);
      const own = candidates.filter((r) => r.authorId === ctx.accountId);
      const others = candidates.filter((r) => r.authorId !== ctx.accountId);
      const otherAuthorIds = [...new Set(others.map((r) => r.authorId))];
      const visibleOtherIds = new Set(await deps.blocks.filterVisible(ctx.accountId, otherAuthorIds));
      const visible = [...own, ...others.filter((r) => visibleOtherIds.has(r.authorId))];

      const ranked = rankPublications(visible, have.length > 0 || tastes.length > 0 ? { have, tastes } : null);
      const page = ranked.slice(0, limit);
      const authorNames = new Map<AccountId, string | null>();
      for (const { record } of page) {
        if (!authorNames.has(record.authorId)) {
          const name = await accountField(deps, record.authorId, "displayName");
          authorNames.set(record.authorId, authorDisplayName(name));
        }
      }
      const items = page.map(({ record, rank }) =>
        publicView(record, authorNames.get(record.authorId) ?? null, rank, cookedByCountAboveFloor(record.optedInCooks, deps.config.minCookedCountFloor)),
      );
      const weekCounter = campusCookedThisWeek(visible, deps.clock.now(), deps.config.minDistinctPeopleForCampusCounts);
      res.status(200).json({
        campus,
        items,
        ...(weekCounter !== undefined ? { cookedThisWeekDistinctPeople: weekCounter } : {}),
      });
    }),
  );

  router.get(
    "/v1/community/moderation/queue",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      await requireModeratorRole(deps, ctx.accountId);
      const status = expectOneOf(req.query["status"] ?? "open", "status", ["open", "resolved"] as const) as ModerationQueueStatus;
      const items = await deps.moderation.list(status);
      res.status(200).json({ items });
    }),
  );

  router.post(
    "/v1/community/moderation/items/:itemId/resolve",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      await requireModeratorRole(deps, ctx.accountId);
      const body = expectRecord(req.body ?? {}, "body");
      const decision = expectOneOf(body["decision"], "decision", ["approved", "rejected"] as const);
      const note = expectOptionalString(body["note"], "note", { min: 1, max: 500 }) ?? null;
      const itemId = parseItemIdParam(req.params["itemId"]);
      const item = await deps.moderation.resolve(itemId, decision, ctx.accountId, note);
      res.status(200).json(item);
    }),
  );

  return router;
}
