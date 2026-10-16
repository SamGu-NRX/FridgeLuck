/**
 * The Greptile PR #166 findings suite on the in-memory store (unit tier —
 * `bun test test/`, no emulator needed). The test bodies live in
 * greptile-fixes.suite.ts and run unchanged against the Firestore adapter
 * under the emulator (test/integration/greptile-fixes.firestore.test.ts).
 *
 * The race tests wrap the store in a macrotask-hop jitter: every plain read
 * yields one macrotask so overlapping requests genuinely interleave — both
 * requests finish their reads before either writes. Transactional reads
 * (inside runTransaction) bypass the wrapper, which is the point — after the
 * fixes the claim/replay checks are serialized by the transaction and the
 * races close deterministically. On Firestore the same tests overlap for real
 * through network latency and SDK transaction retries.
 */

import { runGreptileFixes, type FixturesStoreFactory } from "./greptile-fixes.suite.js";
import { MemoryStore } from "../src/core/store/memory.js";
import type { DocumentStore, StoreCollection, StoreDocRef, StoreQuery } from "../src/core/store/documentStore.js";

function jitteredStore(base: MemoryStore): DocumentStore {
  const delay = <T,>(p: Promise<T>): Promise<T> => new Promise<T>((resolve, reject) => void setTimeout(() => p.then(resolve, reject), 0));
  const wrapDoc = (doc: StoreDocRef): StoreDocRef => ({
    get: () => delay(doc.get()),
    create: (data) => doc.create(data),
    set: (data) => doc.set(data),
    update: (data) => doc.update(data),
  });
  const wrapQuery = (q: StoreQuery): StoreQuery => ({
    where: (f, v) => wrapQuery(q.where(f, v)),
    limit: (n) => q.limit(n),
    get: () => delay(q.get()),
  });
  const wrapColl = (coll: StoreCollection): StoreCollection => ({
    id: coll.id,
    doc: (id) => wrapDoc(coll.doc(id)),
    where: (f, v) => wrapQuery(coll.where(f, v)),
  });
  return { collection: (id) => wrapColl(base.collection(id)), runTransaction: (fn) => base.runTransaction(fn) };
}

const makeStore: FixturesStoreFactory = async (kind) => (kind === "race" ? jitteredStore(new MemoryStore()) : new MemoryStore());

runGreptileFixes("memory", makeStore);
