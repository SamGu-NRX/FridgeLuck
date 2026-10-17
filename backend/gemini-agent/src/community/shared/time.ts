/**
 * Clock injection and the "day only" rule from SPEC 3.4: a shared cook never
 * carries an exact time, only the UTC day it happened.
 */

export interface Clock {
  now(): Date;
}

export const systemClock: Clock = {
  now: () => new Date(),
};

export function fixedClock(at: Date): Clock {
  return { now: () => new Date(at.getTime()) };
}

/** Truncates an instant to its UTC day: "2026-10-11". */
export function toDay(instant: Date): string {
  return instant.toISOString().slice(0, 10);
}

export function toIso(instant: Date): string {
  return instant.toISOString();
}

export function isoOffsetDays(base: Date, days: number): string {
  return new Date(base.getTime() + days * 86_400_000).toISOString();
}
