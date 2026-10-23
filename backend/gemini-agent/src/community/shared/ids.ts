/**
 * Branded identifiers for the community module.
 *
 * Every resource id is a server-generated string with a fixed prefix, validated
 * once at the boundary and branded afterwards so two different resource ids can
 * never be passed to the same function. Callers may never supply an owner id:
 * ownership always comes from the verified session token.
 */

import { errValidation } from "./errors.js";

function brandedId<Brand extends string>(prefix: string, field: string) {
  const pattern = new RegExp(`^${prefix}[0-9a-f-]{36}$`);
  return {
    isValid(raw: string): boolean {
      return pattern.test(raw);
    },
    parse(raw: unknown, where: string): string & { readonly __brand: Brand } {
      if (typeof raw !== "string" || !pattern.test(raw)) {
        // A malformed id is client input, not a server fault: it must ride the
        // module error envelope (422), not surface as an unhandled 500.
        throw errValidation(`${where}: expected ${field} matching ${prefix}<uuid>`);
      }
      return raw as string & { readonly __brand: Brand };
    },
    newId(): string & { readonly __brand: Brand } {
      const raw = `${prefix}${crypto.randomUUID()}`;
      return raw as string & { readonly __brand: Brand };
    },
  };
}

export type AccountId = string & { readonly __brand: "AccountId" };
export type SessionId = string & { readonly __brand: "SessionId" };
export type TableId = string & { readonly __brand: "TableId" };
export type InviteId = string & { readonly __brand: "InviteId" };
export type SharedCookId = string & { readonly __brand: "SharedCookId" };
export type PublicationId = string & { readonly __brand: "PublicationId" };
export type RecipeRevisionId = string & { readonly __brand: "RecipeRevisionId" };
export type ChallengeId = string & { readonly __brand: "ChallengeId" };
export type ChallengeEntryId = string & { readonly __brand: "ChallengeEntryId" };
export type ModerationItemId = string & { readonly __brand: "ModerationItemId" };
export type ReportId = string & { readonly __brand: "ReportId" };
export type DeletionRunId = string & { readonly __brand: "DeletionRunId" };

export const parseAccountId = brandedId<"AccountId">("acct_", "account id");
export const parseSessionId = brandedId<"SessionId">("ses_", "session id");
export const parseTableId = brandedId<"TableId">("tab_", "table id");
export const parseInviteId = brandedId<"InviteId">("inv_", "invite id");
export const parseSharedCookId = brandedId<"SharedCookId">("cook_", "shared cook id");
export const parsePublicationId = brandedId<"PublicationId">("pub_", "publication id");
export const parseRecipeRevisionId = brandedId<"RecipeRevisionId">("rev_", "recipe revision id");
export const parseChallengeId = brandedId<"ChallengeId">("chl_", "challenge id");
export const parseChallengeEntryId = brandedId<"ChallengeEntryId">("ent_", "challenge entry id");
export const parseModerationItemId = brandedId<"ModerationItemId">("mod_", "moderation item id");
export const parseReportId = brandedId<"ReportId">("rpt_", "report id");
export const parseDeletionRunId = brandedId<"DeletionRunId">("del_", "deletion run id");

export function newAccountId(): AccountId {
  return parseAccountId.newId();
}
export function newSessionId(): SessionId {
  return parseSessionId.newId();
}
export function newTableId(): TableId {
  return parseTableId.newId();
}
export function newInviteId(): InviteId {
  return parseInviteId.newId();
}
export function newSharedCookId(): SharedCookId {
  return parseSharedCookId.newId();
}
export function newPublicationId(): PublicationId {
  return parsePublicationId.newId();
}
export function newRecipeRevisionId(): RecipeRevisionId {
  return parseRecipeRevisionId.newId();
}
export function newChallengeId(): ChallengeId {
  return parseChallengeId.newId();
}
export function newChallengeEntryId(): ChallengeEntryId {
  return parseChallengeEntryId.newId();
}
export function newModerationItemId(): ModerationItemId {
  return parseModerationItemId.newId();
}
export function newReportId(): ReportId {
  return parseReportId.newId();
}
export function newDeletionRunId(): DeletionRunId {
  return parseDeletionRunId.newId();
}

/**
 * A blocked-pair document id: deterministic for an unordered pair so both
 * directions of a block land on one document. Direction (who blocked whom)
 * is data on the document, not the id.
 */
export function blockPairId(a: AccountId, b: AccountId): string {
  if (a === b) {
    throw new Error("a block pair needs two distinct accounts");
  }
  const [first, second] = [a, b].sort();
  return `blk_${first}_${second}`;
}
