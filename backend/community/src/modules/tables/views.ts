/**
 * Response view mappers for the tables module — server documents to the
 * contract shapes (table.schema.json, table-card.schema.json, shared-cook.schema.json,
 * block-list.schema.json). The rights declaration pattern carries over: only
 * display names ever reach another member, nothing else about them (SPEC §5.4).
 */

import { CommunityError, errValidation } from "../../core/errors.js";
import { findPersonalData } from "../../core/screening.js";
import { validateRecipeContent, validateRecipeRef } from "../../core/validate.js";
import type { RecipeContent, RecipeRef } from "../../core/contract.js";

/** A stored member row. Departed members stay for history redaction (SPEC §5.1). */
export interface TableMemberRow {
  readonly accountId: string;
  readonly role: "owner" | "member";
  readonly joinedAt: string;
  readonly departedAt: string | null;
}

/** The stored table document. */
export interface TableRecord {
  readonly tableId: string;
  readonly name: string;
  readonly createdAt: string;
  readonly members: TableMemberRow[];
}

/** The stored invite document; the plaintext join code never lives here. */
export interface InviteRecord {
  readonly inviteId: string;
  readonly tableId: string;
  readonly codeHash: string;
  readonly state: "pending" | "approved" | "revoked" | "expired" | "declined";
  readonly createdAt: string;
  readonly expiresAt: string;
  readonly requestedByAccountId: string | null;
  readonly requestedByDisplayName: string | null;
}

/** The stored shared-cook payload (contracts/shared-cook.schema.json, request form). */
export interface SharedCookPayload {
  readonly recipeRef: RecipeRef;
  readonly dishName: string;
  readonly servings: number;
  readonly swaps: readonly { fromName: string; toName: string }[];
  readonly rating: number | null;
  readonly note: string | null;
  readonly day: string;
  readonly authorDisplayName: string;
  readonly content: RecipeContent | null;
}

/** The stored card document. */
export interface CardRecord {
  readonly cardId: string;
  readonly tableId: string;
  readonly authorAccountId: string;
  readonly cook: SharedCookPayload;
  readonly createdAt: string;
  /** Set when the author removes their own card; the feed skips it (§5.2). */
  readonly deletedAt?: string | null;
}

export const MAX_TABLE_MEMBERS = 8;

/** contracts/table.schema.json. pendingInvites appear in the owner view only. */
export function tableView(
  record: TableRecord,
  inviteNames: Map<string, string>,
  pendingInvites: { inviteId: string; state: string; expiresAt: string; requestedByAccountId: string | null }[],
  isOwner: boolean,
): Record<string, unknown> {
  const members = record.members
    .filter((m) => m.departedAt === null)
    .map((m) => ({
      accountId: m.accountId,
      displayName: inviteNames.get(m.accountId) ?? "Cook",
      role: m.role,
      joinedAt: m.joinedAt,
    }));
  const view: Record<string, unknown> = { tableId: record.tableId, name: record.name, createdAt: record.createdAt, members };
  if (isOwner) {
    view.pendingInvites = pendingInvites.map((i) => ({
      inviteId: i.inviteId,
      state: i.state,
      expiresAt: i.expiresAt,
      requestedByDisplayName: i.requestedByAccountId === null ? null : (inviteNames.get(i.requestedByAccountId) ?? null),
    }));
  }
  return view;
}

/** contracts/table-invite.schema.json (creator/owner view). joinCode rides separately. */
export function inviteView(record: InviteRecord, joinCode: string | null = null): Record<string, unknown> {
  return {
    inviteId: record.inviteId,
    state: record.state,
    expiresAt: record.expiresAt,
    requestedByDisplayName: record.requestedByDisplayName,
    ...(joinCode !== null ? { joinCode } : {}),
  };
}

/**
 * contracts/table-card.schema.json as one viewer sees it. A departed author's
 * card stays in the history but renders without their identity or cook content
 * — "name removed, card shows 'left the table'" (SPEC §5.1) — encoded inside
 * the fixed schema by dropping authorDisplayName and collapsing the payload.
 */
export function cardView(record: CardRecord, viewerAccountId: string, authorDeparted: boolean): Record<string, unknown> {
  if (authorDeparted) {
    return {
      cardId: record.cardId,
      tableId: record.tableId,
      cook: {
        recipeRef: record.cook.recipeRef,
        dishName: "Left the table",
        servings: 1,
        swaps: [],
        rating: null,
        note: null,
        day: record.cook.day,
        content: null,
      },
      isMine: record.authorAccountId === viewerAccountId,
      createdAt: record.createdAt,
    };
  }
  return {
    cardId: record.cardId,
    tableId: record.tableId,
    cook: { ...record.cook, swaps: [...record.cook.swaps] },
    isMine: record.authorAccountId === viewerAccountId,
    createdAt: record.createdAt,
  };
}

/** contracts/block-list.schema.json. */
export function blockListView(
  blocks: readonly { accountId: string; displayName: string | null; createdAt: string }[],
): Record<string, unknown> {
  return {
    blocks: blocks.map((b) => ({ accountId: b.accountId, displayName: b.displayName, createdAt: b.createdAt })),
  };
}

function requireString(value: unknown, field: string, max: number): string {
  if (typeof value !== "string" || value.length < 1 || value.length > max) {
    throw errValidation("validation", `field ${field} must be a string of 1-${max} characters`);
  }
  return value;
}

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Validates the share payload against shared-cook.schema.json and SPEC §5.2:
 * exactly the allowed fields, nothing more — never pantry, health, taste data,
 * exact times or photos. The author display name is set server-side from the
 * account, so a client-supplied one is refused.
 */
export function validateSharedCook(raw: unknown, authorDisplayName: string): SharedCookPayload {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw errValidation("validation", "field cook must be an object");
  }
  const cook = raw as Record<string, unknown>;
  const allowed = new Set(["recipeRef", "dishName", "servings", "swaps", "rating", "note", "day", "content"]);
  for (const key of Object.keys(cook)) {
    if (!allowed.has(key)) {
      throw errValidation("validation", `field cook.${key} is not part of the share payload`);
    }
  }
  if (typeof cook["recipeRef"] !== "object" || cook["recipeRef"] === null) {
    throw errValidation("validation", "field cook.recipeRef is required");
  }
  const recipeRef = validateRecipeRef(cook["recipeRef"]);
  if (recipeRef.source !== "user") {
    throw errValidation("validation", "a shared cook references your own recipe (source user)");
  }
  const dishName = requireString(cook["dishName"], "cook.dishName", 120);
  if (!Number.isInteger(cook["servings"]) || (cook["servings"] as number) < 1 || (cook["servings"] as number) > 24) {
    throw errValidation("validation", "field cook.servings must be an integer of 1-24");
  }
  const swapsRaw = cook["swaps"];
  if (!Array.isArray(swapsRaw) || swapsRaw.length > 12) {
    throw errValidation("validation", "field cook.swaps must be an array of at most 12 swaps");
  }
  const swaps = swapsRaw.map((s) => {
    if (typeof s !== "object" || s === null || Array.isArray(s)) {
      throw errValidation("validation", "each swap must be an object with fromName and toName");
    }
    const swap = s as Record<string, unknown>;
    const extra = Object.keys(swap).filter((k) => k !== "fromName" && k !== "toName");
    if (extra.length > 0) {
      throw errValidation("validation", `swap field ${extra[0]} is not part of the share payload`);
    }
    return { fromName: requireString(swap["fromName"] ?? "", "cook.swaps.fromName", 80), toName: requireString(swap["toName"] ?? "", "cook.swaps.toName", 80) };
  });
  const rating = cook["rating"];
  if (rating !== undefined && rating !== null && (!Number.isInteger(rating) || (rating as number) < 1 || (rating as number) > 5)) {
    throw errValidation("validation", "field cook.rating must be an integer of 1-5 or null");
  }
  const note = cook["note"];
  if (note !== undefined && note !== null && (typeof note !== "string" || note.length > 140)) {
    throw errValidation("validation", "field cook.note must be a string of at most 140 characters");
  }
  if (typeof note === "string" && note.length > 0) {
    // The one-line note runs the personal-data screen (SPEC §5.2); the server
    // re-runs it so a skipped client check cannot leak contact details.
    const findings = findPersonalData(note);
    if (findings.length > 0) {
      // "personal_data" is the contract's reason, not a top-level error code.
      throw new CommunityError(422, "validation", `the note contains ${findings[0]}`, "personal_data");
    }
  }
  const day = cook["day"];
  if (typeof day !== "string" || !DAY_PATTERN.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00Z`))) {
    throw errValidation("validation", "field cook.day must be a date (YYYY-MM-DD) — the day only, never an exact time");
  }
  // Content ships only for a revision that was never published (SPEC §5.2):
  // published revisions are fetchable via the publication, so the server
  // strips the duplicate copy. The publish/skip decision is the caller's.
  const contentRaw = cook["content"];
  let content: RecipeContent | null = null;
  if (contentRaw !== undefined && contentRaw !== null) {
    content = validateRecipeContent(contentRaw);
  }
  return {
    recipeRef,
    dishName,
    servings: cook["servings"] as number,
    swaps,
    rating: typeof rating === "number" ? rating : null,
    note: typeof note === "string" && note.length > 0 ? note : null,
    day,
    authorDisplayName,
    content,
  };
}
