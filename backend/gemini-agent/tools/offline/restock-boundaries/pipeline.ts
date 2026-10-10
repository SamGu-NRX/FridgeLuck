// Seeded, byte-reproducible matrix pipeline for the restock-boundaries study.
//
// Everything here is deterministic given (seed): the matrix, the clock pin, the
// permutation shuffles, and every summary count. No Math.random, no wall clock
// reads outside setSystemTime pins. The production functions
// (computeUseSoon / computeRestockList / buildRestockPlan) are driven through
// their real implementation with the clock pinned; per-item buckets use the
// reference mirror, whose equality with production is re-proven on every run by
// the parity check.
//
// The pipeline RECORDS where elapsed-day arithmetic (interpretation A) and the
// UTC reference-date interpretation (B) disagree. It does not select between
// them: choosing one is a product policy decision that belongs to the owner.

import { setSystemTime } from "bun:test";
import {
  buildRestockPlan,
  computeUseSoon,
  computeRestockList,
} from "../../../src/automation/restockJob.js";
import type { InventoryItem, UseSoonAlert } from "../../../src/types/contracts.js";
import {
  MS_PER_DAY,
  classifyA,
  classifyB,
  rawElapsedDays,
  referenceComputeRestockList,
  referenceComputeUseSoon,
  type ExpiryBucket,
} from "./reference/model.js";

// ─── Deterministic PRNG ──────────────────────────────────────────────────────

export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Seeds follow the yyyymmdd convention: seed 20261010 pins the clock to
 * 2026-10-10T00:00:00Z. Any other integer is rejected so runs always state
 * their observation instant explicitly.
 */
export function pinFromSeed(seed: number): number {
  const s = String(seed);
  if (s.length !== 8) {
    throw new Error(`seed ${seed} must be an 8-digit yyyymmdd integer (e.g. 20261010)`);
  }
  const month = Number(s.slice(4, 6));
  const day = Number(s.slice(6, 8));
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    throw new Error(`seed ${seed} does not decode as yyyymmdd`);
  }
  const ms = Date.parse(`${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T00:00:00Z`);
  if (Number.isNaN(ms)) throw new Error(`seed ${seed} does not decode as yyyymmdd`);
  return ms;
}

// ─── Matrix generation ───────────────────────────────────────────────────────

const VOCAB = [
  "Almond Milk", "Basmati Rice", "Bell Peppers", "Blueberries", "Cheddar",
  "Chicken Breast", "Coconut Yogurt", "Cottage Cheese", "Cucumber", "Eggs",
  "Firm Tofu", "Ground Turkey", "Hummus", "Kidney Beans", "Maple Syrup",
  "Oat Milk", "Parmesan", "Pita Bread", "Quinoa", "Smoked Salmon",
  "Sourdough", "Spinach", "Strawberries", "Tomato Paste",
];

const DAY_OFFSETS = [-5, -2, -1, 0, 1, 2, 3, 4, 7, 14, 21];
const TS_OFFSETS_MS = [
  1, -1, 1_000, -1_000, 43_200_000, -43_200_000, 64_800_000, -64_800_000,
  86_400_000, -86_400_000, 129_600_000, -129_600_001,
];
const EDGE_EXPIRIES = [undefined, "", "not-a-date", "2026-13-45", "  "] as const;
const EXACT_INSTANT_SPECIALS = [1, -1, 0, MS_PER_DAY, -MS_PER_DAY];

export interface MatrixMeta {
  itemCount: number;
  missingDates: number;
  invalidDates: number;
  nanGrams: number;
  duplicateClones: number;
  sameNamePartialDuplicates: number;
  dateOnlyExpiries: number;
  timestampedExpiries: number;
}

export function isoDateOnly(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

export function generateItems(seed: number): { items: InventoryItem[]; meta: MatrixMeta } {
  const pinMs = pinFromSeed(seed);
  const rand = mulberry32(seed);
  const items: InventoryItem[] = [];
  const meta: MatrixMeta = {
    itemCount: 0,
    missingDates: 0,
    invalidDates: 0,
    nanGrams: 0,
    duplicateClones: 0,
    sameNamePartialDuplicates: 0,
    dateOnlyExpiries: 0,
    timestampedExpiries: 0,
  };

  const round3 = (v: number) => Math.round(v * 1000) / 1000;

  for (let i = 0; i < 4400; i++) {
    const mode = i % 10;
    let expiry: string | undefined;
    if (mode <= 5) {
      const off = DAY_OFFSETS[Math.floor(rand() * DAY_OFFSETS.length)]!;
      expiry = isoDateOnly(pinMs + off * MS_PER_DAY);
    } else if (mode <= 7) {
      const base = TS_OFFSETS_MS[Math.floor(rand() * TS_OFFSETS_MS.length)]!;
      const jitter = Math.round((rand() * 2 - 1) * 2000);
      expiry = new Date(pinMs + base + jitter).toISOString();
    } else if (mode === 8) {
      if (i % 110 === 8) {
        const special = EXACT_INSTANT_SPECIALS[Math.floor(i / 110) % EXACT_INSTANT_SPECIALS.length]!;
        expiry = new Date(pinMs + special).toISOString();
      } else {
        expiry = new Date(pinMs + Math.round((rand() * 2 - 1) * 48 * 3_600_000)).toISOString();
      }
    } else {
      expiry = EDGE_EXPIRIES[Math.floor(i / 10) % EDGE_EXPIRIES.length];
    }

    const qMode = i % 5;
    let grams: number;
    if (qMode === 0) grams = 50;
    else if (qMode === 1) grams = round3(49.999 + rand() * 0.002);
    else if (qMode === 2) grams = round3(50.0001 + rand() * 0.001);
    else if (qMode === 3) grams = round3(rand() * 120);
    else grams = round3(120 + rand() * 600);
    if (i % 401 === 400) grams = NaN;

    const sameNameAsPrevious = i % 29 === 28 && items.length > 0;
    if (sameNameAsPrevious) meta.sameNamePartialDuplicates++;

    if (i % 17 === 16 && items.length > 0) {
      // Exact duplicate of the previous item (name, expiry, grams). Clones
      // consume no PRNG draws so generation stays deterministic.
      items.push({ ...items[i - 1]! });
      meta.duplicateClones++;
      continue;
    }

    items.push({
      ingredientName: sameNameAsPrevious ? items[i - 1]!.ingredientName : VOCAB[i % VOCAB.length]!,
      quantityGrams: grams,
      ...(expiry !== undefined ? { expiresAt: expiry } : {}),
    });
  }

  // Derive every content counter from the FINAL array. Counting during the loop
  // drifts whenever the clone branch replaces an item that was already counted.
  // Falsy predicates match production's `if (!expiresAt) continue` skip: empty
  // strings are missing dates, never invalid ones.
  const dateOnlyRe = /^\d{4}-\d{2}-\d{2}$/;
  meta.missingDates = items.filter((it) => !it.expiresAt).length;
  meta.invalidDates = items.filter(
    (it) => it.expiresAt && Number.isNaN(new Date(it.expiresAt).getTime())
  ).length;
  meta.dateOnlyExpiries = items.filter(
    (it) => it.expiresAt && dateOnlyRe.test(it.expiresAt)
  ).length;
  meta.timestampedExpiries = items.filter(
    (it) =>
      it.expiresAt &&
      !dateOnlyRe.test(it.expiresAt) &&
      !Number.isNaN(new Date(it.expiresAt).getTime())
  ).length;
  meta.nanGrams = items.filter((it) => Number.isNaN(it.quantityGrams)).length;
  meta.itemCount = items.length;
  return { items, meta };
}

// ─── Scenarios and classification ────────────────────────────────────────────

export interface ScenarioDef {
  name: string;
  suffix: string;
  thresholdDays: number;
}

export const SCENARIOS: ScenarioDef[] = [
  { name: "t1", suffix: "1", thresholdDays: 1 },
  { name: "t3", suffix: "3", thresholdDays: 3 },
];

export const DEFAULT_CUTOFF = 50;

export type BucketCounts = Record<ExpiryBucket, number>;

export interface ScenarioOutcome {
  scenario: string;
  thresholdDays: number;
  /** Real generatedAt observed under the pinned clock. */
  generatedAt: string;
  counts: {
    items: number;
    alertedA: number;
    alertedB: number;
    inclusionDivergence: number;
    expiredUseSoonFlip: number;
    daysMismatch: number;
    expiredAlertsClampedToZero: number;
  };
  bucketsA: BucketCounts;
  bucketsB: BucketCounts;
  divergenceExamples: Array<{
    i: number;
    n: string;
    e: string;
    A: ExpiryBucket;
    B: ExpiryBucket;
    raw: number;
    refDiff: number;
  }>;
  parity: {
    alertsEqual: boolean;
    restockListEqual: boolean;
  };
}

export interface MatrixRecord {
  i: number;
  n: string;
  e: string | null;
  q: number | "NaN";
  [key: string]: unknown; // per-scenario: A1,B1,a1,b1,x1 / A3,B3,a3,b3,x3
}

export interface Check {
  name: string;
  passed: boolean;
  detail: string;
}

export interface PipelineCore {
  pinMs: number;
  items: InventoryItem[];
  meta: MatrixMeta;
  perScenario: Record<string, ScenarioOutcome>;
  records: MatrixRecord[];
  invariance: {
    permutations: number;
    restockListInvariant: boolean;
    alertsMultisetInvariant: boolean;
    tieReorderCount: number;
  };
  duplicates: {
    restockListLength: number;
    belowCutoffCount: number;
    noDedupConfirmed: boolean;
    namesWithMultipleEntries: Array<{ name: string; count: number }>;
  };
  generatedAtRepeatable: boolean;
}

function emptyBuckets(): BucketCounts {
  return { missing: 0, invalid: 0, expired: 0, "use-soon": 0, ok: 0 };
}

/**
 * Map the real alerts back onto items by (name, expiresAt) multiset so every
 * classification is anchored in genuine production output.
 */
function mapRealAlerts(
  items: InventoryItem[],
  alerts: UseSoonAlert[]
): Array<{ alerted: boolean; displayDays?: number }> {
  const multiset = new Map<string, number[]>();
  for (const a of alerts) {
    const key = `${a.ingredientName}\u0000${a.expiresAt}`;
    const arr = multiset.get(key);
    if (arr) arr.push(a.daysRemaining);
    else multiset.set(key, [a.daysRemaining]);
  }
  return items.map((item) => {
    if (!item.expiresAt) return { alerted: false };
    const key = `${item.ingredientName}\u0000${item.expiresAt}`;
    const arr = multiset.get(key);
    if (!arr || arr.length === 0) return { alerted: false };
    const days = arr.shift()!;
    return { alerted: true, displayDays: days };
  });
}

function canonicalAlerts(alerts: UseSoonAlert[]): string {
  return JSON.stringify(
    [...alerts]
      .map((a) => `${a.ingredientName}\u0000${a.expiresAt}\u0000${a.daysRemaining}`)
      .sort()
  );
}

function seededShuffle<T>(items: T[], rand: () => number): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    const tmp = out[i]!;
    out[i] = out[j]!;
    out[j] = tmp;
  }
  return out;
}

/** One full deterministic computation. Running it twice must agree exactly. */
function computeCore(seed: number): PipelineCore {
  const pinMs = pinFromSeed(seed);
  const { items, meta } = generateItems(seed);
  const perScenario: Record<string, ScenarioOutcome> = {};
  const records: MatrixRecord[] = [];
  const realViewsByScenario = new Map<string, Array<{ alerted: boolean; displayDays?: number }>>();

  setSystemTime(pinMs);
  try {
    for (const scenario of SCENARIOS) {
      // Real production functions under the pinned clock.
      const useSoon = computeUseSoon(items, scenario.thresholdDays);
      const restockList = computeRestockList(items, DEFAULT_CUTOFF);
      const realViews = mapRealAlerts(items, useSoon);
      realViewsByScenario.set(scenario.name, realViews);

      // Parity: the reference mirror must reproduce the real outputs exactly.
      const refAlerts = referenceComputeUseSoon(items, pinMs, scenario.thresholdDays);
      const refList = referenceComputeRestockList(items, DEFAULT_CUTOFF);

      const bucketsA = emptyBuckets();
      const bucketsB = emptyBuckets();
      const outcome: ScenarioOutcome = {
        scenario: scenario.name,
        thresholdDays: scenario.thresholdDays,
        generatedAt: new Date(pinMs).toISOString(), // verified against the real plan below
        counts: {
          items: items.length,
          alertedA: 0,
          alertedB: 0,
          inclusionDivergence: 0,
          expiredUseSoonFlip: 0,
          daysMismatch: 0,
          expiredAlertsClampedToZero: 0,
        },
        bucketsA,
        bucketsB,
        divergenceExamples: [],
        parity: {
          alertsEqual: canonicalAlerts(refAlerts) === canonicalAlerts(useSoon),
          restockListEqual: JSON.stringify(refList) === JSON.stringify(restockList),
        },
      };

      // generatedAt comes from the REAL buildRestockPlan under the same pin.
      const realPlan = buildRestockPlan({
        inventorySnapshot: items,
        thresholdDays: scenario.thresholdDays,
        restockBelowGrams: DEFAULT_CUTOFF,
      });
      outcome.generatedAt = realPlan.generatedAt;

      items.forEach((item, idx) => {
        const viewA = classifyA(item, pinMs, scenario.thresholdDays);
        const viewB = classifyB(item, pinMs, scenario.thresholdDays);
        const realView = realViews[idx]!;

        bucketsA[viewA.bucket]!++;
        bucketsB[viewB.bucket]!++;
        if (viewA.alerted) outcome.counts.alertedA++;
        if (viewB.alerted) outcome.counts.alertedB++;

        if (viewA.alerted !== viewB.alerted) outcome.counts.inclusionDivergence++;
        const aExpired = viewA.bucket === "expired";
        const bExpired = viewB.bucket === "expired";
        if (aExpired !== bExpired) outcome.counts.expiredUseSoonFlip++;
        if (aExpired && realView.alerted && realView.displayDays === 0) {
          outcome.counts.expiredAlertsClampedToZero++;
        }
        if (viewA.alerted && viewB.alerted && realView.alerted) {
          if (realView.displayDays! !== viewB.refDiff!) outcome.counts.daysMismatch++;
        }

        if (
          (viewA.alerted !== viewB.alerted || aExpired !== bExpired || viewA.bucket !== viewB.bucket) &&
          outcome.divergenceExamples.length < 200
        ) {
          outcome.divergenceExamples.push({
            i: idx,
            n: item.ingredientName,
            e: item.expiresAt ?? "",
            A: viewA.bucket,
            B: viewB.bucket,
            raw: viewA.raw ?? Number.NaN,
            refDiff: viewB.refDiff ?? Number.NaN,
          });
        }

        if (scenario.name === SCENARIOS[0]!.name) {
          records.push({
            i: idx,
            n: item.ingredientName,
            e: item.expiresAt ?? null,
            q: Number.isNaN(item.quantityGrams) ? "NaN" : item.quantityGrams,
          });
        }
      });

      perScenario[scenario.name] = outcome;
    }

    // Fill per-scenario record fields.
    for (const scenario of SCENARIOS) {
      const views = realViewsByScenario.get(scenario.name)!;
      items.forEach((item, idx) => {
        const viewA = classifyA(item, pinMs, scenario.thresholdDays);
        const viewB = classifyB(item, pinMs, scenario.thresholdDays);
        const realView = views[idx]!;
        const rec = records[idx]!;
        rec[`A${scenario.suffix}`] = viewA.bucket;
        rec[`B${scenario.suffix}`] = viewB.bucket;
        if (realView.alerted) rec[`a${scenario.suffix}`] = realView.displayDays;
        if (viewB.alerted) rec[`b${scenario.suffix}`] = viewB.refDiff;
        rec[`x${scenario.suffix}`] =
          viewA.alerted !== viewB.alerted || viewA.bucket !== viewB.bucket;
      });
    }

    // Invariance: seeded permutations through the REAL granular functions.
    const baseUseSoon = computeUseSoon(items, SCENARIOS[1]!.thresholdDays);
    const baseList = JSON.stringify(computeRestockList(items, DEFAULT_CUTOFF));
    const baseAlertsCanonical = canonicalAlerts(baseUseSoon);
    const baseAlertsSequence = JSON.stringify(baseUseSoon);
    let restockListInvariant = true;
    let alertsMultisetInvariant = true;
    let tieReorderCount = 0;
    const permutations = 25;
    for (let k = 1; k <= permutations; k++) {
      const shuffled = seededShuffle(items, mulberry32((seed ^ Math.imul(0x9e3779b9, k)) >>> 0));
      const shuffledAlerts = computeUseSoon(shuffled, SCENARIOS[1]!.thresholdDays);
      if (JSON.stringify(computeRestockList(shuffled, DEFAULT_CUTOFF)) !== baseList) {
        restockListInvariant = false;
      }
      if (canonicalAlerts(shuffledAlerts) !== baseAlertsCanonical) {
        alertsMultisetInvariant = false;
      } else if (JSON.stringify(shuffledAlerts) !== baseAlertsSequence) {
        tieReorderCount++;
      }
    }

    // Duplicates: the restock list keeps one entry per below-cutoff item.
    const belowCutoff = items.filter((i) => i.quantityGrams < DEFAULT_CUTOFF);
    const restockListFinal = computeRestockList(items, DEFAULT_CUTOFF);
    const listCounts = new Map<string, number>();
    for (const name of restockListFinal) {
      listCounts.set(name, (listCounts.get(name) ?? 0) + 1);
    }
    const namesWithMultipleEntries = [...listCounts.entries()]
      .filter(([, c]) => c > 1)
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => a.name.localeCompare(b.name));

    return {
      pinMs,
      items,
      meta,
      perScenario,
      records,
      invariance: { permutations, restockListInvariant, alertsMultisetInvariant, tieReorderCount },
      duplicates: {
        restockListLength: restockListFinal.length,
        belowCutoffCount: belowCutoff.length,
        noDedupConfirmed: restockListFinal.length === belowCutoff.length,
        namesWithMultipleEntries,
      },
      generatedAtRepeatable: false, // filled by runPipeline's two-pass comparison
    };
  } finally {
    setSystemTime();
  }
}

export function runPipeline(seed: number): PipelineResult {
  const core = computeCore(seed);
  // Determinism contract: a second full pass must produce identical content.
  const repeat = computeCore(seed);
  const stripCore = (c: PipelineCore) =>
    JSON.stringify({
      perScenario: c.perScenario,
      records: c.records,
      invariance: c.invariance,
      duplicates: c.duplicates,
      meta: c.meta,
    });
  const generatedAtRepeatable = stripCore(core) === stripCore(repeat);
  core.generatedAtRepeatable = generatedAtRepeatable;

  const checks = buildChecks(core);
  const pinISO = new Date(core.pinMs).toISOString();

  return {
    manifest: {
      tool: "restock-boundaries",
      seed,
      pinISO,
      scenarios: SCENARIOS.map((s) => ({ name: s.name, thresholdDays: s.thresholdDays })),
      restockBelowGrams: DEFAULT_CUTOFF,
      itemCount: core.items.length,
      matrixMeta: core.meta,
      bunVersion: Bun.version,
      generatedAt: pinISO,
    },
    records: core.records,
    summary: {
      perScenario: core.perScenario,
      invariance: core.invariance,
      duplicates: core.duplicates,
      generatedAtRepeatable,
      checks,
    },
  };
}

export interface PipelineResult {
  manifest: {
    tool: "restock-boundaries";
    seed: number;
    pinISO: string;
    scenarios: Array<{ name: string; thresholdDays: number }>;
    restockBelowGrams: number;
    itemCount: number;
    matrixMeta: MatrixMeta;
    bunVersion: string;
    generatedAt: string;
  };
  records: MatrixRecord[];
  summary: {
    perScenario: Record<string, ScenarioOutcome>;
    invariance: PipelineCore["invariance"];
    duplicates: PipelineCore["duplicates"];
    generatedAtRepeatable: boolean;
    checks: Check[];
  };
}

function buildChecks(core: PipelineCore): Check[] {
  const { perScenario, meta, items, duplicates, invariance, pinMs, generatedAtRepeatable } = core;
  const checks: Check[] = [];
  const scenarios = Object.values(perScenario);

  const parityOK = scenarios.every((s) => s.parity.alertsEqual && s.parity.restockListEqual);
  checks.push({
    name: "parityReferenceEqualsProduction",
    passed: parityOK,
    detail:
      "reference mirror reproduces real computeUseSoon and computeRestockList output exactly (both scenarios, all items)",
  });

  const generatedAtOK = scenarios.every((s) => s.generatedAt === new Date(pinMs).toISOString());
  checks.push({
    name: "generatedAtPinnedToClock",
    passed: generatedAtOK,
    detail: `real buildRestockPlan reported generatedAt === ${new Date(pinMs).toISOString()} under the pinned clock`,
  });
  checks.push({
    name: "generatedAtRepeatable",
    passed: generatedAtRepeatable,
    detail: "two independent full pipeline passes produced byte-identical deterministic content",
  });

  checks.push({
    name: "restockListPermutationInvariant",
    passed: invariance.restockListInvariant,
    detail: `${invariance.permutations} seeded shuffles produced an identical restock list`,
  });
  checks.push({
    name: "alertsMultisetPermutationInvariant",
    passed: invariance.alertsMultisetInvariant,
    detail: `${invariance.permutations} shuffles preserved the alert multiset; ${invariance.tieReorderCount} reordered equal-daysRemaining ties (stable-sort tie order follows input order)`,
  });

  checks.push({
    name: "restockListNoDedup",
    passed: duplicates.noDedupConfirmed,
    detail: `restockList length ${duplicates.restockListLength} equals below-cutoff item count ${duplicates.belowCutoffCount} (duplicate names are kept, not deduplicated)`,
  });

  // Threshold-equality coverage: some alerted item sits exactly at the threshold.
  const equalityPresent = scenarios.some((s) =>
    items.some((item) => {
      if (!item.expiresAt) return false;
      const expiryMs = new Date(item.expiresAt).getTime();
      if (Number.isNaN(expiryMs)) return false;
      return rawElapsedDays(expiryMs, pinMs) === s.thresholdDays;
    })
  );
  checks.push({
    name: "thresholdEqualityCasePresent",
    passed: equalityPresent,
    detail:
      "matrix contains items whose elapsed daysRemaining exactly equals the scenario threshold (inclusive <= alerting is exercised)",
  });

  const exactCutoffPresent = items.some((i) => i.quantityGrams === DEFAULT_CUTOFF);
  checks.push({
    name: "exactCutoffExcluded",
    passed: exactCutoffPresent && duplicates.noDedupConfirmed,
    detail: `matrix contains items with exactly ${DEFAULT_CUTOFF}g and restockList accounting proves strict < (a 50g item in the list would break length == below-cutoff count)`,
  });

  const invalidOK =
    meta.invalidDates > 0 &&
    scenarios.every((s) => s.bucketsA.invalid === meta.invalidDates && s.bucketsB.invalid === meta.invalidDates);
  checks.push({
    name: "invalidDatesPresentAndNeverAlerted",
    passed: invalidOK,
    detail: `${meta.invalidDates} unparsable dates are silently dropped under both interpretations`,
  });

  const missingOK =
    meta.missingDates > 0 &&
    scenarios.every((s) => s.bucketsA.missing === meta.missingDates && s.bucketsB.missing === meta.missingDates);
  checks.push({
    name: "missingDatesPresentAndNeverAlerted",
    passed: missingOK,
    detail: `${meta.missingDates} missing/empty dates are skipped under both interpretations`,
  });

  const expiredPresent = scenarios.every((s) => s.bucketsA.expired > 0 && s.bucketsB.expired > 0);
  checks.push({
    name: "expiredItemsPresent",
    passed: expiredPresent,
    detail: `expired bucket counts per scenario (A): ${scenarios.map((s) => s.bucketsA.expired).join(", ")}`,
  });

  const clampOK = scenarios.every(
    (s) => s.counts.expiredAlertsClampedToZero === s.bucketsA.expired
  );
  checks.push({
    name: "expiredDisplayClampedToZero",
    passed: clampOK,
    detail:
      "every expired item's real alert displays daysRemaining === 0 — production output cannot distinguish expired from use-soon; the distinction lives in the raw pre-clamp arithmetic recorded here",
  });

  const distinctOK = scenarios.every(
    (s) => s.bucketsA.expired > 0 && s.bucketsA["use-soon"] > 0 && s.bucketsB.expired > 0 && s.bucketsB["use-soon"] > 0
  );
  checks.push({
    name: "expiredUseSoonDistinctBuckets",
    passed: distinctOK,
    detail: "expired and use-soon are tracked as separate buckets for both interpretations",
  });

  return checks;
}
