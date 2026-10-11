// Reference model for the restock-boundaries study.
//
// Two interpretations of "days until expiry" are compared over the same matrix:
//
//   A (production): elapsed-time arithmetic as written in src/automation/restockJob.ts —
//     raw = Math.ceil((expiryMs - now) / 86_400_000); alert when raw <= thresholdDays;
//     display Math.max(0, raw). The boundary flips at the expiry INSTANT.
//
//   B (reference-date): calendar-date arithmetic — compare the UTC calendar date of
//     the expiry with the UTC calendar date of the observation instant ("reference
//     date"); dateDiff = (utcMidnight(expiry) - utcMidnight(now)) / 86_400_000;
//     alert when dateDiff <= thresholdDays. The boundary flips at UTC MIDNIGHT.
//
// The mirror functions below (referenceCompute*) exist so that mutation testing
// can perturb a copy of interpretation A without touching production source.
// Their equality with the real production functions is not assumed: the tests
// and the pipeline parity check prove it over every hand-checked fixture and
// over the full seeded matrix. Nothing here decides which interpretation is
// "correct" — that is a product decision this study does not make.

import type { InventoryItem, UseSoonAlert } from "../../../../src/types/contracts.js";

export const MS_PER_DAY = 86_400_000;

export type ExpiryBucket = "missing" | "invalid" | "expired" | "use-soon" | "ok";

/** Parse an expiresAt value; null when missing/empty or unparsable. */
export function parseExpiryMs(expiresAt: string | undefined): number | null {
  if (!expiresAt) return null;
  const ms = new Date(expiresAt).getTime();
  return Number.isNaN(ms) ? null : ms;
}

/** Floor an instant to the start of its UTC calendar day. */
export function utcDayFloor(ms: number): number {
  return Math.floor(ms / MS_PER_DAY) * MS_PER_DAY;
}

/** Interpretation A raw value: ceil of elapsed whole days (can be negative or -0). */
export function rawElapsedDays(expiryMs: number, nowMs: number): number {
  return Math.ceil((expiryMs - nowMs) / MS_PER_DAY);
}

/** Interpretation B value: whole UTC calendar days between dates (integer). */
export function refDateDiff(expiryMs: number, nowMs: number): number {
  return (utcDayFloor(expiryMs) - utcDayFloor(nowMs)) / MS_PER_DAY;
}

/** Production display clamp: Math.max(0, raw) — expired and same-instant items both show 0. */
export function displayDays(raw: number): number {
  return Math.max(0, raw);
}

/**
 * Bucket a raw interpretation-A value. The raw value (pre-clamp) is what keeps
 * expired and use-soon distinct: raw < 0 is expired, 0 <= raw <= threshold is
 * use-soon. Production's emitted alerts cannot make this distinction (they clamp
 * to 0), which is exactly why this study buckets from the raw arithmetic.
 */
export function bucketFromRaw(raw: number, thresholdDays: number): ExpiryBucket {
  if (raw < 0) return "expired";
  if (raw <= thresholdDays) return "use-soon";
  return "ok";
}

/**
 * Interpretation-A mirror of production (verified equal to it elsewhere):
 * alert when raw <= thresholdDays, sorted ascending by raw, display clamped.
 */
export function referenceComputeUseSoon(
  items: InventoryItem[],
  pinMs: number,
  thresholdDays: number
): UseSoonAlert[] {
  const alerts: UseSoonAlert[] = [];
  for (const item of items) {
    if (!item.expiresAt) continue;
    const expiryMs = new Date(item.expiresAt).getTime();
    const raw = Math.ceil((expiryMs - pinMs) / MS_PER_DAY);
    if (raw <= thresholdDays) {
      alerts.push({
        ingredientName: item.ingredientName,
        expiresAt: item.expiresAt,
        daysRemaining: Math.max(0, raw),
      });
    }
  }
  return alerts.sort((a, b) => a.daysRemaining - b.daysRemaining);
}

/** Interpretation-A mirror of computeRestockList (strict <, localeCompare sort, no dedup). */
export function referenceComputeRestockList(
  items: InventoryItem[],
  restockBelowGrams: number
): string[] {
  return items
    .filter((item) => item.quantityGrams < restockBelowGrams)
    .map((item) => item.ingredientName)
    .sort((a, b) => a.localeCompare(b));
}

/** Bucket for interpretation B, including the missing-vs-invalid distinction. */
export function bucketFromRefDate(
  expiresAt: string | undefined,
  pinMs: number,
  thresholdDays: number
): ExpiryBucket {
  if (!expiresAt) return "missing"; // same falsy skip production performs
  const expiryMs = parseExpiryMs(expiresAt);
  if (expiryMs === null) return "invalid";
  const diff = refDateDiff(expiryMs, pinMs);
  if (diff < 0) return "expired";
  if (diff <= thresholdDays) return "use-soon";
  return "ok";
}

export interface ItemView {
  bucket: ExpiryBucket;
  /** Raw interpretation-A value (pre-clamp), undefined for missing/invalid. */
  raw?: number;
  /** Interpretation-B UTC date difference, undefined for missing/invalid. */
  refDiff?: number;
  alerted: boolean;
  displayDays?: number;
}

/** Classify one item under interpretation B. */
export function classifyB(
  item: InventoryItem,
  pinMs: number,
  thresholdDays: number
): ItemView {
  const bucket = bucketFromRefDate(item.expiresAt, pinMs, thresholdDays);
  if (bucket === "missing" || bucket === "invalid") {
    return { bucket, alerted: false };
  }
  const expiryMs = parseExpiryMs(item.expiresAt)!;
  return { bucket, refDiff: refDateDiff(expiryMs, pinMs), alerted: bucket !== "ok" };
}

/**
 * Classify one item under interpretation A using the same arithmetic production
 * performs (verified equal to the real functions by the parity check).
 */
export function classifyA(
  item: InventoryItem,
  pinMs: number,
  thresholdDays: number
): ItemView {
  if (!item.expiresAt) return { bucket: "missing", alerted: false };
  const expiryMs = new Date(item.expiresAt).getTime();
  if (Number.isNaN(expiryMs)) return { bucket: "invalid", alerted: false };
  const raw = rawElapsedDays(expiryMs, pinMs);
  const bucket = bucketFromRaw(raw, thresholdDays);
  return {
    bucket,
    raw,
    alerted: raw <= thresholdDays,
    displayDays: Math.max(0, raw),
  };
}
