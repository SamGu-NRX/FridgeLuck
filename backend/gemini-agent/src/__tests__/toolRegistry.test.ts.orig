import { describe, it, expect } from "bun:test";
import { buildToolRegistry, dispatchToolCall } from "../agent/toolRegistry.js";
import type { ToolDeps } from "../agent/toolRegistry.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import { ConfidenceService } from "../services/confidenceService.js";
import { createLiveSessionStore } from "../session/liveSessionStore.js";

function makeDeps(): ToolDeps {
  const config: any = {
    port: 8080,
    useVertexAi: false,
    apiKey: "test-key",
    recipeModel: "gemini-2.5-flash",
    rankingModel: "gemini-2.5-flash",
    liveModel: "gemini-2.5-flash-native-audio-preview-12-2025",
    restockThresholdDays: 3,
    idempotencyTtlSeconds: 3600,
    restockBelowGrams: 50,
    sessionStoreMode: "memory",
    firestoreCollection: "liveSessions",
    groundingEnabled: true
  };
  return {
    ai: {
      models: {
        generateContent: async ({ contents, config }: any) => {
          if (config?.tools?.[0]?.googleSearch !== undefined) {
            return {
              text: "Grounded answer",
              candidates: [
                {
                  groundingMetadata: {
                    groundingChunks: [{ web: { title: "USDA", uri: "https://example.com/usda" } }]
                  }
                }
              ]
            };
          }

          const joined = JSON.stringify(contents);
          if (joined.includes("selected_recipe_title")) {
            return {
              text: JSON.stringify({
                currentStep: "Saute the onions",
                guidance: "Keep stirring for 1 minute.",
                observedIngredients: ["onion", "olive oil"],
                kitchenRisks: ["Pan looks crowded."],
                modelConfidence: 0.88
              })
            };
          }

          return { text: "{}" };
        }
      }
    } as any,
    config,
    ledger: new InventoryLedger(config),
    confidenceService: new ConfidenceService(),
    sessionStore: createLiveSessionStore(config)
  };
}

describe("buildToolRegistry", () => {
  it("returns a Map with exactly 5 named tools", () => {
    const registry = buildToolRegistry();
    expect(registry.size).toBe(5);
    expect(registry.has("get_recipe_context")).toBe(true);
    expect(registry.has("assess_live_scene")).toBe(true);
    expect(registry.has("ground_food_safety")).toBe(true);
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
    await deps.sessionStore.ensureSession("sess-1");
    const { result, error } = await dispatchToolCall(
      "mutate_inventory",
      {
        operation: "add",
        idempotencyKey: "test-003",
        items: [{ ingredientName: "Tomato", quantityGrams: 300 }]
      },
      registry,
      deps,
      "sess-1"
    );
    expect(error).toBeUndefined();
    const r = result as any;
    expect(r.committed).toBe(true);
    expect(r.snapshot.some((i: any) => i.ingredientName === "Tomato")).toBe(true);
    const session = await deps.sessionStore.getSession("sess-1");
    expect(session.mutationAudit).toHaveLength(1);
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

describe("dispatchToolCall — live context tools", () => {
  it("returns stored recipe context for the session", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    await deps.sessionStore.patchContext("sess-ctx", {
      selectedRecipe: { title: "Skillet Eggs", instructions: "Cook eggs gently." },
      confirmedIngredients: [{ name: "egg", confidence: 0.96 }]
    });

    const { result, error } = await dispatchToolCall("get_recipe_context", {}, registry, deps, "sess-ctx");
    expect(error).toBeUndefined();
    const payload = result as any;
    expect(payload.selectedRecipe.title).toBe("Skillet Eggs");
    expect(payload.confirmedIngredients).toHaveLength(1);
  });

  it("assesses the live scene using stored frame and recipe context", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    await deps.sessionStore.patchContext("sess-live", {
      selectedRecipe: {
        title: "Skillet Eggs",
        instructions: "Saute onions, then add eggs.",
        ingredients: [{ name: "egg" }, { name: "onion" }]
      },
      confirmedIngredients: [{ name: "egg", confidence: 0.97 }, { name: "onion", confidence: 0.9 }]
    });
    await deps.sessionStore.recordLatestFrame("sess-live", {
      mimeType: "image/jpeg",
      dataBase64: "abc123",
      updatedAt: new Date().toISOString()
    });

    const { result, error } = await dispatchToolCall(
      "assess_live_scene",
      { userQuestion: "What should I do next?" },
      registry,
      deps,
      "sess-live"
    );
    expect(error).toBeUndefined();
    const payload = result as any;
    expect(payload.currentStep).toBe("Saute the onions");
    expect(payload.confidence_assessment.mode).toBeDefined();
  });

  it("returns a grounded answer with sources for food-safety questions", async () => {
    const registry = buildToolRegistry();
    const deps = makeDeps();
    const { result, error } = await dispatchToolCall(
      "ground_food_safety",
      { question: "How long is cooked rice safe in the fridge?" },
      registry,
      deps,
      "sess-ground"
    );
    expect(error).toBeUndefined();
    const payload = result as any;
    expect(payload.answer).toContain("Grounded answer");
    expect(payload.sources[0].title).toBe("USDA");
  });
});
