/**
 * Request guards and body readers shared by the modules. `requireAccount`
 * enforces auth without leaking whether a token was absent or invalid
 * (SPEC §5: both are 401).
 */

import { errValidation, errUnauthorized, errForbidden } from "./errors.js";
import type { RequestContext } from "./router.js";

export function requireAccount(ctx: RequestContext): string {
  if (ctx.accountId === null) {
    throw errUnauthorized("authentication required");
  }
  return ctx.accountId;
}

export function requireOperator(ctx: RequestContext, isOperator: (accountId: string) => boolean): string {
  const accountId = requireAccount(ctx);
  if (!isOperator(accountId)) {
    throw errForbidden("operator access required");
  }
  return accountId;
}

export function readObject(ctx: RequestContext): Record<string, unknown> {
  if (typeof ctx.body !== "object" || ctx.body === null || Array.isArray(ctx.body)) {
    throw errValidation("validation", "request body must be a JSON object");
  }
  return ctx.body as Record<string, unknown>;
}

export function readString(body: Record<string, unknown>, field: string, opts?: { optional?: boolean }): string | null {
  const value = body[field];
  if (value === undefined || value === null) {
    if (opts?.optional) {
      return null;
    }
    throw errValidation("validation", `field ${field} is required`);
  }
  if (typeof value !== "string") {
    throw errValidation("validation", `field ${field} must be a string`);
  }
  return value;
}

/** Publication-declaration guard (SPEC §2.3): false or missing is a 422, not a stored lie. */
export function requireTrueDeclaration(body: Record<string, unknown>, field: string): true {
  const value = body[field];
  if (value !== true) {
    throw errValidation("declarations_missing", `field ${field} must be true`);
  }
  return true;
}
