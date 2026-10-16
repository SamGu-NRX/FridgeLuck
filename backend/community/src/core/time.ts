/**
 * Clock abstraction so every timestamp decision is testable without sleeping.
 * Ported from PR #104 `shared/time.ts`.
 */

export interface Clock {
  now(): Date;
}

export class SystemClock implements Clock {
  now(): Date {
    return new Date();
  }
}

/** A clock pinned to a fixed instant (tests move it by mutating `ms`). */
export class FixedClock implements Clock {
  ms: number;
  constructor(iso: string) {
    this.ms = Date.parse(iso);
  }
  now(): Date {
    return new Date(this.ms);
  }
  advance(minutes: number): void {
    this.ms += minutes * 60_000;
  }
}

export function toIso(d: Date): string {
  return d.toISOString();
}
