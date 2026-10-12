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
import { createHash } from "node:crypto";
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
import type { ModerationDecisionKind, PublicationRef, ScreenablePublication, ScreeningStage } from "../shared/contracts.js";
import { runScreeningPipeline, textHygieneStage, type ScreeningFailure, type ScreeningStageOutcome } from "./screening.js";

export type PublicationStatus = "published" | "queued" | "rejected" | "withdrawn";

/**
 * The one derivation of publication visibility from moderation state (PR #104
 * review blocker 5). `status` is the publication's whole moderation state;
 * every visibility answer — the Explore feed, direct reads, the author's own
 * view, the moderation queue's pending set, cook-occurrence and report
 * liveness — is this table's output and nothing else. No surface may consult
 * another field or a flag of its own, and no writer stores a visibility bit:
 * a moderation-state change is the only thing that can change visibility.
 */
export interface PublicationVisibility {
  /** Readers see it: the campus feed, direct reads by non-authors, and the live surfaces that feed it (cook occurrences, new reports). */
  readonly visibleToReaders: boolean;
  /** The author sees their own record whatever its moderation state (SPEC 3.4). */
  readonly visibleToAuthor: boolean;
  /** It is pending a human decision: it belongs to the open moderation queue. */
  readonly inModerationQueue: boolean;
}

export function publicationVisibility(status: PublicationStatus): PublicationVisibility {
  switch (status) {
    case "published":
      return { visibleToReaders: true, visibleToAuthor: true, inModerationQueue: false };
    case "queued":
      return { visibleToReaders: false, visibleToAuthor: true, inModerationQueue: true };
    case "rejected":
    case "withdrawn":
      return { visibleToReaders: false, visibleToAuthor: true, inModerationQueue: false };
  }
}

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
  /**
   * Compound-allergen tags derived by the mandatory food-safety gate's
   * allergen stage at publish time (from the ingredient-facts package).
   * Persisted with the publication — never recomputed at read time, so the
   * response always reflects the evaluation that admitted it.
   */
  readonly allergenTags: readonly string[];
  readonly campus: string | null;
  readonly status: PublicationStatus;
  readonly screeningFailures: readonly ScreeningFailure[];
  readonly createdAtIso: string;
  readonly publishedAtIso: string | null;
  readonly withdrawnAtIso: string | null;
  readonly rejectedAtIso: string | null;
  readonly optedInCooks: Readonly<Record<string, string>>;
  /**
   * The screening evaluation bound to the exact content it judged, recorded
   * at creation. Null on records that predate it — such a record cannot
   * prove a passing food-safety lint at its current revision, so approval
   * refuses it (fail closed).
   */
  readonly screenedEvaluation: ScreenedEvaluation | null;
}

/**
 * The record of one pipeline run: every stage that executed, in order, with
 * its verdict, bound to a hash of the exact screenable content it judged.
 * Approval consults it to verify a passing food-safety lint at the exact
 * revision being approved — visibility still derives solely from moderation
 * state; this only gates whether approval may change that state.
 */
export interface ScreenedEvaluation {
  readonly contentHash: string;
  readonly stages: readonly ScreeningStageOutcome[];
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

function stringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    throw errValidation(`publication record field ${field} is missing or malformed`);
  }
  return value as string[];
}

function readStringArray(data: Record<string, unknown>, field: string): string[] {
  return stringArray(data[field], field);
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

/**
 * Allergen tags written by the publish gate. Documents from before the gate
 * existed may lack the field; they read as untagged rather than invalid.
 */
function readAllergenTags(data: Record<string, unknown>): string[] {
  const value = data["allergenTags"];
  if (value === undefined || value === null) {
    return [];
  }
  return stringArray(value, "allergenTags");
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
    allergenTags: readAllergenTags(data),
    campus: readStringOrNull(data, "campus"),
    status: status as PublicationStatus,
    screeningFailures: readScreeningFailures(data),
    createdAtIso: readStringField(data, "createdAtIso"),
    publishedAtIso: readIsoOrNull(data, "publishedAtIso"),
    withdrawnAtIso: readIsoOrNull(data, "withdrawnAtIso"),
    rejectedAtIso: readIsoOrNull(data, "rejectedAtIso"),
    optedInCooks: readOptedInCooks(data),
    screenedEvaluation: readScreenedEvaluation(data),
  };
}

/**
 * The recorded screening evaluation. Null when the field is absent (a record
 * created before it existed); malformed data throws like any other malformed
 * field.
 */
function readScreenedEvaluation(data: Record<string, unknown>): ScreenedEvaluation | null {
  const raw = data["screenedEvaluation"];
  if (raw === undefined || raw === null) {
    return null;
  }
  if (typeof raw !== "object") {
    throw errValidation("publication record field screenedEvaluation is malformed");
  }
  const value = raw as { contentHash?: unknown; stages?: unknown };
  if (typeof value.contentHash !== "string" || value.contentHash.length === 0 || !Array.isArray(value.stages)) {
    throw errValidation("publication record field screenedEvaluation is malformed");
  }
  const stages: ScreeningStageOutcome[] = [];
  for (const entry of value.stages) {
    if (typeof entry !== "object" || entry === null) {
      throw errValidation("publication record field screenedEvaluation is malformed");
    }
    const outcome = entry as { name?: unknown; passed?: unknown };
    if (typeof outcome.name !== "string" || typeof outcome.passed !== "boolean") {
      throw errValidation("publication record field screenedEvaluation is malformed");
    }
    stages.push({ name: outcome.name, passed: outcome.passed });
  }
  return { contentHash: value.contentHash, stages };
}

/**
 * The screenable projection of a publication — exactly the content the
 * screening pipeline judged. Creation and the approval-side check both use
 * it, so a hash recorded at creation still describes the record's content
 * at approval time unless the record was mutated underneath.
 */
export function screenablePublicationOf(
  publication: Pick<PublicationRecord, "title" | "summary" | "note" | "ingredientLines" | "steps">,
): ScreenablePublication {
  return {
    title: publication.title,
    summary: [publication.summary, publication.note].filter((s) => s !== null).join(" ").trim() || null,
    ingredientLines: publication.ingredientLines,
    steps: publication.steps,
  };
}

/** A stable hash of the exact screenable content a pipeline run judged. */
export function contentHashOf(screenable: ScreenablePublication): string {
  return createHash("sha256")
    .update(JSON.stringify([screenable.title, screenable.summary, screenable.ingredientLines, screenable.steps]))
    .digest("hex");
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
  const screenable = screenablePublicationOf(input);
  const result = await runScreeningPipeline([textHygieneStage(), ...input.screeningStages], screenable);
  const failures: readonly ScreeningFailure[] = result.passed ? [] : result.failures;
  // Tags produced by passing stages — for the mandatory gate, the
  // compound-allergen tags. Deduped and sorted so the persisted form is
  // deterministic regardless of stage order.
  const allergenTags: readonly string[] = [...new Set(result.tags)].sort();

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
    allergenTags,
    campus: input.campus,
    status: result.passed ? "published" : "queued",
    screeningFailures: failures,
    screenedEvaluation: {
      contentHash: contentHashOf(screenable),
      stages: result.stageOutcomes,
    },
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
    allergenTags: record.allergenTags,
    campus: record.campus,
    status: record.status,
    screeningFailures: record.screeningFailures,
    screenedEvaluation: record.screenedEvaluation,
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

/** Reader-visible (live) publications in one campus, candidates for the feed. */
export async function listPublishedByCampus(deps: PublicationDeps, campus: string): Promise<PublicationRecord[]> {
  const snap = await deps.publications.where("campus", "==", campus).get();
  return snap.docs
    .map((doc) => parsePublicationDoc(doc))
    .filter((r): r is PublicationRecord => r !== null)
    .filter((r) => publicationVisibility(r.status).visibleToReaders)
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
    // A decision moves a publication only out of the queue — the source
    // state's meaning comes from the derivation, not a local comparison.
    if (existing === null || !publicationVisibility(existing.status).inModerationQueue) {
      return;
    }
    if (existing.revisionId !== target.revisionId) {
      return;
    }
    if (decision === "approved") {
      // Blocker 1: approval publishes only when the recorded screening
      // proves a passing food-safety lint at exactly this content. A failed
      // lint, a stale pass on an older revision, or a record that cannot
      // prove the mandatory gate ran all refuse the approval — the decision
      // does not land, the item stays open, and nothing is written.
      const refusal = approvalRefusal(existing);
      if (refusal !== null) {
        throw errConflict(refusal);
      }
      tx.update(doc, { status: "published", publishedAtIso: nowIso });
    } else {
      tx.update(doc, { status: "rejected", rejectedAtIso: nowIso });
    }
  });
}

/**
 * Stage names owned by the food-safety gate (foodSafety/gate.ts) — the
 * mandatory screening no human decision may overrule. Referenced by name so
 * approval can verify they ran and passed at the exact content being
 * approved; gate.ts internals are not touched.
 */
const MANDATORY_FOOD_SAFETY_STAGES = ["food-safety-lint", "compound-allergens"] as const;

/**
 * The approval-side food-safety check (PR #104 review blocker 1): approval
 * may publish only when the recorded evaluation proves the mandatory
 * food-safety lint passed at the exact content being approved. Returns null
 * when approval may proceed, otherwise the refusal reason. Fails closed —
 * no recorded evaluation, an evaluation bound to older content, a missing
 * mandatory stage, or a failing one all refuse.
 */
export function approvalRefusal(record: PublicationRecord): string | null {
  const evaluation = record.screenedEvaluation;
  if (evaluation === null) {
    return "approval refused: no screening evaluation is recorded for this publication, so a passing food-safety lint at its current revision cannot be verified";
  }
  if (evaluation.contentHash !== contentHashOf(screenablePublicationOf(record))) {
    return "approval refused: the recorded screening was produced for an older revision of this content; approval requires a passing lint at the exact revision";
  }
  for (const stageName of MANDATORY_FOOD_SAFETY_STAGES) {
    const outcome = evaluation.stages.find((stage) => stage.name === stageName);
    if (outcome === undefined) {
      return `approval refused: the mandatory food-safety stage "${stageName}" did not run for this publication`;
    }
    if (!outcome.passed) {
      return `approval refused: the mandatory food-safety stage "${stageName}" does not pass at this revision`;
    }
  }
  return null;
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
    // Only a reader-visible publication can be hidden by an incoming report
    // or flag — withdrawals and decisions are never overwritten.
    if (existing === null || !publicationVisibility(existing.status).visibleToReaders) {
      return;
    }
    tx.update(doc, { status: "queued", updatedAtIso: atIso });
  });
}
