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

// ---------------------------------------------------------------------------
// Review fix 6 — fit keeps unit dimensions and uncertainty.
//
// Red at base 41597b1: base sumBill/resolveLine collapse everything to bare
// numbers (100 ml "satisfies" a 100 g demand; an unknown bill line followed
// by a known one becomes numeric; an unknown pantry lot reads as zero), and
// buildFit counts assumed staples in its "n of m" form.
// ---------------------------------------------------------------------------

describe("fit: dimensions are preserved (review fix 6)", () => {
  it("never lets volume stock satisfy a mass demand of the same magnitude", () => {
    const r = recipe({
      id: "pan",
      ingredientBill: [{ ingredientId: "stock", name: "Stock", quantity: { kind: "known", value: 100, unit: "g" } }]
    });
    const snap = pantry(pantryLine({ ingredientId: "stock", name: "Stock", quantity: { kind: "known", value: 100, unit: "ml" } }));
    const line = fits([r], snap).get("pan")!.fit.required[0];
    expect(line.state).toBe("short");
    expect(line.state).not.toBe("sufficient");
  });

  it("never lets converted volumes satisfy a converted mass demand", () => {
    const r = recipe({
      id: "pan",
      ingredientBill: [{ ingredientId: "stock", name: "Stock", quantity: { kind: "known", value: 1, unit: "kg" } }]
    });
    const snap = pantry(pantryLine({ ingredientId: "stock", name: "Stock", quantity: { kind: "known", value: 1000, unit: "ml" } }));
    const line = fits([r], snap).get("pan")!.fit.required[0];
    expect(line.state).toBe("short");
  });

  it("keeps a mixed-dimension demand honest when only one dimension is stocked", () => {
    const r = recipe({
      id: "batter",
      ingredientBill: [
        { ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 50, unit: "g" } },
        { ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 2, unit: "tbsp" } }
      ]
    });
    const snap = pantry(pantryLine({ ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 100, unit: "g" } }));
    const line = fits([r], snap).get("batter")!.fit.required[0];
    // 50 g is covered, the 2 tbsp (volume) is not — the line is short, not satisfied.
    expect(line.state).toBe("short");
  });

  it("never covers a mass demand with a volume swap target", () => {
    const r = recipe({ id: "stew", ingredientBill: [{ ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 50, unit: "g" } }] });
    const snap = pantry(pantryLine({ ingredientId: "olive-oil", name: "Olive oil", quantity: { kind: "known", value: 100, unit: "ml" } }));
    const fit = fits([r], snap, { acceptedSwaps: [{ from: "butter", to: "olive oil" }] }).get("stew")!.fit;
    // 100 ml cannot stand in for 50 g: the line stays missing, not swap-covered.
    expect(fit.required[0].state).toBe("missing");
  });

  it("still covers a same-dimension swap", () => {
    const r = recipe({ id: "stew", ingredientBill: [{ ingredientId: "butter", name: "Butter", quantity: { kind: "known", value: 50, unit: "g" } }] });
    const snap = pantry(pantryLine({ ingredientId: "ghee", name: "Ghee", quantity: { kind: "known", value: 100, unit: "g" } }));
    const fit = fits([r], snap, { acceptedSwaps: [{ from: "butter", to: "ghee" }] }).get("stew")!.fit;
    expect(fit.required[0].state).toBe("swap-covered");
  });
});

describe("fit: uncertainty is preserved (review fix 6)", () => {
  it("keeps an unknown bill line unknown even when a later line is known", () => {
    const r = recipe({
      id: "pasta",
      ingredientBill: [
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "unknown" } },
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 2, unit: "piece" } }
      ]
    });
    const snap = pantry(pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 5, unit: "piece" } }));
    const fit = fits([r], snap).get("pasta")!.fit;
    // The unknown line must not collapse to 0 and let "2 of 5" pass.
    expect(fit.required[0].state).toBe("quantity-unknown");
    expect(fit.allSufficient).toBe(false);
    expect(fit.fitLine).toBe("0 recorded · check eggs");
  });

  it("keeps an unknown pantry lot unknown even when another lot is known", () => {
    const r = recipe({
      id: "pasta",
      ingredientBill: [{ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } }]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } }),
      pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "unknown" }, state: "quantity-unknown" })
    );
    const fit = fits([r], snap).get("pasta")!.fit;
    // An unknown lot could hold the needed eggs: the line cannot become numeric.
    expect(fit.required[0].state).toBe("quantity-unknown");
  });

  it("cannot verify a demand against a pantry line with an unknown quantity", () => {
    const r = recipe({
      id: "pasta",
      ingredientBill: [{ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } }]
    });
    const snap = pantry(pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "unknown" }, state: "quantity-unknown" }));
    const fit = fits([r], snap).get("pasta")!.fit;
    expect(fit.required[0].state).toBe("quantity-unknown");
  });
});

describe("fit: assumed staples are named, never counted (review fix 6)", () => {
  it("does not describe an assumed staple as verified stock", () => {
    const r = recipe({
      id: "salad",
      ingredientBill: [
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } },
        { ingredientId: "salt", name: "Salt", quantity: { kind: "unknown" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } }),
      pantryLine({ ingredientId: "salt", name: "Salt", quantity: { kind: "unknown" }, state: "assumed-staple" })
    );
    const fit = fits([r], snap).get("salad")!.fit;
    // No "1 of 2" and no numeric claim about the staple: name the assumption.
    expect(fit.fitLine).toBe("1 recorded · salt assumed");
    expect(fit.allSufficient).toBe(false);
  });

  it("names assumptions instead of counting them when only staples are unverified", () => {
    const r = recipe({
      id: "dressing",
      ingredientBill: [
        { ingredientId: "salt", name: "Salt", quantity: { kind: "unknown" } },
        { ingredientId: "pepper", name: "Pepper", quantity: { kind: "unknown" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "salt", name: "Salt", quantity: { kind: "unknown" }, state: "assumed-staple" }),
      pantryLine({ ingredientId: "pepper", name: "Pepper", quantity: { kind: "unknown" }, state: "assumed-staple" })
    );
    const fit = fits([r], snap).get("dressing")!.fit;
    expect(fit.fitLine).toBe("salt and pepper assumed");
    expect(fit.allSufficient).toBe(false);
  });

  it("keeps assumption wording next to the check list", () => {
    const r = recipe({
      id: "omelette",
      ingredientBill: [
        { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 3, unit: "piece" } },
        { ingredientId: "oil", name: "Oil", quantity: { kind: "unknown" } }
      ]
    });
    const snap = pantry(
      pantryLine({ ingredientId: "oil", name: "Oil", quantity: { kind: "unknown" }, state: "quantity-unknown" })
    );
    const fit = fits([r], snap).get("omelette")!.fit;
    // Eggs are missing, oil is a recorded-but-unknown line; neither is counted as verified.
    expect(fit.fitLine).toBe("0 recorded · check eggs");
  });
});

