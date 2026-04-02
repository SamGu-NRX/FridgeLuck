import { describe, expect, it } from "bun:test";
import { buildNotificationPlan } from "../notifications/notificationPlan.js";
import type { NotificationPlanRequest } from "../types/contracts.js";

function requestWithInventory(
  inventorySnapshot: NotificationPlanRequest["inventorySnapshot"]
): NotificationPlanRequest {
  return {
    installationId: "installation-1",
    timezone: "America/Chicago",
    locale: "en-US",
    generatedAt: "2026-04-02T15:00:00.000Z",
    rules: [
      {
        kind: "use_soon_alerts",
        enabled: true,
        hour: 18,
        minute: 0
      }
    ],
    inventorySnapshot
  };
}

function daysFrom(base: string, days: number): string {
  const date = new Date(base);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString();
}

describe("buildNotificationPlan", () => {
  it("returns no opportunities for empty inventory", () => {
    const plan = buildNotificationPlan(requestWithInventory([]));
    expect(plan.opportunities).toEqual([]);
  });

  it("returns one digest opportunity for a single expiring item", () => {
    const plan = buildNotificationPlan(
      requestWithInventory([
        {
          ingredientId: 3,
          ingredientName: "Spinach",
          quantityGrams: 120,
          expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 1),
          confidenceScore: 0.9
        }
      ])
    );

    expect(plan.opportunities.length).toBe(1);
    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Spinach"]);
  });

  it("collapses multiple expiring ingredients into a single digest", () => {
    const plan = buildNotificationPlan(
      requestWithInventory([
        {
          ingredientId: 10,
          ingredientName: "Milk",
          quantityGrams: 220,
          expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 1),
          confidenceScore: 1
        },
        {
          ingredientId: 4,
          ingredientName: "Spinach",
          quantityGrams: 80,
          expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 2),
          confidenceScore: 0.8
        },
        {
          ingredientId: 7,
          ingredientName: "Parsley",
          quantityGrams: 30,
          expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 1),
          confidenceScore: 0.85
        }
      ])
    );

    expect(plan.opportunities.length).toBe(1);
    expect(plan.opportunities[0]?.payload.ingredientNames.length).toBe(3);
  });

  it("skips already expired ingredients", () => {
    const plan = buildNotificationPlan(
      requestWithInventory([
        {
          ingredientId: 12,
          ingredientName: "Yogurt",
          quantityGrams: 100,
          expiresAt: "2026-04-01T08:00:00.000Z",
          confidenceScore: 0.9
        }
      ])
    );

    expect(plan.opportunities).toEqual([]);
  });

  it("creates stable ids for identical input", () => {
    const request = requestWithInventory([
      {
        ingredientId: 3,
        ingredientName: "Spinach",
        quantityGrams: 120,
        expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 1),
        confidenceScore: 0.9
      }
    ]);

    const first = buildNotificationPlan(request);
    const second = buildNotificationPlan(request);

    expect(first.opportunities[0]?.id).toBe(second.opportunities[0]?.id);
  });
});
