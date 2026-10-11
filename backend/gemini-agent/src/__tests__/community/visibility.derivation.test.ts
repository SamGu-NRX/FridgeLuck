/**
 * Publication visibility derives solely from moderation state (PR #104 review
 * blocker 5). One derivation — `publicationVisibility(status)` in
 * explore/publications.ts — answers every visibility question, and every
 * surface (Explore feed, direct read, author view, moderation queue, cook
 * occurrences, reports) consults it and nothing else.
 *
 * Proven over the real HTTP surface against the Firestore emulator, with the
 * mandatory food-safety gate ACTIVE (fixture packages): fix 1's
 * queued-and-hidden publish behavior composes — a screening-failed
 * publication is queued and hidden until a moderator decides, and only the
 * decision's moderation-state change can make it visible.
 *
 * Arms:
 *   (i)   the derivation matrix, pinned at unit level — the one table mapping
 *         each moderation state to its visibility answers;
 *   (ii)  every surface agrees with the derivation across the full transition
 *         coverage: clean (published), screening-failure (queued),
 *         reinstated (queued → published by approval), reported
 *         (published → queued by report), upheld (queued → rejected), and
 *         withdrawn (from live, and from queued while an item is open);
 *   (iii) tamper: flipping a legacy scattered flag (`hidden`) in the store
 *         WITHOUT changing moderation state cannot make hidden content
 *         visible anywhere — nor visible content hidden.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { createSafetyRoutes } from "../../community/safety/safetyRoutes.js";
import { publicationVisibility } from "../../community/explore/publications.js";
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
let openUrl: string;
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

async function signInAs(sub: string): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `vis-nonce-${String(nonceCounter).padStart(4, "0")}`;
  const res = await fetch(`${openUrl}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: mintAppleToken({ sub, nonce }), nonce, attested18Plus: true }),
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

function publishBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: { recipeId: "recipes/vis-rice", recipeRevision: "rev-000001" },
    recipe: {
      title: "Weeknight tomato rice",
      summary: "A simple tomato rice for two.",
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp tahini"],
      steps: ["Cook the rice.", "Fry the tomatoes, stir in the tahini, fold through the rice."],
    },
    tags: ["quick"],
    campus: "vis-clean",
    note: null,
    declarations: { ownRights: true, noPersonalData: true },
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

async function feed(viewer: TokenPair, campus: string): Promise<Response> {
  return fetch(`${openUrl}/v1/community/explore/${campus}`, {
    headers: { authorization: `Bearer ${viewer.accessToken}` },
  });
}

interface PublicationJson {
  publicationId: string;
  status: string;
}

interface FeedJson {
  campus: string;
  items: ReadonlyArray<{ publicationId: string; title: string }>;
}

interface QueueItemJson {
  itemId: string;
  target: { publicationId: string; revisionId: string };
  status: string;
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

function startApp(deps: CommunityDeps): Promise<string> {
  const app = express();
  app.use(express.json());
  // The safety part is mounted for the reports endpoint — a reader surface
  // the derivation drives (reporting a hidden publication is a conflict).
  app.use(createCommunityRouter(deps, { identity: createIdentityRoutes, explore: createExploreRoutes, safety: createSafetyRoutes }));
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  return new Promise<string>((resolve) => {
    server.once("listening", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        throw new Error("test server did not bind");
      }
      resolve(`http://127.0.0.1:${address.port}`);
    });
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
  openUrl = await startApp({ ...base, screeningStages: [], foodSafetyGate: fixtureFoodSafetyGate() });
  strictUrl = await startApp({
    ...base,
    screeningStages: [stubScreeningFail(["remove the branded mention"], "stub-linter")],
    foodSafetyGate: fixtureFoodSafetyGate(),
  });
  // Warm the Firestore channel during setup: the first gRPC call pays a
  // GCE-metadata probe (with retries) before falling back to the emulator,
  // and that cost would otherwise time out whichever test runs first.
  await harness.store.publications.limit(1).get();
});

afterAll(async () => {
  for (const server of servers) {
    server.close();
  }
  jwksServer.stop(true);
  await harness.close();
});

/** Reader-surface probes: the feed, the direct read, and the live cook-occurrence path. */
async function expectReaderSurface(pubId: string, viewer: TokenPair, campus: string, visible: boolean): Promise<void> {
  const feedBody = (await json(await feed(viewer, campus))) as unknown as FeedJson;
  expect(feedBody.items.some((i) => i.publicationId === pubId)).toBe(visible);

  const direct = await fetch(`${openUrl}/v1/community/publications/${pubId}`, {
    headers: { authorization: `Bearer ${viewer.accessToken}` },
  });
  expect(direct.status).toBe(visible ? 200 : 404);

  const cook = await fetch(`${openUrl}/v1/community/publications/${pubId}/cooks`, {
    method: "POST",
    headers: { authorization: `Bearer ${viewer.accessToken}` },
  });
  expect(cook.status).toBe(visible ? 204 : 409);
}

/** Reporting a hidden publication is a conflict; a live one is reported successfully (which hides it). */
async function expectReportable(pubId: string, reporter: TokenPair, reportable: boolean): Promise<void> {
  const report = await fetch(`${openUrl}/v1/community/publications/${pubId}/reports`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${reporter.accessToken}` },
    body: JSON.stringify({ reason: "other", note: "vis probe" }),
  });
  expect(report.status).toBe(reportable ? 201 : 409);
}

/** The author sees their own record in any moderation state, on the direct read and in /mine. */
async function expectAuthorSees(pubId: string, author: TokenPair, status: string): Promise<void> {
  const direct = await fetch(`${openUrl}/v1/community/publications/${pubId}`, {
    headers: { authorization: `Bearer ${author.accessToken}` },
  });
  expect(direct.status).toBe(200);
  expect(((await json(direct)) as unknown as PublicationJson).status).toBe(status);

  const mine = await fetch(`${openUrl}/v1/community/publications/mine`, {
    headers: { authorization: `Bearer ${author.accessToken}` },
  });
  const mineBody = (await json(mine)) as { items: Array<{ publicationId: string; status: string }> };
  expect(mineBody.items.find((i) => i.publicationId === pubId)?.status).toBe(status);
}

/** The publication sits in the open moderation queue exactly while it is pending a decision. */
async function expectInOpenQueue(pubId: string, mod: TokenPair, present: boolean): Promise<void> {
  const queue = (await json(await fetch(`${openUrl}/v1/community/moderation/queue`, {
    headers: { authorization: `Bearer ${mod.accessToken}` },
  }))) as { items: QueueItemJson[] };
  expect(queue.items.some((i) => i.target.publicationId === pubId)).toBe(present);
}

async function resolveItem(mod: TokenPair, itemId: string, decision: "approved" | "rejected"): Promise<void> {
  const res = await fetch(`${openUrl}/v1/community/moderation/items/${itemId}/resolve`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
    body: JSON.stringify({ decision, note: "vis derivation decision" }),
  });
  expect(res.status).toBe(200);
}

async function openItemFor(mod: TokenPair, pubId: string): Promise<QueueItemJson> {
  const queue = (await json(await fetch(`${openUrl}/v1/community/moderation/queue`, {
    headers: { authorization: `Bearer ${mod.accessToken}` },
  }))) as { items: QueueItemJson[] };
  const item = queue.items.find((i) => i.target.publicationId === pubId);
  expect(item).toBeDefined();
  return item as QueueItemJson;
}

describe("the visibility derivation", () => {
  test("(i) the matrix: one pure table over moderation state answers every visibility question", () => {
    expect(publicationVisibility("published")).toEqual({
      visibleToReaders: true,
      visibleToAuthor: true,
      inModerationQueue: false,
    });
    expect(publicationVisibility("queued")).toEqual({
      visibleToReaders: false,
      visibleToAuthor: true,
      inModerationQueue: true,
    });
    expect(publicationVisibility("rejected")).toEqual({
      visibleToReaders: false,
      visibleToAuthor: true,
      inModerationQueue: false,
    });
    expect(publicationVisibility("withdrawn")).toEqual({
      visibleToReaders: false,
      visibleToAuthor: true,
      inModerationQueue: false,
    });
  });

  test("(ii) clean → published: live on every reader surface, absent from the queue; withdrawn hides it but the author keeps the tombstone", async () => {
    const mod = await makeModerator("vis-mod-clean");
    const alice = await signInAs("vis-clean-alice");
    const bob = await signInAs("vis-clean-bob");
    const res = await publish(openUrl, alice, publishBody({ campus: "vis-clean" }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");

    await expectReaderSurface(created.publicationId, bob, "vis-clean", true);
    await expectAuthorSees(created.publicationId, alice, "published");
    await expectInOpenQueue(created.publicationId, mod, false);

    const gone = await fetch(`${openUrl}/v1/community/publications/${created.publicationId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(gone.status).toBe(204);

    await expectReaderSurface(created.publicationId, bob, "vis-clean", false);
    await expectReportable(created.publicationId, bob, false);
    await expectAuthorSees(created.publicationId, alice, "withdrawn");
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(ii) screening-failure → queued-and-hidden, approval reinstates: only the decision's state change makes it visible (fix 1 composed)", async () => {
    const mod = await makeModerator("vis-mod-queue");
    const dave = await signInAs("vis-queue-dave");
    const bob = await signInAs("vis-queue-bob");
    const res = await publish(strictUrl, dave, publishBody({
      source: { recipeId: "recipes/vis-branded", recipeRevision: "rev-000002" },
      recipe: { title: "Branded stir fry", ingredientLines: ["200 g rice", "soy sauce"], steps: ["Fry everything."] },
      campus: "vis-queue",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");

    // Queued by the mandatory gate's screening: hidden from every reader
    // surface, present in the queue, and the author still sees it.
    await expectReaderSurface(created.publicationId, bob, "vis-queue", false);
    await expectReportable(created.publicationId, bob, false);
    await expectAuthorSees(created.publicationId, dave, "queued");
    await expectInOpenQueue(created.publicationId, mod, true);

    await resolveItem(mod, (await openItemFor(mod, created.publicationId)).itemId, "approved");

    // Reinstated: the decision — not any flag — made it live again.
    await expectReaderSurface(created.publicationId, bob, "vis-queue", true);
    await expectAuthorSees(created.publicationId, dave, "published");
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(ii) reported then upheld: the report hides first, the rejection keeps it hidden, the author still sees it", async () => {
    const mod = await makeModerator("vis-mod-report");
    const alice = await signInAs("vis-report-alice");
    const bob = await signInAs("vis-report-bob");
    const res = await publish(openUrl, alice, publishBody({
      source: { recipeId: "recipes/vis-reported", recipeRevision: "rev-000003" },
      campus: "vis-report",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;

    await expectReportable(created.publicationId, bob, true);

    // Reported: published → queued by the hide-before-enqueue path.
    await expectReaderSurface(created.publicationId, bob, "vis-report", false);
    await expectReportable(created.publicationId, bob, false);
    await expectAuthorSees(created.publicationId, alice, "queued");
    await expectInOpenQueue(created.publicationId, mod, true);

    await resolveItem(mod, (await openItemFor(mod, created.publicationId)).itemId, "rejected");

    // Upheld: queued → rejected; hidden forever, out of the open queue.
    await expectReaderSurface(created.publicationId, bob, "vis-report", false);
    await expectReportable(created.publicationId, bob, false);
    await expectAuthorSees(created.publicationId, alice, "rejected");
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(ii) withdrawn while queued wins over a later decision: the resolved item cannot move the tombstone", async () => {
    const mod = await makeModerator("vis-mod-wq");
    const alice = await signInAs("vis-wq-alice");
    const bob = await signInAs("vis-wq-bob");
    const res = await publish(strictUrl, alice, publishBody({
      source: { recipeId: "recipes/vis-wq", recipeRevision: "rev-000004" },
      recipe: { title: "Branded stew", ingredientLines: ["300 g beef"], steps: ["Stew it."] },
      campus: "vis-wq",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");

    const gone = await fetch(`${openUrl}/v1/community/publications/${created.publicationId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(gone.status).toBe(204);

    // The leftover open item resolves, but the publication is withdrawn —
    // the decision's guard sees no pending state and moves nothing.
    await resolveItem(mod, (await openItemFor(mod, created.publicationId)).itemId, "rejected");
    await expectAuthorSees(created.publicationId, alice, "withdrawn");
    await expectReaderSurface(created.publicationId, bob, "vis-wq", false);
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(iii) tamper: flipping a legacy hidden flag in the store, without touching moderation state, changes no surface", async () => {
    const mod = await makeModerator("vis-mod-tamper");
    const bob = await signInAs("vis-tamper-bob");

    // A queued (screening-failed) publication planted with hidden: false —
    // the scattered-flag flip that would once have leaked it.
    const queued = (await json(await publish(strictUrl, await signInAs("vis-tamper-queued-author"), publishBody({
      source: { recipeId: "recipes/vis-tamper-q", recipeRevision: "rev-000005" },
      recipe: { title: "Branded bake", ingredientLines: ["200 g flour"], steps: ["Bake it."] },
      campus: "vis-tamper",
    })))) as unknown as PublicationJson;
    expect(queued.status).toBe("queued");
    await harness.store.publications.doc(queued.publicationId).update({ hidden: false, hiddenAtIso: null });

    await expectReaderSurface(queued.publicationId, bob, "vis-tamper", false);
    await expectReportable(queued.publicationId, bob, false);
    await expectInOpenQueue(queued.publicationId, mod, true);

    // A published publication planted with hidden: true stays live.
    const liveAuthor = await signInAs("vis-tamper-live-author");
    const live = (await json(await publish(openUrl, liveAuthor, publishBody({
      source: { recipeId: "recipes/vis-tamper-live", recipeRevision: "rev-000006" },
      campus: "vis-tamper-live",
    })))) as unknown as PublicationJson;
    expect(live.status).toBe("published");
    await harness.store.publications.doc(live.publicationId).update({ hidden: true });

    await expectReaderSurface(live.publicationId, bob, "vis-tamper-live", true);
    await expectAuthorSees(live.publicationId, liveAuthor, "published");

    // A rejected publication planted with hidden: false stays hidden.
    const rejectedAuthor = await signInAs("vis-tamper-rejected-author");
    const reporter = await signInAs("vis-tamper-reporter");
    const rejected = (await json(await publish(openUrl, rejectedAuthor, publishBody({
      source: { recipeId: "recipes/vis-tamper-rej", recipeRevision: "rev-000007" },
      campus: "vis-tamper-rej",
    })))) as unknown as PublicationJson;
    await expectReportable(rejected.publicationId, reporter, true);
    await resolveItem(mod, (await openItemFor(mod, rejected.publicationId)).itemId, "rejected");
    await harness.store.publications.doc(rejected.publicationId).update({ hidden: false });

    await expectReaderSurface(rejected.publicationId, bob, "vis-tamper-rej", false);
    await expectAuthorSees(rejected.publicationId, rejectedAuthor, "rejected");
  });
});
