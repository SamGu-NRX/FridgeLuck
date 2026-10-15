/**
 * Server-generated identifiers, shaped by contracts/common.schema.json.
 *
 * Where PR #104 used `acct_`/`mod_` uuid ids, the community contract pins
 * different prefixes and shapes (`acc_`, `pub_`, `cse_`, each +10..alnum);
 * the contract wins (SPEC §7.1: shared types come from contracts/). Session
 * ids never leave the server.
 */

import { errValidation } from "./errors.js";

function base62(bytes: number): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  let out = "";
  for (const b of buf) {
    out += alphabet[b % alphabet.length];
  }
  return out;
}

function prefixed(prefix: string, where: string): { newId(): string; validate(raw: unknown): string } {
  const pattern = new RegExp(`^${prefix}[A-Za-z0-9]{10,}$`);
  return {
    newId(): string {
      return prefix + base62(12);
    },
    validate(raw: unknown): string {
      if (typeof raw !== "string" || !pattern.test(raw)) {
        // Malformed ids are client input, not a server fault: they ride the
        // module error envelope, never an unhandled 500.
        throw errValidation("validation", `${where}: malformed identifier`);
      }
      return raw;
    },
  };
}

export const accountIdShape = prefixed("acc_", "accountId");
export const publicationIdShape = prefixed("pub_", "publicationId");
export const caseIdShape = prefixed("cse_", "caseId");
export const sessionIdShape = prefixed("ses_", "sessionId");

/** A deterministic document id for a mutual block pair; direction is data, not the id. */
export function blockPairId(a: string, b: string): string {
  if (a === b) {
    throw new Error("a block pair needs two distinct accounts");
  }
  const [first, second] = [a, b].sort();
  return `${first}__${second}`;
}
