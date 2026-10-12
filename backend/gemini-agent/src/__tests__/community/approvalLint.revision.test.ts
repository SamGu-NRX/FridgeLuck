/**
 * Moderation approval requires a passing food-safety lint at the exact
 * content revision being approved (PR #104 review blocker 1). Approval used
 * to publish anything queued, including a publication whose screening
 * failed or whose recorded pass predated the current content.
 *
 * The fix records, at creation, the screening evaluation bound to a hash of
 * the exact screenable content it judged (screenedEvaluation on the record).
 * An approve decision refuses — 409, nothing written, the item stays open —
 * unless that evaluation proves the mandatory gate's stages passed at the
 * current content. Visibility still derives solely from moderation state;
 * the refusal only withholds the state change.
 *
 * Proven over the real HTTP surface against the Firestore emulator, with
 * the fixture food-safety gate ACTIVE:
 *   (1) approving a publication whose current revision failed the lint
 *       leaves it hidden from every reader surface, the author keeps their
 *       own queued view, the item stays open, and rejection still works;
 *   (2) a recorded pass from an older revision does not authorize a newer
 *       one — content mutated in the store between the lint and the approve
 *       refuses approval;
 *   (3) a publication whose lint passes at the current revision still goes
 *       live on approval, exactly as before.
 * A unit block pins the pure refusal check over all its branches.
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
import { approvalRefusal, contentHashOf, screenablePublicationOf, type PublicationRecord } from "../../community/explore/publications.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { stubBlockDirectory } from "../../community/shared/testing/stubs.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let blocks: ReturnType<typeof stubBlockDirectory>;
let openUrl: string;
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
  const nonce = `apr-nonce-${String(nonceCounter).padStart(4, "0")}`;
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
    source: { recipeId: "recipes/apr-rice", recipeRevision: "rev-000001" },
    recipe: {
      title: "Weeknight tomato rice",
      summary: "A simple tomato rice for two.",
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp tahini"],
      steps: ["Cook the rice.", "Fry the tomatoes, stir in the tahini, fold through the rice."],
    },
    tags: ["quick"],
    campus: "apr-clean",
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
  openUrl = await startApp({
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks,
    moderation,
    screeningStages: [],
    foodSafetyGate: fixtureFoodSafetyGate(),
  });
  // Warm the Firestore channel during setup: the first gRPC call pays a
  // GCE-metadata probe (with retries) before falling back to the emulator.
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

async function openItemFor(mod: TokenPair, pubId: string): Promise<QueueItemJson> {
  const queue = (await json(await fetch(`${openUrl}/v1/community/moderation/queue`, {
    headers: { authorization: `Bearer ${mod.accessToken}` },
  }))) as { items: QueueItemJson[] };
  const item = queue.items.find((i) => i.target.publicationId === pubId);
  expect(item).toBeDefined();
  return item as QueueItemJson;
}

/** Resolves an item and returns the raw response — refusals expect a conflict status. */
async function resolveItemRaw(mod: TokenPair, itemId: string, decision: "approved" | "rejected"): Promise<Response> {
  return fetch(`${openUrl}/v1/community/moderation/items/${itemId}/resolve`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
    body: JSON.stringify({ decision, note: "approval lint decision" }),
  });
}

describe("approval requires a passing food-safety lint at the exact revision", () => {
  test("(1) approving a publication whose current revision failed the lint refuses and stays hidden — fail closed", async () => {
    const mod = await makeModerator("apr-mod-failed");
    const author = await signInAs("apr-failed-author");
    const bob = await signInAs("apr-failed-bob");

    // "until done" with no thermometer evidence trips the fixture canon's
    // doneness rule: the mandatory gate's lint fails and the publication
    // queues at creation.
    const res = await publish(openUrl, author, publishBody({
      source: { recipeId: "recipes/apr-unevaluated", recipeRevision: "rev-000002" },
      recipe: {
        title: "Weeknight roast chicken",
        summary: "A simple roast chicken.",
        ingredientLines: ["1 kg chicken", "1 lemon"],
        steps: ["Season the chicken.", "Roast until done."],
      },
      campus: "apr-failed",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");

    // Evidence the failure is the mandatory gate's lint itself.
    const stored = await harness.store.publications.doc(created.publicationId).get();
    const failures = stored.get("screeningFailures") as Array<{ stage: string }>;
    expect(failures.some((f) => f.stage === "food-safety-lint")).toBe(true);

    // The approve decision refuses: 409, nothing published, the item stays
    // open so the moderator can still decide with the gate's verdict.
    const approve = await resolveItemRaw(mod, (await openItemFor(mod, created.publicationId)).itemId, "approved");
    expect(approve.status).toBe(409);
    const approveBody = (await approve.json()) as { code: string; error: string };
    expect(approveBody.code).toBe("conflict");
    expect(approveBody.error).toContain('food-safety stage "food-safety-lint" does not pass');

    await expectReaderSurface(created.publicationId, bob, "apr-failed", false);
    await expectAuthorSees(created.publicationId, author, "queued");
    await expectInOpenQueue(created.publicationId, mod, true);

    // The rejection path is untouched: the moderator rejects, the
    // publication stays hidden forever and leaves the queue.
    const reject = await resolveItemRaw(mod, (await openItemFor(mod, created.publicationId)).itemId, "rejected");
    expect(reject.status).toBe(200);
    await expectReaderSurface(created.publicationId, bob, "apr-failed", false);
    await expectAuthorSees(created.publicationId, author, "rejected");
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(2) a recorded lint pass from an older revision does not authorize a newer one: content mutated between lint and approve does not publish", async () => {
    const mod = await makeModerator("apr-mod-stale");
    const author = await signInAs("apr-stale-author");
    const bob = await signInAs("apr-stale-bob");
    const reporter = await signInAs("apr-stale-reporter");

    const res = await publish(openUrl, author, publishBody({
      source: { recipeId: "recipes/apr-stale", recipeRevision: "rev-000003" },
      campus: "apr-stale",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");

    // Reported: hide first, queue for review. The recorded evaluation binds
    // to the content as it was at creation.
    const report = await fetch(`${openUrl}/v1/community/publications/${created.publicationId}/reports`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${reporter.accessToken}` },
      body: JSON.stringify({ reason: "other", note: "apr stale probe" }),
    });
    expect(report.status).toBe(201);

    // Mutate the content UNDERNEATH the recorded evaluation: the record now
    // carries a lint pass for content it no longer matches (and the new
    // step would itself trip the doneness rule).
    await harness.store.publications.doc(created.publicationId).update({ steps: ["Bake until done."] });

    const approve = await resolveItemRaw(mod, (await openItemFor(mod, created.publicationId)).itemId, "approved");
    expect(approve.status).toBe(409);
    const staleBody = (await approve.json()) as { code: string; error: string };
    expect(staleBody.code).toBe("conflict");
    expect(staleBody.error).toContain("older revision");

    await expectReaderSurface(created.publicationId, bob, "apr-stale", false);
    await expectAuthorSees(created.publicationId, author, "queued");
    await expectInOpenQueue(created.publicationId, mod, true);
  });

  test("(3) approving a publication whose lint passes at the current revision still goes live as before", async () => {
    const mod = await makeModerator("apr-mod-pass");
    const author = await signInAs("apr-pass-author");
    const bob = await signInAs("apr-pass-bob");
    const reporter = await signInAs("apr-pass-reporter");

    const res = await publish(openUrl, author, publishBody({
      source: { recipeId: "recipes/apr-pass", recipeRevision: "rev-000004" },
      campus: "apr-pass",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");

    await fetch(`${openUrl}/v1/community/publications/${created.publicationId}/reports`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${reporter.accessToken}` },
      body: JSON.stringify({ reason: "other", note: "apr pass probe" }),
    });
    await expectAuthorSees(created.publicationId, author, "queued");

    const approve = await resolveItemRaw(mod, (await openItemFor(mod, created.publicationId)).itemId, "approved");
    expect(approve.status).toBe(200);

    await expectReaderSurface(created.publicationId, bob, "apr-pass", true);
    await expectAuthorSees(created.publicationId, author, "published");
    await expectInOpenQueue(created.publicationId, mod, false);
  });

  test("(4) approving a publication whose compound-allergens stage failed on unknown composition refuses — unknown is never allowed", async () => {
    const mod = await makeModerator("apr-mod-unknown");
    const author = await signInAs("apr-unknown-author");
    const bob = await signInAs("apr-unknown-bob");

    // "1 cup flurb" matches no reviewed fact: the compound-allergens stage
    // fails on the unknown composition (blocker 3) and the publication
    // queues at creation.
    const res = await publish(openUrl, author, publishBody({
      source: { recipeId: "recipes/apr-unknown", recipeRevision: "rev-000005" },
      recipe: {
        title: "Mystery powder drink",
        summary: "An exotic blend.",
        ingredientLines: ["200 g rice", "1 cup flurb"],
        steps: ["Blend and drink."],
      },
      campus: "apr-unknown",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");

    // Evidence the failure is the unknown composition itself.
    const stored = await harness.store.publications.doc(created.publicationId).get();
    const failures = stored.get("screeningFailures") as Array<{ stage: string }>;
    expect(failures.some((f) => f.stage === "compound-allergens")).toBe(true);

    // Approval still refuses (blocker 1 composes with blocker 3): the
    // decision does not land, the item stays open, nothing publishes.
    const approve = await resolveItemRaw(mod, (await openItemFor(mod, created.publicationId)).itemId, "approved");
    expect(approve.status).toBe(409);
    const approveBody = (await approve.json()) as { code: string; error: string };
    expect(approveBody.code).toBe("conflict");
    expect(approveBody.error).toContain('food-safety stage "compound-allergens" does not pass');

    await expectReaderSurface(created.publicationId, bob, "apr-unknown", false);
    await expectAuthorSees(created.publicationId, author, "queued");
    await expectInOpenQueue(created.publicationId, mod, true);
  });
});

describe("the pure approval refusal check", () => {
  /** A full record fixture; the evaluation, when asked for, binds to its content. */
  function recordFixture(overrides: Partial<PublicationRecord> = {}): PublicationRecord {
    const base: PublicationRecord = {
      publicationId: "pub_apr_fixture" as PublicationRecord["publicationId"],
      revisionId: "rev_apr_fixture" as PublicationRecord["revisionId"],
      authorId: "acc_apr_fixture" as PublicationRecord["authorId"],
      sourceRecipeId: "recipes/apr-fixture",
      sourceRecipeRevision: "rev-000009",
      title: "Fixture stew",
      summary: "A fixture.",
      note: null,
      ingredientLines: ["300 g beef"],
      steps: ["Stew it."],
      tags: [],
      allergenTags: [],
      campus: "apr-fixture",
      status: "queued",
      screeningFailures: [],
      createdAtIso: "2026-10-12T00:00:00.000Z",
      publishedAtIso: null,
      withdrawnAtIso: null,
      rejectedAtIso: null,
      optedInCooks: {},
      screenedEvaluation: null,
    };
    return { ...base, ...overrides };
  }

  function passingEvaluationFor(record: PublicationRecord): NonNullable<PublicationRecord["screenedEvaluation"]> {
    return {
      contentHash: contentHashOf(screenablePublicationOf(record)),
      stages: [
        { name: "text-hygiene", passed: true },
        { name: "food-safety-lint", passed: true },
        { name: "compound-allergens", passed: true },
      ],
    };
  }

  test("a record with no recorded evaluation refuses (fail closed)", () => {
    const refusal = approvalRefusal(recordFixture());
    expect(refusal).toContain("no screening evaluation");
  });

  test("a record whose mandatory stage did not run refuses", () => {
    const record = recordFixture({ screenedEvaluation: { contentHash: contentHashOf(screenablePublicationOf(recordFixture())), stages: [{ name: "text-hygiene", passed: true }] } });
    expect(approvalRefusal(record)).toContain('stage "food-safety-lint" did not run');
  });

  test("a record whose mandatory stage failed refuses", () => {
    const record = recordFixture({ screenedEvaluation: { contentHash: contentHashOf(screenablePublicationOf(recordFixture())), stages: [{ name: "food-safety-lint", passed: false }, { name: "compound-allergens", passed: true }] } });
    expect(approvalRefusal(record)).toContain('stage "food-safety-lint" does not pass');
  });

  test("an evaluation bound to older content refuses", () => {
    const stale = recordFixture({ screenedEvaluation: { contentHash: "0".repeat(64), stages: [{ name: "food-safety-lint", passed: true }, { name: "compound-allergens", passed: true }] } });
    expect(approvalRefusal(stale)).toContain("older revision");
  });

  test("a passing evaluation bound to the exact content approves", () => {
    const record = recordFixture({ screenedEvaluation: passingEvaluationFor(recordFixture()) });
    expect(approvalRefusal(record)).toBeNull();
  });
});
