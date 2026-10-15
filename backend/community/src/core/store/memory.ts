/**
 * In-memory DocumentStore: zero-infrastructure store for the unit-test tier
 * (SPEC §7.3) and for local runs without the Firestore emulator.
 *
 * Transactions take a per-store mutex and run against the live maps with a
 * rollback journal: a thrown error restores every document the transaction
 * touched, so "decision committed in one transaction with visibility" is
 * actually atomic here, not just on Firestore.
 */

import type {
  DocData,
  DocumentStore,
  StoreCollection,
  StoreDoc,
  StoreDocRef,
  StoreQuery,
  StoreTransaction,
} from "./documentStore.js";

interface Filter {
  readonly field: string;
  readonly value: unknown;
}

class MemoryQuery implements StoreQuery {
  private readonly table: Map<string, DocData>;
  private readonly filters: readonly Filter[];
  private readonly max: number | null;
  constructor(
    table: Map<string, DocData>,
    filters: readonly Filter[],
    max: number | null,
  ) {
    this.table = table;
    this.filters = filters;
    this.max = max;
  }
  where(field: string, value: unknown): StoreQuery {
    return new MemoryQuery(this.table, [...this.filters, { field, value }], this.max);
  }
  limit(n: number): StoreQuery {
    return new MemoryQuery(this.table, this.filters, n);
  }
  async get(): Promise<StoreDoc[]> {
    const out: StoreDoc[] = [];
    for (const [id, data] of this.table) {
      let ok = true;
      for (const f of this.filters) {
        if (data[f.field] !== f.value) {
          ok = false;
          break;
        }
      }
      if (ok) {
        out.push({ id, data });
        if (this.max !== null && out.length >= this.max) {
          break;
        }
      }
    }
    return out;
  }
}

export class MemoryStore implements DocumentStore {
  private readonly tables = new Map<string, Map<string, DocData>>();
  private queue: Promise<unknown> = Promise.resolve();

  private table(id: string): Map<string, DocData> {
    let t = this.tables.get(id);
    if (t === undefined) {
      t = new Map();
      this.tables.set(id, t);
    }
    return t;
  }

  collection(id: string): StoreCollection {
    return new MemoryCollection(this, id, this.table(id));
  }

  runTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T> {
    const run = this.queue.then(() => this.executeTransaction(fn));
    // Keep the chain alive even when this transaction fails.
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async executeTransaction<T>(fn: (tx: StoreTransaction) => Promise<T>): Promise<T> {
    const touched: Array<{ table: Map<string, DocData>; id: string; before: DocData | null }> = [];
    const journalWrite = (table: Map<string, DocData>, id: string): void => {
      if (!touched.some((e) => e.table === table && e.id === id)) {
        touched.push({ table, id, before: table.get(id) ?? null });
      }
    };
    const tx: StoreTransaction = {
      collection: (cid: string) => new MemoryCollection(this, cid, this.table(cid), journalWrite),
    };
    try {
      return await fn(tx);
    } catch (error) {
      // Roll back in reverse order of first touch.
      for (let i = touched.length - 1; i >= 0; i -= 1) {
        const entry = touched[i];
        if (entry === undefined) {
          continue;
        }
        if (entry.before === null) {
          entry.table.delete(entry.id);
        } else {
          entry.table.set(entry.id, entry.before);
        }
      }
      throw error;
    }
  }
}

class MemoryCollection implements StoreCollection {
  constructor(
    private readonly store: MemoryStore,
    readonly id: string,
    private readonly table: Map<string, DocData>,
    private readonly journal?: (table: Map<string, DocData>, id: string) => void,
  ) {}

  doc(id: string): StoreDocRef {
    return new MemoryDocRef(this.table, id, this.journal);
  }

  where(field: string, value: unknown): StoreQuery {
    return new MemoryQuery(this.table, [{ field, value }], null);
  }
}

class MemoryDocRef implements StoreDocRef {
  constructor(
    private readonly table: Map<string, DocData>,
    readonly id: string,
    private readonly journal?: (table: Map<string, DocData>, id: string) => void,
  ) {}

  async get(): Promise<StoreDoc> {
    const data = this.table.get(this.id);
    return { id: this.id, data: data === undefined ? null : structuredClone(data) };
  }

  async create(data: DocData): Promise<boolean> {
    if (this.table.has(this.id)) {
      return false;
    }
    this.journal?.(this.table, this.id);
    this.table.set(this.id, structuredClone(data));
    return true;
  }

  async set(data: DocData): Promise<void> {
    this.journal?.(this.table, this.id);
    this.table.set(this.id, structuredClone(data));
  }

  async update(data: DocData): Promise<void> {
    this.journal?.(this.table, this.id);
    const existing = this.table.get(this.id);
    this.table.set(this.id, { ...(existing ?? {}), ...structuredClone(data) });
  }
}

/** Helper the module repositories use for equality scans. */
export async function queryAll(collection: StoreCollection, field: string, value: unknown): Promise<StoreDoc[]> {
  return collection.where(field, value).get();
}
