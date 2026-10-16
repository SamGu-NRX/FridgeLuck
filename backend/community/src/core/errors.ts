/**
 * Typed errors for the community backend, mapped to HTTP at the route edge.
 *
 * Ported from PR #104 `shared/errors.ts` (branch feat/community-service-f1):
 * business logic throws CommunityError; only the route wrapper translates one
 * into the contract's error envelope ({ error: { code, message, reason? } }).
 * Error codes are machine-readable and specific (declarations_missing,
 * rate_limited, ...), per contracts/error.schema.json.
 */

export type CommunityErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "validation"
  | "rate_limited"
  | "unavailable"
  | "internal"
  // Publication- and moderation-specific codes from the contract examples.
  | "declarations_missing"
  | "quarantined_rights"
  | "recipe_revised_offline"
  | "recipe_revision_live"
  | "screening_unavailable";

export class CommunityError extends Error {
  readonly status: number;
  readonly code: CommunityErrorCode;
  readonly reason: string | null;

  constructor(status: number, code: CommunityErrorCode, message: string, reason: string | null = null) {
    super(message);
    this.name = "CommunityError";
    this.status = status;
    this.code = code;
    this.reason = reason;
  }
}

export function errUnauthorized(message: string): CommunityError {
  return new CommunityError(401, "unauthorized", message);
}
export function errForbidden(message: string, reason: string | null = null): CommunityError {
  return new CommunityError(403, "forbidden", message, reason);
}
export function errNotFound(message: string): CommunityError {
  return new CommunityError(404, "not_found", message);
}
export function errConflict(code: CommunityErrorCode, message: string): CommunityError {
  return new CommunityError(409, code, message);
}
export function errValidation(code: CommunityErrorCode, message: string): CommunityError {
  return new CommunityError(422, code, message);
}
export function errRateLimited(message: string): CommunityError {
  return new CommunityError(429, "rate_limited", message);
}
/**
 * A mandatory dependency is not in a state any request can fix — notably the
 * screening packages being unloaded. Fail closed: the operation is refused
 * outright, nothing is persisted (PR #104 behaviour, kept by the spec §2.3).
 */
export function errServiceUnavailable(message: string, code: CommunityErrorCode = "screening_unavailable"): CommunityError {
  return new CommunityError(503, code, message);
}

export function isCommunityError(error: unknown): error is CommunityError {
  return error instanceof CommunityError;
}
