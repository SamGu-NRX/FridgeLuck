import { describe, it, expect, beforeEach } from "bun:test";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import type { InventoryMutationRequest } from "../types/contracts.js";

const testConfig = { idempotencyTtlSeconds: 3600 };

describe("InventoryLedger.addItems", () => {
  let ledger: InventoryLedger;

  beforeEach(() => {
    ledger = new InventoryLedger(testConfig);
  });

  it("adds items and reflects them in snapshot", () => {
    const req: InventoryMutationRequest = {
      idempotencyKey: "add-001",
      items: [
        { ingredientName: "Chicken Breast", quantityGrams: 400, source: "scan" },
        { ingredientName: "Olive Oil", quantityGrams: 200, source: "scan" }
      ]
    };
    const result = ledger.addItems(req);
    expect(result.committed).toBe(true);
    expect(result.snapshot.length).toBe(2);

    const chicken = result.snapshot.find((i) => i.ingredientName === "Chicken Breast");
    expect(chicken?.quantityGrams).toBe(400);
  });

  it("top-ups existing ingredient quantity on subsequent add", () => {
    ledger.addItems({
      idempotencyKey: "add-002a",
      items: [{ ingredientName: "Eggs", quantityGrams: 300 }]
    });
    ledger.addItems({
      idempotencyKey: "add-002b",
      items: [{ ingredientName: "Eggs", quantityGrams: 100 }]
    });
    const snap = ledger.snapshot();
    const eggs = snap.find((i) => i.ingredientName === "Eggs");
    expect(eggs?.quantityGrams).toBe(400);
  });

  it("is case-insensitive for ingredient names", () => {
    ledger.addItems({
      idempotencyKey: "add-003a",
      items: [{ ingredientName: "Garlic", quantityGrams: 50 }]
    });
    ledger.addItems({
      idempotencyKey: "add-003b",
      items: [{ ingredientName: "garlic", quantityGrams: 20 }]
    });
    const snap = ledger.snapshot();
    expect(snap.length).toBe(1);
    expect(snap[0]!.quantityGrams).toBe(70);
  });

  it("clamps negative quantityGrams to 0", () => {
    const result = ledger.addItems({
      idempotencyKey: "add-004",
      items: [{ ingredientName: "Salt", quantityGrams: -100 }]
    });
    const salt = result.snapshot.find((i) => i.ingredientName === "Salt");
    expect(salt?.quantityGrams).toBe(0);
  });

  it("returns committed=false and cached snapshot for duplicate idempotency key", () => {
    const req: InventoryMutationRequest = {
      idempotencyKey: "add-005",
      items: [{ ingredientName: "Milk", quantityGrams: 500 }]
    };
    const first = ledger.addItems(req);
    expect(first.committed).toBe(true);

    // same key again — should be a no-op
    const second = ledger.addItems(req);
    expect(second.committed).toBe(false);
    expect(second.snapshot).toEqual(first.snapshot);

    // ledger state should not have doubled
    const snap = ledger.snapshot();
    const milk = snap.find((i) => i.ingredientName === "Milk");
    expect(milk?.quantityGrams).toBe(500);
  });
});

describe("InventoryLedger.decrementItems", () => {
  let ledger: InventoryLedger;

  beforeEach(() => {
    ledger = new InventoryLedger(testConfig);
    ledger.addItems({
      idempotencyKey: "setup-001",
      items: [
        { ingredientName: "Butter", quantityGrams: 250 },
        { ingredientName: "Flour", quantityGrams: 1000 }
      ]
    });
  });

  it("decrements quantity by the specified amount", () => {
    ledger.decrementItems({
      idempotencyKey: "dec-001",
      items: [{ ingredientName: "Butter", quantityGrams: 100 }]
    });
    const snap = ledger.snapshot();
    const butter = snap.find((i) => i.ingredientName === "Butter");
    expect(butter?.quantityGrams).toBe(150);
  });

  it("clamps quantity to 0, not negative", () => {
    ledger.decrementItems({
      idempotencyKey: "dec-002",
      items: [{ ingredientName: "Butter", quantityGrams: 9999 }]
    });
    const snap = ledger.snapshot();
    const butter = snap.find((i) => i.ingredientName === "Butter");
    expect(butter?.quantityGrams).toBe(0);
  });

  it("silently ignores ingredients not in ledger", () => {
    const result = ledger.decrementItems({
      idempotencyKey: "dec-003",
      items: [{ ingredientName: "Unicorn Dust", quantityGrams: 50 }]
    });
    expect(result.committed).toBe(true);
    // No new item added, existing items unchanged
    expect(result.snapshot.length).toBe(2);
  });

  it("idempotent: duplicate decrement key returns cached result", () => {
    const req: InventoryMutationRequest = {
      idempotencyKey: "dec-004",
      items: [{ ingredientName: "Flour", quantityGrams: 200 }]
    };
    ledger.decrementItems(req);
    const second = ledger.decrementItems(req);
    expect(second.committed).toBe(false);

    // Should only have decremented once
    const flour = ledger.snapshot().find((i) => i.ingredientName === "Flour");
    expect(flour?.quantityGrams).toBe(800);
  });
});

describe("InventoryLedger.snapshot", () => {
  it("returns an empty array on a fresh ledger", () => {
    const ledger = new InventoryLedger(testConfig);
    expect(ledger.snapshot()).toEqual([]);
  });

  it("returns a copy — mutations on the copy do not affect internal state", () => {
    const ledger = new InventoryLedger(testConfig);
    ledger.addItems({
      idempotencyKey: "snap-001",
      items: [{ ingredientName: "Tomato", quantityGrams: 200 }]
    });
    const snap = ledger.snapshot();
    snap[0]!.quantityGrams = 9999; // mutate the copy
    expect(ledger.snapshot()[0]!.quantityGrams).toBe(200); // original unchanged
  });
});

describe("InventoryLedger.clear", () => {
  it("removes all items and idempotency records", () => {
    const ledger = new InventoryLedger(testConfig);
    ledger.addItems({
      idempotencyKey: "clr-001",
      items: [{ ingredientName: "Pepper", quantityGrams: 50 }]
    });
    ledger.clear();
    expect(ledger.snapshot()).toEqual([]);

    // idempotency record should also be gone — same key should commit again
    const result = ledger.addItems({
      idempotencyKey: "clr-001",
      items: [{ ingredientName: "Pepper", quantityGrams: 50 }]
    });
    expect(result.committed).toBe(true);
  });
});
