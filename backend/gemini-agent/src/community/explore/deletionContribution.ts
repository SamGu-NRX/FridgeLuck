/**
 * The explore part's deletion contribution (SPEC §3.4): the account's live
 * publications are withdrawn immediately (they leave every feed and direct
 * fetch at once), and the account's cook-occurrence opt-ins are stripped
 * from aggregates — a deleted account's consent to be counted ends with the
 * account. Publication documents survive as tombstoned records (the audit
 * trail moderation needs); the author's identity is not scrubbed from them
 * here — moderation history depends on it, and SPEC §3.4 keeps records that
 * survive deletion.
 */
import type { AccountDeletionContribution, AccountDeletionContributor } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import { parsePublicationDoc } from "./publications.js";

export function createExploreDeletionContributor(store: CommunityStore): AccountDeletionContributor {
  return {
    part: "explore/publications",
    async run(accountId, atIso): Promise<AccountDeletionContribution> {
      const snap = await store.publications.where("authorId", "==", accountId).get();
      let withdrawn = 0;
      let cookKeysStripped = 0;
      for (const doc of snap.docs) {
        const record = parsePublicationDoc(doc);
        if (record === null) {
          continue;
        }
        if (record.status !== "withdrawn") {
          await doc.ref.update({ status: "withdrawn", withdrawnAtIso: atIso });
          withdrawn += 1;
        }
        if (record.optedInCooks[accountId] !== undefined) {
          const { [accountId]: _removed, ...rest } = record.optedInCooks;
          await doc.ref.update({ optedInCooks: rest });
          cookKeysStripped += 1;
        }
      }
      return {
        part: "explore/publications",
        recordsTouched: withdrawn + cookKeysStripped,
        detail: `${withdrawn} publications withdrawn, ${cookKeysStripped} cook-occurrence keys stripped`,
      };
    },
  };
}
