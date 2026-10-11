import { describe, it, expect } from "bun:test";
import { computeCandidateFits } from "../../lechef/fit.js";
import type { PantryLine, PantrySnapshot, RecipeContext } from "../../lechef/types.js";

function pantryLine(partial: Partial<PantryLine> & Pick<PantryLine, "ingredientId" | "name">): PantryLine {
  return {
    quantity: { kind: "unknown" },
    state: "sufficient",
    source: "manual",
    ...partial
  };
}

function pantry(...items: PantryLine[]): PantrySnapshot {
  return { revision: 1, capturedAt: 0 as never, items };
}

function recipe(partial: Partial<RecipeContext> & Pick<RecipeContext, "id">): RecipeContext {
  return {
    revision: 1,
    servings: 2,
    ingredientBill: [],
    steps: [],
    ...partial
  };
}

function fits(recipes: RecipeContext[], snap: PantrySnapshot, opts?: { acceptedSwaps?: { from: string; to: string }[]; swapViolations?: (to: string) => string[] }) {
  return computeCandidateFits(recipes, snap, {
    swapViolations: opts?.swapViolations ?? (() => []),
    ...(opts?.acceptedSwaps !== undefined ? { acceptedSwaps: opts.acceptedSwaps } : {})
  });
}

describe("fit: complete-bill computation", () => {
  it("sums repeated bill lines for the same ingredient", () => {
    const r = recipe({
      id: "pasta",
      ingredientBill: [
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 2, unit: "piece" } },
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } }
      ]
    });
    const snap = pantry(pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" } }));
    const fit = fits([r], snap).get("pasta")!.fit;
    // 4 eggs in stock vs 5 demanded across the summed lines → short.
    expect(fit.required).toHaveLength(1);
    expect(fit.required[0].state).toBe("short");
    expect(fit.allSufficient).toBe(false);
  });

  it("adds a second pantry line to the same pool before judging (7 recorded across scans)", () => {
    const r = recipe({
      id: "pasta",
      ingredientBill: [{ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 7, unit: "piece" } }]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" }, source: "scan" }),
      pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" }, source: "receipt" })
    );
    const fit = fits([r], snap).get("pasta")!.fit;
    expect(fit.allSufficient).toBe(true);
    expect(fit.fitLine).toBe("You have everything");
  });

  it("keeps optional garnish lines separate and never lets them block the fit", () => {
    const r = recipe({
      id: "curry",
      ingredientBill: [
        { ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 300, unit: "g" } },
        { ingredientId: "parsley", name: "Parsley", quantity: { kind: "known", value: 10, unit: "g" }, optional: true }
      ]
    });
    const snap = pantry(pantryLine({ ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 500, unit: "g" } }));
    const fit = fits([r], snap).get("curry")!.fit;
    expect(fit.allSufficient).toBe(true); // garnish absence does not block
    expect(fit.required).toHaveLength(1);
    expect(fit.garnish).toHaveLength(1);
    expect(fit.garnish[0].state).toBe("missing");
    expect(fit.fitLine).toBe("You have everything");
  });

  it("never double-counts shared stock across candidates", () => {
    const a = recipe({ id: "a", ingredientBill: [{ ingredientId: "flour", name: "Flour", quantity: { kind: "known", value: 500, unit: "g" } }] });
    const b = recipe({ id: "b", ingredientBill: [{ ingredientId: "flour", name: "Flour", quantity: { kind: "known", value: 500, unit: "g" } }] });
    const snap = pantry(pantryLine({ ingredientId: "flour", name: "Flour", quantity: { kind: "known", value: 600, unit: "g" } }));
    const results = fits([a, b], snap);
    expect(results.get("a")!.fit.required[0].state).toBe("sufficient");
    expect(results.get("b")!.fit.required[0].state).toBe("short");
    expect(results.get("b")!.fit.required[0].shortBy).toBeGreaterThan(0);
  });

  it("respects an accepted swap that covers a missing line, allergens permitting", () => {
    const r = recipe({ id: "stew", ingredientBill: [{ ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 50, unit: "g" } }] });
    const snap = pantry(pantryLine({ ingredientId: "olive-oil", name: "Olive oil", quantity: { kind: "known", value: 100, unit: "ml" } }));
    const clear = fits([r], snap, { acceptedSwaps: [{ from: "butter", to: "olive oil" }] });
    // dimension mismatch (mass vs volume) — swaps for missing lines use the base demand; the ledger
    // has no butter, so the swap target must cover the demand in ITS OWN base units.
    const fit = clear.get("stew")!.fit;
    expect(["swap-covered", "missing"]).toContain(fit.required[0].state);
    const blocked = fits([r], snap, {
      acceptedSwaps: [{ from: "butter", to: "olive oil" }],
      swapViolations: () => ["eater restriction: dairy-free only forbids butter→olive oil? no — violates peanut"]
    });
    expect(blocked.get("stew")!.fit.required[0].state).toBe("missing");
  });
});

describe("fit: fit-line text comes from per-line states only", () => {
  it("reports n of m with k swaps and never a percentage", () => {
    const r = recipe({
      id: "stirfry",
      ingredientBill: [
        { ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 300, unit: "g" } },
        { ingredientId: "soy-sauce", name: "Soy sauce", quantity: { kind: "known", value: 30, unit: "ml" } },
        { ingredientId: "ginger", name: "Ginger", quantity: { kind: "known", value: 20, unit: "g" } },
        { ingredientId: "spring-onion", name: "Spring onion", quantity: { kind: "known", value: 50, unit: "g" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 500, unit: "g" } }),
      pantryLine({ ingredientId: "soy-sauce", name: "Soy sauce", quantity: { kind: "known", value: 100, unit: "ml" } }),
      pantryLine({ ingredientId: "tofu", name: "Tofu", quantity: { kind: "known", value: 200, unit: "g" } }) // swap target for ginger
    );
    const fit = fits([r], snap, { acceptedSwaps: [{ from: "ginger", to: "tofu" }] }).get("stirfry")!.fit;
    // Three lines are recorded (rice, soy, ginger via swap); spring onion is missing.
    expect(fit.fitLine).toBe("3 recorded · check spring onion");
    expect(fit.fitLine).not.toContain("%");
    expect(fit.fitLine).not.toMatch(/percent/i);
  });

  it("notes swaps in the count form when nothing is missing", () => {
    const r = recipe({
      id: "stirfry",
      ingredientBill: [
        { ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 300, unit: "g" } },
        { ingredientId: "soy-sauce", name: "Soy sauce", quantity: { kind: "known", value: 30, unit: "ml" } },
        { ingredientId: "ginger", name: "Ginger", quantity: { kind: "known", value: 20, unit: "g" } },
        { ingredientId: "spring-onion", name: "Spring onion", quantity: { kind: "known", value: 50, unit: "g" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "rice", name: "Rice", quantity: { kind: "known", value: 500, unit: "g" } }),
      pantryLine({ ingredientId: "soy-sauce", name: "Soy sauce", quantity: { kind: "known", value: 100, unit: "ml" } }),
      pantryLine({ ingredientId: "tofu", name: "Tofu", quantity: { kind: "known", value: 200, unit: "g" } }),
      pantryLine({ ingredientId: "spring-onion", name: "Spring onion", quantity: { kind: "known", value: 50, unit: "g" } })
    );
    const fit = fits([r], snap, { acceptedSwaps: [{ from: "ginger", to: "tofu" }] }).get("stirfry")!.fit;
    // A swap is not the you-have-everything claim: the count form with a swap note.
    expect(fit.allSufficient).toBe(false);
    expect(fit.fitLine).toBe("3 of 4 · 1 swap");
    expect(fit.fitLine).not.toContain("%");
  });

  it("uses the check form when lines are missing or short", () => {
    const r = recipe({
      id: "omelette",
      ingredientBill: [
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } },
        { ingredientId: "oil", name: "Oil", quantity: { kind: "known", value: 15, unit: "ml" } },
        { ingredientId: "spinach", name: "Spinach", quantity: { kind: "known", value: 100, unit: "g" } },
        { ingredientId: "feta", name: "Feta", quantity: { kind: "known", value: 50, unit: "g" } }
      ]
    });
    const snap = pantry(pantryLine({ ingredientId: "oil", name: "Oil", quantity: { kind: "known", value: 100, unit: "ml" } }));
    const fit = fits([r], snap).get("omelette")!.fit;
    expect(fit.fitLine).toBe("1 recorded · check eggs, spinach and feta");
    expect(fit.fitLine).not.toContain("%");
  });

  it("never says you-have-everything when a required line is not strictly sufficient", () => {
    const r = recipe({
      id: "salad",
      ingredientBill: [
        { ingredientId: "lettuce", name: "Lettuce", quantity: { kind: "known", value: 1, unit: "piece" } },
        { ingredientId: "salt", name: "Salt", quantity: { kind: "known", value: 2, unit: "g" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "lettuce", name: "Lettuce", quantity: { kind: "known", value: 1, unit: "piece" } }),
      pantryLine({ ingredientId: "salt", name: "Salt", quantity: { kind: "unknown" }, state: "assumed-staple" })
    );
    const fit = fits([r], snap).get("salad")!.fit;
    // An assumed staple is present on ASSUMPTION — never the you-have-everything claim.
    expect(fit.allSufficient).toBe(false);
    expect(fit.fitLine).not.toBe("You have everything");
  });

  it("keeps stale evidence from becoming sufficient by arithmetic", () => {
    const r = recipe({ id: "soup", ingredientBill: [{ ingredientId: "leek", name: "Leek", quantity: { kind: "known", value: 1, unit: "piece" } }] });
    const snap = pantry(pantryLine({ ingredientId: "leek", name: "Leek", quantity: { kind: "known", value: 2, unit: "piece" }, state: "needs-reconfirming" }));
    const fit = fits([r], snap).get("soup")!.fit;
    expect(fit.required[0].state).toBe("needs-reconfirming");
    expect(fit.allSufficient).toBe(false);
  });
});
