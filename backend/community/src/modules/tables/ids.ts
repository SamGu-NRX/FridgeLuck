/**
 * Server-generated identifiers for the tables module, shaped by the contract
 * schemas (table.schema.json, table-invite.schema.json, table-card.schema.json).
 * Mirrors core/ids.ts's prefixed shape (which does not export the factory);
 * kept local so this slice touches only its own directories.
 */

import { errValidation } from "../../core/errors.js";

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
        throw errValidation("validation", `${where}: malformed identifier`);
      }
      return raw;
    },
  };
}

export const tableIdShape = prefixed("tbl_", "tableId");
export const inviteIdShape = prefixed("inv_", "inviteId");
export const cardIdShape = prefixed("crd_", "cardId");

/** Join code: 6 characters from the unambiguous alphabet, shown exactly once. */
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function newJoinCode(): string {
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  let out = "";
  for (const b of buf) {
    out += CODE_ALPHABET[b % CODE_ALPHABET.length];
  }
  return out;
}

export function validateJoinCode(raw: unknown): string {
  if (typeof raw !== "string" || !/^[A-Z0-9]{6}$/.test(raw)) {
    throw errValidation("validation", "join code must be 6 characters of A-Z0-9");
  }
  return raw;
}

/** sha-256 of a join code — the plaintext code is never stored (SPEC §5.4). */
export async function joinCodeHash(code: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code)));
  return Array.from(digest)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
