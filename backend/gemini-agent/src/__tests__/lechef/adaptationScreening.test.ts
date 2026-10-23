import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createProposalTools } from "../../lechef/proposals.js";
import type { RecipeContext } from "../../lechef/types.js";
import { LivePhoneExecutor } from "../../services/livePhoneExecutor.js";

const recipe: RecipeContext = {
  id: "stir-fry",
  revision: 3,
  title: "Soy sauce stir-fry",
  servings: 2,
  ingredientBill: [{ ingredientId: "soy-sauce", name: "soy sauce", quantity: { kind: "unknown" } }],
  steps: [{ index: 0, text: "Stir-fry." }]
};

function propose(recipeId: string | undefined, restrictions: string[]) {
  const routed: Record<string, unknown>[] = [];
  const phone = new LivePhoneExecutor((envelope) => routed.push(envelope));
  phone.setSnapshot({
    revision: 7,
    pantry: { revision: 7, items: [] },
    recipes: [recipe],
    cookSession: {
      ...(recipeId !== undefined ? { recipeId } : {}),
      state: "cooking",
      currentStepIndex: 0,
      eaters: [{ restrictions }],
      activeTimers: [],
      cameraMode: "push-to-look"
    }
  });
  const tools = createProposalTools({ phone, clock: { nowMs: () => Date.now() } });
  const result = tools.proposeAdaptation({ servings: 4, change: "double it", rationale: "Two more people joined." });
  phone.close();
  return { result, routed };
}

describe("adaptation screening", () => {
  test("refuses an adaptation without a current recipe instead of claiming an empty screen passed", () => {
    const { result, routed } = propose(undefined, ["wheat_gluten"]);
    expect(result.submitted).toBe(false);
    expect(result.issues).toEqual(["allergen screening blocked this proposal: no current recipe in the session, nothing was screened"]);
    expect(result.evidence).toEqual([]);
    expect(routed).toEqual([]);
  });

  test("refuses a current recipe missing from the catalog without screening evidence", () => {
    const { result, routed } = propose("missing", ["wheat_gluten"]);
    expect(result.submitted).toBe(false);
    expect(result.issues).toEqual(["allergen screening blocked this proposal: the current recipe missing is not in the catalog, nothing was screened"]);
    expect(result.evidence).toEqual([]);
    expect(routed).toEqual([]);
  });

  test("screens the named recipe and blocks its soy sauce for a wheat_gluten eater", () => {
    const { result, routed } = propose(recipe.id, ["wheat_gluten"]);
    expect(result.submitted).toBe(false);
    expect(result.issues?.join("; ")).toContain("wheat");
    expect(result.evidence[0]?.kind).toBe("allergen-recheck");
    expect(result.evidence[0]?.ref).toBe("stir-fry@r3");
    expect(result.evidence[0]?.detail).toContain("blocked:");
    expect(routed).toEqual([]);
  });

  test("routes a named recipe for explicit approval when its actual screen passes", () => {
    const { result, routed } = propose(recipe.id, []);
    expect(result.submitted).toBe(true);
    expect(result.status).toBe("pending_explicit_approval");
    expect(result.evidence[0]).toEqual({
      kind: "allergen-recheck",
      ref: "stir-fry@r3",
      detail: "screened 1 recipe(s) against 1 eater(s) — no violations"
    });
    expect(routed).toHaveLength(1);
    expect(routed[0]?.type).toBe("proposal");
  });
});


test("screens the recipe carried by the live snapshot and blocks a restricted eater", () => {
  const frame = JSON.parse(
    readFileSync(new URL("../fixtures/live-protocol/snapshot.json", import.meta.url), "utf8")
  ) as { payload: { revision: number; pantrySnapshot: unknown; cookSession: any; recipes: RecipeContext[] } };
  frame.payload.cookSession.eaters = [{ name: "you", restrictions: ["wheat_gluten"] }];
  const routed: Record<string, unknown>[] = [];
  const phone = new LivePhoneExecutor((envelope) => routed.push(envelope));
  phone.setSnapshot({
    revision: frame.payload.revision,
    pantry: frame.payload.pantrySnapshot as never,
    cookSession: frame.payload.cookSession,
    recipes: frame.payload.recipes
  });
  const result = createProposalTools({ phone, clock: { nowMs: () => Date.now() } }).proposeAdaptation({
    servings: 4,
    change: "double it",
    rationale: "Two more people joined."
  });
  expect(result.submitted).toBe(false);
  expect(result.evidence[0]?.kind).toBe("allergen-recheck");
  expect(result.issues?.join(";")).toContain("wheat");
  expect(routed).toEqual([]);
  phone.close();
});
