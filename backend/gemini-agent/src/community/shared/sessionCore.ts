/**
 * Server-issued sessions: short-lived HMAC-signed access tokens and one-time,
 * revocable refresh tokens stored hashed in Firestore.
 *
 * No custom crypto primitive: HMAC-SHA256 and SHA-256 from node:crypto only.
 * Apple identity-token verification (issuer, audience, signature against
 * Apple's published keys, nonce) lives in the identity part and mints tokens
 * through this service.
 */
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { CollectionReference, DocumentSnapshot, Firestore, Transaction } from "@google-cloud/firestore";
import type { Clock } from "./time.js";
import { toIso } from "./time.js";
import type { AccountId, SessionId } from "./ids.js";
import { newSessionId, parseAccountId, parseSessionId } from "./ids.js";
import { errUnauthorized } from "./errors.js";

export interface SessionServiceConfig {
  /** HMAC key for access tokens. Required; provided by config at the boundary. */
  readonly sessionSecret: string;
  readonly accessTtlMinutes: number;
  readonly refreshTtlDays: number;
}

interface AccessTokenClaims {
  readonly sub: string;
  readonly sid: string;
  readonly exp: number;
}

export interface IssuedTokens {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly sessionId: SessionId;
  readonly accessExpiresAt: string;
  readonly refreshExpiresAt: string;
}

interface SessionRecord {
  readonly accountId: AccountId;
  readonly refreshHash: string;
  readonly createdAt: string;
  readonly refreshExpiresAt: string;
  readonly revokedAt: string | null;
  readonly rotatedTo: string | null;
}

/**
 * What one rotation attempt decided inside its transaction. The
 * family-revoked verdict returns instead of throwing so its revocations
 * commit; the caller rejects after the transaction has landed.
 */
type RotationOutcome =
  | { readonly verdict: "family-revoked" }
  | {
      readonly verdict: "rotated";
      readonly accountId: AccountId;
      readonly nextSessionId: SessionId;
      readonly newRefreshToken: string;
      readonly nowMs: number;
      readonly refreshExpiresAtMs: number;
    };

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

function sha256Hex(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) {
    return false;
  }
  return timingSafeEqual(ab, bb);
}

function readString(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errUnauthorized(`session record field ${field} is missing or malformed`);
  }
  return value;
}

function readOptionalIso(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  if (value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw errUnauthorized(`session record field ${field} is malformed`);
  }
  return value;
}

function parseSessionDoc(doc: DocumentSnapshot): SessionRecord {
  const data = doc.data() as Record<string, unknown>;
  return {
    accountId: parseAccountId.parse(readString(data, "accountId"), "session record"),
    refreshHash: readString(data, "refreshHash"),
    createdAt: readString(data, "createdAt"),
    refreshExpiresAt: readString(data, "refreshExpiresAt"),
    revokedAt: readOptionalIso(data, "revokedAt"),
    rotatedTo: readOptionalIso(data, "rotatedTo"),
  };
}

export class SessionService {
  constructor(
    private readonly deps: {
      readonly sessions: CollectionReference;
      readonly firestore: Firestore;
      readonly config: SessionServiceConfig;
    },
  ) {}

  async issue(accountId: AccountId, clock: Clock): Promise<IssuedTokens> {
    const sessionId = newSessionId();
    const nowMs = clock.now().getTime();
    const refreshExpiresAt = new Date(nowMs + this.deps.config.refreshTtlDays * 86_400_000);
    const refreshToken = `flr1.${b64url(randomBytes(32))}`;
    const record: SessionRecord = {
      accountId,
      refreshHash: sha256Hex(refreshToken),
      createdAt: toIso(clock.now()),
      refreshExpiresAt: refreshExpiresAt.toISOString(),
      revokedAt: null,
      rotatedTo: null,
    };
    await this.deps.sessions.doc(sessionId).set(record);
    return this.mintBoth(accountId, sessionId, refreshToken, nowMs, refreshExpiresAt.getTime());
  }

  async verifyAccess(accessToken: string, clock: Clock): Promise<{ accountId: AccountId; sessionId: SessionId }> {
    const parts = accessToken.split(".");
    if (parts.length !== 3 || parts[0] !== "fla1") {
      throw errUnauthorized("malformed access token");
    }
    const payloadB64 = parts[1] ?? "";
    const sigB64 = parts[2] ?? "";
    const expectedSig = b64url(createHmac("sha256", this.deps.config.sessionSecret).update(payloadB64).digest());
    if (!safeEqual(sigB64, expectedSig)) {
      throw errUnauthorized("access token signature mismatch");
    }
    let claims: AccessTokenClaims;
    try {
      const parsed: unknown = JSON.parse(Buffer.from(payloadB64, "base64url").toString("utf8"));
      claims = this.parseClaims(parsed);
    } catch {
      throw errUnauthorized("access token claims are unreadable");
    }
    if (claims.exp <= clock.now().getTime()) {
      throw errUnauthorized("access token expired");
    }
    const sessionSnap = await this.deps.sessions.doc(claims.sid).get();
    if (!sessionSnap.exists) {
      throw errUnauthorized("session no longer exists");
    }
    const record = parseSessionDoc(sessionSnap);
    if (record.revokedAt !== null) {
      throw errUnauthorized("session revoked");
    }
    if (Date.parse(record.refreshExpiresAt) <= clock.now().getTime()) {
      throw errUnauthorized("session expired");
    }
    return { accountId: record.accountId, sessionId: parseSessionId.parse(claims.sid, "access token sid") };
  }

  /**
   * Single-use rotation, atomic under concurrency: the hash lookup, every
   * state check, and the consume+create writes run inside one Firestore
   * transaction. Racers on the same token read the same snapshot; only the
   * first commit lands. A loser's commit aborts (the original session doc
   * changed under it), the SDK retries the transaction, the re-read then
   * sees rotatedTo set, and the loser surfaces the reuse rejection instead
   * of minting a second successor.
   */
  async rotate(refreshToken: string, clock: Clock): Promise<IssuedTokens> {
    const hash = sha256Hex(refreshToken);
    const outcome = await this.deps.firestore.runTransaction(async (tx: Transaction): Promise<RotationOutcome> => {
      const matches = await tx.get(this.deps.sessions.where("refreshHash", "==", hash).limit(2));
      if (matches.empty) {
        throw errUnauthorized("unknown refresh token");
      }
      if (matches.size > 1) {
        // Replay or hash collision signal: revoke the whole family. The
        // revocations must survive the call, so the transaction commits
        // them and the rejection is thrown afterwards — a throw inside
        // would roll the writes back.
        const revokedAt = toIso(clock.now());
        for (const doc of matches.docs) {
          tx.update(doc.ref, { revokedAt });
        }
        return { verdict: "family-revoked" };
      }
      const doc = matches.docs[0];
      const record = parseSessionDoc(doc);
      if (record.revokedAt !== null || record.rotatedTo !== null) {
        throw errUnauthorized("refresh token already used or revoked");
      }
      if (Date.parse(record.refreshExpiresAt) <= clock.now().getTime()) {
        throw errUnauthorized("refresh token expired");
      }
      const nowMs = clock.now().getTime();
      const nowIso = toIso(clock.now());
      const nextSessionId = newSessionId();
      const refreshExpiresAt = new Date(nowMs + this.deps.config.refreshTtlDays * 86_400_000);
      const newRefreshToken = `flr1.${b64url(randomBytes(32))}`;
      const newRecord: SessionRecord = {
        accountId: record.accountId,
        refreshHash: sha256Hex(newRefreshToken),
        createdAt: nowIso,
        refreshExpiresAt: refreshExpiresAt.toISOString(),
        revokedAt: null,
        rotatedTo: null,
      };
      tx.update(doc.ref, { revokedAt: nowIso, rotatedTo: nextSessionId });
      tx.create(this.deps.sessions.doc(nextSessionId), newRecord);
      return {
        verdict: "rotated",
        accountId: record.accountId,
        nextSessionId,
        newRefreshToken,
        nowMs,
        refreshExpiresAtMs: refreshExpiresAt.getTime(),
      };
    });
    if (outcome.verdict === "family-revoked") {
      throw errUnauthorized("refresh token replay detected; sessions revoked");
    }
    return this.mintBoth(outcome.accountId, outcome.nextSessionId, outcome.newRefreshToken, outcome.nowMs, outcome.refreshExpiresAtMs);
  }

  async revoke(sessionId: SessionId, clock: Clock): Promise<void> {
    await this.deps.sessions.doc(sessionId).update({ revokedAt: toIso(clock.now()) });
  }

  async revokeAllForAccount(accountId: AccountId, clock: Clock): Promise<void> {
    const batch = this.deps.firestore.batch();
    const snaps = await this.deps.sessions.where("accountId", "==", accountId).where("revokedAt", "==", null).get();
    for (const doc of snaps.docs) {
      batch.update(doc.ref, { revokedAt: toIso(clock.now()) });
    }
    await batch.commit();
  }

  private parseClaims(parsed: unknown): AccessTokenClaims {
    if (typeof parsed !== "object" || parsed === null) {
      throw errUnauthorized("access token claims are unreadable");
    }
    const record = parsed as Record<string, unknown>;
    const exp = record["exp"];
    const sub = record["sub"];
    const sid = record["sid"];
    if (typeof exp !== "number" || typeof sub !== "string" || typeof sid !== "string") {
      throw errUnauthorized("access token claims are incomplete");
    }
    return { exp, sub, sid };
  }

  private mintBoth(accountId: AccountId, sessionId: SessionId, refreshToken: string, nowMs: number, refreshExpiresAtMs: number): IssuedTokens {
    const accessExpiresAtMs = nowMs + this.deps.config.accessTtlMinutes * 60_000;
    const claims: AccessTokenClaims = { sub: accountId, sid: sessionId, exp: accessExpiresAtMs };
    const payloadB64 = b64url(JSON.stringify(claims));
    const sig = createHmac("sha256", this.deps.config.sessionSecret).update(payloadB64).digest();
    return {
      accessToken: `fla1.${payloadB64}.${b64url(sig)}`,
      refreshToken,
      sessionId,
      accessExpiresAt: new Date(accessExpiresAtMs).toISOString(),
      refreshExpiresAt: new Date(refreshExpiresAtMs).toISOString(),
    };
  }
}
