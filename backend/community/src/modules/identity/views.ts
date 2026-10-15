import type { AccountView } from "../../core/contract.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AccountDataLike = any;

const VOTE_AGE_DELAY_MS = 24 * 60 * 60 * 1000;

/**
 * contracts/account.schema.json. isAdult reflects the recorded 18+
 * attestation; canVoteAt is null once the account may vote now, otherwise
 * the UTC instant its votes start counting (account age >= 24 h, SPEC §6.3).
 */
export function accountView(accountId: string, data: AccountDataLike | null, isOperator: boolean, nowMs: number): AccountView {
  const displayName = typeof data?.["displayName"] === "string" && data["displayName"].length > 0 ? data["displayName"] : "Cook";
  const birthYear = data?.["birthYear"];
  const attested = typeof data?.["attested18PlusAtIso"] === "string";
  const currentYear = new Date(nowMs).getUTCFullYear();
  const isAdult = attested && typeof birthYear === "number" && currentYear - birthYear >= 18;
  const createdAt = typeof data?.["createdAt"] === "string" ? Date.parse(data["createdAt"]) : Number.NaN;
  const canVoteAt =
    Number.isFinite(createdAt) && createdAt + VOTE_AGE_DELAY_MS > nowMs ? new Date(createdAt + VOTE_AGE_DELAY_MS).toISOString() : null;
  return { accountId, displayName, isAdult, canVoteAt, moderationOperator: isOperator };
}
