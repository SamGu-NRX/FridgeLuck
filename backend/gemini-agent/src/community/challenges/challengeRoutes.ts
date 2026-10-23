/**
 * Challenge routes (part: challenges).
 *
 * POST /v1/community/challenges                          create a challenge constraint
 * GET  /v1/community/challenges/:challengeId             OPEN: the link's useful object (finding 9)
 * POST /v1/community/challenges/:challengeId/entries     record your private result
 * GET  /v1/community/challenges/:challengeId/entries     your own results for that challenge
 *
 * The open read returns the challenge definition only — no account ids, no
 * entries (results are private per finding 9; "share your result" happens
 * through the publishing, Table and cook-occurrence paths). No votes: battle
 * voting belongs to unselected direction (b).
 */
import { Router, type Router as ExpressRouter } from "express";
import type { CommunityDeps } from "../index.js";
import type { CommunityRuntime } from "../index.js";
import { errNotFound, errValidation } from "../shared/errors.js";
import { expectArray, expectOneOf, expectOptionalInt, expectString } from "../shared/parse.js";
import { mustCommunity, route } from "../shared/http.js";
import { parseChallengeId, type ChallengeId } from "../shared/ids.js";
import { toDay } from "../shared/time.js";
import {
  CHALLENGE_KINDS,
  createChallenge,
  createChallengeEntry,
  getChallenge,
  listOwnEntries,
  type ChallengeDeps,
  type ChallengeKind,
  type ChallengeRecord,
} from "./challenges.js";

function expectRecord(raw: unknown, field: string): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw errValidation(`${field} must be an object`);
  }
  return raw as Record<string, unknown>;
}

function challengeDeps(deps: CommunityDeps): ChallengeDeps {
  return { store: deps.store, clock: deps.clock };
}

function challengeView(challenge: ChallengeRecord): Record<string, unknown> {
  return {
    challengeId: challenge.challengeId,
    kind: challenge.kind,
    title: challenge.title,
    constraint: {
      ingredients: challenge.ingredients,
      ...(challenge.timeLimitMinutes !== null ? { timeLimitMinutes: challenge.timeLimitMinutes } : {}),
    },
    createdAtIso: challenge.createdAtIso,
  };
}

function entryView(entry: {
  entryId: string;
  challengeId: ChallengeId;
  sourceRecipeId: string | null;
  recipeRevision: string | null;
  ingredientsUsed: readonly string[];
  createdAtIso: string;
}): Record<string, unknown> {
  // SPEC 3.4 day-only: the entry's exact record time never leaves the
  // server — the client sees the UTC day the result was recorded. The exact
  // timestamp stays in storage (newest-first ordering) and out of this view.
  return {
    entryId: entry.entryId,
    challengeId: entry.challengeId,
    source:
      entry.sourceRecipeId !== null && entry.recipeRevision !== null
        ? { recipeId: entry.sourceRecipeId, recipeRevision: entry.recipeRevision }
        : null,
    ingredientsUsed: entry.ingredientsUsed,
    recordedOn: toDay(new Date(entry.createdAtIso)),
  };
}

export function createChallengeRoutes(deps: CommunityDeps, runtime: CommunityRuntime): ExpressRouter {
  const router = Router();

  router.post(
    "/v1/community/challenges",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const body = expectRecord(req.body ?? {}, "body");
      const kind = expectOneOf<ChallengeKind>(body["kind"], "kind", CHALLENGE_KINDS);
      const title = expectString(body["title"], "title", { min: 1, max: 80 });
      const ingredientList = expectArray(body["ingredients"], "ingredients", { max: 8 }).map((item, i) =>
        expectString(item, `ingredients[${i}]`, { min: 1, max: 40 }),
      );
      if (ingredientList.length < 1) {
        throw errValidation("a challenge needs at least one constrained ingredient");
      }
      const timeLimitMinutes = expectOptionalInt(body["timeLimitMinutes"], "timeLimitMinutes", { min: 10, max: 240 }) ?? null;
      if (kind === "time-limit" && timeLimitMinutes === null) {
        throw errValidation("a time-limit challenge needs a timeLimitMinutes bound");
      }
      const challenge = await createChallenge(challengeDeps(deps), ctx.accountId, { kind, title, ingredients: ingredientList, timeLimitMinutes });
      res.status(201).json(challengeView(challenge));
    }),
  );

  // Open by design: the challenge link must read without the app (§6.3,
  // finding 9). It exposes the constraint and nothing about people.
  router.get(
    "/v1/community/challenges/:challengeId",
    route(async (req, res) => {
      const challengeId = parseChallengeId.parse(req.params["challengeId"], "challenge path id");
      const challenge = await getChallenge(challengeDeps(deps), challengeId);
      if (challenge === null) {
        throw errNotFound("challenge not found");
      }
      res.status(200).json(challengeView(challenge));
    }),
  );

  router.post(
    "/v1/community/challenges/:challengeId/entries",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const challengeId = parseChallengeId.parse(req.params["challengeId"], "challenge path id");
      const challenge = await getChallenge(challengeDeps(deps), challengeId);
      if (challenge === null) {
        throw errNotFound("challenge not found");
      }
      const body = expectRecord(req.body ?? {}, "body");
      let sourceRecipeId: string | null = null;
      let recipeRevision: string | null = null;
      if (body["source"] !== undefined) {
        const source = expectRecord(body["source"], "source");
        sourceRecipeId = expectString(source["recipeId"], "source.recipeId", { min: 1, max: 128 });
        recipeRevision = expectString(source["recipeRevision"], "source.recipeRevision", { min: 1, max: 128 });
      }
      const ingredientsUsed = expectArray(body["ingredientsUsed"] ?? [], "ingredientsUsed", { max: 8 }).map((item, i) =>
        expectString(item, `ingredientsUsed[${i}]`, { min: 1, max: 40 }),
      );
      const entry = await createChallengeEntry(challengeDeps(deps), challenge, ctx.accountId, {
        sourceRecipeId,
        recipeRevision,
        ingredientsUsed,
      });
      res.status(201).json(entryView(entry));
    }),
  );

  // Private results: the query is scoped to the caller by construction —
  // another account's entries are never returned, never queried.
  router.get(
    "/v1/community/challenges/:challengeId/entries",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      const challengeId = parseChallengeId.parse(req.params["challengeId"], "challenge path id");
      const challenge = await getChallenge(challengeDeps(deps), challengeId);
      if (challenge === null) {
        throw errNotFound("challenge not found");
      }
      const entries = await listOwnEntries(challengeDeps(deps), challengeId, ctx.accountId);
      res.status(200).json({ items: entries.map((entry) => entryView(entry)) });
    }),
  );

  return router;
}
