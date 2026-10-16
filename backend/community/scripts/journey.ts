/**
 * Two-user journey runner for the community backend (scripts/community-e2e/journey.sh).
 * Boots exactly the production wiring (src/app.ts) — same seams as
 * scripts/e2e-server.ts, none in src/ — and walks two members through the
 * whole social surface over real HTTP, asserting every response:
 *
 *   sign-in → table → invite → join → approve → publish → cook share with
 *   idempotent retry → report → moderation hide/dismiss → leave → return →
 *   challenge entry → saved-replay after entries close → block/unblock.
 *
 * The Apple seam is identical to e2e-server.ts: an RSA key set generated in
 * process, JWKS served from localhost, tokens signed locally and verified by
 * the production AppleVerifier (only the signer is local — SPEC test rules).
 *
 *   bun run scripts/journey.ts                       # in-memory store
 *   COMMUNITY_STORE=firestore bun run scripts/journey.ts
 *       # Firestore adapter; needs FIRESTORE_EMULATOR_HOST (and the emulator)
 *
 * Exits 0 when every step passed; on the first failure it prints the step,
 * the response status and body, and exits 1.
 */

import { buildApp } from "../src/app.js";
import { createChallengeDocument } from "../src/modules/challenges/views.js";
import { accountIdShape } from "../src/core/ids.js";
import { generateKeyPairSync, createHash, sign as rsaSign, randomUUID } from "node:crypto";
import type { Clock } from "../src/core/time.js";

const useFirestore = (process.env.COMMUNITY_STORE ?? "memory") === "firestore";
const firestoreProjectId = process.env.FIRESTORE_PROJECT_ID ?? `fridgeluck-journey-${Date.now().toString(36)}`;
if (useFirestore && process.env.FIRESTORE_EMULATOR_HOST === undefined) {
  console.error("journey: COMMUNITY_STORE=firestore needs FIRESTORE_EMULATOR_HOST pointing at a running emulator");
  process.exit(1);
}

/** Movable clock starting at real wall time; the journey advances it once. */
class MovableClock implements Clock {
  private ms: number = Date.now();
  now(): Date {
    return new Date(this.ms);
  }
  advance(hours: number): void {
    this.ms += hours * 60 * 60 * 1000;
  }
}
const clock = new MovableClock();

/** The test Apple: RS256 keys generated in process, JWKS served from localhost. */
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string };
const kid = createHash("sha256").update(jwk.n).digest("hex").slice(0, 16);
const APPLE_ISSUER = "https://appleid.journey.fridgeluck.test";
const APPLE_BUNDLE = "dev.fridgeluck.journey";

const auxiliary = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/keys") {
      return Response.json({ keys: [{ kid, kty: jwk.kty, alg: "RS256", n: jwk.n, e: jwk.e }] });
    }
    return Response.json({ error: { code: "not_found", message: "unknown journey route" } }, { status: 404 });
  },
});

/** Signs an identity token the way Apple would, embedding SHA-256 of the raw nonce. */
function mintIdentityToken(sub: string, rawNonce: string): string {
  const iat = Math.floor(clock.now().getTime() / 1000);
  const head = Buffer.from(JSON.stringify({ alg: "RS256", kid })).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({
      iss: APPLE_ISSUER,
      aud: APPLE_BUNDLE,
      sub,
      nonce: createHash("sha256").update(rawNonce).digest("hex"),
      email: `${sub}@privaterelay.appleid.com`,
      iat,
      exp: iat + 3600,
    }),
  ).toString("base64url");
  const sig = rsaSign("RSA-SHA256", Buffer.from(`${head}.${payload}`), privateKey).toString("base64url");
  return `${head}.${payload}.${sig}`;
}

/** The allowlisted moderation operator: a known account id with a pre-seeded identity. */
const OPERATOR_ACCOUNT_ID = accountIdShape.newId();
const OPERATOR_APPLE_SUB = "journey-operator";

const app = await buildApp({
  clock,
  config: {
    store: useFirestore ? "firestore" : "memory",
    firestoreProjectId,
    sessionSecret: randomUUID(),
    operatorAccountIds: [OPERATOR_ACCOUNT_ID],
    appleIssuer: APPLE_ISSUER,
    appleBundleId: APPLE_BUNDLE,
    appleJwksUrl: `http://127.0.0.1:${auxiliary.port}/keys`,
    screeningPackagesLoaded: true,
  },
});

await app.store.collection("identities").doc(OPERATOR_APPLE_SUB).set({ accountId: OPERATOR_ACCOUNT_ID });
await app.store.collection("accounts").doc(OPERATOR_ACCOUNT_ID).set({ displayName: "Operator", createdAt: clock.now().toISOString() });

const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (request) => app.handle(request) });
const base = `http://127.0.0.1:${server.port}/v1`;

// --- Journey scaffolding -----------------------------------------------------

class StepFailure extends Error {}

async function call(method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  return fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

/** Asserts the status; on mismatch the failure message carries the response body. */
async function expectStatus(response: Response, status: number, what: string): Promise<void> {
  if (response.status !== status) {
    const body = await response.text().catch(() => "<unreadable body>");
    throw new StepFailure(`${what}: expected ${status}, got ${response.status} — ${body.slice(0, 400)}`);
  }
}

interface Session {
  token: string;
  accountId: string;
}

async function signIn(appleSub: string): Promise<Session> {
  const rawNonce = randomUUID();
  const response = await call("POST", "/auth/apple", undefined, {
    identityToken: mintIdentityToken(appleSub, rawNonce),
    nonce: rawNonce,
    attest18Plus: { birthYear: 1990 },
  });
  await expectStatus(response, 200, `sign-in for ${appleSub}`);
  const data = (await response.json()) as { accessToken: string; account: { accountId: string } };
  return { token: data.accessToken, accountId: data.account.accountId };
}

const steps: string[] = [];
let failed = 0;
async function step(name: string, run: () => Promise<void>): Promise<boolean> {
  try {
    await run();
    steps.push(`  ok  ${name}`);
    return true;
  } catch (error) {
    failed += 1;
    steps.push(`  FAIL ${name}: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
}

/** Re-signs both members in; sessions do not survive the journey's clock advance. */
async function freshSessions(): Promise<void> {
  ada = await signIn("journey-ada");
  bo = await signIn("journey-bo");
}

const cook = (over: Record<string, unknown> = {}) => ({
  recipeRef: { source: "user", id: "ur_journey", revision: 1 },
  dishName: "Journey lemon pasta",
  servings: 2,
  swaps: [{ fromName: "milk", toName: "oat milk" }],
  rating: 5,
  note: null,
  day: "2026-10-16",
  content: null,
  ...over,
});

const cleanRecipe = {
  title: "Journey lemon pasta",
  description: "Cooked together, end to end.",
  servings: 2,
  timeMinutes: 15,
  ingredientLines: [{ name: "milk", quantity: 200, unit: "ml" }],
  steps: [{ text: "Boil the pasta, then cook everything together.", timerMinutes: 10 }],
  equipment: ["pan"],
  dietaryTags: ["vegetarian"],
};

// --- The walk ----------------------------------------------------------------

let ada = await signIn("journey-ada");
let bo = await signIn("journey-bo");
const operator = await signIn(OPERATOR_APPLE_SUB);

let tableId = "";
let cardId = "";
let operationId = "";
let challengeId = "";
let entryId = "";
let entryOperationId = "";

const ok =
  (await step("ada creates a table", async () => {
    const created = await call("POST", "/tables", ada.token, { name: "Journey crew" });
    await expectStatus(created, 201, "create table");
    tableId = ((await created.json()) as { tableId: string }).tableId;
  })) &&
  (await step("ada mints an invite", async () => {
    const minted = await call("POST", `/tables/${tableId}/invites`, ada.token, {});
    await expectStatus(minted, 201, "mint invite");
    const { joinCode } = (await minted.json()) as { inviteId: string; joinCode: string };
    const joined = await call("POST", `/invites/${joinCode}/join`, bo.token, {});
    await expectStatus(joined, 202, "bo presents the code");
  })) &&
  (await step("ada approves bo; both see the table", async () => {
    const queue = await call("GET", `/tables/${tableId}`, ada.token);
    await expectStatus(queue, 200, "ada views the table");
    const { pendingInvites, members } = (await queue.json()) as {
      pendingInvites: { inviteId: string; state: string }[];
      members: { accountId: string }[];
    };
    const pending = pendingInvites.find((i) => i.state === "pending");
    if (pending === undefined) throw new StepFailure("no pending invite on the table");
    await expectStatus(await call("POST", `/tables/${tableId}/invites/${pending.inviteId}/approve`, ada.token, {}), 200, "approve");
    const boView = await call("GET", `/tables/${tableId}`, bo.token);
    await expectStatus(boView, 200, "bo views the table");
    const seen = (await boView.json()) as { members: { accountId: string }[] };
    if (!seen.members.some((m) => m.accountId === bo.accountId)) throw new StepFailure("bo is not listed as a member");
    if (members.length + 1 !== seen.members.length) throw new StepFailure(`member count went ${members.length} -> ${seen.members.length}`);
  })) &&
  (await step("bo publishes a recipe and shares a cook card", async () => {
    const published = await call("POST", "/publications", bo.token, {
      operationId: randomUUID(),
      recipeRef: { source: "user", id: "ur_journey", revision: 1 },
      content: cleanRecipe,
      declaration: { ownRights: true, noPersonalData: true },
    });
    await expectStatus(published, 201, "publish");
    operationId = randomUUID();
    const shared = await call("POST", `/tables/${tableId}/cards`, bo.token, { operationId, cook: cook() });
    await expectStatus(shared, 201, "share card");
    cardId = ((await shared.json()) as { cardId: string }).cardId;
  })) &&
  (await step("bo's retry with the same operationId returns the same card", async () => {
    const replayed = await call("POST", `/tables/${tableId}/cards`, bo.token, { operationId, cook: cook() });
    await expectStatus(replayed, 201, "replay");
    const replay = (await replayed.json()) as { cardId: string };
    if (replay.cardId !== cardId) throw new StepFailure(`replay returned ${replay.cardId}, first save was ${cardId}`);
  })) &&
  (await step("ada's feed shows bo's card and only once", async () => {
    const feed = await call("GET", `/tables/${tableId}/cards`, ada.token);
    await expectStatus(feed, 200, "ada's feed");
    const cards = (await feed.json()) as { cards: { cardId: string; isMine: boolean }[] };
    const mine = cards.cards.filter((c) => c.cardId === cardId);
    if (mine.length !== 1) throw new StepFailure(`card appears ${mine.length} times in ada's feed`);
    if (mine[0]?.isMine !== false) throw new StepFailure("ada's feed marks bo's card as hers");
  })) &&
  (await step("ada reports the card; the operator hides it", async () => {
    const reported = await call("POST", "/reports", ada.token, { targetType: "tableCard", targetId: cardId, reason: "spam" });
    await expectStatus(reported, 202, "report");
    const queue = await call("GET", "/moderation/queue", operator.token);
    await expectStatus(queue, 200, "moderation queue");
    const cases = ((await queue.json()) as { cases: { caseId: string; targetId: string; state: string }[] }).cases;
    const found = cases.find((c) => c.targetId === cardId && c.state === "queued");
    if (found === undefined) throw new StepFailure("the reported card is not queued");
    await expectStatus(await call("POST", `/moderation/cases/${found.caseId}/decision`, operator.token, { action: "hide" }), 200, "hide");
    const feed = await call("GET", `/tables/${tableId}/cards`, ada.token);
    await expectStatus(feed, 200, "ada's feed after hide");
    const cards = (await feed.json()) as { cards: { cardId: string }[] };
    if (cards.cards.some((c) => c.cardId === cardId)) throw new StepFailure("the hidden card is still in ada's feed");
  })) &&
  (await step("a dismissed report brings the card back", async () => {
    await expectStatus(await call("POST", "/reports", ada.token, { targetType: "tableCard", targetId: cardId, reason: "spam" }), 202, "second report");
    const queue = await call("GET", "/moderation/queue", operator.token);
    await expectStatus(queue, 200, "moderation queue");
    const cases = ((await queue.json()) as { cases: { caseId: string; targetId: string; state: string }[] }).cases;
    const found = cases.find((c) => c.targetId === cardId && c.state === "queued");
    if (found === undefined) throw new StepFailure("the re-reported card is not queued");
    await expectStatus(await call("POST", `/moderation/cases/${found.caseId}/decision`, operator.token, { action: "dismiss" }), 200, "dismiss");
    const feed = await call("GET", `/tables/${tableId}/cards`, ada.token);
    await expectStatus(feed, 200, "ada's feed after dismiss");
    const cards = (await feed.json()) as { cards: { cardId: string }[] };
    if (!cards.cards.some((c) => c.cardId === cardId)) throw new StepFailure("the dismissed card never came back");
  })) &&
  (await step("bo leaves; the table closes behind him", async () => {
    await expectStatus(await call("POST", `/tables/${tableId}/leave`, bo.token), 204, "leave");
    await expectStatus(await call("GET", `/tables/${tableId}`, bo.token), 404, "bo's view after leaving");
  })) &&
  (await step("bo returns through a fresh invite and shares again", async () => {
    const minted = await call("POST", `/tables/${tableId}/invites`, ada.token, {});
    await expectStatus(minted, 201, "re-mint invite");
    const { inviteId, joinCode } = (await minted.json()) as { inviteId: string; joinCode: string };
    await expectStatus(await call("POST", `/invites/${joinCode}/join`, bo.token, {}), 202, "bo presents the code again");
    await expectStatus(await call("POST", `/tables/${tableId}/invites/${inviteId}/approve`, ada.token, {}), 200, "approve the return");
    const shared = await call("POST", `/tables/${tableId}/cards`, bo.token, { operationId: randomUUID(), cook: cook({ dishName: "Return pasta" }) });
    await expectStatus(shared, 201, "returning member shares");
  })) &&
  (await step("bo enters the challenge", async () => {
    const challenge = await createChallengeDocument(app.store, {
      type: "battle",
      name: "Journey battle",
      brief: "Seeded by the journey runner.",
      opensAt: new Date(clock.now().getTime() - 3600_000).toISOString(),
      entryClosesAt: new Date(clock.now().getTime() + 48 * 3600_000).toISOString(),
      votingClosesAt: new Date(clock.now().getTime() + 96 * 3600_000).toISOString(),
      resolvedItems: null,
      packId: null,
    });
    challengeId = challenge.challengeId;
    entryOperationId = randomUUID();
    const entered = await call("POST", `/challenges/${challengeId}/entries`, bo.token, {
      operationId: entryOperationId,
      recipeRef: { source: "user", id: "ur_journey", revision: 1 },
    });
    await expectStatus(entered, 201, "enter");
    entryId = ((await entered.json()) as { entryId: string }).entryId;
  })) &&
  (await step("after entries close, bo's saved retry replays the same entry", async () => {
    clock.advance(50);
    await freshSessions();
    const replayed = await call("POST", `/challenges/${challengeId}/entries`, bo.token, {
      operationId: entryOperationId, // the saved id: the retry rides the saved response
      recipeRef: { source: "user", id: "ur_journey", revision: 1 },
    });
    // 015fc30 challenges:199: the retry rides the saved operationId response.
    await expectStatus(replayed, 201, "replay after entries close");
    const replay = (await replayed.json()) as { entryId: string };
    if (replay.entryId !== entryId) throw new StepFailure(`replay returned entry ${replay.entryId}, saved was ${entryId}`);
  })) &&
  (await step("ada blocks bo; the pair's feeds go quiet", async () => {
    await expectStatus(await call("PUT", `/blocks/${bo.accountId}`, ada.token), 204, "block");
    const adaFeed = await call("GET", `/tables/${tableId}/cards`, ada.token);
    await expectStatus(adaFeed, 200, "ada's feed while blocked");
    const adaCards = (await adaFeed.json()) as { cards: { cardId: string; isMine: boolean }[] };
    if (adaCards.cards.some((c) => !c.isMine)) throw new StepFailure("ada still sees bo's cards while blocking him");
    const boFeed = await call("GET", `/tables/${tableId}/cards`, bo.token);
    await expectStatus(boFeed, 200, "bo's feed while blocked");
    const boCards = (await boFeed.json()) as { cards: { cardId: string; isMine: boolean }[] };
    if (boCards.cards.some((c) => !c.isMine)) throw new StepFailure("bo still sees ada's cards while she blocks him");
  })) &&
  (await step("unblocking restores the pair's feeds", async () => {
    await expectStatus(await call("DELETE", `/blocks/${bo.accountId}`, ada.token), 204, "unblock");
    const adaFeed = await call("GET", `/tables/${tableId}/cards`, ada.token);
    await expectStatus(adaFeed, 200, "ada's feed after unblock");
    const adaCards = (await adaFeed.json()) as { cards: { cardId: string; isMine: boolean }[] };
    if (adaCards.cards.filter((c) => !c.isMine).length !== 2) {
      throw new StepFailure(`ada sees ${adaCards.cards.filter((c) => !c.isMine).length} of bo's cards after unblocking, expected 2`);
    }
  }));

server.stop(true);
auxiliary.stop(true);

const storeLabel = useFirestore ? `firestore (${firestoreProjectId})` : "memory";
const passed = steps.length - failed;
for (const line of steps) {
  console.log(line);
}
console.log(`\njourney (${storeLabel}): ${passed}/${steps.length} steps passed`);
if (failed > 0) {
  process.exit(1);
}
