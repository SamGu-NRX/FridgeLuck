/**
 * Cloud Firestore implementation of the DocumentStore seam (SPEC §7.3).
 *
 * The import is dynamic and type-only at the surface: the community package
 * depends on `@google-cloud/firestore` like gemini-agent does, but tests and
 * local runs never construct this adapter — they use MemoryStore. The
 * adapter honours FIRESTORE_EMULATOR_HOST automatically (the SDK reads that
 * env var), which is how the integration tier runs without GCP credentials.
 */

import type { Firestore } from "@google-cloud/firestore";
import type { DocData, DocumentStore, StoreCollection, StoreDoc, StoreDocRef, StoreQuery, StoreTransaction } from "./documentStore.js";

export interface FirestoreStoreOptions {
  readonly firestore: Firestore;
}

class FirestoreQuery implements StoreQuery {
  private filters: Array<{ field: string; value: unknown }>;
  private max: number | null;
  constructor(
    private readonly coll: { where(field: string, op: string, value: unknown): unknown; limit(n: number): unknown },
    filters: Array<{ field: string; value: unknown }>,
    max: number | null,
  ) {
    this.filters = filters;
    this.max = max;
  }
  where(field: string, value: unknown): StoreQuery {
    return new FirestoreQuery(this.coll, [...this.filters, { field, value }], this.max);
  }
  limit(n: number): StoreQuery {
    return new FirestoreQuery(this.coll, this.filters, n);
  }
  async get(): Promise<StoreDoc[]> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let q: any = this.coll;
    for (const f of this.filters) {
      q = q.where(f.field, "==", f.value);
    }
    if (this.max !== null) {
      q = q.limit(this.max);
    }
    const snap = await q.get();
    return snap.docs.map((d: { id: string; data(): DocData }) => ({ id: d.id, data: d.data() }));
  }
}

class FirestoreDocRef implements StoreDocRef {
  constructor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    private readonly ref: any,
    readonly id: string,
  ) {}

  async get(): Promise<StoreDoc> {
    const snap = await this.ref.get();
    return { id: this.id, data: snap.exists ? (snap.data() as DocData) : null };
  }
  async create(data: DocData): Promise<boolean> {
    try {
      await this.ref.create(data);
      return true;
    } catch {
      return false;
    }
  }
  async set(data: DocData): Promise<void> {
    await this.ref.set(data);
  }
  async update(data: DocData): Promise<void> {
    await this.ref.update(data);
  }
}

class FirestoreCollection implements StoreCollection {
  constructor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    private readonly coll: any,
    readonly id: string,
  ) {}

  doc(id: string): StoreDocRef {
    return new FirestoreDocRef(this.coll.doc(id), id);
  }
  where(field: string, value: unknown): StoreQuery {
    return new FirestoreQuery(this.coll, [{ field, value }], null);
  }
}

export class FirestoreStore implements DocumentStore {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private readonly fs: any;
  constructor(options: FirestoreStoreOptions) {
    this.fs = options.firestore;
  }

  collection(id: string): StoreCollection {
    return new FirestoreCollection(this.fs.collection(id), id);
  }

  runTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T> {
    return this.fs.runTransaction(async (t: unknown): Promise<T> => {
      const tx: StoreTransaction = {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        collection: (cid: string) => new FirestoreCollection((t as any).collection(cid), cid),
      };
      return fn(tx);
    });
  }
}

/** Builds the production store from the environment; never in tests. */
export async function openFirestoreStore(projectId: string): Promise<FirestoreStore> {
  const { Firestore } = await import("@google-cloud/firestore");
  const firestore = new Firestore({ projectId });
  return new FirestoreStore({ firestore });
}
