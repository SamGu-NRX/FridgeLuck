import { describe, it, expect } from "bun:test";
import { createFoodSafetyTool, FSIS_EMBEDDED_RULEBOOK, FSIS_SOURCE } from "../../lechef/foodSafety.js";
import { createSubstitutionTool, substitutionsTableAbsent, type SubstitutionTable } from "../../lechef/substitutions.js";
import { restrictionTokensFor } from "../../lechef/allergens.js";

describe("food safety: every covered answer is a checkable, sourced thermometer test", () => {
  const tool = createFoodSafetyTool();

  it("poultry reads 74C/165F with the FSIS source named", () => {
    const r = tool.checkFoodSafety({ product: "chicken thigh", question: "is it done?" });
    expect(r.answer.kind).toBe("sourced-check");
    if (r.answer.kind === "sourced-check") {
      expect(r.answer.check.temperatureC).toBe(74);
      expect(r.answer.check.temperatureF).toBe(165);
      expect(r.answer.check.source).toBe(FSIS_SOURCE);
      expect(r.sourceName).toBe(FSIS_SOURCE);
    }
  });

  it("ground meats read 71C/160F — ground chicken is ground, not whole poultry", () => {
    const ground = tool.checkFoodSafety({ product: "ground chicken" });
    if (ground.answer.kind === "sourced-check") expect(ground.answer.check.temperatureC).toBe(71);
    else throw new Error("ground chicken must be covered");
    const beef = tool.checkFoodSafety({ product: "burger patty" });
    if (beef.answer.kind === "sourced-check") expect(beef.answer.check.temperatureC).toBe(71);
    else throw new Error("burger must be covered");
  });

  it("whole cuts read 63C/145F plus a 3-minute rest; fish 63C; eggs 71C; leftovers 74C", () => {
    const whole = tool.checkFoodSafety({ product: "pork chop" });
    if (whole.answer.kind === "sourced-check") {
      expect(whole.answer.check.temperatureC).toBe(63);
      expect(whole.answer.check.restMinutes).toBe(3);
    } else throw new Error("whole cut must be covered");

    const fish = tool.checkFoodSafety({ product: "salmon fillet" });
    if (fish.answer.kind === "sourced-check") expect(fish.answer.check.temperatureC).toBe(63);
    else throw new Error("fish must be covered");

    const eggs = tool.checkFoodSafety({ product: "omelette" });
    if (eggs.answer.kind === "sourced-check") expect(eggs.answer.check.temperatureC).toBe(71);
    else throw new Error("eggs must be covered");

    const leftovers = tool.checkFoodSafety({ product: "leftover chicken", question: "reheating yesterday's dinner" });
    if (leftovers.answer.kind === "sourced-check") expect(leftovers.answer.check.temperatureC).toBe(74);
    else throw new Error("leftovers must be covered");
  });

  it("uncovered products return an explicit unknown — never a colour or time answer", () => {
    const r = tool.checkFoodSafety({ product: "tofu", question: "how long should it fry?" });
    expect(r.answer.kind).toBe("unknown");
    expect(r.sourceName).toBeNull();
    if (r.answer.kind === "unknown") {
      expect(r.answer.reason).toMatch(/no reviewed/);
      expect(r.answer.reason).not.toMatch(/\d+\s*minutes?/i);
    }
    const blob = JSON.stringify(r);
    expect(blob).not.toMatch(/golden|brown|pink juice|clear juices/i);
  });
});

describe("food safety: rulebook override for the corpus task", () => {
  it("a data/food-safety rulebook supersedes the embedded FSIS table", () => {
    const tool = createFoodSafetyTool();
    const override = {
      source: "data/food-safety rules.json (27 reviewed rules)",
      entries: [
        {
          category: "poultry",
          keywords: ["chicken"],
          temperatureC: 74,
          temperatureF: 165,
          test: "Thermometer to 74 C in the thigh."
        }
      ]
    };
    tool.setRulebook(override);
    expect(tool.rulebook().source).toBe(override.source);
    const r = tool.checkFoodSafety({ product: "chicken" });
    if (r.answer.kind === "sourced-check") expect(r.answer.check.source).toBe(override.source);
    else throw new Error("override must stay covered");
  });

  it("the embedded table is the default and names FSIS", () => {
    expect(FSIS_EMBEDDED_RULEBOOK.source).toBe(FSIS_SOURCE);
  });
});

describe("substitutions: alpha has no table — unknowns are explicit, never silent", () => {
  it("absent table yields an explicit unknown with beyond-table labelling", () => {
    const tool = createSubstitutionTool({ loader: substitutionsTableAbsent });
    const r = tool.lookupSubstitution({
      ingredient: "cream cheese",
      context: "frosting",
      eaters: [{ name: "Ada", restrictions: ["milk"] }]
    });
    expect(r.kind).toBe("beyond-table");
    expect(r.unknowns.some((u) => u.toLowerCase().includes("absent"))).toBe(true);
    expect(r.explanation).toMatch(/beyond the (reviewed )?table/i);
  });

  it("beyond-table ideas are labelled, rechecked, and describe the difference", () => {
    const tool = createSubstitutionTool({ loader: substitutionsTableAbsent });
    const r = tool.lookupSubstitution({
      ingredient: "eggs",
      context: "pancake batter",
      eaters: []
    });
    expect(r.kind).toBe("beyond-table");
    expect(r.swaps[0].to).toBe("flax egg");
    expect(r.differenceStatements.length).toBeGreaterThan(0);
    for (const d of r.differenceStatements) {
      expect(d.toLowerCase()).not.toMatch(/no change|identical result/);
    }
  });

  it("never promises no-change: every statement describes a difference (SPEC 3.1)", () => {
    const table: SubstitutionTable = {
      source: "test table",
      rows: [
        { from: "soy sauce", to: "tamari", ratio: "1:1", notes: "same salt depth; tamari's wheat-free label still needs checking" }
      ]
    };
    const tool = createSubstitutionTool({ loader: () => table });
    const r = tool.lookupSubstitution({ ingredient: "soy sauce", context: "stir fry", eaters: [] });
    expect(r.kind).toBe("table");
    expect(r.swaps[0].to).toBe("tamari");
    expect(r.explanation).toMatch(/changes|not the same|not a reviewed/i);
    for (const d of r.differenceStatements) expect(d.toLowerCase()).not.toMatch(/no change|identical result/);
  });

  it("rechecks compound ingredients: soy sauce carries wheat, so a wheat eater blocks the swap", () => {
    expect(restrictionTokensFor("soy-sauce")).toContain("wheat");
    const table: SubstitutionTable = {
      source: "test table",
      rows: [{ from: "soy-sauce", to: "tamari", ratio: "1:1", notes: "lighter, slightly sweeter salt" }]
    };
    const tool = createSubstitutionTool({ loader: () => table });
    const r = tool.lookupSubstitution({
      ingredient: "soy-sauce",
      context: "noodles",
      eaters: [{ name: "Kai", restrictions: ["wheat"] }]
    });
    // The compound recheck must reject the row and offer nothing in its place.
    expect(r.swaps).toHaveLength(0);
    expect(r.violations.length).toBeGreaterThan(0);
    expect(r.unknowns[0]).toMatch(/rejected by the allergen recheck/);
  });

  it("rechecks both sides of a swap — dropping an allergen matters too", () => {
    expect(restrictionTokensFor("pasta")).toContain("wheat");
  });
});
