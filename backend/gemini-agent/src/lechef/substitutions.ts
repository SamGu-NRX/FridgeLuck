/**
 * Substitutions (SPEC 3.5, 3.1).
 *
 * On alpha, data/substitutions is ABSENT. This tool then returns an EXPLICIT
 * unknown — the table is not present — and labels any reasoning it offers as
 * beyond-table. It ALWAYS rechecks every eater's restrictions, including
 * compound ingredients (soy sauce contains wheat, pesto contains nuts), and
 * any swap it names describes what the change is, never promises no-change
 * (SPEC 3.1).
 *
 * When the corpus task drops a reviewed table in at data/substitutions, pass
 * a loader through createSubstitutionTool({ loadTable }) — from then on
 * table rows are authoritative and reasoning is no longer beyond-table.
 */

import { readFileSync } from "node:fs";
import { recheckSwapAllergens } from "./allergens.js";
import type { Eater, Evidence, SubstitutionSwap } from "./types.js";

/** One reviewed substitution row (the shape a data/substitutions table will carry). */
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
 * when the table is absent — alpha's state — and callers pass a loader that
 * reads the real file when it exists.
 */
export type SubstitutionTableLoader = () => SubstitutionTable | null;

/** Alpha default: the table is absent. */
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

/** A swap the tool OFFERS, with its reviewed ratio and note. Not the wire SubstitutionSwap (which is {from, to} only). */
export interface SubstitutionSuggestion {
  readonly from: string;
  readonly to: string;
  readonly ratio?: string;
  readonly note?: string;
}

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
  let loader: SubstitutionTableLoader = options.loader ?? substitutionsTableAbsent;

  return {
    lookupSubstitution({ ingredient, context, eaters }) {
      const table = loader();
      if (!table) {
        // data/substitutions is absent on alpha (SPEC 3.5): explicit unknown,
        // reasoning labelled beyond-table, allergen recheck still runs on any
        // suggestion we dare to name.
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
              detail: "data/substitutions is absent on alpha; beyond-table reasoning labelled"
            }
          ]
        };
      }
      const rows = table.rows.filter((r) => r.from === ingredient);
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
      const swaps: SubstitutionSwap[] = [];
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
  const idea = BEYOND_TABLE_IDEAS.get(ingredient.trim().toLowerCase());
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
