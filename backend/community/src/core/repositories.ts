/**
 * The module-facing repository interfaces (SPEC §7.3 / §11.1). Both are
 * implemented once over the DocumentStore seam (one implementation serves
 * Firestore and in-memory, because they differ only in the store below);
 * the interfaces are the seam modules code against.
 */

import type { RecipeContent, RecipeRef, PublicationState } from "./contract.js";

/** The stored publication document (server-side; the declaration never leaves). */
export interface PublicationRecord {
  readonly publicationId: string;
  readonly authorId: string;
  readonly authorDisplayName: string;
  readonly recipeRef: RecipeRef;
  /** Frozen revision content (SPEC §2.2: published revisions are immutable). */
  readonly content: RecipeContent;
  readonly declaration: { readonly ownRights: boolean; readonly noPersonalData: boolean };
  readonly state: PublicationState;
  readonly allergenTags: readonly string[];
  readonly flaggedTag: string | null;
  readonly challengeId: string | null;
  readonly createdAt: string;
  readonly publishedAt: string;
  readonly withdrawnAt: string | null;
  readonly contentHash: string;
  readonly screening: readonly { readonly check: string; readonly verdict: string; readonly detail: string | null }[];
  /** Distinct opted-in cook account ids → UTC day (written by aggregate tooling, never served raw). */
  readonly optedInCooks: Readonly<Record<string, string>>;
}

/**
 * SPEC §11.1: `PublicationRepository` (create, publish, queue, reject,
 * withdraw, get). `create` runs screening and lands directly in `published`
 * or `queued` — one write, no half-published state (PR #104).
 */
export interface PublicationRepository {
  get(publicationId: string): Promise<PublicationRecord | null>;
  listByAuthor(authorId: string): Promise<PublicationRecord[]>;
  /** Adds an opted-in distinct cook (aggregate tooling; never per-user attributed). */
  addOptedInCook(publicationId: string, cookAccountId: string, dayIso: string): Promise<void>;
}

/** SPEC §11.1: `ExploreRepository` (feedCandidates, cookCount). */
export interface ExploreRepository {
  /** Reader-visible published publications, newest first, capped at 500 (SPEC §3.3). */
  feedCandidates(): Promise<PublicationRecord[]>;
  /** Distinct-cook count, null below the floor of 10 — never a small number (SPEC §3.2). */
  cookCount(publicationId: string): Promise<number | null>;
}
