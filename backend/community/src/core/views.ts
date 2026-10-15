/**
 * Response view mappers: server documents → contract shapes. The rights
 * declaration and the author's account id never leave the server via these
 * views (SPEC §2.2/§5); the display name is the only identity on a
 * publication. The moderation-case view is the one operator-only exception
 * and includes the stored declaration (contracts/moderation-case.schema.json).
 */

import type { PublicationRecord } from "./repositories.js";
import type { PublicationView, ModerationCaseView, ExploreCard, RecipeContent, RightsDeclaration, ScreeningOutcome } from "./contract.js";
import type { DocumentStore } from "./store/documentStore.js";
import { CASES_COLLECTION } from "./storeRepos.js";

/** Decision actions whose effect outlives the case (§6.5): content stays hidden. */
const CONTENT_HIDING_DECISIONS = new Set(["hide", "remove", "escalate_sam"]);

/**
 * Whether any case over the target hides its content (§5.3, §6.5). A queued
 * case hides while under review; once every case is resolved, the LATEST
 * decidedAt decides: hide, remove, or escalate keep the content hidden, and
 * dismiss — including a dismiss of a fresh report over previously hidden
 * content — restores it. An operator re-reviewing is the revert path.
 */
export function casesHideTarget(docs: { data: Record<string, unknown> | null }[]): boolean {
  const caseData = docs.filter((d): d is { data: Record<string, unknown> } => d.data !== null);
  if (caseData.some((d) => d.data["state"] === "queued")) {
    return true;
  }
  const resolved = caseData.filter((d) => {
    if (d.data["state"] !== "resolved") {
      return false;
    }
    const decidedAt = (d.data["decision"] as Record<string, unknown> | undefined)?.["decidedAt"];
    return typeof decidedAt === "string";
  });
  if (resolved.length === 0) {
    return false;
  }
  // Ties (two decisions within one clock tick) resolve to the later-created
  // case in the store's iteration order — the most recent review wins.
  const latest = resolved.reduce((a, b) =>
    String((b.data["decision"] as Record<string, unknown>)["decidedAt"]).localeCompare(
      String((a.data["decision"] as Record<string, unknown>)["decidedAt"]),
    ) >= 0
      ? b
      : a,
  );
  const action = (latest.data["decision"] as Record<string, unknown>)["action"];
  return typeof action === "string" && CONTENT_HIDING_DECISIONS.has(action);
}

/** Reads every moderation case over one target id. */
export async function casesForTarget(store: DocumentStore, targetId: string): Promise<{ data: Record<string, unknown> | null }[]> {
  return store.collection(CASES_COLLECTION).where("targetId", targetId).get();
}

export function publicationView(record: PublicationRecord): PublicationView {
  const content = record.content as unknown as RecipeContent;
  return {
    publicationId: record.publicationId,
    recipeRef: record.recipeRef,
    content,
    authorDisplayName: record.authorDisplayName,
    allergenTags: [...record.allergenTags],
    state: record.state,
    // Queued publications have no publish instant; the submission time stands
    // in so the required field is always present.
    publishedAt: record.publishedAt === "" ? record.createdAt : record.publishedAt,
    withdrawnAt: record.withdrawnAt,
    flaggedTag: record.flaggedTag,
    challengeId: record.challengeId,
  };
}

/** The stored moderation-case document shape (recipes and moderation modules share it). */
export interface ModerationCaseRecord {
  readonly caseId: string;
  readonly targetType: "recipe" | "tableCard" | "challengeEntry" | "tableMember";
  readonly targetId: string;
  readonly origin: "screening" | "report" | "sampling";
  readonly state: "queued" | "resolved";
  readonly createdAt: string;
  readonly declaration: RightsDeclaration | null;
  readonly screening: readonly ScreeningOutcome[];
  readonly reports: readonly { readonly reason: string; readonly detail: string | null }[];
  readonly decision: { readonly action: string; readonly note: string | null; readonly decidedAt: string } | null;
}

export function moderationCaseView(record: ModerationCaseRecord): ModerationCaseView {
  return {
    caseId: record.caseId,
    targetType: record.targetType,
    targetId: record.targetId,
    origin: record.origin,
    state: record.state,
    createdAt: record.createdAt,
    declaration: record.declaration,
    screening: [...record.screening],
    reports: record.reports.map((r) => ({ reason: r.reason, detail: r.detail })),
    decision: record.decision,
  };
}

export function exploreCard(record: PublicationRecord, cookedBy: number | null): ExploreCard {
  const content = record.content as unknown as RecipeContent;
  return {
    recipeRef: record.recipeRef,
    title: content.title,
    authorDisplayName: record.authorDisplayName,
    timeMinutes: content.timeMinutes,
    allergenTags: [...record.allergenTags],
    publishedAt: record.publishedAt === "" ? record.createdAt : record.publishedAt,
    cookedBy,
    challengeId: record.challengeId,
  };
}

/** SPEC §3.2: below the floor of 10 the count is null — never a small number. */
export function distinctCookCount(record: PublicationRecord): number | null {
  const distinct = new Set(Object.keys(record.optedInCooks)).size;
  return distinct >= 10 ? distinct : null;
}
