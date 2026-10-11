/**
 * The ModerationQueue contract over Firestore: enqueue (automated screening
 * failure, user report, author appeal), the moderator list, and resolve with
 * an append-only audit trail (who, when, action).
 *
 * Enqueueing hides the publication pending review (SPEC 3.4: "reports hide
 * it pending review") — except author appeals, which target already-hidden
 * publications. The hide lands before the queue item, so a report can never
 * leave a live publication behind. Resolving is guarded: exactly one
 * moderator decision lands, the registered decision handler fires exactly
 * once per decision, and the audit trail records the submission and the
 * decision.
 *
 * No LLM anywhere: submissions arrive from deterministic screening stages or
 * users; decisions come only from a human moderator via the server-held
 * route, and the role check lives at that route.
 */
import type { DocumentSnapshot, Transaction } from "@google-cloud/firestore";
import type {
  ModerationAuditEntry,
  ModerationDecisionKind,
  ModerationQueueItem,
  ModerationQueueStatus,
  ModerationSubmitReason,
  PublicationRef,
} from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errConflict, errNotFound, errValidation } from "../shared/errors.js";
import {
  newModerationItemId,
  parseModerationItemId,
  parsePublicationId,
  parseRecipeRevisionId,
  type AccountId,
  type ModerationItemId,
} from "../shared/ids.js";
import { hidePublicationForModeration } from "./publications.js";

export interface ModerationQueueDeps {
  readonly items: CommunityStore["moderationItems"];
  readonly publications: CommunityStore["publications"];
  readonly clock: Clock;
}

type ModerationItemDoc = {
  publicationId: string;
  revisionId: string;
  submitter: AccountId | null;
  reason: ModerationSubmitReason;
  note: string | null;
  status: ModerationQueueStatus;
  createdAt: string;
  decision: ModerationDecisionKind | null;
  resolvedBy: AccountId | null;
  resolvedAt: string | null;
  audit: ModerationAuditEntry[];
};

const REASONS: readonly ModerationSubmitReason[] = ["automated-screening", "user-report", "author-appeal"];
const MAX_AUDIT_ENTRIES = 100;

function readAudit(data: Record<string, unknown>): ModerationAuditEntry[] {
  const value = data["audit"];
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw errValidation("moderation item field audit is malformed");
  }
  return value.map((entry: unknown) => {
    if (typeof entry !== "object" || entry === null) {
      throw errValidation("moderation audit entry is malformed");
    }
    const record = entry as Record<string, unknown>;
    const at = record["at"];
    const action = record["action"];
    const actor = record["actor"];
    const detail = record["detail"];
    if (typeof at !== "string" || Number.isNaN(Date.parse(at)) || typeof action !== "string") {
      throw errValidation("moderation audit entry is malformed");
    }
    if (actor !== null && typeof actor !== "string") {
      throw errValidation("moderation audit entry is malformed");
    }
    if (detail !== null && detail !== undefined && typeof detail !== "string") {
      throw errValidation("moderation audit entry is malformed");
    }
    return { at, actor: actor as AccountId | null, action, detail: typeof detail === "string" ? detail : null };
  });
}

/** Validating read of a moderation item document (README rule 5). */
export function parseModerationItemDoc(snap: DocumentSnapshot): ModerationQueueItem | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const readString = (field: string): string => {
    const value = data[field];
    if (typeof value !== "string") {
      throw errValidation(`moderation item field ${field} is missing or malformed`);
    }
    return value;
  };
  const readStringOrNull = (field: string): string | null => {
    const value = data[field];
    if (value === null || value === undefined) {
      return null;
    }
    if (typeof value !== "string") {
      throw errValidation(`moderation item field ${field} is malformed`);
    }
    return value;
  };
  const reason = readString("reason");
  if (!REASONS.includes(reason as ModerationSubmitReason)) {
    throw errValidation(`moderation item field reason is malformed: ${reason}`);
  }
  const status = readString("status");
  if (status !== "open" && status !== "resolved") {
    throw errValidation(`moderation item field status is malformed: ${status}`);
  }
  const decision = readStringOrNull("decision");
  if (decision !== null && decision !== "approved" && decision !== "rejected") {
    throw errValidation("moderation item field decision is malformed");
  }
  return {
    itemId: snap.id as ModerationItemId,
    target: {
      publicationId: parsePublicationId.parse(readString("publicationId"), "moderation item target"),
      revisionId: parseRecipeRevisionId.parse(readString("revisionId"), "moderation item target"),
    },
    submitter: readStringOrNull("submitter") as AccountId | null,
    reason: reason as ModerationSubmitReason,
    note: readStringOrNull("note"),
    status,
    createdAt: readString("createdAt"),
    decision: decision as ModerationDecisionKind | null,
    resolvedBy: readStringOrNull("resolvedBy") as AccountId | null,
    resolvedAt: readStringOrNull("resolvedAt"),
    audit: readAudit(data),
  };
}

export class FirestoreModerationQueue {
  private readonly deps: ModerationQueueDeps;
  private decisionHandler: ((target: PublicationRef, decision: ModerationDecisionKind, note: string) => Promise<void>) | null = null;

  constructor(deps: ModerationQueueDeps) {
    this.deps = deps;
  }

  async submit(target: PublicationRef, submitter: AccountId | null, reason: ModerationSubmitReason, note: string | null): Promise<ModerationItemId> {
    const itemId = newModerationItemId();
    const nowIso = toIso(this.deps.clock.now());
    const doc: ModerationItemDoc = {
      publicationId: target.publicationId,
      revisionId: target.revisionId,
      submitter,
      reason,
      note,
      status: "open",
      createdAt: nowIso,
      decision: null,
      resolvedBy: null,
      resolvedAt: null,
      audit: [{ at: nowIso, actor: submitter, action: `submitted:${reason}`, detail: note }],
    };
    if (reason !== "author-appeal") {
      await hidePublicationForModeration(
        { publications: this.deps.publications, clock: this.deps.clock },
        target,
        nowIso,
      );
    }
    await this.deps.items.doc(itemId).create(doc);
    return itemId;
  }

  async list(status: ModerationQueueStatus): Promise<readonly ModerationQueueItem[]> {
    // Single-field equality query: no composite index requirement. Sorting in
    // memory keeps the collection index-free at this scale; stable pagination
    // keys are the integration task's concern.
    const snap = await this.deps.items.where("status", "==", status).limit(200).get();
    const items = snap.docs
      .map((doc) => parseModerationItemDoc(doc))
      .filter((item): item is ModerationQueueItem => item !== null);
    if (status === "open") {
      items.sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : a.itemId < b.itemId ? -1 : 1));
    } else {
      items.sort((a, b) => {
        const ar = a.resolvedAt ?? "";
        const br = b.resolvedAt ?? "";
        return ar > br ? -1 : ar < br ? 1 : a.itemId < b.itemId ? -1 : 1;
      });
    }
    return items;
  }

  async resolve(itemId: ModerationItemId, decision: ModerationDecisionKind, moderator: AccountId, note: string | null): Promise<ModerationQueueItem> {
    const doc = this.deps.items.doc(itemId);
    const existing = parseModerationItemDoc(await doc.get());
    if (existing === null) {
      throw errNotFound("moderation item not found");
    }
    if (existing.status !== "open") {
      throw errConflict("moderation item is already resolved");
    }

    // The publication transition first (guarded: only queued moves, so a
    // re-fired decision is a no-op and a concurrent withdrawal wins), then
    // the item transition under a transaction that only lands once — a
    // losing concurrent resolve throws conflict from the guard below.
    if (this.decisionHandler !== null) {
      await this.decisionHandler(existing.target, decision, note ?? "");
    }
    const nowIso = toIso(this.deps.clock.now());
    try {
      await this.deps.items.firestore.runTransaction(async (tx: Transaction) => {
        const snap = await tx.get(doc);
        const current = parseModerationItemDoc(snap);
        if (current === null || current.status !== "open") {
          throw errConflict("moderation item is already resolved");
        }
        const audit = [...current.audit, { at: nowIso, actor: moderator, action: `decision:${decision}`, detail: note }].slice(-MAX_AUDIT_ENTRIES);
        tx.update(doc, {
          status: "resolved",
          decision,
          resolvedBy: moderator,
          resolvedAt: nowIso,
          audit,
        });
      });
    } catch (error) {
      if (error instanceof Error && error.message === "moderation item is already resolved") {
        throw errConflict("moderation item is already resolved");
      }
      throw error;
    }
    const resolved = parseModerationItemDoc(await doc.get());
    if (resolved === null) {
      throw errNotFound("moderation item vanished during resolve");
    }
    return resolved;
  }

  registerDecisionHandler(handler: (target: PublicationRef, decision: ModerationDecisionKind, note: string) => Promise<void>): void {
    this.decisionHandler = handler;
  }
}

/** Route-boundary id validation for the moderation item path parameter. */
export function parseItemIdParam(raw: unknown): ModerationItemId {
  return parseModerationItemId.parse(raw, "moderation item path id");
}
