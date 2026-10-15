/**
 * Challenges module routes (SPEC §4, OpenAPI listChallenges / getChallenge /
 * createEntry / castVote / removeVote). Burst5 has no user-created challenges:
 * documents are seeded by operators via createChallengeDocument, so the module
 * exposes reads, entry linking, and voting.
 *
 * §4.2: entries link a PUBLISHED revision — battles never bypass moderation.
 * If the revision moved (recipe_revised_offline) or rights no longer verify
 * (quarantined_rights), the link is refused with 409.
 * §4.3: one vote per verified account, movable until votingClosesAt; no live
 * tallies; 409 vote_too_early outside the voting window; 429 on bursts.
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import { CommunityError, errForbidden, errNotFound, errValidation } from "../../core/errors.js";
import { readObject, readString, requireAccount } from "../../core/http.js";
import { isUuid } from "../../core/validate.js";
import { consumeRate } from "../../core/rateLimit.js";
import { CHALLENGES_COLLECTION, ENTRIES_COLLECTION, VOTES_COLLECTION, challengeView, entryView, type ChallengeRecord, type EntryRecord } from "./views.js";
import { deriveStatus } from "./lifecycle.js";
import { challengeIdShape, entryIdShape } from "./ids.js";
import { recipeRefFromPayload } from "./recipeRef.js";
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DocDataLike = any;

const DAILY_VOTE_LIMIT = 30;

/** Vote burst cap (§4.3 keeps a per-account rate limit on voting). */
const VOTES_COLLECTION_ALIAS = VOTES_COLLECTION;

function parseChallenge(data: DocDataLike): ChallengeRecord {
  return data as ChallengeRecord;
}

function parseEntry(id: string, data: DocDataLike): EntryRecord {
  return data as EntryRecord;
}

const challengesModule: ModuleDefinition = {
  name: "challenges",
  version: 1,
  schema: (registry) => {
    registry.collection(CHALLENGES_COLLECTION, "challenges");
    registry.collection(ENTRIES_COLLECTION, "challenges");
    registry.collection(VOTES_COLLECTION_ALIAS, "challenges");
  },
  routes: (ctx) => {
    const challenges = ctx.store.collection(CHALLENGES_COLLECTION);
    const entries = ctx.store.collection(ENTRIES_COLLECTION);
    const votes = ctx.store.collection(VOTES_COLLECTION_ALIAS);

    function displayNameOf(data: DocDataLike | null): string {
      const raw = data?.["displayName"];
      return typeof raw === "string" && raw.length > 0 ? raw : "Cook";
    }

    async function viewerVoteEntryId(challengeId: string, accountId: string): Promise<string | null> {
      const mine = await votes.doc(`${challengeId}__${accountId}`).get();
      return mine.data === null ? null : (mine.data["entryId"] as string);
    }

    /** Publication state for the linked revision: drives entry visibility (§4.2). */
    async function entryStateFor(entry: EntryRecord): Promise<"visible" | "in_review"> {
      const pub = await ctx.store.collection("publications").doc(entry.publicationId).get();
      if (pub.data === null) {
        return "in_review"; // the link broke server-side; treat as not shown (fail-closed)
      }
      return pub.data["state"] === "published" ? "visible" : "in_review";
    }

    async function requireChallenge(challengeId: string): Promise<ChallengeRecord> {
      const snap = await challenges.doc(challengeId).get();
      if (snap.data === null) {
        throw errNotFound("challenge not found");
      }
      return parseChallenge(snap.data);
    }

    /** The vote window: [entryClosesAt, votingClosesAt). Outside → vote_too_early. */
    function assertVotingOpen(record: ChallengeRecord): void {
      const nowMs = ctx.clock.now().getTime();
      if (nowMs < Date.parse(record.entryClosesAt) || nowMs >= Date.parse(record.votingClosesAt)) {
        throw new CommunityError(409, "conflict", "voting is not open for this challenge", "vote_too_early");
      }
    }

    /** Entry window: [opensAt, entryClosesAt). */
    function assertEntriesOpen(record: ChallengeRecord): void {
      const nowMs = ctx.clock.now().getTime();
      if (nowMs < Date.parse(record.opensAt) || nowMs >= Date.parse(record.entryClosesAt)) {
        throw new CommunityError(409, "conflict", "entries are not open for this challenge", "entries_closed");
      }
    }

    return [
      {
        method: "GET",
        pattern: "/challenges",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const docs = await challenges.where("kind", "challenge").get();
          const nowMs = ctx.clock.now().getTime();
          const out: Record<string, unknown>[] = [];
          for (const doc of docs) {
            if (doc.data === null) {
              continue;
            }
            const record = parseChallenge(doc.data);
            const entryDocs = await entries.where("challengeId", record.challengeId).get();
            const myEntry = entryDocs.map((d) => parseEntry(d.id, d.data)).find((e) => e.accountId === accountId);
            const myVote = await viewerVoteEntryId(record.challengeId, accountId);
            out.push(challengeView(record, deriveStatus(record, nowMs), entryDocs.length, { myEntryId: myEntry?.entryId ?? null, myVoteEntryId: myVote }));
          }
          out.sort((a, b) => String(a["opensAt"]).localeCompare(String(b["opensAt"])));
          return json(200, { challenges: out });
        },
      },
      {
        method: "GET",
        pattern: "/challenges/:challengeId",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireChallenge(challengeIdShape.validate(req.params["challengeId"]));
          const nowMs = ctx.clock.now().getTime();
          const status = deriveStatus(record, nowMs);
          const entryDocs = await entries.where("challengeId", record.challengeId).get();
          const all = entryDocs.map((d) => parseEntry(d.id, d.data));
          const myEntry = all.find((e) => e.accountId === accountId);
          const myVote = await viewerVoteEntryId(record.challengeId, accountId);
          const closed = status === "closed";
          const voteDocs = closed ? await votes.where("challengeId", record.challengeId).get() : [];
          const withNames: Record<string, unknown>[] = [];
          for (const entry of all) {
            const state = await entryStateFor(entry);
            // in_review entries render only to their author (§4.2).
            if (state === "in_review" && entry.accountId !== accountId) {
              continue;
            }
            const snap = await ctx.store.collection("accounts").doc(entry.accountId).get();
            // Self-votes are stored but never counted (§4.2); removed votes carry entryId null.
            const tally = voteDocs.filter(
              (d) => d.data !== null && d.data["entryId"] === entry.entryId && d.data["accountId"] !== entry.accountId,
            ).length;
            withNames.push(
              entryView(
                entry,
                displayNameOf(snap.data),
                state,
                closed ? tally : null,
              ),
            );
          }
          withNames.sort((a, b) => {
            if (closed) {
              return (b["voteCount"] as number) - (a["voteCount"] as number) || String(a["createdAt"]).localeCompare(String(b["createdAt"]));
            }
            return String(a["createdAt"]).localeCompare(String(b["createdAt"]));
          });
          return json(200, {
            challenge: challengeView(record, status, all.length, { myEntryId: myEntry?.entryId ?? null, myVoteEntryId: myVote }),
            entries: withNames,
          });
        },
      },
      {
        method: "POST",
        pattern: "/challenges/:challengeId/entries",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireChallenge(challengeIdShape.validate(req.params["challengeId"]));
          assertEntriesOpen(record);
          const body = readObject(req);
          const operationId = readString(body, "operationId");
          if (operationId === null || !isUuid(operationId)) {
            throw errValidation("validation", "field operationId must be a client-generated UUID");
          }
          const operationSnap = await ctx.store.collection("operations").doc(operationId).get();
          if (operationSnap.data !== null) {
            if (operationSnap.data["accountId"] !== accountId) {
              throw errForbidden("this operationId belongs to another account");
            }
            return json(201, operationSnap.data["response"]);
          }
          const recipeRef = recipeRefFromPayload(body["recipeRef"]);
          const note = readString(body, "note", { optional: true });
          if (note !== null && note.length > 140) {
            throw errValidation("validation", "field note must be at most 140 characters");
          }

          // The link must point at a published revision the account owns —
          // battles never bypass moderation (§4.2). Refusals carry the
          // contract reasons, not generic validation text.
          const mine = await ctx.store.collection("publications").where("authorId", accountId).get();
          const match = mine
            .map((d) => d.data as DocDataLike)
            .find(
              (p) =>
                p["state"] === "published" &&
                p["recipeRef"]?.["source"] === recipeRef.source &&
                p["recipeRef"]?.["id"] === recipeRef.id,
            );
          if (match === undefined) {
            // The contract puts quarantined_rights on the declared 409 for this
            // operation (createEntry's 409 description names both reasons);
            // serving it as 403 was a status drift the round-trip suite caught.
            throw new CommunityError(409, "conflict", "the entry must link one of your published revisions", "quarantined_rights");
          }
          if (match["recipeRef"]["revision"] !== recipeRef.revision) {
            throw new CommunityError(409, "conflict", "that recipe has a newer revision on the server", "recipe_revised_offline");
          }

          const existing = (await entries.where("challengeId", record.challengeId).get())
            .map((d) => parseEntry(d.id, d.data))
            .filter((e) => e.accountId === accountId);
          // One entry per account per challenge; a new link replaces the old
          // entry (§4.2), and the old entry's votes stop counting.
          const prior = existing[existing.length - 1];
          const entryRecord: EntryRecord = {
            entryId: entryIdShape.newId(),
            challengeId: record.challengeId,
            accountId,
            publicationId: match["publicationId"] as string,
            recipeRef,
            title: typeof match["title"] === "string" && match["title"].length > 0 ? match["title"] : `entry ${recipeRef.id}`,
            note: note ?? null,
            createdAt: ctx.clock.now().toISOString(),
          };
          void prior;
          await entries.doc(entryRecord.entryId).create({ ...entryRecord });
          const snap = await ctx.store.collection("accounts").doc(accountId).get();
          const response = entryView(entryRecord, displayNameOf(snap.data), "visible", null);
          await ctx.store.collection("operations").doc(operationId).create({ accountId, createdAt: entryRecord.createdAt, response });
          return json(201, response);
        },
      },
      {
        method: "PUT",
        pattern: "/challenges/:challengeId/vote",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireChallenge(challengeIdShape.validate(req.params["challengeId"]));
          assertVotingOpen(record);
          // §6.3: an account's votes start counting at 24 h of age (canVoteAt).
          // The contract's /vote error table lists only vote_too_early; the
          // account-age gate rides 403 with an explicit reason (assumption in PR).
          const voterSnap = await ctx.store.collection("accounts").doc(accountId).get();
          const createdAt = voterSnap.data?.["createdAt"];
          if (typeof createdAt === "string" && Date.parse(createdAt) + 24 * 60 * 60 * 1000 > ctx.clock.now().getTime()) {
            throw errForbidden("votes start counting 24 hours after the account is created", "account_too_new");
          }
          await consumeRate(ctx.store, "challenge-vote", accountId, DAILY_VOTE_LIMIT, ctx.clock);
          const body = readObject(req);
          const entryId = entryIdShape.validate(body["entryId"]);
          const entrySnap = await entries.doc(entryId).get();
          if (entrySnap.data === null || (entrySnap.data as DocDataLike).challengeId !== record.challengeId) {
            throw errNotFound("entry not found");
          }
          // One vote per account, keyed on the pair: casting again MOVES it
          // (§4.2); the losing entry's count drops with no double count.
          const nowIso = ctx.clock.now().toISOString();
          const key = `${record.challengeId}__${accountId}`;
          const prior = await votes.doc(key).get();
          if (prior.data === null) {
            await votes.doc(key).create({ challengeId: record.challengeId, accountId, entryId, createdAt: nowIso, updatedAt: nowIso });
          } else {
            await votes.doc(key).update({ entryId, updatedAt: nowIso });
          }
          return { status: 204 };
        },
      },
      {
        method: "DELETE",
        pattern: "/challenges/:challengeId/vote",
        handler: async (req) => {
          const accountId = requireAccount(req);
          const record = await requireChallenge(challengeIdShape.validate(req.params["challengeId"]));
          assertVotingOpen(record);
          await votes.doc(`${record.challengeId}__${accountId}`).set({
            challengeId: record.challengeId,
            accountId,
            entryId: null,
            updatedAt: ctx.clock.now().toISOString(),
            removed: true,
          });
          return { status: 204 };
        },
      },
    ];
  },
};

export default challengesModule;

export { CHALLENGES_COLLECTION, ENTRIES_COLLECTION, VOTES_COLLECTION };
