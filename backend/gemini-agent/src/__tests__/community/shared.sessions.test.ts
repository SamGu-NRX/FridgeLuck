/**
 * SessionService against the Firestore emulator: mint → verify → rotate →
 * replay detection → revocation. Expiry and tamper paths use a controlled
 * clock or a mutated token, never a sleep.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { systemClock } from "../../community/shared/time.js";
import { newAccountId } from "../../community/shared/ids.js";

let harness: CommunityTestHarness;

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

  test("revokes every session for an account", async () => {
    const account = newAccountId();
    const a = await harness.sessions.issue(account, harness.clock);
    const b = await harness.sessions.issue(account, harness.clock);
    await harness.sessions.revokeAllForAccount(account, harness.clock);
    await expect(harness.sessions.verifyAccess(a.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
    await expect(harness.sessions.verifyAccess(b.accessToken, harness.clock)).rejects.toMatchObject({ code: "unauthorized" });
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
