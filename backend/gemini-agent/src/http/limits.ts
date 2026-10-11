// Shared transport and parser limits for the HTTP surface.
//
// Photos are bounded by their ENCODED size: the number of base64 characters
// carried in the JSON body, not the decoded JPEG byte count. Every route that
// accepts a photo field uses the same encoded-byte cap and the same parser
// limit, and the field cap always fits inside the parser limit so the field
// check is reachable before the parser cuts the request off.

/** Maximum accepted base64 characters for a photo field (8 MiB encoded ≈ 6 MiB JPEG). */
export const PHOTO_BASE64_MAX_CHARS = 8 * 1024 * 1024;

/** JSON body parser limit for routes that accept photo fields. */
export const JSON_BODY_LIMIT_PHOTO_ROUTES = "10mb";

/** JSON body parser limit for every other route that reads a body. */
export const JSON_BODY_LIMIT_DEFAULT = "1mb";

/**
 * WebSocket transport ceiling owned by this service's wiring (8 MiB).
 * packet025 owns the smaller semantic message caps that live underneath it.
 */
export const WS_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;
