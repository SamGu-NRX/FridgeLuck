import { createHash } from "node:crypto";
import type {
  InventoryItem,
  NotificationOpportunity,
  NotificationPlanRequest,
  NotificationPlanResponse
} from "../types/contracts.js";

const MS_PER_MINUTE = 60 * 1000;
const MS_PER_HOUR = 60 * MS_PER_MINUTE;
const MS_PER_DAY = 24 * MS_PER_HOUR;
const USE_SOON_THRESHOLD_DAYS = 2;
const USE_SOON_DIGEST_CAP = 3;

/**
 * Scheduling policy (local calendar semantics, never elapsed-hour arithmetic):
 * - A rule wall time resolves to instants on the next local dates.
 * - Nonexistent wall time (spring-forward gap): the first valid instant after
 *   the gap on that date, i.e. the transition instant itself.
 * - Repeated wall time (fall-back fold): the earliest matching occurrence
 *   strictly after "now"; if none remains on that local date, the next day.
 * - Candidate eligibility is evaluated against the scheduled fire time, so an
 *   item that expires before the digest fires is not advertised.
 */

interface UseSoonCandidate {
  ingredientId: number;
  ingredientName: string;
  expiresAt: string;
  daysRemaining: number;
}

interface ZonedWallClock {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

/** Real zone offsets stay within ±18h, so probing a day around one instant discovers every offset regime relevant to a wall time. */
const OFFSET_PROBE_DELTAS_MS = [
  0,
  30 * MS_PER_MINUTE,
  MS_PER_HOUR,
  2 * MS_PER_HOUR,
  3 * MS_PER_HOUR,
  6 * MS_PER_HOUR,
  12 * MS_PER_HOUR,
  24 * MS_PER_HOUR
];
const FIXED_POINT_ITERATION_LIMIT = 8;
const NEXT_LOCAL_DAY_SEARCH_LIMIT = 8;

export function buildNotificationPlan(req: NotificationPlanRequest): NotificationPlanResponse {
  const generatedAt = new Date(req.generatedAt || Date.now());
  const generatedAtIso = generatedAt.toISOString();
  const useSoonRule = req.rules.find((rule) => rule.kind === "use_soon_alerts");

  if (!useSoonRule?.enabled) {
    return {
      generatedAt: generatedAtIso,
      opportunities: []
    };
  }

  const scheduledAt = nextScheduledAt({
    baseDate: generatedAt,
    timeZone: req.timezone,
    hour: useSoonRule.hour,
    minute: useSoonRule.minute
  });

  if (scheduledAt.getTime() <= generatedAt.getTime()) {
    // Invariant guard: nextScheduledAt must return a strictly future instant.
    return {
      generatedAt: generatedAtIso,
      opportunities: []
    };
  }

  const candidates = collectUseSoonCandidates(req.inventorySnapshot, generatedAt, scheduledAt);
  if (candidates.length === 0) {
    return {
      generatedAt: generatedAtIso,
      opportunities: []
    };
  }

  const topCandidates = candidates.slice(0, USE_SOON_DIGEST_CAP);
  const opportunity = buildUseSoonDigest(topCandidates, scheduledAt);

  return {
    generatedAt: generatedAtIso,
    opportunities: opportunity ? [opportunity] : []
  };
}

function collectUseSoonCandidates(
  items: InventoryItem[],
  generatedAt: Date,
  scheduledAt: Date
): UseSoonCandidate[] {
  const now = generatedAt.getTime();
  const scheduledMs = scheduledAt.getTime();

  // Group by the (ingredientId, ingredientName) tuple: duplicate lots of the
  // same ingredient collapse onto one entry using the earliest expiry, while
  // conflicting names for one id stay separate entries instead of being
  // silently recombined under a single label.
  interface LotGroup {
    ingredientId: number;
    ingredientName: string;
    earliestExpiryMs: number;
  }
  const lots = new Map<string, LotGroup>();
  const namesByIngredientId = new Map<number, Set<string>>();

  for (const item of items) {
    if (!item.expiresAt) continue;
    const expiry = new Date(item.expiresAt);
    if (Number.isNaN(expiry.getTime())) continue;
    // Eligibility must hold at the scheduled fire time, not only at planning
    // time: an item that expires before the digest fires is not actionable.
    if (expiry.getTime() <= scheduledMs) continue;

    const ingredientId = item.ingredientId ?? 0;
    const key = `${ingredientId}\u0000${item.ingredientName}`;
    const existing = lots.get(key);
    if (existing) {
      existing.earliestExpiryMs = Math.min(existing.earliestExpiryMs, expiry.getTime());
    } else {
      lots.set(key, {
        ingredientId,
        ingredientName: item.ingredientName,
        earliestExpiryMs: expiry.getTime()
      });
    }

    const names = namesByIngredientId.get(ingredientId) ?? new Set<string>();
    names.add(item.ingredientName);
    namesByIngredientId.set(ingredientId, names);
  }

  for (const [ingredientId, names] of namesByIngredientId) {
    if (names.size > 1) {
      console.log(
        JSON.stringify({
          severity: "WARN",
          message: "notification_plan: conflicting_ingredient_names",
          ingredientId,
          names: [...names].sort(),
          timestamp: new Date().toISOString()
        })
      );
    }
  }

  return [...lots.values()]
    .map((lot) => ({
      ingredientId: lot.ingredientId,
      ingredientName: lot.ingredientName,
      expiresAt: new Date(lot.earliestExpiryMs).toISOString(),
      daysRemaining: Math.max(0, Math.ceil((lot.earliestExpiryMs - now) / MS_PER_DAY))
    }))
    .filter((candidate) => candidate.daysRemaining <= USE_SOON_THRESHOLD_DAYS)
    .sort(compareUseSoonCandidates);
}

/**
 * Canonical total order for digest entries: urgency first, then name/id/expiry
 * as deterministic codepoint tie-breakers. Sorting full tuples (never one
 * payload array independently) keeps ids, names, and expiries aligned and makes
 * the resulting order — and therefore the notification id — independent of the
 * inventory input order.
 */
function compareUseSoonCandidates(left: UseSoonCandidate, right: UseSoonCandidate): number {
  if (left.daysRemaining !== right.daysRemaining) {
    return left.daysRemaining - right.daysRemaining;
  }
  if (left.ingredientName !== right.ingredientName) {
    return left.ingredientName < right.ingredientName ? -1 : 1;
  }
  if (left.ingredientId !== right.ingredientId) {
    return left.ingredientId - right.ingredientId;
  }
  if (left.expiresAt !== right.expiresAt) {
    return left.expiresAt < right.expiresAt ? -1 : 1;
  }
  return 0;
}

function buildUseSoonDigest(
  candidates: UseSoonCandidate[],
  scheduledAt: Date
): NotificationOpportunity | null {
  if (candidates.length === 0) return null;

  // Candidates arrive in canonical order; map the aligned tuples straight
  // across. Never sort a payload array independently of the others.
  const ingredientIds = candidates.map((candidate) => candidate.ingredientId);
  const ingredientNames = candidates.map((candidate) => candidate.ingredientName);
  const expiresAt = candidates.map((candidate) => candidate.expiresAt);

  const dayKey = scheduledAt.toISOString().slice(0, 10);
  const stableInput = `${dayKey}:${ingredientIds.join(",")}:${ingredientNames.join(",")}`;
  const id = createHash("sha1").update(stableInput).digest("hex").slice(0, 16);

  const previewNames = ingredientNames.slice(0, 2).join(", ");
  const remaining = Math.max(0, ingredientNames.length - 2);
  const suffix = remaining > 0 ? ` and ${remaining} more` : "";

  return {
    id,
    kind: "use_soon_digest",
    title: "Use these ingredients soon",
    body: `${previewNames}${suffix} should be cooked before they slip past their best days.`,
    scheduledAt: scheduledAt.toISOString(),
    payload: {
      ingredientIds,
      ingredientNames,
      expiresAt
    }
  };
}

function nextScheduledAt({
  baseDate,
  timeZone,
  hour,
  minute
}: {
  baseDate: Date;
  timeZone: string;
  hour: number;
  minute: number;
}): Date {
  // Normalize out-of-range rule fields (e.g. hour 24 or minute 90) into day
  // carries so they mean "next local day", matching Date.UTC overflow behavior.
  const totalMinutes = Math.floor(hour) * 60 + Math.floor(minute);
  const normalizedMinute = ((totalMinutes % 60) + 60) % 60;
  const totalHours = Math.floor(totalMinutes / 60);
  const normalizedHour = ((totalHours % 24) + 24) % 24;
  const dayCarry = Math.floor(totalHours / 24);

  const nowWall = zonedWallClock(baseDate, timeZone);

  // Advance one LOCAL date at a time. Adding 24 elapsed hours (the previous
  // behavior) can land on the same local date after a fall-back transition or
  // skip a date after a spring-forward one.
  for (let dayOffset = 0; dayOffset < NEXT_LOCAL_DAY_SEARCH_LIMIT; dayOffset++) {
    const localDate = addLocalDays(nowWall.year, nowWall.month, nowWall.day, dayOffset + dayCarry);
    const occurrences = resolveZonedWallClock(timeZone, {
      ...localDate,
      hour: normalizedHour,
      minute: normalizedMinute,
      second: 0
    });

    // Policy: the earliest matching occurrence strictly after now wins; if the
    // local date offers none, move to the next local day.
    const occurrence = occurrences.find((instant) => instant.getTime() > baseDate.getTime());
    if (occurrence) return occurrence;
  }

  throw new Error(
    `No upcoming occurrence of ${normalizedHour}:${normalizedMinute} in ${timeZone} within ${NEXT_LOCAL_DAY_SEARCH_LIMIT} local days.`
  );
}

function addLocalDays(
  year: number,
  month: number,
  day: number,
  days: number
): { year: number; month: number; day: number } {
  // Noon anchor + UTC day-field overflow: pure calendar arithmetic, no zone
  // offsets involved, so DST transitions cannot bend the date.
  const anchor = utcMsFromWall({ year, month, day: day + days, hour: 12, minute: 0, second: 0 });
  const date = new Date(anchor);
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() };
}

const zonedFormatterCache = new Map<string, Intl.DateTimeFormat>();

function zonedWallFormatter(timeZone: string): Intl.DateTimeFormat {
  let formatter = zonedFormatterCache.get(timeZone);
  if (!formatter) {
    if (zonedFormatterCache.size >= 64) zonedFormatterCache.clear();
    // hourCycle "h23" is mandatory: `hour12: false` resolves to the h24 cycle
    // on some ICU builds, which formats local midnight as "24:00" and corrupts
    // every downstream day computation built from the hour field.
    formatter = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    });
    zonedFormatterCache.set(timeZone, formatter);
  }
  return formatter;
}

function zonedWallClock(date: Date, timeZone: string): ZonedWallClock {
  const formatter = zonedWallFormatter(timeZone);
  const parts = formatter
    .formatToParts(date)
    .filter((part) => part.type !== "literal")
    .map((part) => [part.type, Number(part.value)] as const);
  const values = Object.fromEntries(parts) as Record<string, number>;

  let year = values.year!;
  let month = values.month!;
  let day = values.day!;
  let hour = values.hour!;
  const minute = values.minute!;
  const second = values.second!;

  if (hour > 23) {
    // Defensive: a runtime that still reports h24-style "24:00" for midnight.
    // Wall "24:00" on day D is the same instant as 00:00 on day D+1.
    hour -= 24;
    const rolled = addLocalDays(year, month, day, 1);
    year = rolled.year;
    month = rolled.month;
    day = rolled.day;
  }

  return { year, month, day, hour, minute, second };
}

function utcMsFromWall(wall: ZonedWallClock): number {
  const ms = Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second);
  if (wall.year >= 0 && wall.year <= 99) {
    // Date.UTC maps years 0-99 onto 1900-1999; restore the intended year.
    const date = new Date(ms);
    date.setUTCFullYear(wall.year);
    return date.getTime();
  }
  return ms;
}

/**
 * Offset between the zone's wall clock and UTC at a given instant (wall - utc),
 * e.g. America/Chicago during CDT: 03:00 - 08:00Z = -5h.
 */
function timeZoneOffsetMs(date: Date, timeZone: string): number {
  // Zone offsets are whole seconds and do not depend on sub-second parts;
  // quantize the instant to the second so offset comparisons stay exact even
  // for probe instants with millisecond remainders.
  const secondMs = Math.floor(date.getTime() / 1000) * 1000;
  const wall = zonedWallClock(new Date(secondMs), timeZone);
  return utcMsFromWall(wall) - secondMs;
}

function wallMatches(date: Date, timeZone: string, wall: ZonedWallClock): boolean {
  const actual = zonedWallClock(date, timeZone);
  return (
    actual.year === wall.year &&
    actual.month === wall.month &&
    actual.day === wall.day &&
    actual.hour === wall.hour &&
    actual.minute === wall.minute &&
    actual.second === wall.second
  );
}

/**
 * Resolve a wall-clock time on a specific local date to the UTC instants whose
 * zoned wall clock equals it, in ascending order.
 * - Ordinary time: one instant.
 * - Repeated (fold) time: two instants, earliest first.
 * - Nonexistent (gap) time: the first valid instant after the gap on that date
 *   (the transition instant itself).
 * - Unresolvable: empty array (the caller advances to the next local day).
 */
function resolveZonedWallClock(timeZone: string, wall: ZonedWallClock): Date[] {
  const targetMs = utcMsFromWall(wall);

  // Fixed-point iteration: find an instant whose zone offset maps the requested
  // wall clock back onto itself. Oscillation means the wall time does not exist
  // (spring-forward gap): the mapping bounces across the transition instant.
  let current = targetMs;
  const visitedMs: number[] = [current];
  let gapWindow: { lowMs: number; highMs: number } | null = null;

  for (let iteration = 0; iteration < FIXED_POINT_ITERATION_LIMIT; iteration++) {
    const offsetMs = timeZoneOffsetMs(new Date(current), timeZone);
    const next = targetMs - offsetMs;

    if (next === current) break;

    if (visitedMs.includes(next)) {
      gapWindow = { lowMs: Math.min(...visitedMs, next), highMs: Math.max(...visitedMs, next) };
      break;
    }

    visitedMs.push(next);
    current = next;
  }

  if (gapWindow) {
    return [findGapTransitionInstant(timeZone, gapWindow.lowMs, gapWindow.highMs)];
  }

  const probeMs = wallMatches(new Date(current), timeZone, wall) ? current : targetMs;
  return enumerateWallOccurrences(timeZone, wall, probeMs);
}

/**
 * Find every instant whose zoned wall clock equals `wall` on its local date, by
 * enumerating the offset regimes in effect around `probeMs` (and around each
 * match). Real zones change offset at most a few times per year, so offsets
 * sampled within a day of one occurrence cover both sides of any same-day
 * transition — including both instants of a fall-back fold.
 */
function enumerateWallOccurrences(timeZone: string, wall: ZonedWallClock, probeMs: number): Date[] {
  const targetMs = utcMsFromWall(wall);
  const seenOffsets = new Set<number>();
  const offsetsToProbe: number[] = [];
  const occurrenceMs: number[] = [];

  const queueOffset = (offsetMs: number) => {
    if (!seenOffsets.has(offsetMs)) {
      seenOffsets.add(offsetMs);
      offsetsToProbe.push(offsetMs);
    }
  };

  for (const deltaMs of OFFSET_PROBE_DELTAS_MS) {
    for (const sign of [1, -1] as const) {
      queueOffset(timeZoneOffsetMs(new Date(probeMs + sign * deltaMs), timeZone));
    }
  }

  while (offsetsToProbe.length > 0) {
    const offsetMs = offsetsToProbe.pop()!;
    const instantMs = targetMs - offsetMs;
    if (!wallMatches(new Date(instantMs), timeZone, wall)) continue;

    occurrenceMs.push(instantMs);
    for (const deltaMs of OFFSET_PROBE_DELTAS_MS) {
      for (const sign of [1, -1] as const) {
        queueOffset(timeZoneOffsetMs(new Date(instantMs + sign * deltaMs), timeZone));
      }
    }
  }

  return [...new Set(occurrenceMs)].sort((left, right) => left - right).map((ms) => new Date(ms));
}

/**
 * Binary-search the instant where the zone offset changes, given a window whose
 * endpoints sit in different offset regimes. The result is the first instant of
 * the new regime: the first valid wall clock after the gap.
 */
function findGapTransitionInstant(timeZone: string, lowMs: number, highMs: number): Date {
  const low = Math.min(lowMs, highMs);
  const high = Math.max(lowMs, highMs);
  const beforeOffsetMs = timeZoneOffsetMs(new Date(low), timeZone);

  // Invariant: offset(low) === beforeOffsetMs, offset(high) !== beforeOffsetMs.
  if (timeZoneOffsetMs(new Date(high), timeZone) === beforeOffsetMs) {
    // No regime change inside the window; fall back to the window's end.
    return new Date(high);
  }

  let lowBound = low;
  let highBound = high;
  while (highBound - lowBound > 1) {
    const midMs = lowBound + Math.floor((highBound - lowBound) / 2);
    if (timeZoneOffsetMs(new Date(midMs), timeZone) === beforeOffsetMs) {
      lowBound = midMs;
    } else {
      highBound = midMs;
    }
  }

  return new Date(highBound);
}
