/**
 * Typed errors for the community module, mapped to HTTP at the router edge.
 * Business logic throws CommunityError (or a subclass); only the route
 * wrapper translates one into a response.
 */

export type CommunityErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "validation"
  | "rate_limited"
  | "internal";

export class CommunityError extends Error {
  readonly status: number;
  readonly code: CommunityErrorCode;

  constructor(status: number, code: CommunityErrorCode, message: string) {
    super(message);
    this.name = "CommunityError";
    this.status = status;
    this.code = code;
  }
}

export function errUnauthorized(message: string): CommunityError {
  return new CommunityError(401, "unauthorized", message);
}
export function errForbidden(message: string): CommunityError {
  return new CommunityError(403, "forbidden", message);
}
export function errNotFound(message: string): CommunityError {
  return new CommunityError(404, "not_found", message);
}
export function errConflict(message: string): CommunityError {
  return new CommunityError(409, "conflict", message);
}
export function errValidation(message: string): CommunityError {
  return new CommunityError(422, "validation", message);
}
export function errRateLimited(message: string): CommunityError {
  return new CommunityError(429, "rate_limited", message);
}

export function isCommunityError(error: unknown): error is CommunityError {
  return error instanceof CommunityError;
}
