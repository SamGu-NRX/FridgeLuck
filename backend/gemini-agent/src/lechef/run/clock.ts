/**
 * Manual clock for offline runs: deterministic, advanced explicitly by the
 * harness (script `advanceMinutes` actions) or by tests.
 */

import type { Clock } from "../types.js";

export class ManualClock implements Clock {
  private currentMs: number;

  constructor(startMs: number = Date.UTC(2026, 0, 1, 0, 0, 0)) {
    this.currentMs = startMs;
  }

  nowMs(): number {
    return this.currentMs;
  }

  advanceMs(ms: number): void {
    if (!Number.isFinite(ms) || ms < 0) throw new Error(`ManualClock.advanceMs: expected a non-negative finite number, got ${ms}`);
    this.currentMs += ms;
  }
}
