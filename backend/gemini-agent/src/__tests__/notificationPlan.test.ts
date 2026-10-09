import { describe, expect, it } from "bun:test";
import { buildNotificationPlan } from "../notifications/notificationPlan.js";
import type { InventoryItem, NotificationPlanResponse } from "../types/contracts.js";

const CHICAGO = "America/Chicago";

function item(ingredientId: number, ingredientName: string, expiresAt: string): InventoryItem {
  return { ingredientId, ingredientName, quantityGrams: 100, expiresAt, confidenceScore: 0.9 };
}

function planFor(options: {
  generatedAt: string;
  hour: number;
  minute: number;
  inventory: InventoryItem[];
  timezone?: string;
}): NotificationPlanResponse {
  return buildNotificationPlan({
    installationId: "installation-1",
    timezone: options.timezone ?? CHICAGO,
    locale: "en-US",
    generatedAt: options.generatedAt,
    rules: [
      {
        kind: "use_soon_alerts",
        enabled: true,
        hour: options.hour,
        minute: options.minute
      }
    ],
    inventorySnapshot: options.inventory
  });
}

function daysFrom(base: string, days: number): string {
  const date = new Date(base);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString();
}

/**
 * All scheduled instants below are pinned UTC timestamps for America/Chicago.
 * Reference transitions for 2026 (verified via Intl this change):
 * - Spring forward: 2026-03-08, wall 02:00 CST -> 03:00 CDT at instant 2026-03-08T08:00:00Z.
 * - Fall back:      2026-11-01, wall 02:00 CDT -> 01:00 CST at instant 2026-11-01T07:00:00Z,
 *   so wall 01:30 occurs twice that day: 06:30Z (CDT) and 07:30Z (CST).
 */
describe("buildNotificationPlan scheduling", () => {
  it("schedules today's rule time on an ordinary day", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(1, "Spinach", "2026-04-03T15:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-04-02T23:00:00.000Z");
  });

  it("advances one local date across the spring-forward day, not 24 elapsed hours", () => {
    // Local now is 2026-03-07 23:30 CST. Today's 18:00 already passed, so the plan
    // must land on the next LOCAL date (March 8), which is a CDT day (-5).
    const plan = planFor({
      generatedAt: "2026-03-08T05:30:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(1, "Spinach", "2026-03-10T05:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-03-08T23:00:00.000Z");
  });

  it("does not vanish for a midnight rule the day after the fall-back transition", () => {
    // Local now is 2026-11-01 00:30 CDT. Today's midnight just passed; the next
    // local midnight is November 2 (CST, -6) = 2026-11-02T06:00:00Z.
    const plan = planFor({
      generatedAt: "2026-11-01T05:30:00.000Z",
      hour: 0,
      minute: 0,
      inventory: [item(1, "Spinach", "2026-11-02T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-11-02T06:00:00.000Z");
  });

  it("reads local midnight as hour 00, not the h24 '24:00' form", () => {
    // generatedAt is exactly local midnight (2026-11-01 24:00 in h24 form).
    // The next 18:00 rule time is November 2 (CST) = 2026-11-03T00:00:00Z.
    const plan = planFor({
      generatedAt: "2026-11-02T06:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(1, "Spinach", "2026-11-03T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-11-03T00:00:00.000Z");
  });

  it("schedules the next local day once the rule hour has passed", () => {
    const plan = planFor({
      generatedAt: "2026-04-03T01:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(1, "Spinach", "2026-04-04T01:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-04-03T23:00:00.000Z");
  });

  it("moves a nonexistent rule time to the first valid instant after the spring gap", () => {
    // Local now is 2026-03-08 01:30 CST. Wall 02:30 does not exist on this date
    // (02:00 -> 03:00 gap); policy: first valid instant after the gap = 03:00 CDT.
    const plan = planFor({
      generatedAt: "2026-03-08T07:30:00.000Z",
      hour: 2,
      minute: 30,
      inventory: [item(1, "Spinach", "2026-03-08T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-03-08T08:00:00.000Z");
  });

  it("schedules the next local day when the gap-shifted instant already passed", () => {
    // Local now is 2026-03-08 03:30 CDT, already past the gap-shifted 03:00.
    // Next occurrence: March 9 at 02:30 CDT = 2026-03-09T07:30:00Z.
    const plan = planFor({
      generatedAt: "2026-03-08T08:30:00.000Z",
      hour: 2,
      minute: 30,
      inventory: [item(1, "Spinach", "2026-03-10T08:30:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-03-09T07:30:00.000Z");
  });

  it("picks the first fold occurrence when it is still ahead", () => {
    // Local now is 2026-11-01 00:00 CDT. Wall 01:30 happens twice: 06:30Z (CDT)
    // and 07:30Z (CST). Policy: earliest occurrence strictly after now.
    const plan = planFor({
      generatedAt: "2026-11-01T05:00:00.000Z",
      hour: 1,
      minute: 30,
      inventory: [item(1, "Spinach", "2026-11-01T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-11-01T06:30:00.000Z");
  });

  it("picks the second fold occurrence once the first has passed", () => {
    // Local now is 2026-11-01 01:45 CDT: the 01:30 CDT occurrence is gone but the
    // 01:30 CST occurrence (07:30Z) is still upcoming on the same local date.
    const plan = planFor({
      generatedAt: "2026-11-01T06:45:00.000Z",
      hour: 1,
      minute: 30,
      inventory: [item(1, "Spinach", "2026-11-01T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-11-01T07:30:00.000Z");
  });

  it("moves to the next local day after both fold occurrences have passed", () => {
    // Local now is 2026-11-01 01:45 CST. Next: November 2 at 01:30 CST.
    const plan = planFor({
      generatedAt: "2026-11-01T07:45:00.000Z",
      hour: 1,
      minute: 30,
      inventory: [item(1, "Spinach", "2026-11-02T12:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.scheduledAt).toBe("2026-11-02T07:30:00.000Z");
  });
});

describe("buildNotificationPlan candidates", () => {
  it("returns no opportunities for empty inventory", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: []
    });

    expect(plan.opportunities).toEqual([]);
  });

  it("returns one digest opportunity for a single expiring item", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(3, "Spinach", daysFrom("2026-04-02T15:00:00.000Z", 1))]
    });

    expect(plan.opportunities.length).toBe(1);
    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Spinach"]);
  });

  it("collapses multiple expiring ingredients into a single digest", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(10, "Milk", daysFrom("2026-04-02T15:00:00.000Z", 1)),
        item(4, "Spinach", daysFrom("2026-04-02T15:00:00.000Z", 2)),
        item(7, "Parsley", daysFrom("2026-04-02T15:00:00.000Z", 1))
      ]
    });

    expect(plan.opportunities.length).toBe(1);
    expect(plan.opportunities[0]?.payload.ingredientNames.length).toBe(3);
  });

  it("skips already expired ingredients", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(12, "Yogurt", "2026-04-01T08:00:00.000Z")]
    });

    expect(plan.opportunities).toEqual([]);
  });

  it("skips items without an expiry timestamp", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        { ingredientId: 2, ingredientName: "Salt", quantityGrams: 500, confidenceScore: 1 },
        item(3, "Spinach", "2026-04-03T15:00:00.000Z")
      ]
    });

    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Spinach"]);
  });

  it("keeps an item at the two-day threshold boundary", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [item(6, "Milk", "2026-04-04T15:00:00.000Z")]
    });

    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([6]);
  });

  it("drops items that expire before the digest is scheduled to fire", () => {
    // Milk expires at 21:00Z, before the 23:00Z digest: planning at 15:00Z still
    // sees ~6h left, but the notification would arrive after expiry.
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(1, "Milk", "2026-04-02T21:00:00.000Z"),
        item(2, "Basil", "2026-04-03T15:00:00.000Z")
      ]
    });

    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Basil"]);
    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([2]);
  });
});

describe("buildNotificationPlan payload integrity", () => {
  it("keeps id/name/expiry tuples aligned through sorting", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(9, "Anise", "2026-04-03T15:00:00.000Z"),
        item(2, "Basil", "2026-04-03T15:00:00.000Z")
      ]
    });

    // Same urgency: canonical order is by name, so Anise (id 9) precedes Basil (id 2).
    // Sorting ids independently of names would pair id 2 with "Anise".
    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([9, 2]);
    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Anise", "Basil"]);
    expect(plan.opportunities[0]?.payload.expiresAt).toEqual([
      "2026-04-03T15:00:00.000Z",
      "2026-04-03T15:00:00.000Z"
    ]);
  });

  it("merges duplicate lots of the same ingredient using the earliest expiry", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(5, "Spinach", "2026-04-04T15:00:00.000Z"),
        item(5, "Spinach", "2026-04-03T15:00:00.000Z")
      ]
    });

    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([5]);
    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Spinach"]);
    expect(plan.opportunities[0]?.payload.expiresAt).toEqual(["2026-04-03T15:00:00.000Z"]);
  });

  it("keeps conflicting names for one ingredient id as separate entries and reports them", () => {
    const logs: unknown[][] = [];
    const originalLog = console.log;
    console.log = (...args: unknown[]) => {
      logs.push(args);
    };

    let plan: NotificationPlanResponse;
    try {
      plan = planFor({
        generatedAt: "2026-04-02T15:00:00.000Z",
        hour: 18,
        minute: 0,
        inventory: [
          item(5, "Spinach", "2026-04-03T15:00:00.000Z"),
          item(5, "Baby Spinach", "2026-04-03T15:00:00.000Z")
        ]
      });
    } finally {
      console.log = originalLog;
    }

    // Not silently recombined into one entry: both (id, name) tuples survive.
    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([5, 5]);
    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Baby Spinach", "Spinach"]);

    const conflictReports = logs.filter(
      (args) => typeof args[0] === "string" && args[0].includes("conflicting_ingredient_names")
    );
    expect(conflictReports.length).toBeGreaterThan(0);
  });

  it("caps the digest at three ingredients", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(40, "Dates", "2026-04-03T15:00:00.000Z"),
        item(41, "Endive", "2026-04-03T15:00:00.000Z"),
        item(42, "Figs", "2026-04-03T15:00:00.000Z"),
        item(43, "Grapes", "2026-04-03T15:00:00.000Z")
      ]
    });

    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Dates", "Endive", "Figs"]);
  });

  it("orders the payload by urgency, then name", () => {
    const plan = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [
        item(20, "Milk", "2026-04-04T15:00:00.000Z"),
        item(21, "Apples", "2026-04-03T15:00:00.000Z"),
        item(22, "Bananas", "2026-04-03T15:00:00.000Z")
      ]
    });

    expect(plan.opportunities[0]?.payload.ingredientNames).toEqual(["Apples", "Bananas", "Milk"]);
    expect(plan.opportunities[0]?.payload.ingredientIds).toEqual([21, 22, 20]);
  });

  it("produces identical ids and payloads regardless of inventory input order", () => {
    const inventory = [
      item(10, "Milk", "2026-04-04T15:00:00.000Z"),
      item(11, "Apples", "2026-04-03T15:00:00.000Z"),
      item(12, "Bananas", "2026-04-03T09:00:00.000Z")
    ];

    const first = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory
    });
    const second = planFor({
      generatedAt: "2026-04-02T15:00:00.000Z",
      hour: 18,
      minute: 0,
      inventory: [inventory[2]!, inventory[0]!, inventory[1]!]
    });

    expect(second.opportunities[0]?.id).toBe(first.opportunities[0]?.id);
    expect(second.opportunities[0]?.payload).toEqual(first.opportunities[0]?.payload);
  });

  it("creates stable ids for identical input", () => {
    const request = {
      installationId: "installation-1",
      timezone: CHICAGO,
      locale: "en-US",
      generatedAt: "2026-04-02T15:00:00.000Z",
      rules: [{ kind: "use_soon_alerts" as const, enabled: true, hour: 18, minute: 0 }],
      inventorySnapshot: [
        {
          ingredientId: 3,
          ingredientName: "Spinach",
          quantityGrams: 120,
          expiresAt: daysFrom("2026-04-02T15:00:00.000Z", 1),
          confidenceScore: 0.9
        }
      ]
    };

    const first = buildNotificationPlan(request);
    const second = buildNotificationPlan(request);

    expect(first.opportunities[0]?.id).toBe(second.opportunities[0]?.id);
  });

  it("returns no opportunities when the use-soon rule is disabled", () => {
    const plan = buildNotificationPlan({
      installationId: "installation-1",
      timezone: CHICAGO,
      locale: "en-US",
      generatedAt: "2026-04-02T15:00:00.000Z",
      rules: [{ kind: "use_soon_alerts", enabled: false, hour: 18, minute: 0 }],
      inventorySnapshot: [item(3, "Spinach", "2026-04-03T15:00:00.000Z")]
    });

    expect(plan.opportunities).toEqual([]);
  });
});
