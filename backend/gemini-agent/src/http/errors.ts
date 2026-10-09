// Error taxonomy for the HTTP surface.
//
// Two rules drive this file:
//
// 1. Only `PublicApiError` — with a code from the fixed allowlist — may reach a
//    client beyond the generic validation/parse codes. The only 422 responses
//    are the two ingredient-policy codes. Arbitrary `Error` objects that happen
//    to carry `status` / `statusCode` / `code` / `response` fields (e.g. errors
//    thrown by provider SDKs) NEVER authorize their messages to be exposed.
// 2. Everything unrecognized collapses to a generic 500 plus a request id.

/** The only public typed error codes a client can ever see as a 422. */
export type PublicErrorCode = "uses_avoided_ingredient" | "uses_unlisted_ingredient";

/** Stable error codes used in response bodies and (only these) in logs. */
export type StableErrorCode =
  | "invalid_json"
  | "invalid_request"
  | "payload_too_large"
  | "rate_limited"
  | "not_found"
  | "internal_error"
  | PublicErrorCode;

/**
 * A recognized, public product error. Services throw this when a request is
 * structurally valid but violates a product policy the client is meant to see.
 * The message deliberately equals the code: no free-form text is attached.
 */
export class PublicApiError extends Error {
  readonly code: PublicErrorCode;

  constructor(code: PublicErrorCode) {
    super(code);
    this.name = "PublicApiError";
    this.code = code;
  }

  get httpStatus(): number {
    return 422;
  }
}

/**
 * Internal rejection raised by request validators. The field path is a static
 * structural location (e.g. "rules[0].hour") — never a value from the request.
 */
export class RequestValidationError extends Error {
  readonly field?: string;
  readonly httpStatus: number;
  readonly code: Extract<StableErrorCode, "invalid_request" | "payload_too_large">;

  constructor(field: string | undefined, httpStatus: 400 | 413 = 400) {
    super(httpStatus === 413 ? "payload_too_large" : "invalid_request");
    this.name = "RequestValidationError";
    this.field = field;
    this.httpStatus = httpStatus;
    this.code = httpStatus === 413 ? "payload_too_large" : "invalid_request";
  }
}

interface BodyParserClassification {
  status: number;
  code: StableErrorCode;
}

/**
 * Map body-parser middleware failures onto safe responses. body-parser errors
 * are recognized infrastructure errors (produced by our own middleware), so a
 * mapping by type is safe — but their messages are still never echoed.
 */
export function classifyBodyParserError(err: unknown): BodyParserClassification | null {
  if (typeof err !== "object" || err === null) return null;
  const type = (err as { type?: unknown }).type;
  if (type === "entity.parse.failed") return { status: 400, code: "invalid_json" };
  if (type === "entity.too.large") return { status: 413, code: "payload_too_large" };
  if (type === "charset.unsupported") return { status: 400, code: "invalid_json" };
  if (type === "encoding.unsupported") return { status: 400, code: "invalid_json" };
  if (type === "request.aborted") return { status: 400, code: "invalid_json" };
  return null;
}
