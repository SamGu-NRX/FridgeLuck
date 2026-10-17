/**
 * Account persistence: Apple `sub` → community account.
 *
 * The account document is created on first sign-in inside a transaction so
 * two concurrent sign-ins with the same Apple id share one account. The
 * 18+ attestation is a first-write timestamp — an attestation is added when
 * missing and never silently overwritten (a later sign-in without the flag
 * does not erase an earlier attestation; un-attesting is an explicit
 * deletion-flow concern).
 */
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { newAccountId, type AccountId } from "../shared/ids.js";

export interface AccountRecord {
  readonly accountId: AccountId;
  readonly appleSub: string;
  readonly email: string | null;
  readonly displayName: string | null;
  readonly attested18PlusAt: string | null;
  readonly createdAtIso: string;
}

export interface AccountDeps {
  readonly accounts: CommunityStore["accounts"];
  readonly clock: Clock;
}

export async function findOrCreateAccountByAppleSub(
  deps: AccountDeps,
  appleSub: string,
  email: string | null,
  attested18Plus: boolean,
): Promise<{ accountId: AccountId; isNew: boolean }> {
  const existing = await deps.accounts.where("appleSub", "==", appleSub).limit(1).get();
  if (!existing.empty) {
    const doc = existing.docs[0];
    if (doc === undefined) {
      throw new Error("query returned an undefined document");
    }
    if (attested18Plus && typeof doc.get("attested18PlusAt") !== "string") {
      await doc.ref.update({ attested18PlusAt: toIso(deps.clock.now()) });
    }
    return { accountId: doc.id as AccountId, isNew: false };
  }

  const accountId = newAccountId();
  const nowIso = toIso(deps.clock.now());
  const created = await deps.accounts.doc(accountId).create({
    appleSub,
    email,
    displayName: null,
    attested18PlusAt: attested18Plus ? nowIso : null,
    createdAtIso: nowIso,
  });
  if (!created) {
    // Lost a create race — re-read; the winner's document is the account.
    const again = await deps.accounts.where("appleSub", "==", appleSub).limit(1).get();
    const doc = again.docs[0];
    if (doc === undefined) {
      throw new Error("account create race lost with no winner");
    }
    return { accountId: doc.id as AccountId, isNew: false };
  }
  return { accountId, isNew: true };
}

export async function getAccountRecord(deps: AccountDeps, accountId: AccountId): Promise<AccountRecord | null> {
  const snap = await deps.accounts.doc(accountId).get();
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  return {
    accountId: snap.id as AccountId,
    appleSub: typeof data["appleSub"] === "string" ? data["appleSub"] : "",
    email: typeof data["email"] === "string" ? data["email"] : null,
    displayName: typeof data["displayName"] === "string" ? data["displayName"] : null,
    attested18PlusAt: typeof data["attested18PlusAt"] === "string" ? data["attested18PlusAt"] : null,
    createdAtIso: typeof data["createdAtIso"] === "string" ? data["createdAtIso"] : "",
  };
}
