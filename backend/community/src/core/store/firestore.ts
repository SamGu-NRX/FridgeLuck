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

/** Per-runTransaction state: the SDK Transaction plus the write journal the
 * seam's read-your-writes guarantee needs (the SDK forbids reads after
 * writes). One instance per runTransaction call, so SDK retries start clean. */
class TxView {
  journal = new Map<string, DocData | null>();
  writesQueued = false;
  constructor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    readonly t: any,
  ) {}
}

class FirestoreQuery implements StoreQuery {
  private filters: Array<{ field: string; value: unknown }>;
  private max: number | null;
  constructor(
    private readonly coll: { where(field: string, op: string, value: unknown): unknown; limit(n: number): unknown },
    filters: Array<{ field: string; value: unknown }>,
    max: number | null,
    // Transactional (t.get(q)) when this query rides a runTransaction; queries
    // must precede writes — the SDK's own rule.
    private readonly view: TxView | null = null,
  ) {
    this.filters = filters;
    this.max = max;
  }
  where(field: string, value: unknown): StoreQuery {
    return new FirestoreQuery(this.coll, [...this.filters, { field, value }], this.max, this.view);
  }
  limit(n: number): StoreQuery {
    return new FirestoreQuery(this.coll, this.filters, n, this.view);
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
    const snap = this.view ? await this.view.t.get(q) : await q.get();
    return snap.docs.map((d: { id: string; data(): DocData }) => ({ id: d.id, data: d.data() }));
  }
}

class FirestoreDocRef implements StoreDocRef {
  constructor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    private readonly ref: any,
    readonly id: string,
    // Bound when this ref rides a runTransaction: every operation routes
    // through view.t (reads see committed state, a thrown fn commits nothing,
    // concurrent fns retry on contention) while doc reads and writes track
    // view.journal for read-your-writes.
    private readonly view: TxView | null = null,
  ) {}

  async get(): Promise<StoreDoc> {
    if (this.view) {
      const cached = this.view.journal.get(this.ref.path);
      if (cached !== undefined) {
        return { id: this.id, data: cached };
      }
      const snap = await this.view.t.get(this.ref);
      const data = snap.exists ? (snap.data() as DocData) : null;
      this.view.journal.set(this.ref.path, data);
      return { id: this.id, data };
    }
    const snap = await this.ref.get();
    return { id: this.id, data: snap.exists ? (snap.data() as DocData) : null };
  }
  async create(data: DocData): Promise<boolean> {
    if (this.view) {
      // Existence resolves at commit: queue the create; if the doc already
      // exists the commit fails and the SDK retries the whole fn.
      this.view.journal.set(this.ref.path, { ...data });
      this.view.t.create(this.ref, data);
      this.view.writesQueued = true;
      return true;
    }
    try {
      await this.ref.create(data);
      return true;
    } catch {
      return false;
    }
  }
  async set(data: DocData): Promise<void> {
    if (this.view) {
      this.view.journal.set(this.ref.path, { ...data });
      this.view.t.set(this.ref, data);
      this.view.writesQueued = true;
      return;
    }
    await this.ref.set(data);
  }
  async update(data: DocData): Promise<void> {
    if (this.view) {
      // The journal must carry the doc's full post-update state for later
      // reads; fetch current state only while reads are still allowed (no
      // writes queued yet), else merge onto whatever the journal already has.
      if (!this.view.journal.has(this.ref.path) && !this.view.writesQueued) {
        const snap = await this.view.t.get(this.ref);
        this.view.journal.set(this.ref.path, snap.exists ? (snap.data() as DocData) : null);
      }
      const current = this.view.journal.get(this.ref.path) ?? null;
      this.view.journal.set(this.ref.path, current === null ? null : { ...current, ...data });
      this.view.t.update(this.ref, data);
      this.view.writesQueued = true;
      return;
    }
    await this.ref.update(data);
  }
}

class FirestoreCollection implements StoreCollection {
  constructor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    private readonly coll: any,
    readonly id: string,
    private readonly view: TxView | null = null,
  ) {}

  doc(id: string): StoreDocRef {
    return new FirestoreDocRef(this.coll.doc(id), id, this.view);
  }
  where(field: string, value: unknown): StoreQuery {
    return new FirestoreQuery(this.coll, [{ field, value }], null, this.view);
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
<<<<<<< HEAD
      const tx: StoreTransaction = {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        collection: (cid: string) => new FirestoreCollection((t as any).collection(cid), cid),
=======
      // Doc refs and queries are path-based (the Transaction object exposes no
      // collection() factory), but the transactional view binds every ref and
      // query to the SDK Transaction t. One TxView per runTransaction call;
      // SDK retries rebuild it, so journals never leak across attempts.
      const view = new TxView(t);
      const tx: StoreTransaction = {
        collection: (cid: string) => new FirestoreCollection(this.fs.collection(cid), cid, view),
>>>>>>> f1e2e31 (fix(community): honour the StoreTransaction seam on Firestore)
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
