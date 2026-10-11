/**
 * SessionService against the Firestore emulator: mint → verify → rotate →
 * replay detection → revocation. Expiry and tamper paths use a controlled
 * clock or a mutated token, never a sleep.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { systemClock, toIso } from "../../community/shared/time.js";
import { newAccountId, newSessionId } from "../../community/shared/ids.js";
import type { IssuedTokens } from "../../community/shared/sessionCore.js";

let harness: CommunityTestHarness;

type RotationResult = { won: true; tokens: IssuedTokens } | { won: false; error: unknown };

beforeAll(async () => {
  harness = await makeHarness();
});

afterAll(async () => {
  await harness.close();
});

function shiftedClock(deltaMs: number) {
  const base = systemClock;
  return { now: (): Date => new Date(base.now().getTime() + deltaMs) };
}

describe("SessionService", () => {
  test("issues and verifies an access token bound to the session record", async () => {
    const account = newAccountId();
    const issued = await harness.sessions.issue(account, harness.clock);
    expect(issued.accessToken.startsWith("fla1.")).toBe(true);
    expect(issued.refreshToken.startsWith("flr1.")).toBe(true);

    const verified = await harness.sessions.verifyAccess(issued.accessToken, harness.clock);
    expect(verified.accountId).toBe(account);
    expect(verified.sessionId).toBe(issued.sessionId);
  });

  test("rejects a tampered access token", async () => {
    const issued = await harness.sessions.issue(newAccountId(), harness.clock);
    const parts = issued.accessToken.split(".");
    const claims = JSON.parse(Buffer.from(parts[1] ?? "", "base64url").toString("utf8")) as { sub: string };
    claims.sub = newAccountId();
    const forged = `fla1.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.${parts[2]}`;
    await expect(harness.sessions.verifyAccess(forged, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("rejects an expired access token without touching the store", async () => {
    const issued = await harness.sessions.issue(newAccountId(), harness.clock);
    const late = shiftedClock((harness.config.accessTtlMinutes + 1) * 60_000);
    await expect(harness.sessions.verifyAccess(issued.accessToken, late)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("rotates: the old refresh token dies, the new one works", async () => {
    const account = newAccountId();
    const first = await harness.sessions.issue(account, harness.clock);
    const second = await harness.sessions.rotate(first.refreshToken, harness.clock);
    expect(second.sessionId).not.toBe(first.sessionId);

    await expect(harness.sessions.rotate(first.refreshToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    const stillValid = await harness.sessions.verifyAccess(second.accessToken, harness.clock);
    expect(stillValid.accountId).toBe(account);
    // The old session was marked rotated: its access token must also die.
    await expect(harness.sessions.verifyAccess(first.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("concurrent rotations of one token: exactly one successor, every loser rejected", async () => {
    const account = newAccountId();
    const issued = await harness.sessions.issue(account, harness.clock);

    // Five refreshes race on the same refresh token. The consumption is a
    // Firestore transaction, so exactly one may commit a successor; the
    // losers must surface the reuse rejection, never a second live session.
    const settled = await Promise.all(
      Array.from({ length: 5 }, (): Promise<RotationResult> =>
        harness.sessions.rotate(issued.refreshToken, harness.clock).then(
          (tokens) => ({ won: true, tokens }),
          (error: unknown) => ({ won: false, error }),
        ),
      ),
    );

    const winners = settled.filter((r): r is { won: true; tokens: IssuedTokens } => r.won);
    const losers = settled.filter((r): r is { won: false; error: unknown } => !r.won);
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(4);
    for (const loser of losers) {
      expect(loser.error).toMatchObject({ code: "unauthorized" });
    }

    // Exactly one successor session exists: the account holds the original
    // plus the winner's record, and the winner's id is that successor.
    const family = await harness.store.sessions.where("accountId", "==", account).get();
    expect(family.size).toBe(2);
    const winner = winners[0]?.tokens;
    if (winner === undefined) {
      throw new Error("expected exactly one winning rotation");
    }
    expect(family.docs.map((d) => d.id)).toContain(winner.sessionId);

    // The winner is fully live; the spent token stays rejected for good.
    await expect(harness.sessions.verifyAccess(winner.accessToken, harness.clock)).resolves.toMatchObject({ accountId: account });
    await expect(harness.sessions.rotate(issued.refreshToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("a duplicated refresh hash is flagged and revokes the whole family", async () => {
    const account = newAccountId();
    const issued = await harness.sessions.issue(account, harness.clock);
    // Forge a twin session sharing the first token's hash: the duplicate-hash
    // signal the service treats as "revoke everything carrying this hash".
    const original = await harness.store.sessions.doc(issued.sessionId).get();
    const data = original.data() as Record<string, unknown>;
    await harness.store.sessions.doc(newSessionId()).set({ ...data });

    await expect(harness.sessions.rotate(issued.refreshToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });

    // The revocations committed even though rotate() rejected: both docs die.
    const family = await harness.store.sessions.where("refreshHash", "==", data["refreshHash"]).get();
    expect(family.size).toBe(2);
    for (const doc of family.docs) {
      const record = doc.data() as Record<string, unknown>;
      expect(record["revokedAt"]).not.toBeNull();
    }
  });

  test("revokes every session for an account", async () => {
    const account = newAccountId();
    const a = await harness.sessions.issue(account, harness.clock);
    const b = await harness.sessions.issue(account, harness.clock);
    await harness.sessions.revokeAllForAccount(account, harness.clock);
    await expect(harness.sessions.verifyAccess(a.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    await expect(harness.sessions.verifyAccess(b.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("a deleting account can neither sign in nor refresh from the moment deletion starts", async () => {
    const account = newAccountId();
    // The deletion flow guarantees an account document: blockForDeletion
    // writes the marker to it (and fails when it is missing).
    await harness.store.accounts.doc(account).set({ appleSub: "deletion-block-sub", createdAtIso: toIso(harness.clock.now()) });
    const issued = await harness.sessions.issue(account, harness.clock);

    // Deletion starts: the marker and the revocations land in one commit.
    const revoked = await harness.sessions.blockForDeletion(account, toIso(harness.clock.now()));
    expect(revoked).toBe(1);

    await expect(harness.sessions.issue(account, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    await expect(harness.sessions.rotate(issued.refreshToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    // The session that existed before deletion started died with it.
    await expect(harness.sessions.verifyAccess(issued.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("a tombstoned account (deletion finished) refuses issuance and rotation", async () => {
    const account = newAccountId();
    await harness.store.accounts.doc(account).set({ appleSub: "tombstone-sub", createdAtIso: toIso(harness.clock.now()) });
    const issued = await harness.sessions.issue(account, harness.clock);
    await harness.store.accounts.doc(account).update({ appleSub: null, deletedAtIso: toIso(harness.clock.now()) });

    await expect(harness.sessions.issue(account, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    await expect(harness.sessions.rotate(issued.refreshToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("blockForDeletion is convergent: a resumption revokes nothing and stamps the same time", async () => {
    const account = newAccountId();
    await harness.store.accounts.doc(account).set({ appleSub: "block-idem-sub", createdAtIso: toIso(harness.clock.now()) });
    await harness.sessions.issue(account, harness.clock);
    await harness.sessions.issue(account, harness.clock);
    const atIso = toIso(harness.clock.now());

    const first = await harness.sessions.blockForDeletion(account, atIso);
    expect(first).toBe(2);
    const resumption = await harness.sessions.blockForDeletion(account, atIso);
    expect(resumption).toBe(0);

    const family = await harness.store.sessions.where("accountId", "==", account).get();
    expect(family.size).toBe(2);
    for (const doc of family.docs) {
      expect((doc.data() as Record<string, unknown>)["revokedAt"]).toBe(atIso);
    }
  });

  test("session records live in Firestore and round-trip through the emulator", async () => {
    const account = newAccountId();
    const issued = await harness.sessions.issue(account, harness.clock);
    const snap = await harness.store.sessions.doc(issued.sessionId).get();
    expect(snap.exists).toBe(true);
    const data = snap.data() as Record<string, unknown>;
    expect(data["accountId"]).toBe(account);
    expect(typeof data["refreshHash"]).toBe("string");
    expect((data["refreshHash"] as string)).not.toBe(issued.refreshToken);
    expect(data["revokedAt"]).toBeNull();
  });
});
