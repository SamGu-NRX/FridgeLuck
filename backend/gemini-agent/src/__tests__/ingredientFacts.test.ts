import { describe, expect, it } from "bun:test";
import {
  failClosedIngredientFactsEvaluator,
  ingredientFactsEvaluator,
  parseRestrictions,
  unionRestrictions
} from "../services/ingredientFacts.js";

describe("unionRestrictions", () => {
  it("unions allergens and diets so an ingredient must satisfy every eater", () => {
    const restrictions = unionRestrictions([
      parseRestrictions(["peanut"], []),
      parseRestrictions([], ["glutenFree"])
    ]);

    expect(restrictions.allergens).toEqual(new Set(["peanut"]));
    expect(restrictions.diets).toEqual(new Set(["glutenFree"]));
  });

  it("keeps both sets active when two eaters restrict different substances", () => {
    const restrictions = unionRestrictions([
      parseRestrictions(["milk"], []),
      parseRestrictions(["soy"], ["dairyFree"])
    ]);

    expect(restrictions.allergens).toEqual(new Set(["milk", "soy"]));
    expect(restrictions.diets).toEqual(new Set(["dairyFree"]));
  });

  it("returns empty sets for no restrictions", () => {
    const restrictions = unionRestrictions([]);
    expect(restrictions.allergens.size).toBe(0);
    expect(restrictions.diets.size).toBe(0);
  });
});

describe("parseRestrictions", () => {
  it("treats avoid terms as allergen-class exclusions", () => {
    const restrictions = parseRestrictions(["peanut", "tree nut"], []);
    expect(restrictions.allergens).toEqual(new Set(["peanut", "tree nut"]));
    expect(restrictions.diets.size).toBe(0);
  });

  it("keeps dietary-restriction tokens active verbatim", () => {
    const restrictions = parseRestrictions([], ["vegetarian"]);
    expect(restrictions.diets).toEqual(new Set(["vegetarian"]));
    expect(restrictions.allergens.size).toBe(0);
  });

  it("keeps an unrecognized restriction token instead of dropping it", () => {
    const restrictions = parseRestrictions([], ["some-unknown-token"]);
    expect(restrictions.diets).toEqual(new Set(["some-unknown-token"]));
  });
});

describe("failClosedIngredientFactsEvaluator (placeholder until data/ingredient-facts lands)", () => {
  it("is vacuously allowed when no restriction is active", () => {
    const evaluation = failClosedIngredientFactsEvaluator.evaluate(
      "rice",
      parseRestrictions([], [])
    );
    expect(evaluation).toEqual({ kind: "allowed", evidence: [] });
  });

  it("answers unknown for any ingredient while an allergen exclusion is active", () => {
    const evaluation = failClosedIngredientFactsEvaluator.evaluate(
      "tofu",
      parseRestrictions(["milk"], [])
    );
    expect(evaluation.kind).toBe("unknown");
    if (evaluation.kind === "unknown") {
      expect(evaluation.missing.length).toBeGreaterThan(0);
    }
  });

  it("answers unknown for any ingredient while a diet restriction is active", () => {
    const evaluation = failClosedIngredientFactsEvaluator.evaluate(
      "rice",
      parseRestrictions([], ["vegetarian"])
    );
    expect(evaluation.kind).toBe("unknown");
  });
});

describe("ingredientFactsEvaluator (production binding)", () => {
  it("fails closed under an active restriction: unknown is never allowed", () => {
    const evaluation = ingredientFactsEvaluator.evaluate(
      "satay sauce",
      parseRestrictions(["peanut"], [])
    );
    expect(evaluation.kind).toBe("unknown");
  });

  it("never claims a violation it has no data for", () => {
    const evaluation = ingredientFactsEvaluator.evaluate(
      "satay sauce",
      parseRestrictions(["peanut"], [])
    );
    expect(evaluation.kind).not.toBe("violated");
  });
});
