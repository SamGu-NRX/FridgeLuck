/**
 * Shared scaffolding for the suite-E composition scenarios: a local Apple
 * JWKS server, the full community app composition (every part mounted, real
 * block directory and moderation queue — the same wiring index.ts assembles),
 * and HTTP helpers that capture every response so the scenarios can assert
 * the suite-E bars (no private fields, no authorization failures).
 */
import express from "express";
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import type { CommunityTestHarness } from "./harness.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import type { ModerationQueue } from "../../community/shared/contracts.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { createTableRoutes } from "../../community/tables/tableRoutes.js";
import { createChallengeRoutes } from "../../community/challenges/challengeRoutes.js";
import { createSafetyRoutes } from "../../community/safety/safetyRoutes.js";
import { FirestoreBlockDirectory } from "../../community/safety/blocks.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const SERVICES_ID = "com.fridgeluck.app.test";
const KID = "suite-e-key-1";

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

export interface CapturedResponse {
  readonly method: string;
  readonly path: string;
  readonly status: number;
  readonly body: unknown;
}

export interface ScenarioHttp {
  /** Every response, kept for the suite-E leak scan. */
  readonly captured: CapturedResponse[];
  get(path: string, tokens: TokenPair): Promise<{ status: number; body: unknown }>;
  send(tokens: TokenPair | null, method: string, path: string, body?: unknown): Promise<{ status: number; body: unknown }>;
}

export interface CommunityApp {
  readonly baseUrl: string;
  readonly http: ScenarioHttp;
  /** The keys the app's JWKS serves — sign-in must use these. */
  readonly keys: AppleTestKeys;
  /** The queue instance the app's parts hold — the only one whose
   * decisions run the publication transitions. */
  readonly moderation: ModerationQueue;
  close(): void;
}

interface AppleClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
  sub: string;
  nonce: string;
}

export interface AppleTestKeys {
  privateKey: KeyObject;
  publicJwk: Record<string, unknown>;
}

export function generateAppleKeys(): AppleTestKeys {
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string };
  return { privateKey, publicJwk: { ...jwk, kid: KID, alg: "RS256" } };
}

export interface JwksServer {
  url: string;
  stop(): void;
}

export function startJwksServer(keys: AppleTestKeys): JwksServer {
  const server = Bun.serve({
    port: 0,
    fetch: () => Response.json({ keys: [keys.publicJwk] }),
  });
  return { url: `http://127.0.0.1:${server.port}/auth/keys`, stop: () => server.stop(true) };
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

export function mintAppleToken(keys: AppleTestKeys, sub: string, nonce: string): string {
  const now = Date.now();
  const claims: AppleClaims = {
    iss: APPLE_ISSUER,
    aud: SERVICES_ID,
    exp: Math.floor(now / 1000) + 600,
    iat: Math.floor(now / 1000),
    sub,
    nonce,
  };
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
  const payload = b64url(JSON.stringify(claims));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), keys.privateKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

/**
 * The full composition: identity, explore, tables, challenges and safety
 * over the harness store with the REAL block directory and moderation
 * queue — exactly what production assembles in the parent join. Config
 * floors come through the harness's CommunityConfig.
 */
export async function startCommunityApp(harness: CommunityTestHarness): Promise<CommunityApp> {
  const keys = generateAppleKeys();
  const jwks = startJwksServer(keys);
  const moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const deps: CommunityDeps = {
    store: harness.store,
    clock: harness.clock,
    // Identity must verify against the app's OWN local JWKS, and against the
    // SAME issuer/audience the scenario tokens are minted with (the module
    // constants are the single source for both sides — same approach as the
    // identity part's own test suite, which overrides its config likewise).
    config: { ...harness.config, appleIssuer: APPLE_ISSUER, appleServicesId: SERVICES_ID, appleJwksUrl: jwks.url },
    blocks: new FirestoreBlockDirectory(harness.store),
    moderation,
    screeningStages: [],
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
  const server: Server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    jwks.stop();
    throw new Error("suite-E app did not bind");
  }
  const baseUrl = `http://127.0.0.1:${address.port}`;

  const captured: CapturedResponse[] = [];
  const parseBody = async (res: Response): Promise<unknown> => {
    const text = await res.text();
    return text === "" ? null : JSON.parse(text);
  };
  const http: ScenarioHttp = {
    captured,
    async get(path, tokens) {
      const res = await fetch(`${baseUrl}${path}`, { headers: { authorization: `Bearer ${tokens.accessToken}` } });
      const body = await parseBody(res);
      captured.push({ method: "GET", path, status: res.status, body });
      return { status: res.status, body };
    },
    async send(tokens, method, path, body) {
      const res = await fetch(`${baseUrl}${path}`, {
        method,
        headers: {
          "content-type": "application/json",
          ...(tokens !== null ? { authorization: `Bearer ${tokens.accessToken}` } : {}),
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
      const parsed = await parseBody(res);
      captured.push({ method, path, status: res.status, body: parsed });
      return { status: res.status, body: parsed };
    },
  };

  return {
    baseUrl,
    http,
    keys,
    moderation,
    close() {
      server.close();
      jwks.stop();
    },
  };
}

let nonceCounter = 0;

/** Signs a fresh Apple identity token (unique nonce) and signs the account in. */
export async function signInAs(http: ScenarioHttp, keys: AppleTestKeys, sub: string): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `suite-e-nonce-${String(nonceCounter).padStart(4, "0")}`;
  const identityToken = mintAppleToken(keys, sub, nonce);
  const { status, body } = await http.send(null, "POST", "/v1/community/auth/apple", {
    identityToken,
    nonce,
    attested18Plus: true,
  });
  if (status !== 200) {
    throw new Error(`suite-E sign-in failed for ${sub}: ${status}`);
  }
  return body as TokenPair;
}

/**
 * The suite-E leak scan: no response may carry identity-provider fields,
 * session material, or person identifiers outside the app's own design.
 * Auth endpoints are exempt for refreshToken/accessToken (the client's own
 * credentials, returned to the caller by design).
 */
const DENYLIST_KEYS = new Set(["applesub", "email", "sessionsecret", "sessiontoken", "idtoken", "identitytoken"]);

function walk(value: unknown, path: string, leaks: string[], httpPath: string): void {
  if (Array.isArray(value)) {
    value.forEach((item, i) => walk(item, `${path}[${i}]`, leaks, httpPath));
    return;
  }
  if (typeof value === "object" && value !== null) {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const normalized = k.toLowerCase();
      const exempt = httpPath.includes("/auth/") && (k === "accessToken" || k === "refreshToken");
      if (DENYLIST_KEYS.has(normalized) && !exempt) {
        leaks.push(`${httpPath} ${path}.${k}`);
      }
      walk(v, `${path}.${k}`, leaks, httpPath);
    }
  }
}

export function scanForLeaks(captured: readonly CapturedResponse[]): string[] {
  const leaks: string[] = [];
  for (const response of captured) {
    walk(response.body, "$", leaks, response.path);
  }
  return leaks;
}
