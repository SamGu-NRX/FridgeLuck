import { describe, it, expect } from "bun:test";
import { buildToolRegistry, dispatchToolCall } from "../agent/toolRegistry.js";
import type { ToolDeps } from "../agent/toolRegistry.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import { ConfidenceService } from "../services/confidenceService.js";

// Minimal mock deps that don't require real Gemini API calls
function makeDeps(): ToolDeps {
  const config: any = {
    port: 8080,
    useVertexAi: false,
    apiKey: "test-key",
    recipeModel: "gemini-2.5-flash",
    rankingModel: "gemini-2.5-flash",
    liveModel: "gemini-live-2.5-flash-preview",
    restockThresholdDays: 3,
    idempotencyTtlSeconds: 3600,
    restockBelowGrams: 50
  };
  return {
    ai: {} as any,
    config,
    ledger: new InventoryLedger(config),
    confidenceService: new ConfidenceService()
  };
}

describe("buildToolRegistry", () => {
  it("returns a Map with exactly 5 named tools", () => {
    const registry = buildToolRegistry();
    expect(registry.size).toBe(5);
    expect(registry.has("scan_fridge")).toBe(true);
    expect(registry.has("reverse_scan_meal")).toBe(true);
    expect(registry.has("generate_recipe")).toBe(true);
    expect(registry.has("mutate_inventory")).toBe(true);
    expect(registry.has("get_restock_plan")).toBe(true);
  });
});

describe("dispatchToolCall — unknown tool", () => {
  it("returns error and null result for an unregistered tool name", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "nonexistent_tool",
      {},
      registry,
      deps
    );
    expect(result).toBeNull();
    expect(typeof error).toBe("string");
    expect(error).toContain("nonexistent_tool");
  });
});

describe("dispatchToolCall — mutate_inventory", () => {
  it("returns error when idempotencyKey is missing", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "mutate_inventory",
      {
        operation: "add",
        // idempotencyKey intentionally missing
        items: [{ ingredientName: "Garlic", quantityGrams: 50 }]
      },
      registry,
      deps
    );
    expect(result).toBeNull();
    expect(error).toContain("idempotencyKey");
  });

  it("returns error when items array is empty", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "mutate_inventory",
      {
        operation: "add",
        idempotencyKey: "test-001",
        items: []
      },
      registry,
      deps
    );
    expect(result).toBeNull();
    expect(error).toContain("items");
  });

  it("returns error for unknown operation", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "mutate_inventory",
      {
        operation: "explode",
        idempotencyKey: "test-002",
        items: [{ ingredientName: "Sugar", quantityGrams: 100 }]
      },
      registry,
      deps
    );
    expect(result).toBeNull();
    expect(error).toContain("explode");
  });

  it("successfully adds items to the ledger", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "mutate_inventory",
      {
        operation: "add",
        idempotencyKey: "test-003",
        items: [{ ingredientName: "Tomato", quantityGrams: 300 }]
      },
      registry,
      deps
    );
    expect(error).toBeUndefined();
    const r = result as any;
    expect(r.committed).toBe(true);
    expect(r.snapshot.some((i: any) => i.ingredientName === "Tomato")).toBe(true);
  });
});

describe("dispatchToolCall — get_restock_plan", () => {
  it("returns a restock plan object with required fields", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();

    // Pre-populate inventory
    deps.ledger.addItems({
      idempotencyKey: "setup",
      items: [
        {
          ingredientName: "Spinach",
          quantityGrams: 20, // below 50g threshold
          expiresAt: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000).toISOString().split("T")[0]
        }
      ]
    });

    const { result, error } = await dispatchToolCall(
      "get_restock_plan",
      {},
      registry,
      deps
    );
    expect(error).toBeUndefined();
    const plan = result as any;
    expect(Array.isArray(plan.useSoonAlerts)).toBe(true);
    expect(Array.isArray(plan.restockList)).toBe(true);
    expect(typeof plan.generatedAt).toBe("string");
    expect(plan.restockList).toContain("Spinach");
  });
});
