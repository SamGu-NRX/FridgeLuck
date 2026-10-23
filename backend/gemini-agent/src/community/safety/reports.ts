/**
 * Reports (SPEC §3.4: "anyone can leave, block and report"; "reports hide it
 * pending review"). Submitting a report on a live publication always goes
 * through the ModerationQueue seam's user-report submission path, which
 * hides the publication BEFORE the queue item is written — a report can
 * never leave a live publication behind. The report itself is a record for
 * the audit trail: who reported what, why, when.
 *
 * Rate limit: at most config.reportLimitPerDay reports per reporter per
 * rolling day (an abuse guard for the moderation operator's queue).
 * Enforcement reads the reporter's own reports (equality query, no
 * composite index) and filters the window in memory.
 *
 * The reason vocabulary is the narrow set this part needs to route a human
 * review: food-safety, not-own-recipe, other. The spec does not enumerate
 * reasons; recorded as an interpretation in the M4 handoff.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import type { ModerationQueue, PublicationRef } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errValidation } from "../shared/errors.js";
import {
  newReportId,
  parsePublicationId,
  parseRecipeRevisionId,
  type AccountId,
  type ReportId,
} from "../shared/ids.js";
import { parsePublicationDoc, publicationVisibility } from "../explore/publications.js";

export const REPORT_REASONS = ["food-safety", "not-own-recipe", "other"] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

export interface ReportRecord {
  readonly reportId: ReportId;
  readonly publicationId: string;
  readonly revisionId: string;
  readonly reporterAccountId: AccountId;
  readonly reason: ReportReason;
  readonly note: string | null;
  readonly createdAtIso: string;
}

export interface ReportDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
  readonly moderation: ModerationQueue;
  readonly reportLimitPerDay: number;
}

function readStringField(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errValidation(`report record field ${field} is missing or malformed`);
  }
  return value;
}

/** Validating read of a report document (README rule 5). */
export function parseReportDoc(snap: DocumentSnapshot): ReportRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const reason = readStringField(data, "reason");
  if (!REPORT_REASONS.includes(reason as ReportReason)) {
    throw errValidation(`report record field reason is malformed: ${reason}`);
  }
  const note = data["note"];
  return {
    reportId: snap.id as ReportId,
    publicationId: readStringField(data, "publicationId"),
    revisionId: readStringField(data, "revisionId"),
    reporterAccountId: readStringField(data, "reporterAccountId") as AccountId,
    reason: reason as ReportReason,
    note: typeof note === "string" ? note : null,
    createdAtIso: readStringField(data, "createdAtIso"),
  };
}

export type SubmitReportOutcome =
  | { readonly outcome: "ok"; readonly report: ReportRecord; readonly itemId: string }
  | { readonly outcome: "missing" }
  | { readonly outcome: "conflict"; readonly reason: "not-live" }
  | { readonly outcome: "conflict"; readonly reason: "limit" };

/**
 * Reports a publication. Only a LIVE (published) publication can be
 * reported — reporting a withdrawn or already-hidden one is a conflict, not
 * a new queue item (the moderation queue is for humans, not bookkeeping).
 */
export async function submitReport(
  deps: ReportDeps,
  publicationId: string,
  reporter: AccountId,
  reason: ReportReason,
  note: string | null,
): Promise<SubmitReportOutcome> {
  const snap = await deps.store.publications.doc(publicationId).get();
  // Validating read (README rule 5); liveness derives from the moderation
  // state, the same single derivation every other surface uses.
  const existing = parsePublicationDoc(snap);
  if (existing === null) {
    return { outcome: "missing" };
  }
  if (!publicationVisibility(existing.status).visibleToReaders) {
    return { outcome: "conflict", reason: "not-live" };
  }
  const cutoffIso = toIso(new Date(deps.clock.now().getTime() - 24 * 60 * 60 * 1000));
  const ownReports = await deps.store.reports.where("reporterAccountId", "==", reporter).get();
  const recent = ownReports.docs.filter((doc) => {
    const createdAt = doc.get("createdAtIso");
    return typeof createdAt === "string" && createdAt >= cutoffIso;
  }).length;
  if (recent + 1 > deps.reportLimitPerDay) {
    return { outcome: "conflict", reason: "limit" };
  }
  // The queue submission is the hide: it hides the publication before the
  // queue item exists (SPEC 3.4). The report record is written after, so a
  // crash in between leaves the publication hidden (never live-with-report).
  const target: PublicationRef = {
    publicationId: parsePublicationId.parse(snap.id, "reported publication"),
    revisionId: parseRecipeRevisionId.parse(existing.revisionId, "reported revision"),
  };
  const itemId = await deps.moderation.submit(target, reporter, "user-report", note);
  const report: ReportRecord = {
    reportId: newReportId(),
    publicationId,
    revisionId: existing.revisionId,
    reporterAccountId: reporter,
    reason,
    note,
    createdAtIso: toIso(deps.clock.now()),
  };
  await deps.store.reports.doc(report.reportId).create(report);
  return { outcome: "ok", report, itemId };
}
