/**
 * The tables part's deletion contribution (SPEC §3.4): the account leaves
 * every table it belongs to — its memberships are removed outright
 * (directory entries); a table it owns is dissolved (the owner-leave rule:
 * no one is left to approve invites or members). The account's shared-cook
 * records are tombstoned, not erased, and disappear from every table feed
 * immediately (listSharedCooks filters tombstones).
 */
import type { AccountDeletionContribution, AccountDeletionContributor } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { dissolveTable, membershipDocId, parseMembershipDoc, parseSharedCookDoc } from "./tables.js";
import type { TableId } from "../shared/ids.js";

export function createTablesDeletionContributor(store: CommunityStore, clock: Clock): AccountDeletionContributor {
  return {
    part: "tables",
    async run(accountId, atIso): Promise<AccountDeletionContribution> {
      const memberDocs = await store.tableMemberships.where("accountId", "==", accountId).get();
      let ownedDissolved = 0;
      let membershipsRemoved = 0;
      for (const doc of memberDocs.docs) {
        const record = parseMembershipDoc(doc);
        if (record === null) {
          continue;
        }
        if (record.role === "owner") {
          // Dissolving removes every membership of the table, this one
          // included — no separate delete.
          await dissolveTable({ store, clock }, record.tableId as TableId);
          ownedDissolved += 1;
        } else {
          await store.tableMemberships.doc(membershipDocId(record.tableId, accountId)).delete();
          membershipsRemoved += 1;
        }
      }
      const ownCooks = await store.sharedCooks.where("authorId", "==", accountId).get();
      let cooksTombstoned = 0;
      for (const doc of ownCooks.docs) {
        const record = parseSharedCookDoc(doc);
        if (record === null || record.deletedAtIso !== null) {
          continue;
        }
        await doc.ref.update({ deletedAtIso: atIso });
        cooksTombstoned += 1;
      }
      return {
        part: "tables",
        recordsTouched: ownedDissolved + membershipsRemoved + cooksTombstoned,
        detail: `${ownedDissolved} tables dissolved, ${membershipsRemoved} memberships removed, ${cooksTombstoned} shared cooks tombstoned`,
      };
    },
  };
}
