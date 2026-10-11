/**
 * The identity part over HTTP: Sign in with Apple against a local JWKS
 * (real RS256 signatures, real fetch), account creation keyed by Apple's
 * stable `sub`, refresh rotation with replay detection, logout revocation,
 * and the 18+ attestation's write-once behavior. Runs against the Firestore
 * emulator; no external Apple endpoint is contacted.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { stubBlockDirectory, stubModerationQueue } from "../../community/shared/testing/stubs.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let baseUrl: string;
let server: Server;

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
  email?: string;
}

function mintAppleToken(claims: AppleClaims, signingKey: KeyObject = privateKey, kid: string = KID): string {
  const header = b64url(JSON.stringify({ alg: "RS256", kid }));
  const payload = b64url(JSON.stringify(claims));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signingKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

function appleClaims(sub: string, nonce: string, nowMs: number, email?: string): AppleClaims {
  return {
    iss: APPLE_ISSUER,
    aud: SERVICES_ID,
    exp: Math.floor(nowMs / 1000) + 600,
    iat: Math.floor(nowMs / 1000),
    sub,
    nonce,
    ...(email !== undefined ? { email } : {}),
  };
}

async function signIn(identityToken: string, nonce: string, attested18Plus = true): Promise<Response> {
  return fetch(`${baseUrl}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken, nonce, attested18Plus }),
  });
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

async function tokenPair(res: Response): Promise<TokenPair> {
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
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
  };
  const app = express();
  app.use(express.json());
  app.use(createCommunityRouter(deps, { identity: createIdentityRoutes }));
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

describe("identity part", () => {
  test("a valid Apple identity token creates an account and a working session", async () => {
    const now = Date.now();
    const res = await signIn(mintAppleToken(appleClaims("apple-sub-001", "nonce-001", now)), "nonce-001");
    const tokens = await tokenPair(res);
    expect(tokens.isNewAccount).toBe(true);
    expect(tokens.accountId.startsWith("acct_")).toBe(true);

    const whoami = await fetch(`${baseUrl}/v1/community/whoami`, {
      headers: { authorization: `Bearer ${tokens.accessToken}` },
    });
    expect(whoami.status).toBe(200);
    expect(((await whoami.json()) as { accountId: string }).accountId).toBe(tokens.accountId);

    const me = await fetch(`${baseUrl}/v1/community/me`, {
      headers: { authorization: `Bearer ${tokens.accessToken}` },
    });
    expect(me.status).toBe(200);
    const meBody = (await me.json()) as { attested18PlusAt: string | null; displayName: string | null };
    expect(meBody.attested18PlusAt).not.toBeNull();
    expect(meBody.displayName).toBeNull();
  });

  test("the same Apple sub reuses the account; the attestation is never erased", async () => {
    const now = Date.now();
    const first = await tokenPair(await signIn(mintAppleToken(appleClaims("apple-sub-002", "nonce-002", now)), "nonce-002", true));
    const second = await tokenPair(await signIn(mintAppleToken(appleClaims("apple-sub-002", "nonce-003", now)), "nonce-003", false));
    expect(second.isNewAccount).toBe(false);
    expect(second.accountId).toBe(first.accountId);

    const me = await fetch(`${baseUrl}/v1/community/me`, {
      headers: { authorization: `Bearer ${second.accessToken}` },
    });
    const meBody = (await me.json()) as { attested18PlusAt: string | null };
    expect(meBody.attested18PlusAt).not.toBeNull();
  });

  test("a nonce mismatch is 401 — tokens cannot be replayed across sign-ins", async () => {
    const now = Date.now();
    const res = await signIn(mintAppleToken(appleClaims("apple-sub-003", "nonce-009", now)), "nonce-other");
    expect(res.status).toBe(401);
    expect(((await res.json()) as { code: string }).code).toBe("unauthorized");
  });

  test("a wrong audience is 401 — tokens minted for another service are refused", async () => {
    const now = Date.now();
    const claims = { ...appleClaims("apple-sub-004", "nonce-004", now), aud: "com.other.app" };
    const res = await signIn(mintAppleToken(claims), "nonce-004");
    expect(res.status).toBe(401);
  });

  test("an expired identity token is 401", async () => {
    const claims = { ...appleClaims("apple-sub-005", "nonce-005", Date.now()), exp: Math.floor(Date.now() / 1000) - 10 };
    const res = await signIn(mintAppleToken(claims), "nonce-005");
    expect(res.status).toBe(401);
  });

  test("a signature from a key Apple does not publish is 401", async () => {
    const { privateKey: strangerKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const res = await signIn(mintAppleToken(appleClaims("apple-sub-006", "nonce-006", Date.now()), strangerKey), "nonce-006");
    expect(res.status).toBe(401);
  });

  test("refresh rotates: the old refresh token is dead the moment it is used", async () => {
    const now = Date.now();
    const tokens = await tokenPair(await signIn(mintAppleToken(appleClaims("apple-sub-007", "nonce-007", now)), "nonce-007"));

    const refreshed = await fetch(`${baseUrl}/v1/community/auth/refresh`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: tokens.refreshToken }),
    });
    expect(refreshed.status).toBe(200);
    const rotated = (await refreshed.json()) as { accessToken: string; refreshToken: string };

    const replay = await fetch(`${baseUrl}/v1/community/auth/refresh`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: tokens.refreshToken }),
    });
    expect(replay.status).toBe(401);

    const whoami = await fetch(`${baseUrl}/v1/community/whoami`, {
      headers: { authorization: `Bearer ${rotated.accessToken}` },
    });
    expect(whoami.status).toBe(200);
  });

  test("logout revokes the session: whoami is 401 afterwards", async () => {
    const now = Date.now();
    const tokens = await tokenPair(await signIn(mintAppleToken(appleClaims("apple-sub-008", "nonce-008", now)), "nonce-008"));

    const logout = await fetch(`${baseUrl}/v1/community/auth/logout`, {
      method: "POST",
      headers: { authorization: `Bearer ${tokens.accessToken}` },
    });
    expect(logout.status).toBe(204);

    const whoami = await fetch(`${baseUrl}/v1/community/whoami`, {
      headers: { authorization: `Bearer ${tokens.accessToken}` },
    });
    expect(whoami.status).toBe(401);
  });

  test("a truncated sign-in body fails validation, not 500", async () => {
    const res = await fetch(`${baseUrl}/v1/community/auth/apple`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ nonce: "short" }),
    });
    expect(res.status).toBe(422);
    expect(((await res.json()) as { code: string }).code).toBe("validation");
  });
});
