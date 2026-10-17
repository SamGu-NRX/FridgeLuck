/**
 * SPEC 3.4 day-only boundary for shared-cook responses (review blocker 2):
 * a response may say two accounts cooked together, and only ever to the UTC
 * day — never the exact shared-cook timestamp.
 *
 * Swept surfaces (every response carrying shared-cook time data):
 * - POST /v1/community/publications/:id/cooks  — cook-occurrence write
 * - POST/GET /v1/community/tables/:id/cooks    — shared-cook write and query
 * - POST/GET /v1/community/challenges/:id/entries — the recorded challenge result
 * - the Explore campus counters (cookedByCount, cookedThisWeekDistinctPeople)
 *
 * Deliberately NOT swept: publication lifecycle timestamps (publishedAtIso,
 * the author self view) — publishing a recipe is a separate, previewed
 * action per SPEC 3.4 and carries no cook time; and table/challenge/
 * membership/invite/moderation lifecycle timestamps, which date the
 * entity's own creation, not a cook. The UTC day rendering is
 * `toDay` (shared/time.ts), the same convention the campus counter uses.
 *
 * The app runs on a controllable clock pinned next to a UTC midnight; tests
 * flip `nowMs` to either side of the boundary and watch the rendered day
 * follow. Identity and sessions verify against the same clock, so the
 * minted Apple tokens carry fake-clock-relative exp/iat.
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
import { createChallengeRoutes } from "../../community/challenges/challengeRoutes.js";
import { createSafetyRoutes } from "../../community/safety/safetyRoutes.js";
import { FirestoreBlockDirectory } from "../../community/safety/blocks.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import type { Clock } from "../../community/shared/time.js";

const KID = "day-only-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let baseUrl: string;
let server: Server;

// The controllable app clock. Starts one second before the 2026-10-11 →
// 2026-10-12 UTC midnight; each test pins it where it needs it.
let nowMs = Date.parse("2026-10-11T23:59:59.500Z");
const clock: Clock = { now: () => new Date(nowMs) };

// An exact time is any ISO instant carrying a time-of-day component. A bare
// UTC day ("2026-10-12") is the ONLY time shape a shared-cook response may carry.
const EXACT_TIME_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;
const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/** Collects every exact-time string reachable in a response body, labeled by path. */
function collectExactTimes(value: unknown, label: string, path: string, out: string[]): void {
  if (typeof value === "string") {
    if (EXACT_TIME_PATTERN.test(value)) {
      out.push(`${label} ${path}=${value}`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, i) => collectExactTimes(item, label, `${path}[${i}]`, out));
    return;
  }
  if (typeof value === "object" && value !== null) {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      collectExactTimes(v, label, `${path}.${k}`, out);
    }
  }
}

/** Collects every occurrence of a key name (e.g. createdAtIso) in a response body. */
function collectKeysNamed(value: unknown, keyName: string, label: string, path: string, out: string[]): void {
  if (Array.isArray(value)) {
    value.forEach((item, i) => collectKeysNamed(item, keyName, label, `${path}[${i}]`, out));
    return;
  }
  if (typeof value === "object" && value !== null) {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (k === keyName) {
        out.push(`${label} ${path}.${k}`);
      }
      collectKeysNamed(v, keyName, label, `${path}.${k}`, out);
    }
  }
}

function expectNoExactTimes(body: unknown, label: string): void {
  const found: string[] = [];
  collectExactTimes(body, label, "$", found);
  const createdAtIso: string[] = [];
  collectKeysNamed(body, "createdAtIso", label, "$", createdAtIso);
  expect([...found, ...createdAtIso]).toEqual([]);
}

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

function mintAppleToken(claims: AppleClaims): string {
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
  const payload = b64url(JSON.stringify(claims));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), privateKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

let nonceCounter = 0;

async function signInAs(sub: string): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `day-nonce-${String(nonceCounter).padStart(4, "0")}`;
  const claims: AppleClaims = {
    iss: APPLE_ISSUER,
    aud: SERVICES_ID,
    exp: Math.floor(nowMs / 1000) + 600,
    iat: Math.floor(nowMs / 1000),
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

/** A two-member table (owner + approved member) to share cooks inside. */
async function createTableWithMembers(owner: TokenPair, member: TokenPair): Promise<string> {
  const created = await send("/v1/community/tables", owner, "POST", { name: "Day-only table" });
  expect(created.status).toBe(201);
  const { tableId } = (await json(created)) as { tableId: string };
  const minted = await send(`/v1/community/tables/${tableId}/invites`, owner, "POST");
  const { token } = (await json(minted)) as { token: string };
  expect((await send(`/v1/community/invites/${encodeURIComponent(token)}/redeem`, member, "POST")).status).toBe(200);
  expect((await send(`/v1/community/tables/${tableId}/members/${member.accountId}/approve`, owner, "POST")).status).toBe(200);
  return tableId;
}

function cookBody(): Record<string, unknown> {
  return {
    source: { recipeId: "recipes/test-boundary-curry", recipeRevision: "rev-000011" },
    servings: 2,
    swapsMade: ["swapped rice for couscous"],
    rating: 4,
    note: "Friday regular",
  };
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
    clock,
    config: harness.config,
    blocks: new FirestoreBlockDirectory(harness.store),
    moderation: new FirestoreModerationQueue({
      items: harness.store.moderationItems,
      publications: harness.store.publications,
      clock,
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
      challenges: createChallengeRoutes,
      safety: createSafetyRoutes,
    }),
  );
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("day-only test server did not bind");
  }
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  server.close();
  jwksServer.stop(true);
  await harness.close();
});

describe("shared-cook responses are day-only (SPEC 3.4)", () => {
  test("the shared-cook write response exposes the cook's day, never the exact share time", async () => {
    nowMs = Date.parse("2026-10-11T14:00:00.000Z");
    const owner = await signInAs("day-owner-1");
    const member = await signInAs("day-member-1");
    const tableId = await createTableWithMembers(owner, member);

    const res = await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", {
      ...cookBody(),
      cookedOn: "2026-10-10",
    });
    expect(res.status).toBe(201);
    const body = await json(res);
    expect(body["cookedOn"]).toBe("2026-10-10");
    expectNoExactTimes(body, "POST table cooks");
  });

  test("UTC day boundary: a shared cook near midnight maps to its own UTC day", async () => {
    nowMs = Date.parse("2026-10-11T23:59:59.999Z");
    const owner = await signInAs("day-owner-2");
    const member = await signInAs("day-member-2");
    const tableId = await createTableWithMembers(owner, member);

    // Cooked (and shared) 1 ms before midnight: the 10-11 side of the boundary.
    const before = await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", cookBody());
    expect(before.status).toBe(201);
    const beforeBody = await json(before);
    expect(beforeBody["cookedOn"]).toBe("2026-10-11");
    expectNoExactTimes(beforeBody, "POST table cooks before midnight");

    // 1 ms after midnight: the 10-12 side. Same route, no explicit day — the
    // server-rendered day follows the clock across the boundary.
    nowMs = Date.parse("2026-10-12T00:00:00.001Z");
    const after = await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", cookBody());
    expect(after.status).toBe(201);
    const afterBody = await json(after);
    expect(afterBody["cookedOn"]).toBe("2026-10-12");
    expectNoExactTimes(afterBody, "POST table cooks after midnight");
  });

  test("the table's shared-cook feed carries the day for every member and no exact time", async () => {
    nowMs = Date.parse("2026-10-11T12:00:00.000Z");
    const owner = await signInAs("day-owner-3");
    const member = await signInAs("day-member-3");
    const tableId = await createTableWithMembers(owner, member);
    // Both days are at or before the app clock's day (the route rejects a
    // future cookedOn): the owner cooked yesterday, the member today.
    expect((await send(`/v1/community/tables/${tableId}/cooks`, owner, "POST", { ...cookBody(), cookedOn: "2026-10-10" })).status).toBe(201);
    expect((await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", { ...cookBody(), cookedOn: "2026-10-11" })).status).toBe(201);

    const res = await get(`/v1/community/tables/${tableId}/cooks`, member);
    expect(res.status).toBe(200);
    const feed = (await json(res)) as { items: Array<Record<string, unknown>> };
    expect(feed.items).toHaveLength(2);
    // Both accounts' cooks render — the co-presence surface — and every one
    // is day-only.
    // Shares inside one frozen-clock instant carry equal createdAtIso, so the
    // feed's render order is not asserted — membership and days are.
    expect([...feed.items.map((i) => i["authorAccountId"])].sort()).toEqual([member.accountId, owner.accountId].sort());
    expect([...feed.items.map((i) => i["cookedOn"])].sort()).toEqual(["2026-10-10", "2026-10-11"]);
    for (const item of feed.items) {
      expect(DAY_PATTERN.test(item["cookedOn"] as string)).toBe(true);
    }
    expectNoExactTimes(feed, "GET table cooks");
  });

  test("challenge entry responses expose the recorded day on either side of midnight, never the exact time", async () => {
    nowMs = Date.parse("2026-10-11T23:59:59.500Z");
    const author = await signInAs("day-entry-4");
    const created = await send("/v1/community/challenges", author, "POST", {
      kind: "three-ingredients",
      title: "Boundary three",
      ingredients: ["eggs", "tomatoes", "onion"],
    });
    expect(created.status).toBe(201);
    const { challengeId } = (await json(created)) as { challengeId: string };

    nowMs = Date.parse("2026-10-11T23:59:59.999Z");
    const first = await send(`/v1/community/challenges/${challengeId}/entries`, author, "POST", {
      ingredientsUsed: ["eggs", "tomatoes"],
    });
    expect(first.status).toBe(201);
    const firstBody = await json(first);
    expect(firstBody["recordedOn"]).toBe("2026-10-11");
    expectNoExactTimes(firstBody, "POST challenge entry before midnight");

    // Entries converge per (account, challenge): a re-submission replaces the
    // author's result in place rather than stacking duplicates. The re-post
    // across the boundary therefore refreshes the ONE entry's rendered day —
    // the response carries the new day, not the first attempt's.
    nowMs = Date.parse("2026-10-12T00:00:00.001Z");
    const second = await send(`/v1/community/challenges/${challengeId}/entries`, author, "POST", {
      ingredientsUsed: ["eggs", "onion"],
    });
    expect(second.status).toBe(201);
    const secondBody = await json(second);
    expect(secondBody["recordedOn"]).toBe("2026-10-12");
    expectNoExactTimes(secondBody, "POST challenge entry after midnight");

    // The list still holds the single converged entry, now day-only for the
    // re-submission's day — and nothing else.
    const list = await get(`/v1/community/challenges/${challengeId}/entries`, author);
    expect(list.status).toBe(200);
    const entries = (await json(list)) as { items: Array<Record<string, unknown>> };
    expect(entries.items).toHaveLength(1);
    expect(entries.items[0]?.["recordedOn"]).toBe("2026-10-12");
    expectNoExactTimes(entries, "GET challenge entries");
  });

  test("the cook-occurrence write answers with no body and the recorded day survives midnight", async () => {
    nowMs = Date.parse("2026-10-11T23:59:59.500Z");
    const author = await signInAs("day-occur-author-5");
    const cook = await signInAs("day-occur-cook-5");
    const publicationId = await publishRecipe(author, "boundary-campus", "Boundary curry");

    // 1 ms before midnight → the occurrence's day is 2026-10-11.
    nowMs = Date.parse("2026-10-11T23:59:59.999Z");
    const before = await send(`/v1/community/publications/${publicationId}/cooks`, cook, "POST", {});
    expect(before.status).toBe(204);
    expect(await before.text()).toBe("");
    const beforeCooks = (await harness.store.publications.doc(publicationId).get()).get("optedInCooks") as Record<string, string>;
    expect(beforeCooks[cook.accountId]).toBe("2026-10-11");
    expect(Object.keys(beforeCooks)).toHaveLength(1);

    // 1 ms after midnight → the re-cook refreshes the same entry to 2026-10-12.
    nowMs = Date.parse("2026-10-12T00:00:00.001Z");
    const after = await send(`/v1/community/publications/${publicationId}/cooks`, cook, "POST", {});
    expect(after.status).toBe(204);
    expect(await after.text()).toBe("");
    const afterCooks = (await harness.store.publications.doc(publicationId).get()).get("optedInCooks") as Record<string, string>;
    expect(afterCooks[cook.accountId]).toBe("2026-10-12");
    expect(Object.keys(afterCooks)).toHaveLength(1);
  });

  test("campus counters render as bare numbers — cook presence, never cook times", async () => {
    nowMs = Date.parse("2026-10-11T12:00:00.000Z");
    const author = await signInAs("day-count-author-6");
    const cookA = await signInAs("day-count-a-6");
    const cookB = await signInAs("day-count-b-6");
    const publicationId = await publishRecipe(author, "counter-campus", "Counter curry");
    expect((await send(`/v1/community/publications/${publicationId}/cooks`, cookA, "POST", {})).status).toBe(204);
    expect((await send(`/v1/community/publications/${publicationId}/cooks`, cookB, "POST", {})).status).toBe(204);

    const feed = (await json(await get("/v1/community/explore/counter-campus", author))) as {
      items: Array<{ publicationId: string; cookedByCount?: number }>;
      cookedThisWeekDistinctPeople?: number;
    };
    const item = feed.items.find((i) => i.publicationId === publicationId);
    // Above the cooked-by floor: a bare number, no day, no time.
    expect(item?.cookedByCount).toBe(2);
    expect(typeof item?.cookedByCount).toBe("number");
    // Below the campus-counter floor: absent, never zero.
    expect(feed.cookedThisWeekDistinctPeople).toBeUndefined();
    // The feed's items carry publication lifecycle timestamps (publishedAt)
    // — publication metadata, not shared-cook time, per SPEC 3.4's separate
    // publishing action — so the body is not walker-swept here; the counters
    // themselves are asserted to be numbers above.
  });

  test("sweep: no response field anywhere in the swept shared-cook surfaces carries an exact time", async () => {
    nowMs = Date.parse("2026-10-11T23:59:59.999Z");
    const owner = await signInAs("day-sweep-owner-7");
    const member = await signInAs("day-sweep-member-7");
    const author = await signInAs("day-sweep-author-7");

    // Drive every swept surface once, end to end, and sweep every body:
    // cook-occurrence write, shared-cook write and query, challenge entry
    // write and list. Setup bodies (table/challenge definitions, publishes)
    // are not shared-cook surfaces and are not swept.
    const tableId = await createTableWithMembers(owner, member);
    const publicationId = await publishRecipe(author, "sweep-campus", "Sweep curry");

    const swept: Array<{ label: string; body: unknown }> = [];
    const occurrence = await send(`/v1/community/publications/${publicationId}/cooks`, owner, "POST", {});
    expect(occurrence.status).toBe(204);
    swept.push({ label: "POST publication cooks (204)", body: (await occurrence.text()) || null });

    const cookCreated = await send(`/v1/community/tables/${tableId}/cooks`, member, "POST", cookBody());
    expect(cookCreated.status).toBe(201);
    swept.push({ label: "POST table cooks", body: await json(cookCreated) });

    const cookFeed = await get(`/v1/community/tables/${tableId}/cooks`, member);
    expect(cookFeed.status).toBe(200);
    const cookFeedBody = await json(cookFeed);
    swept.push({ label: "GET table cooks", body: cookFeedBody });

    const challengeCreated = await send("/v1/community/challenges", author, "POST", {
      kind: "use-it-up",
      title: "Sweep challenge",
      ingredients: ["rice", "peas"],
    });
    expect(challengeCreated.status).toBe(201);
    const { challengeId } = (await json(challengeCreated)) as { challengeId: string };

    const entryCreated = await send(`/v1/community/challenges/${challengeId}/entries`, author, "POST", {
      ingredientsUsed: ["rice"],
    });
    expect(entryCreated.status).toBe(201);
    swept.push({ label: "POST challenge entry", body: await json(entryCreated) });

    const entryList = await get(`/v1/community/challenges/${challengeId}/entries`, author);
    expect(entryList.status).toBe(200);
    swept.push({ label: "GET challenge entries", body: await json(entryList) });

    // The sweep itself: no exact time anywhere, and the day present and
    // well-formed where the surfaces render it.
    for (const response of swept) {
      expectNoExactTimes(response.body, response.label);
    }
    const cookCreatedBody = swept[1]?.body as Record<string, unknown>;
    expect(DAY_PATTERN.test(cookCreatedBody["cookedOn"] as string)).toBe(true);
    for (const item of (swept[2]?.body as { items: Array<Record<string, unknown>> }).items) {
      expect(DAY_PATTERN.test(item["cookedOn"] as string)).toBe(true);
    }
    const entryBody = swept[3]?.body as Record<string, unknown>;
    expect(DAY_PATTERN.test(entryBody["recordedOn"] as string)).toBe(true);
  });
});
