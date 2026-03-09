import type {
  InventoryItem,
  RestockPlanRequest,
  RestockPlanResponse,
  UseSoonAlert
} from "../types/contracts.js";

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_RESTOCK_BELOW_GRAMS = 50;

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

  return alerts.sort((a, b) => a.daysRemaining - b.daysRemaining);
}

export function computeRestockList(
  items: InventoryItem[],
  restockBelowGrams = DEFAULT_RESTOCK_BELOW_GRAMS
): string[] {
  return items
    .filter((item) => item.quantityGrams < restockBelowGrams)
    .map((item) => item.ingredientName)
    .sort((a, b) => a.localeCompare(b));
}

export function buildRestockPlan(req: RestockPlanRequest): RestockPlanResponse {
  const { inventorySnapshot, thresholdDays, restockBelowGrams } = req;

  return {
    useSoonAlerts: computeUseSoon(inventorySnapshot, thresholdDays),
    restockList: computeRestockList(inventorySnapshot, restockBelowGrams),
    generatedAt: new Date().toISOString()
  };
}
