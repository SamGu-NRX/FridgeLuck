/**
 * Server-side deletion of a community account (SPEC §3.4).
 *
 * Order is the contract:
 * 1. every session is revoked first — the account stops acting immediately
 *    (whoami and every authenticated route 401 on the old token);
 * 2. each part removes or tombstones the account's records through its own
 *    contributor (the seam in shared/contracts.ts) — the safety part's
 *    contributor removes the block pairs, explore withdraws publications and
 *    strips cook-occurrence keys, tables removes memberships and dissolves
 *    owned tables, challenges tombstones entries. Content records are
 *    tombstoned, not erased, where the spec keeps records that moderation
 *    and abuse history depend on; directory entries (memberships, block
 *    pairs) go outright;
 * 3. the account document itself is tombstoned: deletedAtIso set, the Apple
 *    sub and email erased (PII goes with deletion; the record id and
 *    timestamps survive so moderation history and ids stay coherent);
 *    re-signing in creates a fresh account, never resurrects this one;
 * 4. a deletionRuns record captures what was touched, for the audit trail.
 */
import type { AccountDeletionContribution, AccountDeletionContributor } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errNotFound } from "../shared/errors.js";
import { newDeletionRunId, parseAccountId, type AccountId, type DeletionRunId } from "../shared/ids.js";
import type { SessionService } from "../shared/sessionCore.js";

export interface DeletionRunRecord {
  readonly deletionRunId: DeletionRunId;
  readonly accountId: AccountId;
  readonly startedAtIso: string;
  readonly finishedAtIso: string;
  readonly sessionsRevoked: boolean;
  readonly contributions: readonly AccountDeletionContribution[];
}

export interface DeletionDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
  readonly sessions: SessionService;
  readonly contributors: readonly AccountDeletionContributor[];
}

export interface AccountDeletionService {
  run(accountId: AccountId): Promise<DeletionRunRecord>;
}

/** The safety part's own share of the deletion: block pairs are removed. */
export function blockDirectoryCleanupContributor(store: CommunityStore): AccountDeletionContributor {
  return {
    part: "safety/blocks",
    async run(accountId: AccountId): Promise<AccountDeletionContribution> {
      const [asA, asB] = await Promise.all([
        store.blocks.where("a", "==", accountId).get(),
        store.blocks.where("b", "==", accountId).get(),
      ]);
      const docs = [...asA.docs, ...asB.docs];
      for (const doc of docs) {
        await doc.ref.delete();
      }
      return { part: "safety/blocks", recordsTouched: docs.length, detail: "block pairs removed" };
    },
  };
}

export async function runAccountDeletion(deps: DeletionDeps, accountId: AccountId): Promise<DeletionRunRecord> {
  const startedAtIso = toIso(deps.clock.now());
  const parsedId = parseAccountId.parse(accountId, "account id");

  // Lock the account out first: once the sessions are gone, nothing below
  // can be exercised by the deleted account.
  await deps.sessions.revokeAllForAccount(parsedId, deps.clock);

  const contributions: AccountDeletionContribution[] = [];
  for (const contributor of deps.contributors) {
    contributions.push(await contributor.run(parsedId, startedAtIso));
  }

  const accountDoc = deps.store.accounts.doc(parsedId);
  const accountSnap = await accountDoc.get();
  if (!accountSnap.exists) {
    throw errNotFound("account not found");
  }
  await accountDoc.update({ deletedAtIso: startedAtIso, appleSub: null, email: null, displayName: null });

  const finishedAtIso = toIso(deps.clock.now());
  const record: DeletionRunRecord = {
    deletionRunId: newDeletionRunId(),
    accountId: parsedId,
    startedAtIso,
    finishedAtIso,
    sessionsRevoked: true,
    contributions,
  };
  await deps.store.deletionRuns.doc(record.deletionRunId).create(record);
  return record;
}

export function createAccountDeletionService(deps: DeletionDeps): AccountDeletionService {
  return { run: (accountId) => runAccountDeletion(deps, accountId) };
}
