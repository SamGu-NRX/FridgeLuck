/**
 * Store-backed implementations of the repositories, shared by the modules.
 * Firestore and the in-memory store differ only below the DocumentStore
 * seam, so one implementation serves both (SPEC §7.4).
 */

import { errConflict, errNotFound } from "./errors.js";
import type { DocumentStore, StoreCollection, StoreTransaction } from "./store/documentStore.js";
import type { Clock } from "./time.js";
import { contentHashOf } from "./screening.js";
import type { ScreeningResult } from "./screening.js";
import { publicationIdShape } from "./ids.js";
import type { PublicationRecord, PublicationRepository, ExploreRepository } from "./repositories.js";
import type { RecipeContent, RecipeRef, PublicationState } from "./contract.js";

export const PUBLICATIONS_COLLECTION = "publications";
export const CASES_COLLECTION = "cases";
export const OPERATIONS_COLLECTION = "operations";
export const REPORTS_COLLECTION = "reports";
export const BLOCKS_COLLECTION = "blocks";
export const COOK_COUNTS_COLLECTION = "cookCounts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DocDataLike = any;

function parsePublication(id: string, data: DocDataLike): PublicationRecord {
  return data as PublicationRecord; // stored under our own write path; shape asserted by view mapping on read-out
}

export class StorePublicationRepository implements PublicationRepository {
  private readonly collection: StoreCollection;

  constructor(private readonly deps: { readonly store: DocumentStore; readonly clock: Clock }) {
    this.collection = deps.store.collection(PUBLICATIONS_COLLECTION);
  }

  async get(publicationId: string): Promise<PublicationRecord | null> {
    const snap = await this.collection.doc(publicationId).get();
    return snap.data === null ? null : parsePublication(snap.id, snap.data);
  }

  async require(publicationId: string): Promise<PublicationRecord> {
    const record = await this.get(publicationId);
    if (record === null) {
      throw errNotFound("publication not found");
    }
    return record;
  }

  async listByAuthor(authorId: string): Promise<PublicationRecord[]> {
    const docs = await this.collection.where("authorId", authorId).get();
    return docs.map((d) => parsePublication(d.id, d.data));
  }

  /**
   * The publish decision (SPEC §2.4, PR #104's one-write rule): screening
   * runs first; the record lands directly in `published` or `queued` —
   * never a half-published intermediate state.
   */
  private buildRecord(input: {
    authorId: string;
    authorDisplayName: string;
    recipeRef: RecipeRef;
    content: RecipeContent;
    declaration: { ownRights: boolean; noPersonalData: boolean };
    screening: ScreeningResult;
    challengeId: string | null;
  }): PublicationRecord {
    const nowIso = this.deps.clock.now().toISOString();
    const state: PublicationState = input.screening.blocked ? "queued" : "published";
    return {
      publicationId: publicationIdShape.newId(),
      authorId: input.authorId,
      authorDisplayName: input.authorDisplayName,
      recipeRef: input.recipeRef,
      content: input.content,
      declaration: input.declaration,
      state,
      allergenTags: input.screening.allergenTags,
      flaggedTag: input.screening.flaggedTag,
      challengeId: input.challengeId,
      createdAt: nowIso,
      publishedAt: state === "published" ? nowIso : "",
      withdrawnAt: null,
      contentHash: contentHashOf(input.content),
      screening: input.screening.outcomes,
      optedInCooks: {},
    };
  }

  async create(input: {
    authorId: string;
    authorDisplayName: string;
    recipeRef: RecipeRef;
    content: RecipeContent;
    declaration: { ownRights: boolean; noPersonalData: boolean };
    screening: ScreeningResult;
    challengeId: string | null;
  }): Promise<PublicationRecord> {
    const record = this.buildRecord(input);
    await this.collection.doc(record.publicationId).create({ ...record });
    return record;
  }

  /**
   * Creates the publication inside a caller-owned transaction (review finding
   * 6): the publish handler reserves the operation, the publication, and the
   * moderation case in one commit, so a concurrent twin with the same
   * operationId can never strand two publications.
   */
  async createWithin(
    tx: StoreTransaction,
    input: Parameters<StorePublicationRepository["create"]>[0],
  ): Promise<PublicationRecord> {
    const record = this.buildRecord(input);
    await tx.collection(PUBLICATIONS_COLLECTION).doc(record.publicationId).create({ ...record });
    return record;
  }

  async setState(publicationId: string, state: PublicationState, atIso: string): Promise<PublicationRecord> {
    return this.deps.store.runTransaction(async (tx) => {
      const snap = await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).get();
      if (snap.data === null) {
        throw errNotFound("publication not found");
      }
      const record = parsePublication(snap.id, snap.data);
      if (record.state !== "published" && record.state !== "queued" && record.state !== "rejected" && state !== "published") {
        throw errConflict("conflict", `publication is ${record.state}; no further transitions`);
      }
      const patch: Record<string, unknown> = { state };
      if (state === "withdrawn") {
        patch.withdrawnAt = atIso;
      }
      if (state === "published" && record.publishedAt === "") {
        patch.publishedAt = atIso;
      }
      await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).update(patch);
      return { ...record, ...(patch as Partial<PublicationRecord>) };
    });
  }

  /** Idempotent approval: same state+hash → no-op; different hash → 409 (PR #104's hash-bound approval). */
  async approveIfHashMatches(publicationId: string, contentHash: string): Promise<"approved" | "already-approved" | "hash-mismatch" | "rejected"> {
    return this.deps.store.runTransaction(async (tx) => {
      const snap = await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).get();
      if (snap.data === null) {
        throw errNotFound("publication not found");
      }
      const record = parsePublication(snap.id, snap.data);
      if (record.state === "rejected") {
        return "rejected" as const;
      }
      if (record.state === "published") {
        return record.contentHash === contentHash ? ("already-approved" as const) : ("hash-mismatch" as const);
      }
      if (record.state !== "queued") {
        return "hash-mismatch" as const;
      }
      if (record.contentHash !== contentHash) {
        return "hash-mismatch" as const;
      }
      await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).update({ state: "published", publishedAt: this.deps.clock.now().toISOString() });
      return "approved" as const;
    });
  }

  async addOptedInCook(publicationId: string, cookAccountId: string, dayIso: string): Promise<void> {
    await this.deps.store.runTransaction(async (tx) => {
      const snap = await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).get();
      if (snap.data === null) {
        throw errNotFound("publication not found");
      }
      const record = parsePublication(snap.id, snap.data);
      if (record.optedInCooks[cookAccountId] !== undefined) {
        return;
      }
      const cooks = { ...record.optedInCooks, [cookAccountId]: dayIso };
      await tx.collection(PUBLICATIONS_COLLECTION).doc(publicationId).update({ optedInCooks: cooks });
    });
  }
}

export class StoreExploreRepository implements ExploreRepository {
  private readonly publications: StoreCollection;

  constructor(store: DocumentStore) {
    this.publications = store.collection(PUBLICATIONS_COLLECTION);
  }

  async feedCandidates(): Promise<PublicationRecord[]> {
    const docs = await this.publications.where("state", "published").get();
    const records = docs.map((d) => parsePublication(d.id, d.data));
    records.sort((a, b) => b.publishedAt.localeCompare(a.publishedAt) || a.publicationId.localeCompare(b.publicationId));
    return records.slice(0, 500);
  }

  /** SPEC §3.2: below the floor of 10 the count is null — "10+ people" or nothing. */
  async cookCount(publicationId: string): Promise<number | null> {
    const snap = await this.publications.doc(publicationId).get();
    if (snap.data === null) {
      return null;
    }
    const record = parsePublication(snap.id, snap.data);
    const distinct = new Set(Object.keys(record.optedInCooks)).size;
    return distinct >= 10 ? distinct : null;
  }
}
