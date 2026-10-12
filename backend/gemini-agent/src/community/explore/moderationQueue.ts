/**
 * The ModerationQueue contract over Firestore: enqueue (automated screening
 * failure, user report, author appeal), the moderator list, and resolve with
 * an append-only audit trail (who, when, action).
 *
 * Enqueueing hides the publication pending review (SPEC 3.4: "reports hide
 * it pending review") — except author appeals, which target already-hidden
 * publications. The hide lands before the queue item, so a report can never
 * leave a live publication behind. Resolving is ONE atomic transaction (PR
 * #104 review blocker 5): the decision, its audit entry, and the
 * publication's visibility transition — the moderation-state change
 * visibility derives from — commit together or not at all, so no reader
 * (concurrent, or after a crash) can observe a decision whose visibility
 * did not move with it. Exactly one decision lands per item: a losing
 * concurrent resolve aborts on the commit, retries, re-reads the resolved
 * item, and surfaces conflict. The registered decision handler is notified
 * exactly once per decision, after the commit — it can no longer gate the
 * decision or land a second write beside it.
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
import {
  approvalRefusal,
  hidePublicationForModeration,
  parsePublicationDoc,
  publicationVisibility,
} from "./publications.js";

export interface ModerationQueueDeps {
  readonly items: CommunityStore["moderationItems"];
  readonly publications: CommunityStore["publications"];
  readonly clock: Clock;
  /**
   * Test-only fault injection: when set, resolve() calls it inside the
   * decision transaction right after the visibility write is queued and
   * before the decision write is queued. The thrown error aborts the
   * transaction, letting tests observe that both writes roll back together.
   * Production wiring never sets it — a mid-transaction failure cannot be
   * provoked from outside the transaction.
   */
  readonly throwInsideResolveForTests?: () => void;
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
    const nowIso = toIso(this.deps.clock.now());
    let resolved: ModerationQueueItem;
    try {
      resolved = await this.deps.items.firestore.runTransaction(async (tx: Transaction): Promise<ModerationQueueItem> => {
        const snap = await tx.get(doc);
        const current = parseModerationItemDoc(snap);
        if (current === null) {
          throw errNotFound("moderation item not found");
        }
        if (current.status !== "open") {
          throw errConflict("moderation item is already resolved");
        }
        // ONE transaction for the decision and the visibility transition
        // (review blocker 5): the publication's guarded state change — the
        // same guards as publications.ts's transitionOnDecision, whose own
        // transaction this replaces because it could not join this one —
        // reads and writes this same snapshot. Both writes commit together
        // or not at all: no reader, concurrent or after a crash, can see a
        // decision whose visibility did not move with it. Only a queued
        // publication at the item's revision moves (a re-fired decision is
        // a no-op, a concurrent withdrawal wins), and a losing concurrent
        // resolve aborts on the commit, retries, re-reads the resolved
        // item, and surfaces the conflict below.
        const pubDoc = this.deps.publications.doc(current.target.publicationId);
        const pubSnap = await tx.get(pubDoc);
        const publication = parsePublicationDoc(pubSnap);
        if (
          publication !== null &&
          publicationVisibility(publication.status).inModerationQueue &&
          publication.revisionId === current.target.revisionId
        ) {
          if (decision === "approved") {
            // Blocker 1's refusal keeps guarding approval (fail closed,
            // 409): it throws before anything is written, so the
            // transaction aborts with the item open and visibility
            // untouched.
            const refusal = approvalRefusal(publication);
            if (refusal !== null) {
              throw errConflict(refusal);
            }
            tx.update(pubDoc, { status: "published", publishedAtIso: nowIso });
          } else {
            tx.update(pubDoc, { status: "rejected", rejectedAtIso: nowIso });
          }
        }
        // Test-only fault injection (see ModerationQueueDeps): force the
        // abort between the two queued writes so tests can observe the
        // rollback of both.
        this.deps.throwInsideResolveForTests?.();
        const audit = [...current.audit, { at: nowIso, actor: moderator, action: `decision:${decision}`, detail: note }].slice(-MAX_AUDIT_ENTRIES);
        tx.update(doc, {
          status: "resolved",
          decision,
          resolvedBy: moderator,
          resolvedAt: nowIso,
          audit,
        });
        return { ...current, status: "resolved", decision, resolvedBy: moderator, resolvedAt: nowIso, audit };
      });
    } catch (error) {
      if (error instanceof Error && error.message === "moderation item is already resolved") {
        throw errConflict("moderation item is already resolved");
      }
      throw error;
    }
    // The registered handler fires exactly once per decision, after the
    // commit: it can no longer gate the decision or land a second write
    // beside it. Production registers publications.ts's guarded transition,
    // which is now a no-op — the publication already moved in this very
    // transaction.
    if (this.decisionHandler !== null) {
      await this.decisionHandler(resolved.target, decision, note ?? "");
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
