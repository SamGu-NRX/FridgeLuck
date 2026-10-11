/**
 * Explore feed ranking and the aggregate-count floors (SPEC §6, review
 * finding 10). Pure functions: no Firestore, no framework — the route feeds
 * publication records in and renders what comes out.
 *
 * Two privacy rules live here:
 * - Fit and taste are the viewer's own business. The phone computes the real
 *   fit line; the server ranks from per-request inputs (`have`, `tastes`)
 *   that are never stored.
 * - Counts below their floors are ABSENT, never zero (finding 10: counts
 *   hide scarcity when they imply a crowd that does not exist).
 */
import type { PublicationRecord } from "./publications.js";
import { errValidation } from "../shared/errors.js";

export interface ViewerRankingInput {
  /** Normalized single-word ingredient tokens the viewer says they have. */
  readonly have: readonly string[];
  /** Normalized taste tag tokens the viewer cares about. */
  readonly tastes: readonly string[];
}

export interface RankView {
  /** Present only when the viewer sent `have`. */
  cookableNow?: boolean;
  matchedIngredients?: number;
  totalIngredients?: number;
  /** Matched taste tags — present only when the viewer sent `tastes`. */
  tasteTags?: readonly string[];
}

export interface RankedPublication<T> {
  readonly record: T;
  readonly rank: RankView | null;
}

const UNIT_WORDS = new Set([
  "tbsp", "tsp", "tablespoon", "tablespoons", "teaspoon", "teaspoons", "cup", "cups",
  "oz", "ounce", "ounces", "fl", "ml", "lb", "lbs", "clove", "cloves",
  "pinch", "pinches", "dash", "slices", "slice", "can", "cans", "pkg", "package",
  "sheet", "sheets", "stalk", "stalks", "stick", "sticks", "to", "of",
  "and", "or", "with", "into", "plus", "for",
]);

export function normalizeToken(raw: string): string {
  return raw.trim().toLowerCase();
}

/** Splits a viewer input list ("rice, brown sugar, eggs") into clean tokens. */
export function parseTokenList(raw: string, maxTokens: number): string[] {
  const tokens = raw
    .toLowerCase()
    .split(/[\s,]+/)
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
  const unique = [...new Set(tokens)];
  if (unique.length > maxTokens) {
    throw errValidation(`token list is limited to ${maxTokens} items`);
  }
  return unique;
}

/**
 * The ingredient keywords one publication needs: alphabetic words from its
 * lines, minus unit and stop words. Numbers and measures never become needs —
 * the phone does real quantity-aware fit; this is coarse set membership.
 */
export function needTokens(ingredientLines: readonly string[]): ReadonlySet<string> {
  const tokens = new Set<string>();
  for (const line of ingredientLines) {
    for (const word of line.toLowerCase().split(/[^a-z]+/)) {
      if (word.length >= 3 && !UNIT_WORDS.has(word)) {
        tokens.add(word);
      }
    }
  }
  return tokens;
}

/** Plural-tolerant match: "eggs" covers need "egg" and vice versa. */
function tokenCovers(need: string, have: string): boolean {
  if (need === have) {
    return true;
  }
  if (need.length > 3 && have === `${need}s`) {
    return true;
  }
  if (have.length > 3 && need === `${have}s`) {
    return true;
  }
  return false;
}

function coveredNeeds(needs: ReadonlySet<string>, have: readonly string[]): number {
  let covered = 0;
  for (const need of needs) {
    if (have.some((h) => tokenCovers(need, h))) {
      covered += 1;
    }
  }
  return covered;
}

export function tasteMatches(tags: readonly string[], tastes: readonly string[]): readonly string[] {
  const tasteSet = new Set(tastes);
  return tags.filter((t) => tasteSet.has(normalizeToken(t)));
}

/**
 * Ranks a feed: what the viewer can cook now first (SPEC §6 "ranked by what
 * you can cook now ... and your taste"), then taste overlap, then newest.
 * Rank fields appear only for the inputs the viewer actually sent.
 */
export function rankPublications<T extends Pick<PublicationRecord, "tags" | "ingredientLines" | "createdAtIso" | "publicationId">>(
  records: readonly T[],
  input: ViewerRankingInput | null,
): Array<RankedPublication<T>> {
  const ranked = records.map((record) => {
    if (input === null || (input.have.length === 0 && input.tastes.length === 0)) {
      return { record, rank: null };
    }
    const rank: RankView = {};
    if (input.have.length > 0) {
      const needs = needTokens(record.ingredientLines);
      const matched = coveredNeeds(needs, input.have);
      rank.cookableNow = needs.size > 0 && matched === needs.size;
      rank.matchedIngredients = matched;
      rank.totalIngredients = needs.size;
    }
    if (input.tastes.length > 0) {
      rank.tasteTags = tasteMatches(record.tags, input.tastes);
    }
    return { record, rank };
  });

  const scoreOf = (entry: RankedPublication<T>): { cookable: number; taste: number } => {
    if (entry.rank === null) {
      return { cookable: 0, taste: 0 };
    }
    return {
      cookable: entry.rank.cookableNow === true ? 1 : 0,
      taste: entry.rank.tasteTags?.length ?? 0,
    };
  };

  return ranked.sort((a, b) => {
    const sa = scoreOf(a);
    const sb = scoreOf(b);
    if (sa.cookable !== sb.cookable) {
      return sb.cookable - sa.cookable;
    }
    if (sa.taste !== sb.taste) {
      return sb.taste - sa.taste;
    }
    if (a.record.createdAtIso !== b.record.createdAtIso) {
      return a.record.createdAtIso < b.record.createdAtIso ? 1 : -1;
    }
    return a.record.publicationId < b.record.publicationId ? 1 : -1;
  });
}

/**
 * "Cooked by N" (SPEC §6): the count of distinct opted-in cooks, shown only
 * at or above the floor. Below the floor the count is absent (undefined),
 * never zero.
 */
export function cookedByCountAboveFloor(optedInCooks: Readonly<Record<string, string>>, floor: number): number | undefined {
  const distinctCooks = Object.keys(optedInCooks).length;
  return distinctCooks >= floor ? distinctCooks : undefined;
}

function dayOffset(now: Date, days: number): string {
  return new Date(now.getTime() + days * 86_400_000).toISOString().slice(0, 10);
}

/**
 * Campus counter ("N people at your school cooked something this week"):
 * distinct opted-in cook ids across the feed's publications with a cook day
 * inside the trailing seven UTC days. Shown only at or above the floor;
 * absent below it.
 */
export function campusCookedThisWeek(records: readonly PublicationRecord[], now: Date, floor: number): number | undefined {
  const earliestDay = dayOffset(now, -6);
  const today = dayOffset(now, 0);
  const cooks = new Set<string>();
  for (const record of records) {
    for (const [cookId, day] of Object.entries(record.optedInCooks)) {
      if (day >= earliestDay && day <= today) {
        cooks.add(cookId);
      }
    }
  }
  return cooks.size >= floor ? cooks.size : undefined;
}
