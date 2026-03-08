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

export class InventoryLedger {
  private readonly store = new Map<string, InventoryItem>();
  private readonly seen = new Map<string, IdempotencyRecord>();
  private readonly ttlMs: number;

  constructor(config: Pick<AppConfig, "idempotencyTtlSeconds">) {
    this.ttlMs = config.idempotencyTtlSeconds * 1000;
  }

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

  decrementItems(req: InventoryMutationRequest): InventoryMutationResponse {
    const cached = this.checkIdempotency(req.idempotencyKey);
    if (cached) return cached;

    for (const item of req.items) {
      const key = this.itemKey(item.ingredientName);
      const existing = this.store.get(key);
      if (existing) {
        existing.quantityGrams = Math.max(0, existing.quantityGrams - Math.max(0, item.quantityGrams));
      }
    }

    return this.commitIdempotency(req.idempotencyKey);
  }

  snapshot(): InventoryItem[] {
    return [...this.store.values()].map((item) => ({ ...item }));
  }

  clear(): void {
    this.store.clear();
    this.seen.clear();
  }

  private itemKey(name: string): string {
    return name.trim().toLowerCase();
  }

  private checkIdempotency(key: string): InventoryMutationResponse | null {
    const record = this.seen.get(key);
    if (!record) return null;
    if (Date.now() - record.committedAt < this.ttlMs) {
      return { committed: false, snapshot: record.snapshot };
    }
    this.seen.delete(key);
    return null;
  }

  private commitIdempotency(key: string): InventoryMutationResponse {
    const snap = this.snapshot();
    this.seen.set(key, { committedAt: Date.now(), snapshot: snap });
    return { committed: true, snapshot: snap };
  }
}
