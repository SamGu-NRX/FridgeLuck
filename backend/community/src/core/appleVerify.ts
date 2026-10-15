/**
 * Apple identity-token verification (Sign in with Apple).
 *
 * Ported from PR #104 `identity/appleVerify.ts` (branch feat/community-service-f1,
 * credited in the PR body). Checks, in order: token shape → RS256 signature
 * against the configured JWKS → issuer, audience, expiry → the client's nonce
 * (replay binding). The `sub` claim is Apple's stable per-developer user id
 * and is the only identity this module trusts; email is optional profile
 * data, never copied into sharing surfaces.
 *
 * Adaptations: the JWKS fetch is injectable, so tests sign tokens against a
 * locally generated test key set (no real Apple calls, SPEC test rules); the
 * audience is FridgeLuck's bundle identifier — the contract's auth examples
 * target app sign-ins, not the Services ID.
 */

import { createPublicKey, verify as cryptoVerify } from "node:crypto";
import { errUnauthorized } from "./errors.js";

export interface AppleIdentityTokenClaims {
  readonly appleSub: string;
  readonly nonce: string;
  readonly email: string | null;
}

interface AppleJwk {
  readonly kid: string;
  readonly kty: string;
  readonly alg: string;
  readonly n: string;
  readonly e: string;
}

export interface AppleJwks {
  readonly keys: AppleJwk[];
}

interface RawTokenHeader {
  readonly kid?: unknown;
  readonly alg?: unknown;
}

interface RawTokenClaims {
  readonly iss?: unknown;
  readonly aud?: unknown;
  readonly exp?: unknown;
  readonly sub?: unknown;
  readonly nonce?: unknown;
  readonly email?: unknown;
}

async function defaultFetchJwks(url: string): Promise<AppleJwks> {
  const res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) {
    throw errUnauthorized("apple key directory is unavailable");
  }
  return (await res.json()) as AppleJwks;
}

export interface AppleVerifierConfig {
  readonly appleIssuer: string;
  readonly appleBundleId: string;
  readonly appleJwksUrl: string;
}

export interface AppleVerifierDeps {
  readonly config: AppleVerifierConfig;
  readonly fetchJwks?: (url: string) => Promise<AppleJwks>;
}

function decodeSegment(segment: string): unknown {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8")) as unknown;
}

export class AppleVerifier {
  constructor(private readonly deps: AppleVerifierDeps) {}

  async verify(identityToken: string, expectedNonce: string, nowMs: number): Promise<AppleIdentityTokenClaims> {
    const parts = identityToken.split(".");
    if (parts.length !== 3) {
      throw errUnauthorized("malformed identity token");
    }
    const [headerB64, payloadB64, sigB64] = parts as [string, string, string];

    const header = this.readHeader(headerB64);
    if (header.alg !== "RS256") {
      throw errUnauthorized("identity token must be RS256");
    }

    const jwk = await this.findJwk(header.kid);
    const key = createPublicKey({ key: jwk as unknown as import("node:crypto").JsonWebKey, format: "jwk" });
    const ok = cryptoVerify("RSA-SHA256", Buffer.from(`${headerB64}.${payloadB64}`), key, Buffer.from(sigB64, "base64url"));
    if (!ok) {
      throw errUnauthorized("identity token signature mismatch");
    }

    const claims = this.readClaims(payloadB64);
    if (claims.iss !== this.deps.config.appleIssuer) {
      throw errUnauthorized("identity token issuer mismatch");
    }
    if (claims.aud !== this.deps.config.appleBundleId) {
      throw errUnauthorized("identity token audience mismatch");
    }
    if (typeof claims.exp !== "number" || claims.exp * 1000 <= nowMs) {
      throw errUnauthorized("identity token expired");
    }
    if (typeof claims.sub !== "string" || claims.sub.length === 0) {
      throw errUnauthorized("identity token has no subject");
    }
    if (claims.nonce !== expectedNonce) {
      throw errUnauthorized("identity token nonce mismatch");
    }
    return {
      appleSub: claims.sub,
      nonce: expectedNonce,
      email: typeof claims.email === "string" && claims.email.length > 0 ? claims.email : null,
    };
  }

  private readHeader(headerB64: string): { alg: string; kid: string } {
    let raw: RawTokenHeader;
    try {
      raw = decodeSegment(headerB64) as RawTokenHeader;
    } catch {
      throw errUnauthorized("identity token header is unreadable");
    }
    if (typeof raw.kid !== "string" || typeof raw.alg !== "string") {
      throw errUnauthorized("identity token header is incomplete");
    }
    return { alg: raw.alg, kid: raw.kid };
  }

  private readClaims(payloadB64: string): RawTokenClaims {
    try {
      const parsed = decodeSegment(payloadB64) as RawTokenClaims;
      if (typeof parsed !== "object" || parsed === null) {
        throw new Error("not an object");
      }
      return parsed;
    } catch {
      throw errUnauthorized("identity token claims are unreadable");
    }
  }

  private async findJwk(kid: string): Promise<AppleJwk> {
    const jwks = await (this.deps.fetchJwks ?? defaultFetchJwks)(this.deps.config.appleJwksUrl);
    const match = jwks.keys.find((k) => k.kid === kid && k.kty === "RSA" && k.alg === "RS256");
    if (match === undefined) {
      throw errUnauthorized("identity token key is not published by Apple");
    }
    return match;
  }
}
