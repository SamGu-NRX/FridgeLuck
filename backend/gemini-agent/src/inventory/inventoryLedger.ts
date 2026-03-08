import type {
  InventoryItem,
  InventoryMutationRequest,
  InventoryMutationResponse
} from "../types/contracts.js";
import type { AppConfig } from "../config.js";

interface IdempotencyRecord {
  committedAt: number;
  snapshot: InventoryItem[];
}

/**
 * In-memory inventory ledger with idempotency-key deduplication.
 *
 * Design: pure in-memory so it is testable without I/O.
 * To swap in Firestore: replace the Map fields with Firestore collection reads/writes
 * behind the same addItems/decrementItems/snapshot interface.
 */
export class InventoryLedger {
  private readonly store = new Map<string, InventoryItem>();
  private readonly seen = new Map<string, IdempotencyRecord>();
  private readonly ttlMs: number;

  constructor(config: Pick<AppConfig, "idempotencyTtlSeconds">) {
    this.ttlMs = config.idempotencyTtlSeconds * 1000;
  }

  /**
   * Add (or top-up) items to the ledger.
   * Duplicate idempotency keys within TTL are returned as committed=false with the cached snapshot.
   */
  addItems(req: InventoryMutationRequest): InventoryMutationResponse {
    const cached = this.checkIdempotency(req.idempotencyKey);
    if (cached) return cached;

    for (const item of req.items) {
      const key = this.itemKey(item.ingredientName);
      const existing = this.store.get(key);
      if (existing) {
        existing.quantityGrams += Math.max(0, item.quantityGrams);
        if (item.expiresAt) existing.expiresAt = item.expiresAt;
        if (item.source) existing.source = item.source;
      } else {
        this.store.set(key, { ...item, quantityGrams: Math.max(0, item.quantityGrams) });
      }
    }

    return this.commitIdempotency(req.idempotencyKey);
  }

  /**
   * Decrement item quantities (e.g. after cooking). Quantities are clamped at 0.
   * Items depleted to 0 remain in the ledger (do not auto-remove).
   */
  decrementItems(req: InventoryMutationRequest): InventoryMutationResponse {
    const cached = this.checkIdempotency(req.idempotencyKey);
    if (cached) return cached;

    for (const item of req.items) {
      const key = this.itemKey(item.ingredientName);
      const existing = this.store.get(key);
      if (existing) {
        existing.quantityGrams = Math.max(0, existing.quantityGrams - Math.max(0, item.quantityGrams));
      }
      // Items not found in the ledger are silently ignored (idempotency-safe)
    }

    return this.commitIdempotency(req.idempotencyKey);
  }

  /** Return a shallow copy of all current inventory items. */
  snapshot(): InventoryItem[] {
    return [...this.store.values()].map((item) => ({ ...item }));
  }

  /** Remove all items and idempotency records. Intended for tests only. */
  clear(): void {
    this.store.clear();
    this.seen.clear();
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  private itemKey(name: string): string {
    return name.trim().toLowerCase();
  }

  private checkIdempotency(key: string): InventoryMutationResponse | null {
    const record = this.seen.get(key);
    if (!record) return null;
    const age = Date.now() - record.committedAt;
    if (age < this.ttlMs) {
      return { committed: false, snapshot: record.snapshot };
    }
    // TTL expired — allow re-execution
    this.seen.delete(key);
    return null;
  }

  private commitIdempotency(key: string): InventoryMutationResponse {
    const snap = this.snapshot();
    this.seen.set(key, { committedAt: Date.now(), snapshot: snap });
    return { committed: true, snapshot: snap };
  }
}
