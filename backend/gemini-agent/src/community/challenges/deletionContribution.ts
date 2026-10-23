/**
 * The challenges part's deletion contribution (SPEC §3.4): the account's
 * challenge entries are tombstoned, not erased — the records survive for
 * moderation history, nothing private about the person ever leaves this
 * collection (entries carry no display name), and listOwnEntries reads only
 * live entries.
 */
import type { AccountDeletionContribution, AccountDeletionContributor } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { tombstoneEntriesForAccount } from "./challenges.js";

export function createChallengesDeletionContributor(store: CommunityStore, clock: Clock): AccountDeletionContributor {
  return {
    part: "challenges",
    async run(accountId, atIso): Promise<AccountDeletionContribution> {
      const tombstoned = await tombstoneEntriesForAccount({ store, clock }, accountId, atIso);
      return {
        part: "challenges",
        recordsTouched: tombstoned,
        detail: `${tombstoned} challenge entries tombstoned`,
      };
    },
  };
}
