/**
 * Explore feed ranking and the aggregate-count floors (SPEC §6, review
 * finding 10). Pure functions: no Firestore, no framework — the route feeds
 * publication records in and renders what comes out.
 *
 * Two privacy rules live here:
 * - Fit and taste are the viewer's own business. The phone computes the real
 *   fit line; the server ranks from per-request inputs (`have`, `tastes`)
 *   that are never stored. The server sees no quantities, units or inventory
 *   lots — only the stock tokens the viewer asserted with this request — so
 *   its cookability claim is item-level pantry fit (SPEC §3.2): a bill line
 *   fits from recorded stock, an accepted substitution, or an assumed
 *   staple. Lot allocation and stale evidence stay on the phone, where the
 *   evidence lives.
 * - Counts below their floors are ABSENT, never zero (finding 10: counts
 *   hide scarcity when they imply a crowd that does not exist).
 */
import type { PublicationRecord } from "./publications.js";
import { errValidation } from "../shared/errors.js";

export interface ViewerRankingInput {
  /** Normalized stock tokens the viewer says they have (`?have=`). */
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

/**
 * Measure words name an amount, never an ingredient. The phone matches lines
 * by quantity with compatible units (SPEC §3.2); the server only needs them
 * to never become requirements.
 */
const MEASURE_WORDS = new Set([
  "tbsp", "tsp", "tablespoon", "tablespoons", "teaspoon", "teaspoons", "cup", "cups",
  "oz", "ounce", "ounces", "fl", "ml", "g", "gram", "grams", "kg", "kilogram", "kilograms",
  "lb", "lbs", "l", "liter", "liters", "litre", "litres", "pound", "pounds", "quart", "quarts",
  "pint", "pints", "clove", "cloves", "pinch", "pinches", "dash", "dashes", "slice", "slices",
  "can", "cans", "pkg", "package", "sheet", "sheets", "stalk", "stalks", "stick", "sticks",
  "bunch", "bunches", "handful", "handfuls", "sprig", "sprigs", "head", "heads",
]);

/** Connectives inside an ingredient phrase — never the requirement itself. */
const CONNECTIVE_WORDS = new Set(["to", "of", "and", "or", "with", "into", "plus", "for"]);

/**
 * Preparation, size and freshness qualifiers. The phone matches preparation
 * forms separately (SPEC §3.2 "compatible preparation"); stripping them keeps
 * the words from impersonating stock: a lone "chopped" in `have` cannot cover
 * a missing ingredient, and "frozen peas" is met by the peas the viewer has.
 */
const QUALIFIER_WORDS = new Set([
  "cooked", "chopped", "diced", "minced", "sliced", "grated", "shredded", "peeled", "beaten",
  "softened", "melted", "ground", "fresh", "frozen", "canned", "dried", "boneless", "skinless",
  "unsalted", "salted", "kosher", "sea", "extra", "virgin", "large", "small", "medium", "whole",
  "ripe", "raw", "room", "temperature", "optional", "leaves", "leaf",
]);

/**
 * Assumed staples (SPEC §3.2 "assumed staple"): bill lines that fit without
 * recorded stock. Deliberately minimal — the spec's own fit-line example
 * ("check eggs and oil") treats eggs and oils as recorded stock.
 */
const ASSUMED_STAPLES: ReadonlySet<string> = new Set(["salt", "water", "black pepper"]);

/**
 * Accepted substitutions (SPEC §3.2 "accepted swaps"). Unordered reviewed
 * pairs: either side's requirement accepts the other. SPEC §3.1 makes the
 * eaters' allergen recheck part of every substitution — that runs on the
 * phone before a swap is shown; the server only counts the pair as fit.
 */
const SUBSTITUTION_PAIRS: readonly (readonly [string, string])[] = [
  ["soy sauce", "tamari"],
  ["butter", "margarine"],
  ["lime", "lemon"],
  ["cilantro", "parsley"],
  ["heavy cream", "coconut cream"],
];

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

/** One ingredient line's requirement: the item phrase the bill needs, or null when the line names no item — an unparsable line stays in the bill as unmet (incomplete evidence prompts, it never silently claims). */
interface BillLine {
  readonly item: string | null;
  readonly optional: boolean;
}

/**
 * Extracts a line's item phrase: drops parentheticals and anything after the
 * comma (preparation clauses), leading quantities and measures, connectives,
 * and qualifiers — unless nothing else remains, in which case the line keeps
 * its qualifier word as the item rather than collapse to nothing.
 */
function parseBillLine(raw: string): BillLine {
  const optional = /\(\s*optional\s*\)/.test(raw);
  const noParens = raw.toLowerCase().replace(/\([^)]*\)/g, " ");
  const head = noParens.split(",")[0].replace(/\bto taste\b/g, " ");
  const tokens = head.split(/[^a-z0-9]+/).filter((t) => t.length > 0);
  let at = 0;
  while (at < tokens.length && /^\d+$/.test(tokens[at])) {
    at += 1;
  }
  while (at < tokens.length && MEASURE_WORDS.has(tokens[at])) {
    at += 1;
  }
  const stripped = tokens.slice(at).filter((t) => !CONNECTIVE_WORDS.has(t));
  const content = stripped.filter((t) => !QUALIFIER_WORDS.has(t));
  const kept = content.length > 0 ? content : stripped;
  return { item: kept.length > 0 ? kept.join(" ") : null, optional };
}

/**
 * The bill (SPEC §3.2): requirements for the non-optional lines, repeated
 * items summed into one requirement; optional garnish is separate.
 */
function billRequirements(ingredientLines: readonly string[]): readonly BillLine[] {
  const seen = new Set<string>();
  const bill: BillLine[] = [];
  for (const line of ingredientLines) {
    const parsed = parseBillLine(line);
    if (parsed.optional) {
      continue;
    }
    if (parsed.item !== null && seen.has(parsed.item)) {
      continue;
    }
    if (parsed.item !== null) {
      seen.add(parsed.item);
    }
    bill.push(parsed);
  }
  return bill;
}

/**
 * The server-side fit state of one bill line (SPEC §3.2 line states at the
 * granularity the request can support): "short", "quantity unknown" and
 * "needs reconfirming" all surface as unmet here — the server has no
 * quantities or evidence ages to tell them apart, and the phone refines.
 */
export type IngredientFit =
  | { readonly kind: "recorded"; readonly item: string }
  | { readonly kind: "assumedStaple"; readonly item: string }
  | { readonly kind: "substituted"; readonly item: string; readonly substitute: string }
  | { readonly kind: "unmet"; readonly item: string | null };

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

/** A phrase is covered when every one of its words is covered: "soy sauce" needs both tokens; a lone "soy" does not carry it. */
function phraseCoveredBy(phrase: string, stock: readonly string[]): boolean {
  return phrase.split(" ").every((word) => stock.some((h) => tokenCovers(word, h)));
}

/** The reviewed substitute for `item` that the stock actually covers, if any. */
function substituteCovering(item: string, stock: readonly string[]): string | null {
  for (const [a, b] of SUBSTITUTION_PAIRS) {
    const partner = a === item ? b : b === item ? a : null;
    if (partner !== null && phraseCoveredBy(partner, stock)) {
      return partner;
    }
  }
  return null;
}

function fitLine(line: BillLine, stock: readonly string[]): IngredientFit {
  if (line.item === null) {
    return { kind: "unmet", item: null };
  }
  if (ASSUMED_STAPLES.has(line.item)) {
    return { kind: "assumedStaple", item: line.item };
  }
  if (phraseCoveredBy(line.item, stock)) {
    return { kind: "recorded", item: line.item };
  }
  const substitute = substituteCovering(line.item, stock);
  return substitute === null ? { kind: "unmet", item: line.item } : { kind: "substituted", item: line.item, substitute };
}

function fitIsMet(fit: IngredientFit): boolean {
  switch (fit.kind) {
    case "recorded":
    case "assumedStaple":
    case "substituted":
      return true;
    case "unmet":
      return false;
  }
}

/**
 * Fits the whole bill (SPEC §3.2): every non-optional line must come from the
 * pantry — recorded stock, an accepted substitution, or an assumed staple.
 * Never "you have everything" otherwise.
 */
export function fitBill(ingredientLines: readonly string[], stock: readonly string[]): readonly IngredientFit[] {
  return billRequirements(ingredientLines).map((line) => fitLine(line, stock));
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
      const fits = fitBill(record.ingredientLines, input.have);
      const matched = fits.filter(fitIsMet).length;
      rank.cookableNow = fits.length > 0 && matched === fits.length;
      rank.matchedIngredients = matched;
      rank.totalIngredients = fits.length;
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
