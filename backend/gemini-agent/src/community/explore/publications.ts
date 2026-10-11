/**
 * Publication persistence and the publication state machine (SPEC 3.4, 6).
 *
 * A publication is one immutable revision of a user recipe offered to
 * Explore. States:
 *
 *   published  screening passed (or a moderator approved): visible in feeds
 *   queued     screening failed or a report arrived: hidden, in the human
 *              queue; a moderator approves (→ published) or rejects
 *   rejected   a moderator rejected: hidden, terminal
 *   withdrawn  the author withdrew: tombstoned, terminal
 *
 * Screening runs before the document is created, so there is no intermediate
 * "screening" state and a publish is a single write — a crash cannot leave a
 * half-published document behind.
 *
 * `optedInCooks` maps distinct cook account ids to the UTC day they cooked.
 * It is written only by the opt-in aggregation (a later part); the API never
 * returns the raw map, only floored counts.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errConflict, errValidation } from "../shared/errors.js";
import {
  newPublicationId,
  newRecipeRevisionId,
  type AccountId,
  type PublicationId,
  type RecipeRevisionId,
} from "../shared/ids.js";
import type { ModerationDecisionKind, PublicationRef, ScreeningStage } from "../shared/contracts.js";
import { runScreeningPipeline, textHygieneStage, type ScreeningFailure } from "./screening.js";

export type PublicationStatus = "published" | "queued" | "rejected" | "withdrawn";

export interface PublicationRecord {
  readonly publicationId: PublicationId;
  readonly revisionId: RecipeRevisionId;
  readonly authorId: AccountId;
  /** Provenance: where the published revision came from in the author's cookbook. */
  readonly sourceRecipeId: string;
  readonly sourceRecipeRevision: string;
  readonly title: string;
  readonly summary: string | null;
  readonly note: string | null;
  readonly ingredientLines: readonly string[];
  readonly steps: readonly string[];
  readonly tags: readonly string[];
  readonly campus: string | null;
  readonly status: PublicationStatus;
  readonly screeningFailures: readonly ScreeningFailure[];
  readonly createdAtIso: string;
  readonly publishedAtIso: string | null;
  readonly withdrawnAtIso: string | null;
  readonly rejectedAtIso: string | null;
  readonly optedInCooks: Readonly<Record<string, string>>;
}

export interface PublicationDeps {
  readonly publications: CommunityStore["publications"];
  readonly clock: Clock;
}

export interface NewPublicationInput {
  readonly authorId: AccountId;
  readonly sourceRecipeId: string;
  readonly sourceRecipeRevision: string;
  readonly title: string;
  readonly summary: string | null;
  readonly note: string | null;
  readonly ingredientLines: readonly string[];
  readonly steps: readonly string[];
  readonly tags: readonly string[];
  readonly campus: string | null;
  /** Extra stages wired by the parent join (linter, allergens); text hygiene always runs. */
  readonly screeningStages: readonly ScreeningStage[];
}

export type CreatePublicationResult =
  | { readonly outcome: "published"; readonly record: PublicationRecord }
  | { readonly outcome: "queued"; readonly record: PublicationRecord; readonly failures: readonly ScreeningFailure[] };

const STATUSES: readonly PublicationStatus[] = ["published", "queued", "rejected", "withdrawn"];

function readStringField(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errValidation(`publication record field ${field} is missing or malformed`);
  }
  return value;
}

function readStringOrNull(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw errValidation(`publication record field ${field} is malformed`);
  }
  return value;
}

function readStringArray(data: Record<string, unknown>, field: string): string[] {
  const value = data[field];
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    throw errValidation(`publication record field ${field} is missing or malformed`);
  }
  return value as string[];
}

function readIsoOrNull(data: Record<string, unknown>, field: string): string | null {
  const value = readStringOrNull(data, field);
  if (value === null) {
    return null;
  }
  if (Number.isNaN(Date.parse(value))) {
    throw errValidation(`publication record field ${field} is not an ISO timestamp`);
  }
  return value;
}

function readScreeningFailures(data: Record<string, unknown>): ScreeningFailure[] {
  const value = data["screeningFailures"];
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw errValidation("publication record field screeningFailures is malformed");
  }
  return value.map((entry: unknown) => {
    if (typeof entry !== "object" || entry === null) {
      throw errValidation("publication record screening failure is malformed");
    }
    const record = entry as Record<string, unknown>;
    return {
      stage: readStringField(record, "stage"),
      reasons: readStringArray(record, "reasons"),
    };
  });
}

function readOptedInCooks(data: Record<string, unknown>): Record<string, string> {
  const value = data["optedInCooks"];
  if (value === undefined || value === null) {
    return {};
  }
  if (typeof value !== "object") {
    throw errValidation("publication record field optedInCooks is malformed");
  }
  const cooks: Record<string, string> = {};
  for (const [cookId, day] of Object.entries(value as Record<string, unknown>)) {
    if (typeof day !== "string" || Number.isNaN(Date.parse(day))) {
      throw errValidation("publication record field optedInCooks is malformed");
    }
    cooks[cookId] = day;
  }
  return cooks;
}

/** Validating read of a publication document (README rule 5). */
export function parsePublicationDoc(snap: DocumentSnapshot): PublicationRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  const status = readStringField(data, "status");
  if (!STATUSES.includes(status as PublicationStatus)) {
    throw errValidation(`publication record field status is malformed: ${status}`);
  }
  return {
    publicationId: snap.id as PublicationId,
    revisionId: readStringField(data, "revisionId") as RecipeRevisionId,
    authorId: readStringField(data, "authorId") as AccountId,
    sourceRecipeId: readStringField(data, "sourceRecipeId"),
    sourceRecipeRevision: readStringField(data, "sourceRecipeRevision"),
    title: readStringField(data, "title"),
    summary: readStringOrNull(data, "summary"),
    note: readStringOrNull(data, "note"),
    ingredientLines: readStringArray(data, "ingredientLines"),
    steps: readStringArray(data, "steps"),
    tags: readStringArray(data, "tags"),
    campus: readStringOrNull(data, "campus"),
    status: status as PublicationStatus,
    screeningFailures: readScreeningFailures(data),
    createdAtIso: readStringField(data, "createdAtIso"),
    publishedAtIso: readIsoOrNull(data, "publishedAtIso"),
    withdrawnAtIso: readIsoOrNull(data, "withdrawnAtIso"),
    rejectedAtIso: readIsoOrNull(data, "rejectedAtIso"),
    optedInCooks: readOptedInCooks(data),
  };
}

/**
 * Creates the publication with its final status in one write. Uniqueness: one
 * live publication per (author, source recipe revision); withdrawn
 * publications keep their tombstone and do not block a fresh publish.
 */
export async function createPublication(deps: PublicationDeps, input: NewPublicationInput): Promise<CreatePublicationResult> {
  const existing = await deps.publications.where("authorId", "==", input.authorId).get();
  for (const doc of existing.docs) {
    if (
      doc.get("sourceRecipeId") === input.sourceRecipeId &&
      doc.get("sourceRecipeRevision") === input.sourceRecipeRevision &&
      doc.get("status") !== "withdrawn"
    ) {
      throw errConflict("this recipe revision is already published");
    }
  }

  const nowIso = toIso(deps.clock.now());
  const screenable = {
    title: input.title,
    summary: [input.summary, input.note].filter((s) => s !== null).join(" ").trim() || null,
    ingredientLines: input.ingredientLines,
    steps: input.steps,
  };
  const result = await runScreeningPipeline([textHygieneStage(), ...input.screeningStages], screenable);
  const failures: readonly ScreeningFailure[] = result.passed ? [] : result.failures;

  const publicationId = newPublicationId();
  const revisionId = newRecipeRevisionId();
  const record: PublicationRecord = {
    publicationId,
    revisionId,
    authorId: input.authorId,
    sourceRecipeId: input.sourceRecipeId,
    sourceRecipeRevision: input.sourceRecipeRevision,
    title: input.title,
    summary: input.summary,
    note: input.note,
    ingredientLines: input.ingredientLines,
    steps: input.steps,
    tags: input.tags,
    campus: input.campus,
    status: result.passed ? "published" : "queued",
    screeningFailures: failures,
    createdAtIso: nowIso,
    publishedAtIso: result.passed ? nowIso : null,
    withdrawnAtIso: null,
    rejectedAtIso: null,
    optedInCooks: {},
  };
  await deps.publications.doc(publicationId).create({
    authorId: record.authorId,
    revisionId: record.revisionId,
    sourceRecipeId: record.sourceRecipeId,
    sourceRecipeRevision: record.sourceRecipeRevision,
    title: record.title,
    summary: record.summary,
    note: record.note,
    ingredientLines: record.ingredientLines,
    steps: record.steps,
    tags: record.tags,
    campus: record.campus,
    status: record.status,
    screeningFailures: record.screeningFailures,
    createdAtIso: record.createdAtIso,
    publishedAtIso: record.publishedAtIso,
    withdrawnAtIso: null,
    rejectedAtIso: null,
    optedInCooks: {},
  });
  return result.passed ? { outcome: "published", record } : { outcome: "queued", record, failures };
}

export async function getPublication(deps: PublicationDeps, publicationId: PublicationId): Promise<PublicationRecord | null> {
  const snap = await deps.publications.doc(publicationId).get();
  return parsePublicationDoc(snap);
}

/** The author's own publications, any status, newest first. */
export async function listOwnPublications(deps: PublicationDeps, authorId: AccountId): Promise<PublicationRecord[]> {
  const snap = await deps.publications.where("authorId", "==", authorId).get();
  return snap.docs
    .map((doc) => parsePublicationDoc(doc))
    .filter((r): r is PublicationRecord => r !== null)
    .sort(compareNewestFirst);
}

/** Live (published) publications in one campus, candidates for the feed. */
export async function listPublishedByCampus(deps: PublicationDeps, campus: string): Promise<PublicationRecord[]> {
  const snap = await deps.publications.where("campus", "==", campus).get();
  return snap.docs
    .map((doc) => parsePublicationDoc(doc))
    .filter((r): r is PublicationRecord => r !== null)
    .filter((r) => r.status === "published")
    .sort(compareNewestFirst);
}

function compareNewestFirst(a: PublicationRecord, b: PublicationRecord): number {
  if (a.createdAtIso !== b.createdAtIso) {
    return a.createdAtIso < b.createdAtIso ? 1 : -1;
  }
  return a.publicationId < b.publicationId ? 1 : -1;
}

export type WithdrawOutcome =
  | { readonly outcome: "ok"; readonly record: PublicationRecord }
  | { readonly outcome: "missing" }
  | { readonly outcome: "forbidden" };

/**
 * Author withdrawal (SPEC 3.4: "can be withdrawn at any time"). Tombstone:
 * the document survives with status withdrawn. Idempotent — withdrawing an
 * already-withdrawn publication converges to the same state.
 */
export async function withdrawPublication(deps: PublicationDeps, publicationId: PublicationId, authorId: AccountId): Promise<WithdrawOutcome> {
  const doc = deps.publications.doc(publicationId);
  const nowIso = toIso(deps.clock.now());
  const record = await deps.publications.firestore.runTransaction(async (tx): Promise<WithdrawOutcome> => {
    const snap = await tx.get(doc);
    const existing = parsePublicationDoc(snap);
    if (existing === null) {
      return { outcome: "missing" };
    }
    if (existing.authorId !== authorId) {
      return { outcome: "forbidden" };
    }
    if (existing.status !== "withdrawn") {
      tx.update(doc, { status: "withdrawn", withdrawnAtIso: nowIso });
    }
    return { outcome: "ok", record: existing };
  });
  return record;
}

/**
 * The moderation decision transition, registered as the queue's decision
 * handler at wiring time. Guarded: only a queued publication moves, so a
 * concurrent withdrawal always wins and a re-fired decision is a no-op.
 */
export async function transitionOnDecision(deps: PublicationDeps, target: PublicationRef, decision: ModerationDecisionKind): Promise<void> {
  const doc = deps.publications.doc(target.publicationId);
  const nowIso = toIso(deps.clock.now());
  await deps.publications.firestore.runTransaction(async (tx) => {
    const snap = await tx.get(doc);
    const existing = parsePublicationDoc(snap);
    if (existing === null || existing.status !== "queued") {
      return;
    }
    if (existing.revisionId !== target.revisionId) {
      return;
    }
    if (decision === "approved") {
      tx.update(doc, { status: "published", publishedAtIso: nowIso });
    } else {
      tx.update(doc, { status: "rejected", rejectedAtIso: nowIso });
    }
  });
}

/**
 * Hides a live publication when it enters the moderation queue (a report or
 * flag arrived — SPEC 3.4: "reports hide it pending review"). Guarded to
 * published → queued so withdrawals and decisions are never overwritten.
 */
export async function hidePublicationForModeration(deps: PublicationDeps, target: PublicationRef, atIso: string): Promise<void> {
  const doc = deps.publications.doc(target.publicationId);
  await deps.publications.firestore.runTransaction(async (tx) => {
    const snap = await tx.get(doc);
    const existing = parsePublicationDoc(snap);
    if (existing === null || existing.status !== "published") {
      return;
    }
    tx.update(doc, { status: "queued", updatedAtIso: atIso });
  });
}
