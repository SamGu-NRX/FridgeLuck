import { InventoryLedger } from "./inventoryLedger.js";

/**
 * Per-session inventory ledgers.
 *
 * Before this module, the backend inventory was ONE process-wide map shared
 * by every live session — a client could not attach to another client's
 * session (session ids were client-chosen, which packet on session minting
 * fixes), but any session's mutations landed in the same pile, and the
 * restock tool read the whole pile. That made the backend look like the
 * owner of a global kitchen, which it is not: the phone owns the user's real
 * ledger (GRDB on device). The backend keeps a per-session scratch shadow,
 * and this module is where that scoping becomes structural.
 *
 * Bound: at most `maxSessions` ledgers are retained; the least-recently-used
 * one is evicted when the bound is exceeded, and idle ledgers expire after
 * `ttlMs` (matching the logical session expiry of the session store). A
 * shadow that outlives its session is worthless — eviction is the safe
 * direction, never data loss about anyone's real kitchen.
 */

export const SESSION_LEDGERS_MAX_SESSIONS = 200;
export const SESSION_LEDGERS_TTL_MS = 24 * 60 * 60 * 1000;

export interface SessionLedgersOptions {
  /** Maximum session ledgers retained. Default: 200. */
  maxSessions?: number;
  /** Idle lifetime in ms. Default: 24 hours (matches session expiry). */
  ttlMs?: number;
  /** Clock source (ms). Tests inject a controllable clock. */
  now?: () => number;
}

export class SessionLedgers {
  private readonly entries = new Map<
    string,
    { ledger: InventoryLedger; lastUsedMs: number }
  >();
  private readonly idempotencyTtlSeconds: number;
  private readonly maxSessions: number;
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(
    idempotencyTtlSeconds: number,
    options: SessionLedgersOptions = {}
  ) {
    this.idempotencyTtlSeconds = idempotencyTtlSeconds;
    this.maxSessions = options.maxSessions ?? SESSION_LEDGERS_MAX_SESSIONS;
    this.ttlMs = options.ttlMs ?? SESSION_LEDGERS_TTL_MS;
    this.now = options.now ?? Date.now;
  }

  /** Returns this session's scoped ledger, creating it on first use. */
  get(sessionId: string): InventoryLedger {
    this.sweep();

    const existing = this.entries.get(sessionId);
    if (existing) {
      existing.lastUsedMs = this.now();
      // Re-insert to make Map iteration order true LRU order.
      this.entries.delete(sessionId);
      this.entries.set(sessionId, existing);
      return existing.ledger;
    }

    if (this.entries.size >= this.maxSessions) {
      this.evictLeastRecentlyUsed();
    }

    const entry = {
      ledger: new InventoryLedger({
        idempotencyTtlSeconds: this.idempotencyTtlSeconds
      }),
      lastUsedMs: this.now()
    };
    this.entries.set(sessionId, entry);
    return entry.ledger;
  }

  /** Number of live session ledgers (for tests and health introspection). */
  size(): number {
    return this.entries.size;
  }

  /** Drops idle ledgers past the TTL. */
  sweep(): void {
    const nowMs = this.now();
    for (const [sessionId, entry] of this.entries) {
      if (nowMs - entry.lastUsedMs > this.ttlMs) {
        this.entries.delete(sessionId);
      }
    }
  }

  private evictLeastRecentlyUsed(): void {
    const oldest = this.entries.keys().next().value;
    if (oldest !== undefined) this.entries.delete(oldest);
  }
}
