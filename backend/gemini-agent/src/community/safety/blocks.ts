/**
 * The real BlockDirectory (SPEC §3.4: "anyone can leave, block and report";
 * the seam doc: a blocked pair sees nothing of each other in either
 * direction). One document per unordered pair — both directions land on the
 * same id (`blockPairId`), direction (who blocked whom) is data on the
 * document, so a block and its enforcement are one read.
 *
 * Unblock is the blocker's act only: the block's consent belongs to whoever
 * created it, and letting the blocked party lift it would defeat the guard.
 * A pair where both parties blocked each other is one document; either may
 * lift it (each is a blocker of that pair). Recorded as an interpretation
 * in the M4 handoff.
 */
import type { DocumentSnapshot } from "@google-cloud/firestore";
import type { BlockDirectory } from "../shared/contracts.js";
import type { CommunityStore } from "../shared/store.js";
import type { Clock } from "../shared/time.js";
import { toIso } from "../shared/time.js";
import { errForbidden, errValidation } from "../shared/errors.js";
import { blockPairId, type AccountId } from "../shared/ids.js";

export interface BlockPairRecord {
  readonly pairId: string;
  readonly a: AccountId;
  readonly b: AccountId;
  /** The account whose block created (or last renewed) this pair. */
  readonly blocker: AccountId;
  readonly createdAtIso: string;
}

export interface BlockDirectoryDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
}

function readStringField(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== "string") {
    throw errValidation(`block record field ${field} is missing or malformed`);
  }
  return value;
}

/** Validating read of a block-pair document (README rule 5). */
export function parseBlockPairDoc(snap: DocumentSnapshot): BlockPairRecord | null {
  if (!snap.exists) {
    return null;
  }
  const data = snap.data();
  if (data === undefined) {
    return null;
  }
  return {
    pairId: snap.id,
    a: readStringField(data, "a") as AccountId,
    b: readStringField(data, "b") as AccountId,
    blocker: readStringField(data, "blocker") as AccountId,
    createdAtIso: readStringField(data, "createdAtIso"),
  };
}

/** Records a block by `blocker` against `blocked`; idempotent. */
export async function blockAccount(deps: BlockDirectoryDeps, blocker: AccountId, blocked: AccountId): Promise<BlockPairRecord> {
  if (blocker === blocked) {
    throw errValidation("you cannot block yourself");
  }
  const pairId = blockPairId(blocker, blocked);
  const [a, b] = [blocker, blocked].sort() as [AccountId, AccountId];
  const createdAtIso = toIso(deps.clock.now());
  await deps.store.blocks.doc(pairId).set({ pairId, a, b, blocker, createdAtIso });
  return { pairId, a, b, blocker, createdAtIso };
}

/** The caller's blocks (who they have blocked), newest first. */
export async function listBlocksForAccount(deps: BlockDirectoryDeps, blocker: AccountId): Promise<BlockPairRecord[]> {
  const snap = await deps.store.blocks.where("blocker", "==", blocker).get();
  return snap.docs
    .map((doc) => parseBlockPairDoc(doc))
    .filter((r): r is BlockPairRecord => r !== null)
    .sort((a, b) => (a.createdAtIso < b.createdAtIso ? 1 : -1));
}

export type UnblockOutcome = { readonly outcome: "ok" } | { readonly outcome: "missing" } | { readonly outcome: "forbidden" };

/** Lifts a block; only the blocker of the pair may (see module doc). */
export async function unblockAccount(deps: BlockDirectoryDeps, requesterId: AccountId, blocked: AccountId): Promise<UnblockOutcome> {
  const doc = deps.store.blocks.doc(blockPairId(requesterId, blocked));
  const record = parseBlockPairDoc(await doc.get());
  if (record === null) {
    return { outcome: "missing" };
  }
  if (record.blocker !== requesterId) {
    return { outcome: "forbidden" };
  }
  await doc.delete();
  return { outcome: "ok" };
}

export class FirestoreBlockDirectory implements BlockDirectory {
  private readonly store: CommunityStore;

  constructor(store: CommunityStore) {
    this.store = store;
  }

  async assertCanInteract(a: AccountId, b: AccountId): Promise<void> {
    const snap = await this.store.blocks.doc(blockPairId(a, b)).get();
    if (snap.exists) {
      throw errForbidden("a block exists between these accounts");
    }
  }

  async filterVisible(viewer: AccountId, candidates: readonly AccountId[]): Promise<AccountId[]> {
    if (candidates.length === 0) {
      return [];
    }
    const docs = candidates.map((c) => this.store.blocks.doc(blockPairId(viewer, c)));
    const snaps = await this.store.firestore.getAll(...docs);
    return candidates.filter((_, i) => {
      const snap = snaps[i];
      return snap !== undefined && !snap.exists;
    });
  }
}
