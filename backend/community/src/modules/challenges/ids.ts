/**
 * Server-generated identifiers for the challenges module, shaped by
 * challenge.schema.json / challenge-entry.schema.json. Local mirror of
 * core/ids.ts's prefixed factory so this slice touches only its directories.
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

export const challengeIdShape = prefixed("chl_", "challengeId");
export const entryIdShape = prefixed("ent_", "entryId");
