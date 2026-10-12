/**
 * Fit computation over a complete ingredient bill (SPEC 3.2).
 *
 * Rules implemented here:
 * - Repeated bill lines for the same ingredient are SUMMED per unit
 *   dimension (mass g/kg, volume ml/l/tbsp/tsp, count piece/clove; other
 *   units only match themselves); optional garnish lines are computed
 *   separately and never block the fit line.
 * - Known quantities are allocated from remaining stock of the SAME
 *   dimension WITHOUT counting the same stock twice across bill lines,
 *   accepted swaps or candidates (candidates are allocated in the order
 *   given, required lines before garnish). A quantity in one unit family
 *   never satisfies a demand in another — 100 ml cannot satisfy a 100 g
 *   demand; the mismatched line is short, not satisfied.
 * - Unknown quantity is never arithmetic: an unknown bill line, or an
 *   unknown lot in the pantry pool, makes the line quantity-unknown even
 *   when other lines or lots are known (strictest state wins). Unknown
 *   propagates through summation and allocation alike.
 * - The per-line state comes from the pantry line's own state first
 *   (needs-reconfirming evidence can never become sufficient by arithmetic;
 *   assumed staples are present on assumption, not evidence), then from
 *   quantity math.
 * - The fit LINE text uses those states only: "n of m · k swaps" or
 *   "x recorded · check a, b and c". NEVER a percentage. "You have
 *   everything" only when every required line is strictly sufficient — an
 *   accepted swap keeps the count form. An assumed or unknown-quantity
 *   staple is NAMED, never counted: "1 recorded · salt assumed",
 *   "salt and pepper assumed".
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
  /** Unit family of the stored quantity; null when the quantity (and so its dimension) is unknown. */
  readonly dimension: string | null;
  remainingBase: number | null; // null = unknown quantity, cannot be allocated numerically
}

/**
 * Stock pools shared across all lines and candidates of one computation.
 * Allocating from the ledger reserves stock, so the same lot cannot be
 * counted twice across bill lines, swaps, or several dinners in a plan.
 * Queries take a unit DIMENSION: stock in one unit family never satisfies a
 * demand in another, and an unknown lot makes the pool unknown for every
 * dimension (its quantity could be the demanded one).
 */
export class StockLedger {
  private readonly pools = new Map<string, SupplyLot[]>();

  constructor(pantry: PantrySnapshot) {
    for (const line of pantry.items) {
      const lots = this.pools.get(line.ingredientId) ?? [];
      const known = line.quantity.kind === "known" ? toBaseUnit(line.quantity.value, line.quantity.unit) : null;
      lots.push({
        line,
        dimension: known ? known.dimension : null,
        remainingBase: known ? known.base : null
      });
      this.pools.set(line.ingredientId, lots);
    }
  }

  /**
   * Total remaining stock of ONE dimension in base units. Returns null when
   * any lot's quantity is unknown (it could hold the demanded dimension);
   * returns 0 when the ingredient has stock but none in this dimension.
   */
  peekKnown(ingredientId: string, dimension: string): number | null {
    const lots = this.pools.get(ingredientId);
    if (!lots || lots.length === 0) return 0;
    let total = 0;
    let matched = false;
    for (const lot of lots) {
      if (lot.remainingBase === null) return null;
      if (lot.dimension !== dimension) continue;
      matched = true;
      total += lot.remainingBase;
    }
    return matched ? total : 0;
  }

  firstLine(ingredientId: string): PantryLine | undefined {
    return this.pools.get(ingredientId)?.[0]?.line;
  }

  /** Consume up to `base` units of `dimension` from eligible lots; returns what was taken. */
  allocate(ingredientId: string, base: number, dimension: string): number {
    let taken = 0;
    for (const lot of this.pools.get(ingredientId) ?? []) {
      if (taken >= base) break;
      if (lot.remainingBase === null || lot.remainingBase <= 0) continue;
      if (lot.dimension !== dimension) continue;
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
  /**
   * Demand per unit dimension, in that dimension's base units. Dimensions
   * stay split: 100 g and 2 tbsp of one ingredient are two needs, and stock
   * of one family never satisfies the other.
   */
  readonly demandByDimension: ReadonlyMap<string, number>;
  /** Any contributing line had an unknown quantity — the demand total is unknown, whatever the known lines add. */
  readonly anyUnknownQuantity: boolean;
}

function sumBill(recipe: RecipeContext): BillDemand[] {
  interface Accum {
    name: string;
    optional: boolean;
    demandByDimension: Map<string, number>;
    anyUnknownQuantity: boolean;
  }
  const byKey = new Map<string, Accum>();
  for (const line of recipe.ingredientBill) {
    const optional = line.optional === true;
    // Required and garnish demands of one ingredient stay separate lines.
    const key = `${line.ingredientId}|${optional ? "garnish" : "required"}`;
    let acc = byKey.get(key);
    if (!acc) {
      acc = { name: line.name, optional, demandByDimension: new Map(), anyUnknownQuantity: false };
      byKey.set(key, acc);
    }
    if (line.quantity.kind === "known") {
      const known = toBaseUnit(line.quantity.value, line.quantity.unit);
      acc.demandByDimension.set(known.dimension, (acc.demandByDimension.get(known.dimension) ?? 0) + known.base);
    } else {
      // Unknown quantity stays unknown: a later known line must not
      // resurrect a number (strictest state wins).
      acc.anyUnknownQuantity = true;
    }
  }
  return [...byKey.entries()].map(([key, acc]) => ({
    ingredientId: key.slice(0, key.lastIndexOf("|")),
    name: acc.name,
    optional: acc.optional,
    demandByDimension: acc.demandByDimension,
    anyUnknownQuantity: acc.anyUnknownQuantity
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

/**
 * Compare a demand against a source's stock. null = every dimension
 * component is covered; "unknown" = the source's quantity is unknown for
 * some component; otherwise the first uncovered component.
 */
function uncoveredComponent(
  demand: BillDemand,
  ledger: StockLedger,
  sourceId: string
): { dimension: string; base: number } | "unknown" | null {
  for (const [dimension, base] of demand.demandByDimension) {
    const remaining = ledger.peekKnown(sourceId, dimension);
    if (remaining === null) return "unknown";
    if (remaining < base - EPSILON) return { dimension, base };
  }
  return null;
}

/** Reserve every dimension component of a demand from `sourceId` (call only after a full-cover check). */
function allocateDemand(demand: BillDemand, ledger: StockLedger, sourceId: string): void {
  for (const [dimension, base] of demand.demandByDimension) {
    ledger.allocate(sourceId, base, dimension);
  }
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
    const swap = demand.anyUnknownQuantity ? undefined : swaps.find((s) => s.from === ingredientId);
    if (swap && swapClearsAllergens(swap.to)) {
      const uncovered = uncoveredComponent(demand, ledger, swap.to);
      if (uncovered === null) {
        allocateDemand(demand, ledger, swap.to);
        return { ingredientId, name, state: "swap-covered", swap };
      }
      if (uncovered === "unknown") {
        // The swap target's quantity is unknown — strictest state wins.
        return { ingredientId, name, state: "quantity-unknown" };
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
  // 4. Unknown quantity anywhere (pantry state, bill line, or any pantry
  //    lot — peekKnown is null while one lot is unknown) cannot be verified.
  if (pantryLine.state === "quantity-unknown" || demand.anyUnknownQuantity) {
    return { ingredientId, name, state: "quantity-unknown" };
  }
  for (const dimension of demand.demandByDimension.keys()) {
    if (ledger.peekKnown(ingredientId, dimension) === null) {
      return { ingredientId, name, state: "quantity-unknown" };
    }
  }

  // 5. Quantity math over allocated (reserved) stock, per dimension.
  const firstUncovered = uncoveredComponent(demand, ledger, ingredientId);
  if (firstUncovered === null) {
    allocateDemand(demand, ledger, ingredientId);
    return { ingredientId, name, state: "sufficient" };
  }

  // 6. An accepted swap may cover the shortfall, allergens permitting.
  const swap = swaps.find((s) => s.from === ingredientId);
  if (swap && swapClearsAllergens(swap.to)) {
    const uncoveredBySwap = uncoveredComponent(demand, ledger, swap.to);
    if (uncoveredBySwap === null) {
      allocateDemand(demand, ledger, swap.to);
      return { ingredientId, name, state: "swap-covered", swap };
    }
    if (uncoveredBySwap === "unknown") {
      return { ingredientId, name, state: "quantity-unknown" };
    }
  }

  if (firstUncovered === "unknown") {
    // Unreachable while the case-4 check passed (peekKnown was non-null for
    // every demanded dimension), but the type keeps it possible; the
    // strictest state wins if it ever is.
    return { ingredientId, name, state: "quantity-unknown" };
  }

  // 7. Short — reserve the partial stock so later candidates cannot count it.
  //    The shortfall is reported in the first uncovered component's own base
  //    units (mixed-dimension shortfalls never add across families).
  const taken = ledger.allocate(ingredientId, firstUncovered.base, firstUncovered.dimension);
  return { ingredientId, name, state: "short", shortBy: shortBy(firstUncovered.base, taken) };
}

// ---------------------------------------------------------------------------
// Fit line text
// ---------------------------------------------------------------------------

function listNames(lines: readonly FitLine[]): string {
  const names = lines.slice(0, 3).map((l) => l.name.toLowerCase());
  const more = lines.length > 3 ? ` and ${lines.length - 3} more` : "";
  const joined =
    names.length > 1
      ? `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`
      : (names[0] ?? "");
  return `${joined}${more}`;
}

function buildFit(required: readonly FitLine[], garnish: readonly FitLine[]): RecipeFit {
  const requiredCount = required.length;
  const sufficientCount = required.filter((l) => l.state === "sufficient").length;
  const swapCount = required.filter((l) => l.state === "swap-covered").length;
  const allSufficient = requiredCount > 0 && sufficientCount === requiredCount && swapCount === 0;
  const problems = required.filter((l) => PROBLEM_STATES.has(l.state));
  // Assumed staples and unknown-quantity lines hold no usable number: they
  // are NAMED, never counted as verified stock (review fix 6).
  const assumed = required.filter((l) => l.state === "assumed-staple");
  const assumeSuffix = assumed.length > 0 ? ` · ${listNames(assumed)} assumed` : "";
  // "Recorded" counts lines with positive recorded evidence only.
  const recorded = required.filter(
    (l) =>
      l.state === "sufficient" ||
      l.state === "swap-covered" ||
      l.state === "short" ||
      l.state === "needs-reconfirming"
  ).length;

  let fitLine: string;
  if (allSufficient) {
    // The only case where this phrase is allowed (SPEC 3.2).
    fitLine = "You have everything";
  } else if (problems.length === 0 && assumed.length === 0) {
    const swaps = swapCount > 0 ? ` · ${swapCount} swap${swapCount === 1 ? "" : "s"}` : "";
    fitLine = `${sufficientCount} of ${requiredCount}${swaps}`;
  } else if (problems.length === 0) {
    // Only assumptions keep the line from "you have everything": name them
    // instead of counting them as verified stock.
    fitLine = recorded > 0 ? `${recorded} recorded${assumeSuffix}` : `${listNames(assumed)} assumed`;
  } else {
    fitLine = `${recorded} recorded · check ${listNames(problems)}${assumeSuffix}`;
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
