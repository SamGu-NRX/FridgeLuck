/**
 * The challenges part over HTTP: challenge creation with kind-specific
 * constraints, the open definition read (the link's useful object, no
 * people data), private convergent entries, and the route boundaries
 * (401/404/422). Runs against the Firestore emulator.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createChallengeRoutes } from "../../community/challenges/challengeRoutes.js";
import { stubBlockDirectory, stubModerationQueue } from "../../community/shared/testing/stubs.js";
import { parseChallengeId } from "../../community/shared/ids.js";

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

async function send(path: string, tokens: TokenPair | null, method: string, body?: unknown): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(tokens !== null ? { authorization: `Bearer ${tokens.accessToken}` } : {}),
    },
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
  });
  const deps: CommunityDeps = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks: stubBlockDirectory(),
    moderation: stubModerationQueue(),
    screeningStages: [],
    foodSafetyGate: fixtureFoodSafetyGate(),
  };
  const app = express();
  app.use(express.json());
  app.use(createCommunityRouter(deps, { identity: createIdentityRoutes, challenges: createChallengeRoutes }));
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

describe("challenges part", () => {
  test("create the three kinds; kind-specific constraints enforced", async () => {
    const alice = await signInAs("challenges-alice");

    const threeIngredients = await send("/v1/community/challenges", alice, "POST", {
      kind: "three-ingredients",
      title: "Tahini week",
      ingredients: ["tahini", "lemon", "chickpeas"],
    });
    expect(threeIngredients.status).toBe(201);
    const body = (await json(threeIngredients)) as { challengeId: string; kind: string; constraint: { ingredients: string[] } };
    expect(body.kind).toBe("three-ingredients");
    expect(body.constraint.ingredients).toEqual(["tahini", "lemon", "chickpeas"]);

    const useItUp = await send("/v1/community/challenges", alice, "POST", {
      kind: "use-it-up",
      title: "Empty the tin shelf",
      ingredients: ["tinned tomatoes"],
    });
    expect(useItUp.status).toBe(201);

    const timeLimit = await send("/v1/community/challenges", alice, "POST", {
      kind: "time-limit",
      title: "Twenty minutes flat",
      ingredients: ["eggs"],
      timeLimitMinutes: 20,
    });
    expect(timeLimit.status).toBe(201);
    const timeBody = (await json(timeLimit)) as { constraint: { timeLimitMinutes?: number } };
    expect(timeBody.constraint.timeLimitMinutes).toBe(20);
  });

  test("creation validation: wrong kind, empty ingredients, unbounded time-limit, oversized list, no token", async () => {
    const alice = await signInAs("challenges-validator");
    const badKind = await send("/v1/community/challenges", alice, "POST", {
      kind: "battle-vote",
      title: "Not a kind",
      ingredients: ["tofu"],
    });
    expect(badKind.status).toBe(422);
    const emptyIngredients = await send("/v1/community/challenges", alice, "POST", {
      kind: "use-it-up",
      title: "Nothing to use",
      ingredients: [],
    });
    expect(emptyIngredients.status).toBe(422);
    const wrongCount = await send("/v1/community/challenges", alice, "POST", {
      kind: "three-ingredients",
      title: "Two is not three",
      ingredients: ["a", "b"],
    });
    expect(wrongCount.status).toBe(422);
    const unbounded = await send("/v1/community/challenges", alice, "POST", {
      kind: "time-limit",
      title: "No bound",
      ingredients: ["eggs"],
    });
    expect(unbounded.status).toBe(422);
    const oversized = await send("/v1/community/challenges", alice, "POST", {
      kind: "use-it-up",
      title: "Too many",
      ingredients: ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
    });
    expect(oversized.status).toBe(422);
    const noToken = await send("/v1/community/challenges", null, "POST", {
      kind: "use-it-up",
      title: "Anonymous",
      ingredients: ["rice"],
    });
    expect(noToken.status).toBe(401);
  });

  test("the open read: definition only, no authentication, no people data", async () => {
    const alice = await signInAs("challenges-open");
    const created = await send("/v1/community/challenges", alice, "POST", {
      kind: "use-it-up",
      title: "Link me",
      ingredients: ["orzo"],
    });
    expect(created.status).toBe(201);
    const { challengeId } = (await json(created)) as { challengeId: string };

    // No Authorization header at all: the link must read without the app.
    const open = await fetch(`${baseUrl}/v1/community/challenges/${challengeId}`);
    expect(open.status).toBe(200);
    const body = (await json(open)) as Record<string, unknown>;
    expect(body["title"]).toBe("Link me");
    expect(body["createdByAccountId"]).toBeUndefined();
    expect(body["entries"]).toBeUndefined();

    const unknown = await fetch(`${baseUrl}/v1/community/challenges/${parseChallengeId.newId()}`);
    expect(unknown.status).toBe(404);
  });

  test("entries: private, convergent per account, never another account's", async () => {
    const alice = await signInAs("challenges-alice-2");
    const bob = await signInAs("challenges-bob-2");
    const created = await send("/v1/community/challenges", alice, "POST", {
      kind: "three-ingredients",
      title: "Tahini, lemon, chickpeas",
      ingredients: ["tahini", "lemon", "chickpeas"],
    });
    const { challengeId } = (await json(created)) as { challengeId: string };

    const firstEntry = await send(`/v1/community/challenges/${challengeId}/entries`, alice, "POST", {
      source: { recipeId: "recipes/test-hummus", recipeRevision: "rev-000004" },
      ingredientsUsed: ["tahini", "lemon", "chickpeas"],
    });
    expect(firstEntry.status).toBe(201);
    const firstBody = (await json(firstEntry)) as { source: { recipeId: string } | null; ingredientsUsed: string[] };
    expect(firstBody.source?.recipeId).toBe("recipes/test-hummus");

    // Re-submission converges: one entry, updated in place.
    const secondEntry = await send(`/v1/community/challenges/${challengeId}/entries`, alice, "POST", {
      ingredientsUsed: ["tahini", "lemon"],
    });
    expect(secondEntry.status).toBe(201);
    const secondBody = (await json(secondEntry)) as { source: { recipeId: string } | null };
    expect(secondBody.source).toBeNull();

    const ownList = await send(`/v1/community/challenges/${challengeId}/entries`, alice, "GET");
    expect(ownList.status).toBe(200);
    const ownBody = (await json(ownList)) as { items: unknown[] };
    expect(ownBody.items).toHaveLength(1);

    // Bob's list is his own — never Alice's entries.
    const bobList = await send(`/v1/community/challenges/${challengeId}/entries`, bob, "GET");
    const bobBody = (await json(bobList)) as { items: unknown[] };
    expect(bobBody.items).toHaveLength(0);

    // Entries require a session.
    const anonymous = await send(`/v1/community/challenges/${challengeId}/entries`, null, "POST", { ingredientsUsed: ["tahini"] });
    expect(anonymous.status).toBe(401);

    // Unknown challenge → 404, not a silent create.
    const unknown = await send(`/v1/community/challenges/${parseChallengeId.newId()}/entries`, alice, "POST", { ingredientsUsed: ["tahini"] });
    expect(unknown.status).toBe(404);
  });
});
