/**
 * Test-only boot for the community end-to-end walk (apps/ios/Tools/community-e2e).
 * Not a deployment target: run.sh starts it, the walk drives it, and it dies
 * with the shell.
 *
 * It starts exactly the production wiring (src/app.ts) on the in-memory store,
 * with three test seams that live here and nowhere in src/:
 *
 *  - an Apple test key set generated locally (RSA-2048) and served from
 *    localhost. The production AppleVerifier fetches this JWKS over HTTP and
 *    verifies real RS256 tokens against it — nothing about verification is
 *    stubbed; only the signer is local (SPEC test rules: no real Apple keys,
 *    no network beyond localhost).
 *  - POST /mint on the same localhost service plays Apple: it signs an
 *    identity token embedding the nonce value the app bound into the sign-in
 *    request (SHA-256 of the raw nonce), exactly what Apple does with the
 *    ASAuthorization request's nonce.
 *  - a movable clock with POST /test/clock/advance, so the account-age vote
 *    gate (24 h, SPEC 4.3) and the challenge windows are reachable without
 *    sleeping, plus a challenge seed endpoint (burst5 has no user-created
 *    challenges — documents are seeded, SPEC 4.2).
 *
 * A test operator account is seeded before boot (env allowlists name a known
 * account id, SPEC 6.6) so an allowlisted operator can sign in through the
 * normal identity route. The real screening path runs: screeningPackagesLoaded
 * is true and the pipeline is the in-module ported ruleset (the PR #126/#127
 * data packages are not on this base branch — noted in the PR body).
 */

import { buildApp } from "../src/app.js";
import { createChallengeDocument } from "../src/modules/challenges/views.js";
import { accountIdShape } from "../src/core/ids.js";
import { generateKeyPairSync, createHash, sign as rsaSign, randomUUID } from "node:crypto";
import type { Clock } from "../src/core/time.js";

/** Movable clock starting at real wall time; the walk advances it via the seam. */
class MovableClock implements Clock {
  private ms: number = Date.now();
  now(): Date {
    return new Date(this.ms);
  }
  advance(hours: number): void {
    this.ms += hours * 60 * 60 * 1000;
  }
}

/** The test Apple: RS256 keys generated in-process, JWKS served from localhost. */
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string };
const kid = createHash("sha256").update(jwk.n).digest("hex").slice(0, 16);

const APPLE_ISSUER = "https://appleid.e2e.fridgeluck.test";
const APPLE_BUNDLE = "dev.fridgeluck.e2e";

const clock = new MovableClock();

/** localhost service playing Apple's key directory + token issuer, plus the clock seam. */
const auxiliary = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: async (request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/keys") {
      return Response.json({ keys: [{ kid, kty: jwk.kty, alg: "RS256", n: jwk.n, e: jwk.e }] });
    }
    if (request.method === "POST" && url.pathname === "/mint") {
      const body = (await request.json()) as { sub?: unknown; nonce?: unknown; email?: unknown };
      if (typeof body.sub !== "string" || body.sub.length === 0 || typeof body.nonce !== "string" || body.nonce.length === 0) {
        return Response.json({ error: { code: "validation", message: "sub and nonce are required" } }, { status: 400 });
      }
      const iat = Math.floor(clock.now().getTime() / 1000);
      const head = Buffer.from(JSON.stringify({ alg: "RS256", kid })).toString("base64url");
      const payload = Buffer.from(
        JSON.stringify({
          iss: APPLE_ISSUER,
          aud: APPLE_BUNDLE,
          sub: body.sub,
          nonce: body.nonce,
          email: typeof body.email === "string" ? body.email : `${body.sub}@privaterelay.appleid.com`,
          iat,
          exp: iat + 3600,
        }),
      ).toString("base64url");
      const sig = rsaSign("RSA-SHA256", Buffer.from(`${head}.${payload}`), privateKey).toString("base64url");
      return Response.json({ identityToken: `${head}.${payload}.${sig}` });
    }
    if (request.method === "POST" && url.pathname === "/test/clock/advance") {
      const body = (await request.json()) as { hours?: unknown };
      if (typeof body.hours !== "number" || !Number.isFinite(body.hours) || body.hours < 0) {
        return Response.json({ error: { code: "validation", message: "hours must be a non-negative number" } }, { status: 400 });
      }
      clock.advance(body.hours);
      return Response.json({ now: clock.now().toISOString() });
    }
    if (request.method === "POST" && url.pathname === "/test/seed/challenge") {
      const body = (await request.json().catch(() => ({}))) as { name?: unknown; entryClosesInMinutes?: unknown };
      const now = clock.now();
      // Default entry window mirrors the burst5 seeded documents (30 h). The
      // e2e walk needs entries to close within bob's 24 h account-age gate,
      // so it passes a short window — voting opens while bob is still gated.
      const entryClosesInMinutes =
        typeof body.entryClosesInMinutes === "number" && body.entryClosesInMinutes > 0
          ? body.entryClosesInMinutes
          : 30 * 60;
      const record = await createChallengeDocument(app.store, {
        type: "battle",
        name: typeof body.name === "string" && body.name.length > 0 ? body.name : "E2E chili week",
        brief: "Seeded by the e2e boot: entries open, voting after entry close.",
        opensAt: now.toISOString(),
        entryClosesAt: new Date(now.getTime() + entryClosesInMinutes * 60 * 1000).toISOString(),
        votingClosesAt: new Date(now.getTime() + 96 * 60 * 60 * 1000).toISOString(),
        resolvedItems: null,
        packId: null,
      });
      return Response.json({ challengeId: record.challengeId });
    }
    return Response.json({ error: { code: "not_found", message: "unknown test route" } }, { status: 404 });
  },
});

/** The test operator: allowlisted account id, identity pre-seeded so sign-in resolves. */
const OPERATOR_ACCOUNT_ID = accountIdShape.newId();
const OPERATOR_APPLE_SUB = "e2e-operator";

const app = await buildApp({
  clock,
  config: {
    store: "memory",
    sessionSecret: randomUUID(),
    operatorAccountIds: [OPERATOR_ACCOUNT_ID],
    appleIssuer: APPLE_ISSUER,
    appleBundleId: APPLE_BUNDLE,
    appleJwksUrl: `http://127.0.0.1:${auxiliary.port}/keys`,
    screeningPackagesLoaded: true,
  },
});

// Seed the operator identity/account before serving (pattern per test harnesses:
// env allowlists name a known id; identity lookup resolves through sign-in).
await app.store.collection("identities").doc(OPERATOR_APPLE_SUB).set({ accountId: OPERATOR_ACCOUNT_ID });
await app.store.collection("accounts").doc(OPERATOR_ACCOUNT_ID).set({
  displayName: "Operator",
  createdAt: clock.now().toISOString(),
});

const server = Bun.serve({
  port: Number(process.env.PORT ?? 0),
  hostname: "127.0.0.1",
  fetch: (request) => app.handle(request),
});

// One JSON line on stdout; run.sh parses it. Everything else must stay quiet.
console.log(
  JSON.stringify({
    port: server.port,
    apple: auxiliary.port,
    operatorSub: OPERATOR_APPLE_SUB,
  }),
);
