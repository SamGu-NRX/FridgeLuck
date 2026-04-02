import { createHash } from "node:crypto";
import type {
  InventoryItem,
  NotificationOpportunity,
  NotificationPlanRequest,
  NotificationPlanResponse
} from "../types/contracts.js";

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const USE_SOON_THRESHOLD_DAYS = 2;

interface UseSoonCandidate {
  ingredientId: number;
  ingredientName: string;
  expiresAt: string;
  daysRemaining: number;
}

export function buildNotificationPlan(req: NotificationPlanRequest): NotificationPlanResponse {
  const generatedAt = new Date(req.generatedAt || Date.now());
  const useSoonRule = req.rules.find((rule) => rule.kind === "use_soon_alerts");

  if (!useSoonRule?.enabled) {
    return {
      generatedAt: generatedAt.toISOString(),
      opportunities: []
    };
  }

  const candidates = collectUseSoonCandidates(req.inventorySnapshot, generatedAt);
  if (candidates.length === 0) {
    return {
      generatedAt: generatedAt.toISOString(),
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
    return {
      generatedAt: generatedAt.toISOString(),
      opportunities: []
    };
  }

  const topCandidates = candidates.slice(0, 3);
  const opportunity = buildUseSoonDigest(topCandidates, scheduledAt);

  return {
    generatedAt: generatedAt.toISOString(),
    opportunities: opportunity ? [opportunity] : []
  };
}

function collectUseSoonCandidates(items: InventoryItem[], generatedAt: Date): UseSoonCandidate[] {
  const now = generatedAt.getTime();

  return items
    .flatMap((item) => {
      if (!item.expiresAt) return [];
      const expiry = new Date(item.expiresAt);
      if (Number.isNaN(expiry.getTime())) return [];
      if (expiry.getTime() < now) return [];

      const daysRemaining = Math.ceil((expiry.getTime() - now) / MS_PER_DAY);
      if (daysRemaining > USE_SOON_THRESHOLD_DAYS) return [];

      return [{
        ingredientId: item.ingredientId ?? 0,
        ingredientName: item.ingredientName,
        expiresAt: expiry.toISOString(),
        daysRemaining: Math.max(0, daysRemaining)
      }];
    })
    .sort((left, right) => {
      if (left.daysRemaining !== right.daysRemaining) {
        return left.daysRemaining - right.daysRemaining;
      }
      return left.ingredientName.localeCompare(right.ingredientName);
    });
}

function buildUseSoonDigest(
  candidates: UseSoonCandidate[],
  scheduledAt: Date
): NotificationOpportunity | null {
  if (candidates.length === 0) return null;

  const ids = candidates.map((candidate) => candidate.ingredientId).sort((a, b) => a - b);
  const names = candidates.map((candidate) => candidate.ingredientName);
  const expiresAt = candidates.map((candidate) => candidate.expiresAt);
  const dayKey = scheduledAt.toISOString().slice(0, 10);
  const stableInput = `${dayKey}:${ids.join(",")}:${names.join(",")}`;
  const id = createHash("sha1").update(stableInput).digest("hex").slice(0, 16);

  const previewNames = names.slice(0, 2).join(", ");
  const remaining = Math.max(0, names.length - 2);
  const suffix = remaining > 0 ? ` and ${remaining} more` : "";

  return {
    id,
    kind: "use_soon_digest",
    title: "Use these ingredients soon",
    body: `${previewNames}${suffix} should be cooked before they slip past their best days.`,
    scheduledAt: scheduledAt.toISOString(),
    payload: {
      ingredientIds: ids,
      ingredientNames: names,
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
  const zonedNow = zonedDateParts(baseDate, timeZone);
  const firstCandidate = dateFromZonedParts(
    {
      year: zonedNow.year,
      month: zonedNow.month,
      day: zonedNow.day,
      hour,
      minute,
      second: 0
    },
    timeZone
  );

  if (firstCandidate.getTime() > baseDate.getTime()) {
    return firstCandidate;
  }

  const tomorrowUtc = new Date(baseDate.getTime() + MS_PER_DAY);
  const zonedTomorrow = zonedDateParts(tomorrowUtc, timeZone);
  return dateFromZonedParts(
    {
      year: zonedTomorrow.year,
      month: zonedTomorrow.month,
      day: zonedTomorrow.day,
      hour,
      minute,
      second: 0
    },
    timeZone
  );
}

function zonedDateParts(date: Date, timeZone: string): {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
} {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  });

  const parts = formatter.formatToParts(date);
  const values = Object.fromEntries(
    parts
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)])
  ) as Record<string, number>;

  return {
    year: values.year!,
    month: values.month!,
    day: values.day!,
    hour: values.hour!,
    minute: values.minute!,
    second: values.second!
  };
}

function dateFromZonedParts(
  parts: {
    year: number;
    month: number;
    day: number;
    hour: number;
    minute: number;
    second: number;
  },
  timeZone: string
): Date {
  const utcGuess = new Date(
    Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second)
  );
  const offsetMs = zonedTimeOffsetMs(utcGuess, timeZone);
  return new Date(utcGuess.getTime() - offsetMs);
}

function zonedTimeOffsetMs(date: Date, timeZone: string): number {
  const zoned = zonedDateParts(date, timeZone);
  const utcEquivalent = Date.UTC(
    zoned.year,
    zoned.month - 1,
    zoned.day,
    zoned.hour,
    zoned.minute,
    zoned.second
  );
  return utcEquivalent - date.getTime();
}
