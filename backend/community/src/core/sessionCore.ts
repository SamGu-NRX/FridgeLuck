/**
 * Server-issued sessions: short-lived HMAC-signed access tokens and one-time,
 * revocable refresh tokens stored only as sha-256 hashes.
 *
 * Ported from PR #104 `shared/sessionCore.ts` (branch feat/community-service-f1,
 * credited in the PR body): `fla1.` access tokens (15-minute TTL, no server
 * state needed to verify integrity) and single-use `flr1.` refresh tokens
 * (30-day TTL) with atomic rotation that revokes the whole family on reuse —
 * replaying an old refresh token kills the attacker's session, not just the
 * client's (SPEC §6.1).
 *
 * Adaptation from PR #104: Firestore collections are replaced by the
 * DocumentStore seam, so the same code runs on Firestore (production) and the
 * in-memory store (tests).
 */

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Clock } from "./time.js";
import { toIso } from "./time.js";
import { sessionIdShape } from "./ids.js";
import { errUnauthorized } from "./errors.js";
import type { DocumentStore, StoreCollection } from "./store/documentStore.js";

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
  readonly accountId: string;
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly sessionId: string;
  readonly accessExpiresAt: string;
  readonly refreshExpiresAt: string;
}

interface SessionRecord {
  readonly accountId: string;
  readonly refreshHash: string;
  readonly createdAt: string;
  readonly refreshExpiresAt: string;
  readonly revokedAt: string | null;
  readonly rotatedTo: string | null;
}

type RotationOutcome =
  | { readonly verdict: "family-revoked" }
  | {
      readonly verdict: "rotated";
      readonly accountId: string;
      readonly nextSessionId: string;
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

function readString(data: DocDataLike, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errUnauthorized(`session record field ${field} is missing or malformed`);
  }
  return value;
}

function readOptionalIso(data: DocDataLike, field: string): string | null {
  const value = data[field];
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== "string") {
    throw errUnauthorized(`session record field ${field} is malformed`);
  }
  return value;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DocDataLike = any;

function parseSessionDoc(id: string, data: DocDataLike): SessionRecord {
  return {
    accountId: readString(data, "accountId"),
    refreshHash: readString(data, "refreshHash"),
    createdAt: readString(data, "createdAt"),
    refreshExpiresAt: readString(data, "refreshExpiresAt"),
    revokedAt: readOptionalIso(data, "revokedAt"),
    rotatedTo: readOptionalIso(data, "rotatedTo"),
  };
}

/** Deletion state on the account document: from the moment a deletion starts the account can neither sign in nor refresh. */
export const DELETION_STARTED_AT_FIELD = "deletionStartedAtIso";
export const DELETED_AT_FIELD = "deletedAtIso";

export function accountDeletionBlockedFrom(data: DocDataLike | undefined): boolean {
  if (data === undefined || data === null) {
    return false;
  }
  return typeof data[DELETION_STARTED_AT_FIELD] === "string" || typeof data[DELETED_AT_FIELD] === "string";
}

export class SessionCore {
  private readonly sessions: StoreCollection;
  private readonly accounts: StoreCollection;

  constructor(
    private readonly deps: {
      readonly store: DocumentStore;
      readonly config: SessionServiceConfig;
      readonly clock: Clock;
    },
  ) {
    this.sessions = deps.store.collection("sessions");
    this.accounts = deps.store.collection("accounts");
  }

  async issue(accountId: string): Promise<IssuedTokens> {
    const sessionId = sessionIdShape.newId();
    const nowMs = this.deps.clock.now().getTime();
    const refreshExpiresAt = new Date(nowMs + this.deps.config.refreshTtlDays * 86_400_000);
    const refreshToken = `flr1.${b64url(randomBytes(32))}`;
    const record: SessionRecord = {
      accountId,
      refreshHash: sha256Hex(refreshToken),
      createdAt: toIso(this.deps.clock.now()),
      refreshExpiresAt: refreshExpiresAt.toISOString(),
      revokedAt: null,
      rotatedTo: null,
    };
    // The deletion check rides the same transaction that creates the session:
    // a concurrent blockForDeletion commit serializes against this one.
    await this.deps.store.runTransaction(async (tx): Promise<void> => {
      const accountSnap = await tx.collection("accounts").doc(accountId).get();
      this.assertNotDeletionBlocked(accountSnap.data, "sign-in");
      await tx.collection("sessions").doc(sessionId).create({ ...record });
    });
    return this.mintBoth(accountId, sessionId, refreshToken, nowMs, refreshExpiresAt.getTime());
  }

  async verifyAccess(accessToken: string): Promise<{ accountId: string; sessionId: string }> {
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
    if (claims.exp <= this.deps.clock.now().getTime()) {
      throw errUnauthorized("access token expired");
    }
    const sessionSnap = await this.sessions.doc(claims.sid).get();
    if (sessionSnap.data === null) {
      throw errUnauthorized("session no longer exists");
    }
    const record = parseSessionDoc(sessionSnap.id, sessionSnap.data);
    if (record.revokedAt !== null) {
      throw errUnauthorized("session revoked");
    }
    if (Date.parse(record.refreshExpiresAt) <= this.deps.clock.now().getTime()) {
      throw errUnauthorized("session expired");
    }
    return { accountId: record.accountId, sessionId: sessionIdShape.validate(claims.sid) };
  }

  /**
   * Single-use rotation, atomic under concurrency: hash lookup, state checks,
   * and consume+create run inside one store transaction. A replayed token
   * (unknown, already used, or duplicate hashes) revokes the whole family.
   */
  async rotate(refreshToken: string): Promise<IssuedTokens> {
    const hash = sha256Hex(refreshToken);
    const outcome = await this.deps.store.runTransaction(async (tx): Promise<RotationOutcome> => {
      const matches = await tx.collection("sessions").where("refreshHash", hash).limit(2).get();
      if (matches.length === 0) {
        throw errUnauthorized("unknown refresh token");
      }
      if (matches.length > 1) {
        // Replay or hash-collision signal: revoke the family. The revocations
        // must survive the call, so the transaction commits them and the
        // rejection is thrown afterwards.
        const revokedAt = toIso(this.deps.clock.now());
        for (const doc of matches) {
          await tx.collection("sessions").doc(doc.id).update({ revokedAt });
        }
        return { verdict: "family-revoked" };
      }
      const doc = matches[0];
      if (doc === undefined || doc.data === null) {
        throw errUnauthorized("unknown refresh token");
      }
      const record = parseSessionDoc(doc.id, doc.data);
      const accountSnap = await tx.collection("accounts").doc(record.accountId).get();
      this.assertNotDeletionBlocked(accountSnap.data, "refresh");
      if (record.revokedAt !== null || record.rotatedTo !== null) {
        // Replay of an already-used token revokes the whole family: the
        // replayed session and every session rotated from it. The updates
        // must survive, so the tx returns normally and the rejection is
        // thrown after the commit (same pattern as the hash-collision branch).
        let cursor: { id: string; rotatedTo: string | null; revokedAt: string | null } | undefined = {
          id: doc.id,
          rotatedTo: record.rotatedTo,
          revokedAt: record.revokedAt,
        };
        const replayRevokedAt = toIso(this.deps.clock.now());
        while (cursor !== undefined) {
          if (cursor.revokedAt === null) {
            await tx.collection("sessions").doc(cursor.id).update({ revokedAt: replayRevokedAt });
          }
          if (cursor.rotatedTo === null) {
            break;
          }
          const nextSnap = await tx.collection("sessions").doc(cursor.rotatedTo).get();
          const nextRecord: { rotatedTo: string | null; revokedAt: string | null } | null =
            nextSnap.data === null ? null : parseSessionDoc(nextSnap.id, nextSnap.data);
          cursor =
            nextRecord === null ? undefined : { id: nextSnap.id, rotatedTo: nextRecord.rotatedTo, revokedAt: nextRecord.revokedAt };
        }
        return { verdict: "family-revoked" as const };
      }
      if (Date.parse(record.refreshExpiresAt) <= this.deps.clock.now().getTime()) {
        throw errUnauthorized("refresh token expired");
      }
      const nowMs = this.deps.clock.now().getTime();
      const nowIso = toIso(this.deps.clock.now());
      const nextSessionId = sessionIdShape.newId();
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
      await tx.collection("sessions").doc(doc.id).update({ revokedAt: nowIso, rotatedTo: nextSessionId });
      await tx.collection("sessions").doc(nextSessionId).create({ ...newRecord });
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

  async revoke(sessionId: string): Promise<void> {
    await this.sessions.doc(sessionId).update({ revokedAt: toIso(this.deps.clock.now()) });
  }

  /** Sign-out-everywhere: revokes every live session of the account. */
  async revokeAll(accountId: string): Promise<number> {
    const live = await this.sessions.where("accountId", accountId).where("revokedAt", null).get();
    const atIso = toIso(this.deps.clock.now());
    for (const doc of live) {
      await this.sessions.doc(doc.id).update({ revokedAt: atIso });
    }
    return live.length;
  }

  /**
   * Deletion start, transactionally: marks the account deleting and revokes
   * every live session in one commit. issue() and rotate() read the marker
   * inside their own transactions, so nothing slips in behind a deletion.
   */
  async blockForDeletion(accountId: string, atIso: string): Promise<number> {
    return this.deps.store.runTransaction(async (tx): Promise<number> => {
      const accountRef = tx.collection("accounts").doc(accountId);
      const accountSnap = await accountRef.get();
      if (accountSnap.data === null) {
        throw errUnauthorized("account not found");
      }
      const liveSessions = await tx.collection("sessions").where("accountId", accountId).where("revokedAt", null).get();
      for (const doc of liveSessions) {
        await tx.collection("sessions").doc(doc.id).update({ revokedAt: atIso });
      }
      await accountRef.update({ [DELETION_STARTED_AT_FIELD]: atIso });
      return liveSessions.length;
    });
  }

  private assertNotDeletionBlocked(accountData: DocDataLike | null, what: string): void {
    if (accountDeletionBlockedFrom(accountData ?? undefined)) {
      throw errUnauthorized(`account is deleted or deletion is in progress; ${what} refused`);
    }
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

  private mintBoth(accountId: string, sessionId: string, refreshToken: string, nowMs: number, refreshExpiresAtMs: number): IssuedTokens {
    const accessExpiresAtMs = nowMs + this.deps.config.accessTtlMinutes * 60_000;
    const claims: AccessTokenClaims = { sub: accountId, sid: sessionId, exp: accessExpiresAtMs };
    const payloadB64 = b64url(JSON.stringify(claims));
    const sig = createHmac("sha256", this.deps.config.sessionSecret).update(payloadB64).digest();
    return {
      accountId,
      accessToken: `fla1.${payloadB64}.${b64url(sig)}`,
      refreshToken,
      sessionId,
      accessExpiresAt: new Date(accessExpiresAtMs).toISOString(),
      refreshExpiresAt: new Date(refreshExpiresAtMs).toISOString(),
    };
  }
}
