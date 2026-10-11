/**
 * Fit computation over a complete ingredient bill (SPEC 3.2).
 *
 * Rules implemented here:
 * - Repeated bill lines for the same ingredient are SUMMED; optional garnish
 *   lines are computed separately and never block the fit line.
 * - Known quantities are matched with compatible units (mass g/kg, volume
 *   ml/l/tbsp/tsp, count pieces/clove) and allocated from remaining stock
 *   WITHOUT counting the same stock twice across bill lines, accepted swaps
 *   or candidates (candidates are allocated in the order given, required
 *   lines before garnish).
 * - The per-line state comes from the pantry line's own state first
 *   (needs-reconfirming evidence can never become sufficient by arithmetic;
 *   assumed staples are present on assumption, not evidence), then from
 *   quantity math.
 * - The fit LINE text uses those states only: "n of m · k swaps" or
 *   "x recorded · check a, b and c". NEVER a percentage. "You have
 *   everything" only when every required line is strictly sufficient — an
 *   assumed staple or an accepted swap keeps the count form instead.
 */

import type {
  Evidence,
  FitLine,
  FitLineState,
  PantryLine,
  PantrySnapshot,
  RecipeContext,
  RecipeFit,
  SubstitutionSwap
} from "./types.js";
import { payloadHash } from "./wire.js";

const EPSILON = 1e-9;

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

/** Conversion table. Units outside these classes only match themselves (opaque dimension). */
const UNIT_CONVERSIONS: ReadonlyMap<string, { dimension: string; factor: number }> = new Map([
  ["g", { dimension: "mass", factor: 1 }],
  ["kg", { dimension: "mass", factor: 1000 }],
  ["ml", { dimension: "volume", factor: 1 }],
  ["l", { dimension: "volume", factor: 1000 }],
  ["tbsp", { dimension: "volume", factor: 15 }],
  ["tsp", { dimension: "volume", factor: 5 }],
  ["piece", { dimension: "count", factor: 1 }],
  ["clove", { dimension: "count", factor: 1 }]
]);

function toBaseUnit(value: number, unit: string): { dimension: string; base: number } {
  const { dimension, factor } = UNIT_CONVERSIONS.get(unit) ?? { dimension: `opaque:${unit}`, factor: 1 };
  return { dimension, base: value * factor };
}

// ---------------------------------------------------------------------------
// Shared stock ledger — the only place stock is consumed
// ---------------------------------------------------------------------------

interface SupplyLot {
  readonly line: PantryLine;
  remainingBase: number | null; // null = unknown quantity, cannot be allocated numerically
}

/**
 * Stock pools shared across all lines and candidates of one computation.
 * Allocating from the ledger reserves stock, so the same lot cannot be
 * counted twice across bill lines, swaps, or several dinners in a plan.
 */
export class StockLedger {
  private readonly pools = new Map<string, SupplyLot[]>();

  constructor(pantry: PantrySnapshot) {
    for (const line of pantry.items) {
      const lots = this.pools.get(line.ingredientId) ?? [];
      const known = line.quantity.kind === "known" ? toBaseUnit(line.quantity.value, line.quantity.unit) : null;
      lots.push({ line, remainingBase: known ? known.base : null });
      this.pools.set(line.ingredientId, lots);
    }
  }

  /** Total remaining stock in base units, or null when any lot's quantity is unknown. */
  peekKnown(ingredientId: string): number | null {
    const lots = this.pools.get(ingredientId);
    if (!lots || lots.length === 0) return 0;
    let total = 0;
    for (const lot of lots) {
      if (lot.remainingBase === null) return null;
      total += lot.remainingBase;
    }
    return total;
  }

  firstLine(ingredientId: string): PantryLine | undefined {
    return this.pools.get(ingredientId)?.[0]?.line;
  }

  /** Consume up to `base` units from eligible lots; returns what was taken. */
  allocate(ingredientId: string, base: number): number {
    let taken = 0;
    for (const lot of this.pools.get(ingredientId) ?? []) {
      if (taken >= base) break;
      if (lot.remainingBase === null || lot.remainingBase <= 0) continue;
      const use = Math.min(lot.remainingBase, base - taken);
      lot.remainingBase -= use;
      taken += use;
    }
    return taken;
  }
}

// ---------------------------------------------------------------------------
// Bill summation
// ---------------------------------------------------------------------------

interface BillDemand {
  readonly ingredientId: string;
  readonly name: string;
  readonly optional: boolean;
  /** Total demand in base units; null when any contributing line has an unknown quantity. */
  readonly demandBase: number | null;
}

function sumBill(recipe: RecipeContext): BillDemand[] {
  interface Accum {
    name: string;
    demandBase: number | null;
    optional: boolean;
  }
  const byKey = new Map<string, Accum>();
  for (const line of recipe.ingredientBill) {
    const optional = line.optional === true;
    // Required and garnish demands of one ingredient stay separate lines.
    const key = `${line.ingredientId}|${optional ? "garnish" : "required"}`;
    const known = line.quantity.kind === "known" ? toBaseUnit(line.quantity.value, line.quantity.unit) : null;
    const existing = byKey.get(key);
    if (existing) {
      existing.demandBase = known ? (existing.demandBase ?? 0) + known.base : null;
    } else {
      byKey.set(key, { name: line.name, demandBase: known ? known.base : null, optional });
    }
  }
  return [...byKey.entries()].map(([key, acc]) => ({
    ingredientId: key.slice(0, key.lastIndexOf("|")),
    name: acc.name,
    optional: acc.optional,
    demandBase: acc.demandBase
  }));
}

// ---------------------------------------------------------------------------
// Per-line state
// ---------------------------------------------------------------------------

const PROBLEM_STATES: ReadonlySet<FitLineState> = new Set([
  "short",
  "quantity-unknown",
  "needs-reconfirming",
  "missing"
]);

function shortBy(demandBase: number, taken: number): number {
  return Math.round(Math.max(demandBase - taken, 0) * 1000) / 1000;
}

function resolveLine(
  demand: BillDemand,
  ledger: StockLedger,
  swaps: readonly SubstitutionSwap[],
  swapClearsAllergens: (to: string) => boolean
): FitLine {
  const { ingredientId, name } = demand;

  // 1. No pantry line at all — an accepted swap may still cover it.
  const pantryLine = ledger.firstLine(ingredientId);
  if (!pantryLine) {
    const swap = demand.demandBase !== null ? swaps.find((s) => s.from === ingredientId) : undefined;
    if (swap && swapClearsAllergens(swap.to) && demand.demandBase !== null) {
      const targetRemaining = ledger.peekKnown(swap.to);
      if (targetRemaining !== null && targetRemaining >= demand.demandBase - EPSILON) {
        ledger.allocate(swap.to, demand.demandBase);
        return { ingredientId, name, state: "swap-covered", swap };
      }
    }
    return { ingredientId, name, state: "missing" };
  }
  // 2. Stale evidence can never become sufficient by arithmetic.
  if (pantryLine.state === "needs-reconfirming") {
    return { ingredientId, name, state: "needs-reconfirming" };
  }
  // 3. Assumed staples are present on assumption, not evidence.
  if (pantryLine.state === "assumed-staple") {
    return { ingredientId, name, state: "assumed-staple" };
  }
  // 4. Unknown quantity anywhere (pantry or bill) cannot be verified.
  if (pantryLine.state === "quantity-unknown" || pantryLine.quantity.kind === "unknown" || demand.demandBase === null) {
    return { ingredientId, name, state: "quantity-unknown" };
  }

  // 5. Quantity math over allocated (reserved) stock.
  const demandBase = demand.demandBase;
  const remaining = ledger.peekKnown(ingredientId) ?? 0;
  if (remaining >= demandBase - EPSILON) {
    ledger.allocate(ingredientId, demandBase);
    return { ingredientId, name, state: "sufficient" };
  }

  // 6. An accepted swap may cover the shortfall, allergens permitting.
  const swap = swaps.find((s) => s.from === ingredientId);
  if (swap && swapClearsAllergens(swap.to)) {
    const targetRemaining = ledger.peekKnown(swap.to);
    if (targetRemaining !== null && targetRemaining >= demandBase - EPSILON) {
      ledger.allocate(swap.to, demandBase);
      return { ingredientId, name, state: "swap-covered", swap };
    }
  }

  // 7. Short — reserve the partial stock so later candidates cannot count it.
  const taken = ledger.allocate(ingredientId, demandBase);
  return { ingredientId, name, state: "short", shortBy: shortBy(demandBase, taken) };
}

// ---------------------------------------------------------------------------
// Fit line text
// ---------------------------------------------------------------------------

function buildFit(required: readonly FitLine[], garnish: readonly FitLine[]): RecipeFit {
  const requiredCount = required.length;
  const sufficientCount = required.filter((l) => l.state === "sufficient").length;
  const swapCount = required.filter((l) => l.state === "swap-covered").length;
  const allSufficient = requiredCount > 0 && sufficientCount === requiredCount && swapCount === 0;
  const problems = required.filter((l) => PROBLEM_STATES.has(l.state));

  let fitLine: string;
  if (allSufficient) {
    // The only case where this phrase is allowed (SPEC 3.2).
    fitLine = "You have everything";
  } else if (problems.length === 0) {
    const swaps = swapCount > 0 ? ` · ${swapCount} swap${swapCount === 1 ? "" : "s"}` : "";
    fitLine = `${sufficientCount} of ${requiredCount}${swaps}`;
  } else {
    const recorded = required.filter((l) => l.state !== "missing").length;
    const names = problems.slice(0, 3).map((p) => p.name.toLowerCase());
    const more = problems.length > 3 ? ` and ${problems.length - 3} more` : "";
    const list =
      names.length > 1
        ? `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`
        : (names[0] ?? "");
    fitLine = `${recorded} recorded · check ${list}${more}`;
  }

  return { fitLine, required, garnish, sufficientCount, requiredCount, swapCount, allSufficient };
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

export interface FitComputation {
  readonly fit: RecipeFit;
  readonly evidence: readonly Evidence[];
}

export interface FitOptions {
  readonly acceptedSwaps?: readonly SubstitutionSwap[];
  /** Returns the allergen violations a swap target raises for ALL eaters (compound-aware). */
  readonly swapViolations?: (to: string) => readonly string[];
}

/** Compute fits for several candidates against one pantry, allocating shared stock once. */
export function computeCandidateFits(
  candidates: readonly RecipeContext[],
  pantry: PantrySnapshot,
  options: FitOptions = {}
): Map<string, FitComputation> {
  const ledger = new StockLedger(pantry);
  const swaps = options.acceptedSwaps ?? [];
  const swapClearsAllergens = (to: string): boolean =>
    options.swapViolations ? options.swapViolations(to).length === 0 : true;
  const results = new Map<string, FitComputation>();
  for (const recipe of candidates) {
    const evidence: Evidence[] = [
      { kind: "pantry-line", ref: `pantry-revision-${pantry.revision}`, detail: "bounded snapshot used for fit" }
    ];
    const demands = sumBill(recipe);
    for (const d of demands) {
      evidence.push({
        kind: "recipe-bill",
        ref: `${recipe.id}@r${recipe.revision}:${d.ingredientId}`,
        detail: d.optional ? "optional garnish line" : "required line"
      });
    }
    // Required lines allocate first; garnish gets what remains.
    const required = demands.filter((d) => !d.optional).map((d) => resolveLine(d, ledger, swaps, swapClearsAllergens));
    const garnish = demands.filter((d) => d.optional).map((d) => resolveLine(d, ledger, swaps, swapClearsAllergens));
    const fit = buildFit(required, garnish);
    results.set(recipe.id, {
      fit,
      evidence: [
        ...evidence,
        { kind: "acceptance-record", ref: `fit:${recipe.id}@r${recipe.revision}`, detail: fit.fitLine }
      ]
    });
  }
  return results;
}

/** Stable content key for a recipe context (id + revision + bill + steps). */
export function recipeContentKey(recipe: RecipeContext): string {
  return payloadHash({
    kind: "recipeContext",
    id: recipe.id,
    revision: recipe.revision,
    bill: recipe.ingredientBill,
    steps: recipe.steps
  });
}
