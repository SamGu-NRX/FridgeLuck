// Hand-checked boundary fixtures for the real automation/restockJob functions.
//
// Every epoch value below is a literal, and every expected count was derived by
// hand from the arithmetic shown in the comment next to it. The tests drive the
// REAL production functions (src/automation/restockJob.ts) with the clock pinned
// to these instants via Bun's setSystemTime, then compare against these
// expectations. Nothing here re-implements production semantics; the reference
// model used for divergence recording lives in ../reference/model.ts and is
// separately proven equal to production over every fixture and the full matrix.
//
// Anchor instants (UTC):
//   2026-10-01T00:00:00Z = 1790812800000
//   2026-10-08T00:00:00Z = 1791417600000
//   2026-10-09T00:00:00Z = 1791504000000
//   2026-10-10T00:00:00Z = 1791590400000
//   2026-10-11T00:00:00Z = 1791676800000   <- expiry "2026-10-11" (date-only parses to this)
//   2026-10-11T18:00:00Z = 1791741600000
//   2026-10-12T00:00:00Z = 1791763200000
//
// Production semantics under test (as written in src/automation/restockJob.ts):
//   daysRemaining = Math.ceil((expiryMs - Date.now()) / 86400000)
//   alert when daysRemaining <= thresholdDays; display Math.max(0, daysRemaining)
//   restock when quantityGrams < restockBelowGrams (strict), default 50
//   missing expiresAt is skipped; unparsable expiresAt yields NaN and is silently dropped

import type { InventoryItem } from "../../../../src/types/contracts.js";

export const MS_PER_DAY = 86_400_000;

// Epoch anchors as literals so the fixtures are readable without a calendar.
export const T_2026_10_01 = 1_790_812_800_000;
export const T_2026_10_08 = 1_791_417_600_000;
export const T_2026_10_09 = 1_791_504_000_000;
export const T_2026_10_10 = 1_791_590_400_000;
export const T_2026_10_11 = 1_791_676_800_000; // expiry instant of "2026-10-11"
export const T_2026_10_11_18 = 1_791_741_600_000; // 18:00 same day
export const T_2026_10_12 = 1_791_763_200_000;

export interface BoundaryRow {
  label: string;
  /** Clock pin for the observation instant. */
  pinMs: number;
  thresholdDays: number;
  /** expiresAt value handed to the production function. */
  expiry?: string;
  grams: number;
  /** Hand-checked raw Math.ceil value of (expiryMs - pinMs) / MS_PER_DAY. */
  rawCeil: number;
  /** Hand-checked whether the production function includes the item. */
  expectIncluded: boolean;
  /** Hand-checked displayed daysRemaining (Math.max(0, rawCeil)) when included. */
  expectDisplayDays: number;
  /** Hand-checked UTC calendar-date difference (reference-date interpretation). */
  refDateDiff: number;
  note?: string;
}

const farFromCutoffGrams = 500; // never restock-eligible at the default 50g cutoff

/**
 * Midnight / instant boundary matrix around expiry "2026-10-11" (UTC midnight).
 * rawCeil hand-check example (row "1ms before expiry"):
 *   1791676800000 - 1791676799999 = 1 ms; 1 / 86400000 ≈ 1.16e-11 d; ceil = 1.
 * Row "exactly one full day after expiry":
 *   1791676800000 - 1791763200000 = -86400000 ms; -1 d exactly; ceil = -1.
 * Row "1ms after expiry":
 *   -1 ms / 86400000 ≈ -1.16e-11; ceil = -0; Math.max(0, -0) = 0.
 */
export const midnightRows: BoundaryRow[] = [
  {
    label: "1ms before expiry",
    pinMs: T_2026_10_11 - 1,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 1,
    expectIncluded: true,
    expectDisplayDays: 1,
    refDateDiff: 1,
  },
  {
    label: "exact expiry instant",
    pinMs: T_2026_10_11,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 0,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: 0,
  },
  {
    label: "1ms after expiry",
    pinMs: T_2026_10_11 + 1,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: -0,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: 0,
    note: "raw ceil is -0; display clamps to 0; elapsed model still calls this use-soon, not expired",
  },
  {
    label: "1ms before a full day after expiry",
    pinMs: T_2026_10_12 - 1,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: -0,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: 0,
    note: "still -0 because ceil(-0.99999...) = -0; reference date is still the expiry day",
  },
  {
    label: "exactly one full day after expiry",
    pinMs: T_2026_10_12,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: -1,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: -1,
    note: "both interpretations say expired; production display clamps the -1 to 0",
  },
  {
    label: "midnight pin, exactly one day before expiry",
    pinMs: T_2026_10_10,
    thresholdDays: 1,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 1,
    expectIncluded: true,
    expectDisplayDays: 1,
    refDateDiff: 1,
    note: "date-only expiry at a midnight pin: elapsed and reference-date agree exactly",
  },
];

/**
 * Threshold-equality rows at thresholdDays = 2 against expiry "2026-10-11".
 * Hand-check:
 *   pin 1791504000000: (1791676800000 - 1791504000000) = 172800000 ms = exactly 2 d → ceil 2 → 2 <= 2 → included.
 *   pin 1791504000001: 1 ms inside → (2 d - 1 ms) → ceil 2 → included.
 *   pin 1791503999999: 1 ms outside → (2 d + 1 ms) → ceil 3 → 3 > 2 → excluded.
 */
export const thresholdEqualityRows: BoundaryRow[] = [
  {
    label: "threshold equality: exactly 2 days remaining is alerted",
    pinMs: T_2026_10_09,
    thresholdDays: 2,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 2,
    expectIncluded: true,
    expectDisplayDays: 2,
    refDateDiff: 2,
    note: "production uses <=, so equality alerts",
  },
  {
    label: "threshold equality: 1ms inside the boundary still alerts",
    pinMs: T_2026_10_09 + 1,
    thresholdDays: 2,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 2,
    expectIncluded: true,
    expectDisplayDays: 2,
    refDateDiff: 2,
  },
  {
    label: "threshold equality: 1ms outside the boundary is not alerted",
    pinMs: T_2026_10_09 - 1,
    thresholdDays: 2,
    expiry: "2026-10-11",
    grams: farFromCutoffGrams,
    rawCeil: 3,
    expectIncluded: false,
    expectDisplayDays: 0,
    refDateDiff: 3,
  },
];

/**
 * Divergence rows where elapsed-day arithmetic and the reference-date
 * interpretation disagree. These are recorded, not resolved: the task is to
 * make the divergence reproducible, not to pick a product policy.
 * Hand-check for "divergent inclusion":
 *   expiry 1791741600000, pin 1791633600000 → 108000000 ms = 1.25 d → ceil 2 → 2 > 1 → excluded.
 *   Reference date: 2026-10-10 → 2026-10-11 = 1 day → 1 <= 1 → alerted.
 * Hand-check for the 24h-past agreement row:
 *   pin 1791828000000 (2026-10-12T18:00:00Z) − 1791741600000 = −86400000 ms → ceil = −1 → expired.
 *   Reference date: 2026-10-11 → 2026-10-12 = −1 → expired. Both agree again at exactly −24h.
 */
export const divergenceRows: BoundaryRow[] = [
  {
    label: "divergent inclusion: timestamped expiry, noon pin",
    pinMs: T_2026_10_10 + 43_200_000, // 2026-10-10T12:00:00Z
    thresholdDays: 1,
    expiry: "2026-10-11T18:00:00Z",
    grams: farFromCutoffGrams,
    rawCeil: 2,
    expectIncluded: false,
    expectDisplayDays: 0,
    refDateDiff: 1,
    note: "elapsed-day says 2 days out (excluded); reference date says 1 day out (would alert)",
  },
  {
    label: "divergent days: same-day timestamped expiry shows 1 under elapsed arithmetic",
    pinMs: T_2026_10_11,
    thresholdDays: 1,
    expiry: "2026-10-11T18:00:00Z",
    grams: farFromCutoffGrams,
    rawCeil: 1,
    expectIncluded: true,
    expectDisplayDays: 1,
    refDateDiff: 0,
    note: "reference-date would say it expires today (0); elapsed says 1",
  },
  {
    label: "divergent bucket: 6h past a timestamped expiry is still 'not expired' under elapsed arithmetic",
    pinMs: T_2026_10_12,
    thresholdDays: 1,
    expiry: "2026-10-11T18:00:00Z",
    grams: farFromCutoffGrams,
    rawCeil: -0,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: -1,
    note: "elapsed raw -0 is not negative, so it lands in the use-soon bucket; reference date says expired",
  },
  {
    label: "agreement returns once fully past: exactly 24h past a timestamped expiry",
    pinMs: T_2026_10_12 + 64_800_000, // 2026-10-12T18:00:00Z
    thresholdDays: 1,
    expiry: "2026-10-11T18:00:00Z",
    grams: farFromCutoffGrams,
    rawCeil: -1,
    expectIncluded: true,
    expectDisplayDays: 0,
    refDateDiff: -1,
  },
];

/** Long-expired row: expiry "2026-10-01" observed at 2026-10-12T00:00:00Z → -11 d. */
export const longExpiredRow: BoundaryRow = {
  label: "long expired (11 days past)",
  pinMs: T_2026_10_12,
  thresholdDays: 3,
  expiry: "2026-10-01",
  grams: 20,
  rawCeil: -11,
  expectIncluded: true,
  expectDisplayDays: 0,
  refDateDiff: -11,
  note: "expired items stay alerted indefinitely and display 0; with 20g they also appear in the restock list",
};

export interface CutoffRow {
  label: string;
  grams: number;
  cutoff: number;
  expectInRestockList: boolean;
  note?: string;
}

/** Strict less-than cutoff rows (production: quantityGrams < restockBelowGrams). */
export const cutoffRows: CutoffRow[] = [
  { label: "exactly at the cutoff is excluded", grams: 50, cutoff: 50, expectInRestockList: false, note: "strict <" },
  { label: "just below the cutoff is included", grams: 49.999, cutoff: 50, expectInRestockList: true },
  { label: "just above the cutoff is excluded", grams: 50.001, cutoff: 50, expectInRestockList: false, note: "hand-check: 50.001 < 50 is false" },
  { label: "zero grams is included", grams: 0, cutoff: 50, expectInRestockList: true },
  { label: "negative grams is included", grams: -5, cutoff: 50, expectInRestockList: true, note: "recorded behavior, not a policy endorsement" },
  { label: "NaN grams is excluded", grams: NaN, cutoff: 50, expectInRestockList: false, note: "NaN < 50 is false, so NaN grams silently never restock" },
];

/** Items for the missing / invalid date fixtures. */
export function item(name: string, grams: number, expiry?: string): InventoryItem {
  return expiry === undefined
    ? { ingredientName: name, quantityGrams: grams }
    : { ingredientName: name, quantityGrams: grams, expiresAt: expiry };
}

export const expiredInvalidMissing: Array<{
  label: string;
  pinMs: number;
  thresholdDays: number;
  items: InventoryItem[];
  expectAlertNames: string[];
  note?: string;
}> = [
  {
    label: "missing expiresAt is skipped entirely",
    pinMs: T_2026_10_10,
    thresholdDays: 3,
    items: [item("Salt", 500)],
    expectAlertNames: [],
  },
  {
    label: "empty-string expiresAt is skipped (falsy)",
    pinMs: T_2026_10_10,
    thresholdDays: 3,
    items: [item("Sugar", 500, "")],
    expectAlertNames: [],
    note: "the falsy check drops it before parsing; it never becomes an invalid-date case",
  },
  {
    label: "unparsable expiresAt is silently dropped",
    pinMs: T_2026_10_10,
    thresholdDays: 3,
    items: [item("MysteryJam", 500, "not-a-date")],
    expectAlertNames: [],
    note: "NaN <= threshold is false, so unparsable dates never alert and never error",
  },
  {
    label: "impossible calendar values are silently dropped",
    pinMs: T_2026_10_10,
    thresholdDays: 3,
    items: [item("VoidFruit", 500, "2026-13-45")],
    expectAlertNames: [],
  },
  {
    label: "whitespace-only expiresAt is silently dropped",
    pinMs: T_2026_10_10,
    thresholdDays: 3,
    items: [item("GhostGreens", 500, "  ")],
    expectAlertNames: [],
  },
  {
    label: "expired and depleted items appear in both lists",
    pinMs: T_2026_10_12,
    thresholdDays: 3,
    items: [item("OldYogurt", 20, "2026-10-01")],
    expectAlertNames: ["OldYogurt"],
    note: "useSoonAlerts (expired bucket) and restockList are independent outputs",
  },
];
