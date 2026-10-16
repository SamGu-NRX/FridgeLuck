/**
 * The store seam (SPEC §7.3): every module talks to its store through this
 * document-store interface. Production implements it with Cloud Firestore
 * (`firestore.ts`); tests use the in-memory implementation (`memory.ts`).
 * Modules never import `@google-cloud/firestore` directly — the interface is
 * what makes a later store swap a bounded change instead of a rewrite.
 */

export type DocData = Record<string, unknown>;

export interface StoreDoc {
  readonly id: string;
  readonly data: DocData | null;
}

export interface StoreQuery {
  /** Adds an equality filter. Chaining multiple where()s ANDs them. */
  where(field: string, value: unknown): StoreQuery;
  limit(n: number): StoreQuery;
  get(): Promise<StoreDoc[]>;
}

export interface StoreCollection {
  readonly id: string;
  doc(id: string): StoreDocRef;
  where(field: string, value: unknown): StoreQuery;
}

export interface StoreDocRef {
  get(): Promise<StoreDoc>;
  /** Fails (returns false) when the document already exists. */
  create(data: DocData): Promise<boolean>;
  set(data: DocData): Promise<void>;
  update(data: DocData): Promise<void>;
}

/**
 * A transactional view of the store. Reads inside the transaction see the
 * transaction's own writes; on a thrown error nothing commits (the in-memory
 * store rolls back via a journal — the property the moderation decision
 * test relies on).
 */
export interface StoreTransaction {
  collection(id: string): StoreCollection;
}

export interface DocumentStore {
  collection(id: string): StoreCollection;
  runTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T>;
}
