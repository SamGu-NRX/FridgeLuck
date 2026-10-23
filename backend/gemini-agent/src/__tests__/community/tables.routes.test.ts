/**
 * The tables part over HTTP: create/join/leave lifecycle, owner-approved
 * invites, block-aware membership writes, shared cooks, and the
 * cook-occurrence write path feeding the Explore counts. Runs against the
 * Firestore emulator with the REAL FirestoreBlockDirectory (read-time and
 * write-time block enforcement against actual block documents).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { createTableRoutes } from "../../community/tables/tableRoutes.js";
import { createSafetyRoutes } from "../../community/safety/safetyRoutes.js";
import { FirestoreBlockDirectory } from "../../community/safety/blocks.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { recordCookOccurrence } from "../../community/explore/cooks.js";
import type { Clock } from "../../community/shared/time.js";
import type { AccountId, PublicationId } from "../../community/shared/ids.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let baseUrl: string;
let server: Server;
let nonceCounter = 0;

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

interface AppleClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
  sub: string;
  nonce: string;
}

function mintAppleToken(claims: AppleClaims, signingKey: KeyObject = privateKey): string {
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
  const payload = b64url(JSON.stringify(claims));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signingKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

async function signInAs(sub: string): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `nonce-${String(nonceCounter).padStart(4, "0")}`;
  const now = Date.now();
  const claims: AppleClaims = {
    iss: APPLE_ISSUER,
    aud: SERVICES_ID,
    exp: Math.floor(now / 1000) + 600,
    iat: Math.floor(now / 1000),
    sub,
    nonce,
  };
  const res = await fetch(`${baseUrl}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: mintAppleToken(claims), nonce, attested18Plus: true }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
}

async function get(path: string, tokens: TokenPair): Promise<Response> {
  return fetch(`${baseUrl}${path}`, { headers: { authorization: `Bearer ${tokens.accessToken}` } });
}

async function send(path: string, tokens: TokenPair, method: string, body?: unknown): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: { "content-type": "application/json", authorization: `Bearer ${tokens.accessToken}` },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

beforeAll(async () => {
  jwksServer = Bun.serve({
    port: 0,
    fetch: () => Response.json({ keys: [publicJwk] }),
  });
  harness = await makeHarness({
    appleIssuer: APPLE_ISSUER,
    appleServicesId: SERVICES_ID,
    appleJwksUrl: `http://127.0.0.1:${jwksServer.port}/auth/keys`,
    minCookedCountFloor: 2,
    minDistinctPeopleForCampusCounts: 3,
  });
  const deps: CommunityDeps = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks: new FirestoreBlockDirectory(harness.store),
    moderation: new FirestoreModerationQueue({
      items: harness.store.moderationItems,
      publications: harness.store.publications,
      clock: harness.clock,
    }),
    screeningStages: [],
    foodSafetyGate: fixtureFoodSafetyGate(),
  };
  const app = express();
  app.use(express.json());
  app.use(
    createCommunityRouter(deps, {
      identity: createIdentityRoutes,
      explore: createExploreRoutes,
      tables: createTableRoutes,
      safety: createSafetyRoutes,
    }),
  );
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("test server did not bind");
  }
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  server.close();
  jwksServer.stop(true);
  await harness.close();
});

async function publishRecipe(tokens: TokenPair, campus: string, title: string): Promise<string> {
  const res = await send("/v1/community/publications", tokens, "POST", {
    source: { recipeId: `recipes/test-${title.toLowerCase().replace(/\s+/g, "-")}`, recipeRevision: "rev-000010" },
    recipe: {
      title,
      summary: "A test recipe.",
      ingredientLines: ["1 onion", "1 tin chickpeas", "1 tbsp curry paste"],
      steps: ["Fry the onion.", "Add chickpeas and paste, simmer."],
    },
    tags: ["quick"],
    campus,
    note: null,
    declarations: { ownRights: true, noPersonalData: true, sourceRights: { textRedistribution: "permitted", attributionRequired: false } },
  });
  expect(res.status).toBe(201);
  return ((await res.json()) as { publicationId: string }).publicationId;
}

describe("tables part", () => {
  test("create → owner sees the table with an owner membership; detail shows the roster", async () => {
    const owner = await signInAs("tables-owner-1");
    const created = await send("/v1/community/tables", owner, "POST", { name: "Flat 12 cooks" });
    expect(created.status).toBe(201);
    const body = (await json(created)) as { tableId: string; name: string; your: { role: string; status: string } };
    expect(body.name).toBe("Flat 12 cooks");
    expect(body.your.role).toBe("owner");
    expect(body.your.status).toBe("active");

    const list = await get("/v1/community/tables", owner);
    expect(list.status).toBe(200);
    const listed = (await json(list)) as { tables: Array<{ tableId: string; your: { role: string } }> };
    expect(listed.tables).toHaveLength(1);
    expect(listed.tables[0]?.tableId).toBe(body.tableId);

    const detail = await get(`/v1/community/tables/${body.tableId}`, owner);
    expect(detail.status).toBe(200);
    const detailBody = (await json(detail)) as { members: Array<{ accountId: string; role: string; status: string }> };
    expect(detailBody.members).toHaveLength(1);
    expect(detailBody.members[0]?.role).toBe("owner");
  });

  test("invite → open link read → redeem pending → owner approves; non-owner cannot approve", async () => {
    const owner = await signInAs("tables-owner-2");
    const joiner = await signInAs("tables-joiner-2");
    const outsider = await signInAs("tables-outsider-2");
    const created = await send("/v1/community/tables", owner, "POST", { name: "Supper club" });
    const { tableId } = (await json(created)) as { tableId: string };

    const minted = await send(`/v1/community/tables/${tableId}/invites`, owner, "POST");
    expect(minted.status).toBe(201);
    const { token } = (await json(minted)) as { token: string };

    // A non-owner cannot mint invites for a table they do not own.
    const strangerMint = await send(`/v1/community/tables/${tableId}/invites`, joiner, "POST");
    expect(strangerMint.status).toBe(403);

    // The link's useful object reads without the app: name only, no ids.
    const open = await fetch(`${baseUrl}/v1/community/invites/${encodeURIComponent(token)}`);
    expect(open.status).toBe(200);
    const openBody = (await json(open)) as { tableName: string; tableId?: string | null };
    expect(openBody.tableName).toBe("Supper club");
    expect(openBody.tableId === null || openBody.tableId === undefined).toBe(true);

    // Redeem → pending; the roster shows the candidate to the owner only.
    const redeemed = await send(`/v1/community/invites/${encodeURIComponent(token)}/redeem`, joiner, "POST");
    expect(redeemed.status).toBe(200);
    const redeemBody = (await json(redeemed)) as { status: string };
    expect(redeemBody.status).toBe("pending");

    const joinerDetail = await get(`/v1/community/tables/${tableId}`, joiner);
    expect(joinerDetail.status).toBe(200);
    const joinerRoster = (await json(joinerDetail)) as { members: unknown[] };
    expect(joinerRoster.members).toHaveLength(1); // owner only — pending not visible to members

    const ownerDetail = await get(`/v1/community/tables/${tableId}`, owner);
    const ownerRoster = (await json(ownerDetail)) as { members: Array<{ status: string }> };
    expect(ownerRoster.members).toHaveLength(2); // owner + the pending candidate
    expect(ownerRoster.members.some((m) => m.status === "pending")).toBe(true);

    // Non-owner approval refused.
    const strangerApprove = await send(`/v1/community/tables/${tableId}/members/${joiner.accountId}/approve`, outsider, "POST");
    expect(strangerApprove.status).toBe(403);

    const approved = await send(`/v1/community/tables/${tableId}/members/${joiner.accountId}/approve`, owner, "POST");
    expect(approved.status).toBe(200);
    const afterApprove = (await json(await get(`/v1/community/tables/${tableId}`, owner))) as { members: Array<{ status: string }> };
    expect(afterApprove.members.every((m) => m.status === "active")).toBe(true);
  });

  test("block-aware membership: a blocked candidate cannot be approved; unblock restores it", async () => {
    const owner = await signInAs("tables-owner-3");
    const candidate = await signInAs("tables-candidate-3");
    const created = await send("/v1/community/tables", owner, "POST", { name: "Blocked gate" });
    const { tableId } = (await json(created)) as { tableId: string };
    const minted = await send(`/v1/community/tables/${tableId}/invites`, owner, "POST");
    const { token } = (await json(minted)) as { token: string };
    const redeemed = await send(`/v1/community/invites/${encodeURIComponent(token)}/redeem`, candidate, "POST");
    expect(redeemed.status).toBe(200);

    // Owner blocks the candidate → approval refused at the seam.
    const block = await send("/v1/community/blocks", owner, "POST", { accountId: candidate.accountId });
    expect(block.status).toBe(201);
    const blockedApprove = await send(`/v1/community/tables/${tableId}/members/${candidate.accountId}/approve`, owner, "POST");
    expect(blockedApprove.status).toBe(403);

    // Unblock → approval goes through (the block decision is the blocker's).
    const unblocked = await send(`/v1/community/blocks/${candidate.accountId}`, owner, "DELETE");
    expect(unblocked.status).toBe(204);
    const approved = await send(`/v1/community/tables/${tableId}/members/${candidate.accountId}/approve`, owner, "POST");
    expect(approved.status).toBe(200);
  });

  test("shared cooks: active members read, pending and strangers do not", async () => {
    const owner = await signInAs("tables-owner-4");
    const member = await signInAs("tables-member-4");
    const created = await send("/v1/community/tables", owner, "POST", { name: "Cook log" });
    const { tableId } = (await json(created)) as { tableId: string };
    const minted = await send(`/v1/community/tables/${tableId}/invites`, owner, "POST");
    const { token } = (await json(minted)) as { token: string };
    await send(`/v1/community/invites/${encodeURIComponent(token)}/redeem`, member, "POST");

    // A pending member cannot read the cooks feed.
    const pendingRead = await get(`/v1/community/tables/${tableId}/cooks`, member);
    expect(pendingRead.status).toBe(403);

    await send(`/v1/community/tables/${tableId}/members/${member.accountId}/approve`, owner, "POST");
    const today = new Date().toISOString().slice(0, 10);
    const posted = await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", {
      source: { recipeId: "recipes/test-shakshuka", recipeRevision: "rev-000002" },
      servings: 2,
      swapsMade: ["swapped feta for halloumi"],
      rating: 5,
      note: "Friday regular now",
      cookedOn: today,
    });
    expect(posted.status).toBe(201);

    const ownerFeed = await get(`/v1/community/tables/${tableId}/cooks`, owner);
    expect(ownerFeed.status).toBe(200);
    const feedBody = (await json(ownerFeed)) as { items: Array<{ authorAccountId: string; cookedOn: string }> };
    expect(feedBody.items).toHaveLength(1);
    expect(feedBody.items[0]?.cookedOn).toBe(today);

    // A stranger (never a member) gets refusal, not the content.
    const stranger = await signInAs("tables-stranger-4");
    const strangerRead = await get(`/v1/community/tables/${tableId}/cooks`, stranger);
    expect(strangerRead.status).toBe(403);
  });

  test("leaving removes the membership; the owner leaving dissolves the table", async () => {
    const owner = await signInAs("tables-owner-5");
    const member = await signInAs("tables-member-5");
    const created = await send("/v1/community/tables", owner, "POST", { name: "Transient" });
    const { tableId } = (await json(created)) as { tableId: string };
    const minted = await send(`/v1/community/tables/${tableId}/invites`, owner, "POST");
    const { token } = (await json(minted)) as { token: string };
    await send(`/v1/community/invites/${encodeURIComponent(token)}/redeem`, member, "POST");
    await send(`/v1/community/tables/${tableId}/members/${member.accountId}/approve`, owner, "POST");

    const left = await send(`/v1/community/tables/${tableId}/members/${member.accountId}`, member, "DELETE");
    expect(left.status).toBe(204);
    const afterLeave = (await json(await get(`/v1/community/tables/${tableId}`, owner))) as { members: Array<{ accountId: string }> };
    expect(afterLeave.members).toHaveLength(1);

    const dissolved = await send(`/v1/community/tables/${tableId}/members/${owner.accountId}`, owner, "DELETE");
    expect(dissolved.status).toBe(204);
    const gone = await get(`/v1/community/tables/${tableId}`, owner);
    expect(gone.status).toBe(404);
  });

  test("cook occurrence writer: one entry per distinct cook across days; floors suppress at read", async () => {
    const author = await signInAs("cooks-author-6");
    const cookA = await signInAs("cooks-a-6");
    const cookB = await signInAs("cooks-b-6");
    const cookC = await signInAs("cooks-c-6");

    // Writer-level, with a controllable clock: the dedup window is one map
    // entry per account — later cooks refresh the stored day, never add a
    // second count. (campus-south keeps this fixture out of the campus feed
    // assertions below.)
    const dedupPub = await publishRecipe(author, "campus-south", "Dedup curry");
    let day = 0;
    const fakeClock: Clock = {
      now(): Date {
        return new Date(Date.UTC(2026, 9, 11 + day, 12, 0, 0));
      },
    };
    const deps = { publications: harness.store.publications, clock: fakeClock };
    const first = await recordCookOccurrence(deps, dedupPub as PublicationId, cookA.accountId as AccountId);
    expect(first.outcome === "ok" && first.firstOccurrence).toBe(true);
    const againSameDay = await recordCookOccurrence(deps, dedupPub as PublicationId, cookA.accountId as AccountId);
    expect(againSameDay.outcome === "ok" && againSameDay.firstOccurrence).toBe(false);
    expect(againSameDay.outcome === "ok" && againSameDay.distinctCooks).toBe(1);
    day = 1; // the next UTC day: the same cook still counts once
    const nextDay = await recordCookOccurrence(deps, dedupPub as PublicationId, cookA.accountId as AccountId);
    expect(nextDay.outcome === "ok" && nextDay.firstOccurrence).toBe(false);
    expect(nextDay.outcome === "ok" && nextDay.distinctCooks).toBe(1);
    const secondCook = await recordCookOccurrence(deps, dedupPub as PublicationId, cookB.accountId as AccountId);
    expect(secondCook.outcome === "ok" && secondCook.distinctCooks).toBe(2);

    // Read-level, over HTTP with the real clock: two distinct cooks reaches
    // the "cooked by N" floor (2) but sits below the campus-counter floor
    // (3) — the badge shows, the counter stays absent (floors suppress,
    // never zero).
    const feedPub = await publishRecipe(author, "campus-north", "Floor curry");
    await send(`/v1/community/publications/${feedPub}/cooks`, cookA, "POST");
    await send(`/v1/community/publications/${feedPub}/cooks`, cookB, "POST");
    const feedTwo = (await json(await get("/v1/community/explore/campus-north", author))) as {
      items: Array<{ publicationId: string; cookedByCount?: number }>;
      cookedThisWeekDistinctPeople?: number;
    };
    const item = feedTwo.items.find((i) => i.publicationId === feedPub);
    expect(item?.cookedByCount).toBe(2);
    expect(feedTwo.cookedThisWeekDistinctPeople).toBeUndefined();

    await send(`/v1/community/publications/${feedPub}/cooks`, cookC, "POST");
    const feedThree = (await json(await get("/v1/community/explore/campus-north", author))) as {
      items: Array<{ publicationId: string; cookedByCount?: number }>;
      cookedThisWeekDistinctPeople?: number;
    };
    const itemThree = feedThree.items.find((i) => i.publicationId === feedPub);
    expect(itemThree?.cookedByCount).toBe(3);
    expect(feedThree.cookedThisWeekDistinctPeople).toBe(3);

    // A cook on a withdrawn publication refuses: never-live, never counted.
    const authorPub = await publishRecipe(author, "campus-north", "Withdrawn curry");
    const withdrawn = await send(`/v1/community/publications/${authorPub}`, author, "DELETE");
    expect(withdrawn.status).toBe(204);
    const notLive = await send(`/v1/community/publications/${authorPub}/cooks`, cookA, "POST");
    expect(notLive.status).toBe(409);
  });
});
