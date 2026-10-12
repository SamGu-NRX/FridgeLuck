/**
 * Substitutions (SPEC 3.5, 3.1).
 *
 * The reviewed table is the PINNED substitution canon at
 * ./canon/substitutions/pairs.json (verbatim from
 * overhaul/substitution-table; see canon/PROVENANCE.md) — 279 reviewed
 * pairs, each carrying a functional role, an evidence-qualified ratio, the
 * reviewed difference sentence, and the roles where the swap fails. There
 * is no embedded table here to drift from the canon: the default loader
 * adapts the pinned pairs (identity fold makes "soy_sauce" and "soy sauce"
 * the same row key), ordered by review quality — sourced ratios before
 * convention, convention before unknown, then most-versatile, then
 * fewest failure modes.
 *
 * It ALWAYS rechecks every eater's restrictions through the pinned
 * ingredient-facts canon (allergens.ts), including compound ingredients
 * (soy sauce contains wheat) and both sides of a swap. A swap the recheck
 * rejects is never offered. Any swap it names describes what the change
 * is, never promises no-change (SPEC 3.1).
 *
 * A rulebook override through createSubstitutionTool({ loadTable }) /
 * setLoader still supersedes the canon (the corpus task's drop-in path),
 * and substitutionsTableAbsent reproduces the alpha state for tests.
 */

import { readFileSync } from "node:fs";
import { recheckSwapAllergens } from "./allergens.js";
import type { Eater, Evidence } from "./types.js";

/** One reviewed substitution row (the shape a data/substitutions table carries). */
export interface SubstitutionRow {
  readonly from: string;
  readonly to: string;
  readonly ratio: string;
  readonly notes: string;
}

export interface SubstitutionTable {
  readonly source: string;
  readonly rows: readonly SubstitutionRow[];
}

/**
 * Loader hook for the corpus task's data/substitutions table. Returns null
 * when the table is absent; callers pass a loader that reads the real file
 * when it exists.
 */
export type SubstitutionTableLoader = () => SubstitutionTable | null;

/** Alpha state for tests: no table installed. */
export const substitutionsTableAbsent: SubstitutionTableLoader = () => null;

/** File-based loader for when data/substitutions.json exists. Throws on malformed files. */
export function loadSubstitutionTable(path: string): SubstitutionTableLoader {
  return () => {
    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(path, "utf8"));
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw err; // a malformed table must surface, never degrade silently
    }
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new Error(`substitutions table ${path}: expected an object`);
    }
    const record = raw as Record<string, unknown>;
    if (typeof record["source"] !== "string" || !Array.isArray(record["rows"])) {
      throw new Error(`substitutions table ${path}: expected { source, rows }`);
    }
    return record as unknown as SubstitutionTable;
  };
}

// ---------------------------------------------------------------------------
// Pinned substitution canon (default table)
// ---------------------------------------------------------------------------

/** Canonical identity fold — the same rule allergens.ts uses. */
function fold(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

/** Canonical key → human phrase ("bacon_fat" → "bacon fat"). */
function display(name: string): string {
  return name.replace(/_/g, " ");
}

interface CanonPair {
  readonly id: string;
  readonly original: string;
  readonly substitute: string;
  readonly role: string;
  readonly ratio?: {
    readonly value?: number;
    readonly basis?: string;
    readonly status?: string;
    readonly note?: string;
  };
  readonly function_status?: string;
  readonly supported_also?: readonly unknown[];
  readonly fails?: readonly { readonly role: string; readonly why: string }[];
  readonly difference?: string;
}

interface CanonPairs {
  readonly schema_version?: string;
  readonly description?: string;
  readonly pairs?: readonly CanonPair[];
}

function ratioText(ratio: CanonPair["ratio"]): string {
  if (!ratio || typeof ratio.value !== "number") return "reviewed ratio";
  const value = `${ratio.value}:1`;
  const basis = ratio.basis ? ` by ${ratio.basis}` : "";
  const status = ratio.status ? ` (${ratio.status})` : "";
  return `${value}${basis}${status}`;
}

function functionTier(status: string | undefined): number {
  if (status === "sourced") return 0;
  if (status === "convention") return 1;
  return 2;
}

/**
 * Adapt the pinned canon pairs into reviewed rows. Rows for the same
 * original are ordered by review quality so the first offered swap is the
 * best-evidenced, most versatile one — the canon's own ordering across
 * roles is preserved within a tie.
 */
function adaptCanonPairs(raw: CanonPairs): SubstitutionTable {
  const pairs = raw.pairs ?? [];
  const ordered = [...pairs].sort((a, b) => {
    const tierA = functionTier(a.function_status);
    const tierB = functionTier(b.function_status);
    if (tierA !== tierB) return tierA - tierB;
    const supA = a.supported_also?.length ?? 0;
    const supB = b.supported_also?.length ?? 0;
    if (supA !== supB) return supB - supA;
    const failsA = a.fails?.length ?? 0;
    const failsB = b.fails?.length ?? 0;
    if (failsA !== failsB) return failsA - failsB;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  const rows = ordered.map((pair) => {
    const difference = pair.difference ?? "the reviewed table records this pair without a difference sentence";
    const failsWhen = (pair.fails ?? [])
      .slice(0, 2)
      .map((f) => `as ${f.role}: ${f.why}`)
      .join("; ");
    return {
      from: display(pair.original),
      to: display(pair.substitute),
      ratio: ratioText(pair.ratio),
      notes: `For the ${pair.role} role. ${difference}${failsWhen ? ` Fails ${failsWhen}.` : ""}`
    } satisfies SubstitutionRow;
  });
  return {
    source: `pinned substitution canon (overhaul/substitution-table @ 7b85bec0, schema ${raw.schema_version ?? "?"}, ${rows.length} reviewed pairs)`,
    rows
  };
}

let canonTableCache: SubstitutionTable | null | undefined;
/** The default loader: the pinned substitution canon. Unreadable file → null; malformed JSON throws. */
export function substitutionsCanonLoader(): SubstitutionTable | null {
  if (canonTableCache === undefined) {
    let raw: string;
    try {
      raw = readFileSync(new URL("./canon/substitutions/pairs.json", import.meta.url), "utf8");
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        canonTableCache = null;
        return null;
      }
      throw err;
    }
    canonTableCache = adaptCanonPairs(JSON.parse(raw) as CanonPairs);
  }
  return canonTableCache;
}

// ---------------------------------------------------------------------------
// Tool
// ---------------------------------------------------------------------------

export interface SubstitutionResult {
  /** The reviewed answer: table row(s) or an explicit beyond-table suggestion. */
  readonly kind: "table" | "beyond-table" | "unknown";
  readonly swaps: readonly SubstitutionSuggestion[];
  readonly explanation: string;
  /** Every swap describes the difference; no swap promises "no change". */
  readonly differenceStatements: readonly string[];
  readonly violations: readonly string[];
  readonly unknowns: readonly string[];
  readonly evidence: readonly Evidence[];
}

/** A swap the tool OFFERS, with its reviewed ratio and note. Not the wire SubstitutionSwap (which is {from, to} only). */
export interface SubstitutionSuggestion {
  readonly from: string;
  readonly to: string;
  readonly ratio?: string;
  readonly note?: string;
}

export interface SubstitutionTool {
  lookupSubstitution(input: {
    ingredient: string;
    context?: string;
    eaters: readonly Eater[];
  }): SubstitutionResult;
  /** Swap the table in force (also usable by tests). */
  setLoader(loader: SubstitutionTableLoader): void;
}

export function createSubstitutionTool(options: {
  loader?: SubstitutionTableLoader;
} = {}): SubstitutionTool {
  let loader: SubstitutionTableLoader = options.loader ?? substitutionsCanonLoader;

  return {
    lookupSubstitution({ ingredient, context, eaters }) {
      const table = loader();
      if (!table) {
        // No table in force: explicit unknown, reasoning labelled
        // beyond-table, allergen recheck still runs on any suggestion we
        // dare to name.
        const unknowns = [
          "substitutions: no reviewed table is installed in this build (data/substitutions absent), so no reviewed substitution can be returned",
          "any idea below is reasoning beyond the reviewed table (SPEC 3.5) and must be labelled as such to the user"
        ];
        const beyond = beyondTableSuggestion(ingredient, eaters);
        return {
          kind: "beyond-table",
          swaps: beyond.swaps,
          explanation:
            "No reviewed substitution table is installed in this build, so anything offered here is reasoning beyond the table, not a reviewed answer (SPEC 3.5).",
          differenceStatements: beyond.differences,
          violations: beyond.violations,
          unknowns,
          evidence: [
            {
              kind: "acceptance-record",
              ref: "substitutions:table-absent",
              detail: "no substitution table is installed; beyond-table reasoning labelled"
            }
          ]
        };
      }
      const rows = table.rows.filter((r) => fold(r.from) === fold(ingredient));
      if (rows.length === 0) {
        return {
          kind: "unknown",
          swaps: [],
          explanation: `No reviewed substitution for "${ingredient}" in ${table.source}.`,
          differenceStatements: [],
          violations: [],
          unknowns: [`substitutions: "${ingredient}" is not in the reviewed table (${table.source})`],
          evidence: [
            {
              kind: "acceptance-record",
              ref: `substitutions:${table.source}`,
              detail: `no row for ${ingredient}`
            }
          ]
        };
      }
      const swaps: SubstitutionSuggestion[] = [];
      const differences: string[] = [];
      const violations: string[] = [];
      for (const row of rows) {
        const found = recheckSwapAllergens(row.from, row.to, eaters);
        if (found.length > 0) {
          violations.push(...found);
          continue; // a violating swap is never offered
        }
        const swap: SubstitutionSuggestion = { from: row.from, to: row.to, ratio: row.ratio, note: row.notes };
        swaps.push(swap);
        differences.push(
          `Swapping ${row.from} for ${row.to} (${row.ratio}): ${row.notes} — the dish changes, it is not the same.`
        );
      }
      return {
        kind: "table",
        swaps,
        explanation: `From the reviewed table (${table.source}). Each swap changes the dish; nothing here promises an identical result.`,
        differenceStatements: differences,
        violations,
        unknowns: swaps.length === 0 && violations.length > 0
          ? [`substitutions: every table row for "${ingredient}" was rejected by the allergen recheck`]
          : [],
        evidence: [
          { kind: "acceptance-record", ref: `substitutions:${table.source}:${ingredient}`, detail: `${swaps.length} row(s) offered after allergen recheck` }
        ]
      };
    },
    setLoader(next) {
      loader = next;
    }
  };
}

// ---------------------------------------------------------------------------
// Beyond-table reasoning (labelled, rechecked, difference-stating)
// ---------------------------------------------------------------------------

const BEYOND_TABLE_IDEAS: ReadonlyMap<string, { to: string; ratio: string; note: string }> = new Map([
  ["butter", { to: "olive oil", ratio: "3/4 the volume", note: "less browning, a different (dairy-free) fat" }],
  ["eggs", { to: "flax egg", ratio: "1 tbsp ground flax + 3 tbsp water per egg", note: "binding without egg; denser crumb" }],
  ["milk", { to: "oat milk", ratio: "1:1", note: "thinner and sweeter, no lactose" }],
  ["soy-sauce", { to: "tamari", ratio: "1:1", note: "same salt depth; check tamari's own wheat-free label" }],
  ["lemon-juice", { to: "lime juice", ratio: "1:1", note: "similar acidity, different aroma" }]
]);

function beyondTableSuggestion(
  ingredient: string,
  eaters: readonly Eater[]
): { swaps: SubstitutionSuggestion[]; differences: string[]; violations: string[] } {
  const idea = BEYOND_TABLE_IDEAS.get(fold(ingredient));
  if (!idea) {
    return { swaps: [], differences: [], violations: [] };
  }
  const violations = recheckSwapAllergens(ingredient, idea.to, eaters);
  if (violations.length > 0) {
    return { swaps: [], differences: [], violations: [...violations] };
  }
  return {
    swaps: [{ from: ingredient, to: idea.to, ratio: idea.ratio, note: idea.note }],
    differences: [
      `Beyond the reviewed table: ${idea.to} in place of ${ingredient} (${idea.ratio}) — ${idea.note}. The dish changes; this is not a reviewed answer.`
    ],
    violations: []
  };
}
