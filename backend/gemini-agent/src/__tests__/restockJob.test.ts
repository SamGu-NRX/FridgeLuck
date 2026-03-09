import { describe, it, expect } from "bun:test";
import {
  computeUseSoon,
  computeRestockList,
  buildRestockPlan
} from "../automation/restockJob.js";
import type { InventoryItem } from "../types/contracts.js";

// Helper to produce an ISO date string N days from now
function daysFromNow(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return d.toISOString().split("T")[0]!;
}

describe("computeUseSoon", () => {
  it("returns empty array for empty inventory", () => {
    expect(computeUseSoon([], 3)).toEqual([]);
  });

  it("returns empty array when no items have expiresAt", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Salt", quantityGrams: 500 },
      { ingredientName: "Sugar", quantityGrams: 300 }
    ];
    expect(computeUseSoon(items, 3)).toEqual([]);
  });

  it("includes items expiring within threshold", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Spinach", quantityGrams: 100, expiresAt: daysFromNow(1) },
      { ingredientName: "Milk", quantityGrams: 200, expiresAt: daysFromNow(2) },
      { ingredientName: "Cheese", quantityGrams: 150, expiresAt: daysFromNow(10) }
    ];
    const alerts = computeUseSoon(items, 3);
    expect(alerts.length).toBe(2);
    const names = alerts.map((a) => a.ingredientName);
    expect(names).toContain("Spinach");
    expect(names).toContain("Milk");
    expect(names).not.toContain("Cheese");
  });

  it("excludes items expiring exactly at threshold boundary + 1 day", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Yogurt", quantityGrams: 200, expiresAt: daysFromNow(4) }
    ];
    // threshold = 3 days; 4 days away should NOT be included
    expect(computeUseSoon(items, 3)).toEqual([]);
  });

  it("returns daysRemaining of 0 for already-expired items", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Leftover", quantityGrams: 50, expiresAt: daysFromNow(-2) }
    ];
    const alerts = computeUseSoon(items, 5);
    expect(alerts.length).toBe(1);
    expect(alerts[0]!.daysRemaining).toBe(0);
  });

  it("sorts by daysRemaining ascending (most urgent first)", () => {
    const items: InventoryItem[] = [
      { ingredientName: "B", quantityGrams: 100, expiresAt: daysFromNow(3) },
      { ingredientName: "A", quantityGrams: 100, expiresAt: daysFromNow(1) },
      { ingredientName: "C", quantityGrams: 100, expiresAt: daysFromNow(2) }
    ];
    const alerts = computeUseSoon(items, 5);
    expect(alerts.map((a) => a.ingredientName)).toEqual(["A", "C", "B"]);
  });
});

describe("computeRestockList", () => {
  it("returns empty array for empty inventory", () => {
    expect(computeRestockList([], 50)).toEqual([]);
  });

  it("returns ingredients below threshold grams", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Pepper", quantityGrams: 10 },
      { ingredientName: "Rice", quantityGrams: 800 },
      { ingredientName: "Cumin", quantityGrams: 5 }
    ];
    const list = computeRestockList(items, 50);
    expect(list).toContain("Pepper");
    expect(list).toContain("Cumin");
    expect(list).not.toContain("Rice");
  });

  it("includes item at exactly 0 grams", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Paprika", quantityGrams: 0 }
    ];
    expect(computeRestockList(items, 50)).toContain("Paprika");
  });

  it("excludes items at exactly the threshold", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Oregano", quantityGrams: 50 }
    ];
    // quantityGrams < threshold: 50 is NOT less than 50
    expect(computeRestockList(items, 50)).not.toContain("Oregano");
  });

  it("uses default threshold of 50g when not specified", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Chilli", quantityGrams: 49 }
    ];
    expect(computeRestockList(items)).toContain("Chilli");
  });

  it("returns list sorted alphabetically", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Zinc Supplement", quantityGrams: 10 },
      { ingredientName: "Apple Cider Vinegar", quantityGrams: 10 },
      { ingredientName: "Mustard", quantityGrams: 10 }
    ];
    const list = computeRestockList(items, 50);
    expect(list).toEqual(["Apple Cider Vinegar", "Mustard", "Zinc Supplement"]);
  });
});

describe("buildRestockPlan", () => {
  it("returns a plan with all required fields", () => {
    const plan = buildRestockPlan({
      inventorySnapshot: [],
      thresholdDays: 3
    });
    expect(Array.isArray(plan.useSoonAlerts)).toBe(true);
    expect(Array.isArray(plan.restockList)).toBe(true);
    expect(typeof plan.generatedAt).toBe("string");
  });

  it("generatedAt is a valid ISO 8601 string", () => {
    const plan = buildRestockPlan({ inventorySnapshot: [], thresholdDays: 3 });
    const date = new Date(plan.generatedAt);
    expect(isNaN(date.getTime())).toBe(false);
  });

  it("combines use-soon and restock correctly for realistic inventory", () => {
    const items: InventoryItem[] = [
      { ingredientName: "Broccoli", quantityGrams: 30, expiresAt: daysFromNow(1) },  // use-soon + restock
      { ingredientName: "Pasta", quantityGrams: 500 }                                // neither
    ];
    const plan = buildRestockPlan({ inventorySnapshot: items, thresholdDays: 3, restockBelowGrams: 50 });
    expect(plan.useSoonAlerts.map((a) => a.ingredientName)).toContain("Broccoli");
    expect(plan.restockList).toContain("Broccoli");
    expect(plan.restockList).not.toContain("Pasta");
  });
});
