/**
 * The publication rights declaration is kept with the revision and source
 * restrictions are enforced at the submission boundary (PR #104 review
 * blocker 4).
 *
 * The submission handler used to validate the declaration's shape and throw
 * it away: nothing reached the record, and nothing asked what the recipe's
 * SOURCE permits — while community publication redistributes the recipe's
 * text (SPEC 3.5: rights apply to user recipes exactly as to the catalog;
 * unknown rights mean quarantine; the iOS RecipeExportGate refuses
 * forbidden/unknown redistribution and uncarried attribution on the same
 * axes).
 *
 * Proven over the real HTTP surface against the Firestore emulator, with
 * the fixture food-safety gate ACTIVE:
 *   (1) a valid declaration is stored verbatim on the record at submission
 *       and is retrievable with the record (POST response, author GET,
 *       /mine, and the raw document), including rights axes beyond the two
 *       publication exercises (for future exports to honor);
 *   (2) missing or malformed declarations are refused with an honest 422
 *       naming the field — and nothing is persisted;
 *   (3) a declaration whose source forbids what publication does is
 *       refused (403, the reason names the restriction), "unknown"
 *       quarantines the same way, and nothing is persisted;
 *   (4) a valid declaration flows through unchanged: screening and the
 *       moderation queue behave exactly as before (a lint-passing queued
 *       record still goes live on approval), and the declaration rides on
 *       the record the whole way;
 *   (5) a source that requires attribution: the submission is refused
 *       without the attribution, and stored verbatim with it —
 *       attribution-carrying publications reach readers without
 *       over-blocking;
 *   (6) the pure refusal policy covers its branches, and an author surface
 *       reports a record with no stored declaration as null (rights
 *       unknown), never as a clearance.
 */
import { FieldValue } from "@google-cloud/firestore";
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes, publicationRightsRefusal, type SourceRightsDeclaration } from "../../community/explore/exploreRoutes.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { stubBlockDirectory, stubScreeningFail } from "../../community/shared/testing/stubs.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let blocks: ReturnType<typeof stubBlockDirectory>;
let baseUrl: string;
let strictUrl: string;
let servers: Server[] = [];
let nonceCounter = 0;

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

interface AppleClaims {
  sub: string;
  nonce: string;
}

function mintAppleToken(claims: AppleClaims): string {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
  const payload = b64url(JSON.stringify({ iss: APPLE_ISSUER, aud: SERVICES_ID, exp: now + 600, iat: now, ...claims }));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), privateKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

async function signInAs(sub: string, attested18Plus = true): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `rights-nonce-${String(nonceCounter).padStart(4, "0")}`;
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
    body: JSON.stringify({ identityToken: mintAppleToken(claims), nonce, attested18Plus }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
}

/** Moderator permissions come from server-owned roles; tests seed the role the way an operator would. */
async function makeModerator(sub: string): Promise<TokenPair> {
  const tokens = await signInAs(sub);
  await harness.store.accounts.doc(tokens.accountId).set({ role: "moderator" }, { merge: true });
  return tokens;
}

function sourceRights(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { textRedistribution: "permitted", attributionRequired: false, ...overrides };
}

function declarations(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ownRights: true, noPersonalData: true, sourceRights: sourceRights(), ...overrides };
}

function publishBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: { recipeId: "recipes/test-rice-1", recipeRevision: "rev-000001" },
    recipe: {
      title: "Weeknight tomato rice",
      summary: "A simple tomato rice for two.",
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp tahini"],
      steps: ["Cook the rice.", "Fry the tomatoes, stir in the tahini, fold through the rice."],
    },
    tags: ["quick", "vegetarian"],
    campus: "campus-north",
    note: "Made this all last week.",
    declarations: declarations(),
    ...overrides,
  };
}

async function publish(url: string, tokens: TokenPair, body: Record<string, unknown>): Promise<Response> {
  return fetch(`${url}/v1/community/publications`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${tokens.accessToken}` },
    body: JSON.stringify(body),
  });
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

async function publicationCount(): Promise<number> {
  return (await harness.store.publications.listDocuments()).length;
}

async function getRecord(tokens: TokenPair, publicationId: string): Promise<Response> {
  return fetch(`${baseUrl}/v1/community/publications/${publicationId}`, {
    headers: { authorization: `Bearer ${tokens.accessToken}` },
  });
}

interface QueueItemJson {
  itemId: string;
  target: { publicationId: string; revisionId: string };
  status: string;
  decision: string | null;
}

async function openItemFor(mod: TokenPair, publicationId: string): Promise<QueueItemJson> {
  const queue = (await json(await fetch(`${baseUrl}/v1/community/moderation/queue`, {
    headers: { authorization: `Bearer ${mod.accessToken}` },
  }))) as { items: QueueItemJson[] };
  const item = queue.items.find((i) => i.target.publicationId === publicationId);
  expect(item).toBeDefined();
  return item as QueueItemJson;
}

async function resolveItem(mod: TokenPair, itemId: string, decision: "approved" | "rejected"): Promise<Response> {
  return fetch(`${baseUrl}/v1/community/moderation/items/${itemId}/resolve`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
    body: JSON.stringify({ decision, note: "rights declaration flow-through" }),
  });
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
  blocks = stubBlockDirectory();
  const moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const base = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks,
    moderation,
  };
  const apps: Array<{ deps: CommunityDeps; setUrl: (url: string) => void }> = [
    { deps: { ...base, screeningStages: [], foodSafetyGate: fixtureFoodSafetyGate() }, setUrl: (u) => (baseUrl = u) },
    { deps: { ...base, screeningStages: [stubScreeningFail(["remove the branded mention"], "stub-linter")], foodSafetyGate: fixtureFoodSafetyGate() }, setUrl: (u) => (strictUrl = u) },
  ];
  for (const { deps, setUrl } of apps) {
    const app = express();
    app.use(express.json());
    app.use(createCommunityRouter(deps, { identity: createIdentityRoutes, explore: createExploreRoutes }));
    const server = app.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("test server did not bind");
    }
    setUrl(`http://127.0.0.1:${address.port}`);
    servers.push(server);
  }
});

afterAll(async () => {
  for (const server of servers) {
    server.close();
  }
  jwksServer.stop(true);
  await harness.close();
});

afterEach(() => {
  blocks.reset();
});

describe("the declaration is kept with the revision", () => {
  test("a valid declaration is stored verbatim at submission and retrievable with the record", async () => {
    const alice = await signInAs("rights-alice-keep");
    // Rights beyond the two the publication exercises ride along verbatim —
    // the export-side gates (caching, offline use) must find them later.
    const submitted = {
      ownRights: true,
      noPersonalData: true,
      sourceRights: {
        textRedistribution: "permitted",
        attributionRequired: false,
        cachingAllowed: "permitted",
        offlineUseAllowed: "permitted",
      },
    };

    const res = await publish(baseUrl, alice, publishBody({ declarations: submitted }));
    expect(res.status).toBe(201);
    const created = await json(res);
    const publicationId = created.publicationId as string;
    expect(created.declarations).toEqual(submitted);

    // The author's GET returns it with the record.
    const got = await getRecord(alice, publicationId);
    expect(got.status).toBe(200);
    const record = await json(got);
    expect(record.declarations).toEqual(submitted);

    // So does /mine.
    const mine = await fetch(`${baseUrl}/v1/community/publications/mine`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(mine.status).toBe(200);
    const mineBody = (await json(mine)) as { items: Array<Record<string, unknown>> };
    expect(mineBody.items).toHaveLength(1);
    expect(mineBody.items[0].declarations).toEqual(submitted);

    // And it sits verbatim on the raw document the revision is stored in.
    const raw = await harness.store.publications.doc(publicationId).get();
    expect(raw.get("declarations")).toEqual(submitted);
  });

  test("a reader does not receive the declaration; a record without one reads as rights-unknown (null)", async () => {
    const alice = await signInAs("rights-alice-visibility");
    const bob = await signInAs("rights-bob-visibility");
    const res = await publish(baseUrl, alice, publishBody());
    expect(res.status).toBe(201);
    const created = await json(res);
    const publicationId = created.publicationId as string;

    const readerRes = await getRecord(bob, publicationId);
    expect(readerRes.status).toBe(200);
    const readerView = await json(readerRes);
    expect("declarations" in readerView).toBe(false);

    // A record whose declaration is absent (a pre-declaration record, or a
    // store write that did not complete) is rights-unknown: the author
    // surface shows null, never a fabricated clearance.
    await harness.store.publications.doc(publicationId).update({ declarations: FieldValue.delete() });
    const got = await getRecord(alice, publicationId);
    expect(got.status).toBe(200);
    const record = await json(got);
    expect(record.declarations).toBeNull();
  });
});

describe("incomplete declarations are refused", () => {
  test("missing or malformed declaration fields get an honest 422 and nothing persists", async () => {
    const before = await publicationCount();
    const alice = await signInAs("rights-alice-missing");

    const noDeclarations = publishBody();
    delete noDeclarations["declarations"];
    const absent = await publish(baseUrl, alice, noDeclarations);
    expect(absent.status).toBe(422);
    expect((await json(absent))["code"]).toBe("validation");

    const noSourceRights = await publish(baseUrl, alice, publishBody({ declarations: { ownRights: true, noPersonalData: true } }));
    expect(noSourceRights.status).toBe(422);
    expect(String((await json(noSourceRights))["error"])).toContain("declarations.sourceRights");

    const noAttributionFlag = await publish(baseUrl, alice, publishBody({
      declarations: { ownRights: true, noPersonalData: true, sourceRights: { textRedistribution: "permitted" } },
    }));
    expect(noAttributionFlag.status).toBe(422);
    expect(String((await json(noAttributionFlag))["error"])).toContain("declarations.sourceRights.attributionRequired");

    const unknownState = await publish(baseUrl, alice, publishBody({
      declarations: declarations({ sourceRights: sourceRights({ textRedistribution: "maybe" }) }),
    }));
    expect(unknownState.status).toBe(422);
    expect(String((await json(unknownState))["error"])).toContain("declarations.sourceRights.textRedistribution");

    // Fail closed end to end: a refused submission is not silently accepted
    // — no record exists for any of the four refusals.
    expect(await publicationCount()).toBe(before);
  });
});

describe("the source's restrictions are enforced", () => {
  test("a source that forbids redistribution is refused, naming the restriction; nothing persists", async () => {
    const before = await publicationCount();
    const alice = await signInAs("rights-alice-forbidden");
    const res = await publish(baseUrl, alice, publishBody({
      declarations: declarations({ sourceRights: sourceRights({ textRedistribution: "forbidden" }) }),
    }));
    expect(res.status).toBe(403);
    const body = await json(res);
    expect(body["code"]).toBe("forbidden");
    const reason = String(body["error"]);
    expect(reason).toContain("forbidden");
    expect(reason).toContain("redistribution");
    expect(await publicationCount()).toBe(before);
  });

  test("a source whose redistribution right is unknown quarantines — fail closed; nothing persists", async () => {
    const before = await publicationCount();
    const alice = await signInAs("rights-alice-unknown");
    const res = await publish(baseUrl, alice, publishBody({
      declarations: declarations({ sourceRights: sourceRights({ textRedistribution: "unknown" }) }),
    }));
    expect(res.status).toBe(403);
    const body = await json(res);
    expect(body["code"]).toBe("forbidden");
    const reason = String(body["error"]);
    expect(reason).toContain("unknown");
    expect(reason).toContain("quarantine");
    expect(await publicationCount()).toBe(before);
  });
});

describe("a source that requires attribution", () => {
  test("the submission is refused without the attribution and stored verbatim with it", async () => {
    const alice = await signInAs("rights-alice-attribution");

    const without = await publish(baseUrl, alice, publishBody({
      declarations: declarations({ sourceRights: sourceRights({ attributionRequired: true }) }),
    }));
    expect(without.status).toBe(422);
    expect(String((await json(without))["error"])).toContain("declarations.sourceRights.attribution");

    const blank = await publish(baseUrl, alice, publishBody({
      declarations: declarations({ sourceRights: sourceRights({ attributionRequired: true, attribution: "   " }) }),
    }));
    // A whitespace-only attribution is a declaration that carries nothing —
    // the source's requirement is unmet, so this is a rights refusal (403
    // naming it), not a missing field (422).
    expect(blank.status).toBe(403);
    expect(String((await json(blank))["error"])).toContain("attribution");

    const submitted = {
      ownRights: true,
      noPersonalData: true,
      sourceRights: {
        textRedistribution: "permitted",
        attributionRequired: true,
        attribution: "Adapted from the Open Recipe Collection (CC BY 4.0)",
      },
    };
    const carried = await publish(baseUrl, alice, publishBody({ declarations: submitted }));
    expect(carried.status).toBe(201);
    const created = await json(carried);
    expect(created.declarations).toEqual(submitted);

    // No over-blocking: the attribution-carrying publication reaches readers.
    const bob = await signInAs("rights-bob-attribution");
    const feed = await fetch(`${baseUrl}/v1/community/explore/campus-north`, {
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(feed.status).toBe(200);
    const feedBody = (await json(feed)) as { items: Array<{ publicationId: string }> };
    expect(feedBody.items.some((item) => item.publicationId === created.publicationId)).toBe(true);
  });
});

describe("a valid declaration flows through screening and the queue unchanged", () => {
  test("clean content still publishes outright", async () => {
    const alice = await signInAs("rights-alice-clean");
    const res = await publish(baseUrl, alice, publishBody({ campus: "rights-clean" }));
    expect(res.status).toBe(201);
    const created = await json(res);
    expect(created.status).toBe("published");
    expect(created.publishedAtIso).not.toBeNull();
    // The declaration is on the published record too.
    const raw = await harness.store.publications.doc(created.publicationId as string).get();
    expect(raw.get("declarations")).toEqual(declarations());
  });

  test("failing screening still queues, and approval still publishes a lint-passing record — declaration riding along", async () => {
    const mod = await makeModerator("rights-mod-flow");
    const author = await signInAs("rights-alice-flow");

    // The strict app's stub stage always fails: the publication queues at
    // creation, exactly as before the declaration existed.
    const res = await publish(strictUrl, author, publishBody({ campus: "rights-flow" }));
    expect(res.status).toBe(201);
    const created = await json(res);
    const publicationId = created.publicationId as string;
    expect(created.status).toBe("queued");
    expect(created.declarations).toEqual(declarations());

    // The moderation queue holds the item; the author keeps their queued view.
    const item = await openItemFor(mod, publicationId);
    const got = await getRecord(author, publicationId);
    expect(got.status).toBe(200);
    expect(((await json(got)) as Record<string, unknown>)["status"]).toBe("queued");

    // The mandatory fixture gate's lint passed at this exact revision, so
    // approval publishes — the blocker-1 approval machinery is unchanged.
    const approve = await resolveItem(mod, item.itemId, "approved");
    expect(approve.status).toBe(200);

    const published = await getRecord(author, publicationId);
    expect(published.status).toBe(200);
    const record = await json(published);
    expect(record.status).toBe("published");
    expect(record.declarations).toEqual(declarations());
  });
});

describe("the publication refusal policy (pure)", () => {
  test("it refuses exactly what publication may not do", () => {
    const refusalFor = (sourceRights: Partial<SourceRightsDeclaration> & Record<string, unknown>): string | null =>
      publicationRightsRefusal({
        textRedistribution: "permitted",
        attributionRequired: false,
        attribution: null,
        ...sourceRights,
      } as SourceRightsDeclaration);

    expect(refusalFor({})).toBeNull();
    expect(refusalFor({ attributionRequired: true, attribution: "Source (CC BY 4.0)" })).toBeNull();

    const forbidden = refusalFor({ textRedistribution: "forbidden" });
    expect(forbidden).not.toBeNull();
    expect(forbidden).toContain("forbidden");

    const unknown = refusalFor({ textRedistribution: "unknown" });
    expect(unknown).not.toBeNull();
    expect(unknown).toContain("quarantine");

    const uncarried = refusalFor({ attributionRequired: true });
    expect(uncarried).not.toBeNull();
    expect(uncarried).toContain("attribution");
  });
});
