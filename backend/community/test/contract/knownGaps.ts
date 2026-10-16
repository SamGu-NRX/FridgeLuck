/**
 * KNOWN_CONTRACT_GAPS — served behaviour the contract (docs/spec/community/contracts/)
 * does not declare yet. Sam is reviewing the spec, so docs/spec/ is not edited here;
 * instead each gap is listed explicitly and the suite ASSERTS against this list:
 *
 *   - every route the server serves but openapi.yaml does not declare must appear
 *     here as a `route` gap, and every listed `route` gap must still be served
 *     (a stale entry fails the suite and must be removed);
 *   - every driven response whose status the operation does not declare must appear
 *     here as a `status` gap, and each `status` gap's scenario keeps running so the
 *     behaviour stays pinned.
 *
 * Anything not listed fails the suite with its method and path (route gaps) or
 * operation and status (status gaps). When Sam lands a contract change, delete the
 * entry and add the declared schema/status to the suite's normal assertions.
 */

export type ContractGap =
  | {
      readonly kind: "route";
      readonly method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
      /** Server pattern form (`:param`), e.g. "/tables/:tableId/cards". */
      readonly pattern: string;
      /** What the server serves today and why it exists. */
      readonly reason: string;
      /** The exact contract change that closes the gap (for the spec PR). */
      readonly exactContractChange: string;
    }
  | {
      readonly kind: "status";
      readonly method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
      /** OpenAPI path form (`{param}`), e.g. "/challenges/{challengeId}/vote". */
      readonly path: string;
      readonly status: number;
      /** The scenario that drives this status, so it stays covered. */
      readonly drives: string;
      readonly reason: string;
      readonly exactContractChange: string;
    };

export const KNOWN_CONTRACT_GAPS: readonly ContractGap[] = [
  {
    kind: "route",
    method: "GET",
    pattern: "/tables/:tableId/cards",
    reason:
      "PR #166's Table card feed: members read the shared-cook history (blocks, hiding and leave-redaction are feed behaviours that need a read surface). openapi.yaml declares only POST (shareCookToTable) and DELETE (deleteCard) on /tables/{tableId}/cards.",
    exactContractChange:
      'Add to openapi.yaml under /tables/{tableId}/cards:\n\n    get:\n      operationId: listTableCards\n      summary: The Table\'s card feed as the caller sees it (blocked pairs filtered, reported cards hidden, departed authors redacted).\n      responses:\n        "200":\n          content:\n            application/json:\n              schema: "schemas/table-card-feed.schema.json"\n\nand add schemas/table-card-feed.schema.json:\n\n{\n  "$schema": "https://json-schema.org/draft/2020-12/schema",\n  "$id": "https://fridgeluck.dev/community/schemas/table-card-feed.schema.json",\n  "title": "TableCardFeed",\n  "type": "object",\n  "additionalProperties": false,\n  "required": ["cards"],\n  "properties": {\n    "cards": {\n      "type": "array",\n      "items": { "$ref": "https://fridgeluck.dev/community/schemas/table-card.schema.json" }\n    }\n  }\n}\n\nplus the manifest.json entry: "listTableCards": { "responseSchema": "table-card-feed.schema.json" }.',
  },
  {
    kind: "status",
    method: "PUT",
    path: "/challenges/{challengeId}/vote",
    status: 403,
    drives: "a signed-in account younger than 24 h votes on a voting-open challenge (SPEC §6.3 gate).",
    reason:
      "PR #166's 24 h account-age gate rides 403 with reason account_too_new; openapi.yaml declares only 204/409/429 for castVote, and its vote error table lists only vote_too_early.",
    exactContractChange:
      'Add to the castVote operation (PUT /challenges/{challengeId}/vote) responses:\n\n        "403":\n          description: The account is younger than 24 hours (account_too_new) — votes start counting at 24 h of account age (SPEC §6.3).\n          content:\n            application/json:\n              schema: "schemas/error.schema.json"',
  },
  {
    kind: "status",
    method: "POST",
    path: "/tables/{tableId}/leave",
    status: 409,
    drives: "the table owner posts /tables/{tableId}/leave (SPEC §5.1: the owner cannot leave — the owner deletes the table instead).",
    reason:
      "The server refuses an owner's leave with 409 conflict; openapi.yaml declares only 204 for leaveTable.",
    exactContractChange:
      'Add to the leaveTable operation (POST /tables/{tableId}/leave) responses:\n\n        "409":\n          description: The owner cannot leave (the contract has no delete-table endpoint; the owner deletes the table instead — SPEC §5.1).\n          content:\n            application/json:\n              schema: "schemas/error.schema.json"',
  },
];

export function routeGapFor(method: string, pattern: string): ContractGap | undefined {
  return KNOWN_CONTRACT_GAPS.find((g) => g.kind === "route" && g.method === method && g.pattern === pattern);
}

export function statusGapFor(method: string, path: string, status: number): ContractGap | undefined {
  return KNOWN_CONTRACT_GAPS.find((g) => g.kind === "status" && g.method === method && g.path === path && g.status === status);
}
