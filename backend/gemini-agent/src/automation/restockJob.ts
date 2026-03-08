import type {
  InventoryItem,
  RestockPlanRequest,
  RestockPlanResponse,
  UseSoonAlert
} from "../types/contracts.js";

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_RESTOCK_BELOW_GRAMS = 50;

/**
 * Compute which items will expire within `thresholdDays`.
 * Items without an expiresAt are excluded (unknown shelf life).
 */
export function computeUseSoon(items: InventoryItem[], thresholdDays: number): UseSoonAlert[] {
  const now = Date.now();
  const alerts: UseSoonAlert[] = [];

  for (const item of items) {
    if (!item.expiresAt) continue;
    const expiryMs = new Date(item.expiresAt).getTime();
    const daysRemaining = Math.ceil((expiryMs - now) / MS_PER_DAY);
    if (daysRemaining <= thresholdDays) {
      alerts.push({
        ingredientName: item.ingredientName,
        expiresAt: item.expiresAt,
        daysRemaining: Math.max(0, daysRemaining)
      });
    }
  }

  // Sort most urgent first
  return alerts.sort((a, b) => a.daysRemaining - b.daysRemaining);
}

/**
 * Compute which items have been depleted below `restockBelowGrams`.
 * Returns the ingredient names only (the shopping list).
 */
export function computeRestockList(
  items: InventoryItem[],
  restockBelowGrams = DEFAULT_RESTOCK_BELOW_GRAMS
): string[] {
  return items
    .filter((item) => item.quantityGrams < restockBelowGrams)
    .map((item) => item.ingredientName)
    .sort((a, b) => a.localeCompare(b));
}

/**
 * Build a complete restock plan from an inventory snapshot.
 * Pure function — no I/O, easy to unit test.
 */
export function buildRestockPlan(req: RestockPlanRequest): RestockPlanResponse {
  const { inventorySnapshot, thresholdDays, restockBelowGrams } = req;

  return {
    useSoonAlerts: computeUseSoon(inventorySnapshot, thresholdDays),
    restockList: computeRestockList(inventorySnapshot, restockBelowGrams),
    generatedAt: new Date().toISOString()
  };
}
