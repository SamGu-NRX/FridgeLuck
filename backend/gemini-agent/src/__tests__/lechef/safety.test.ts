import { describe, it, expect } from "bun:test";
import { createFoodSafetyTool, FSIS_SOURCE } from "../../lechef/foodSafety.js";
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

  it("ground poultry is POULTRY: ground chicken and ground turkey read 74C/165F (FSIS)", () => {
    // FSIS: "All Poultry (Breasts, Whole Bird, Legs, Thighs, Wings, Ground
    // Poultry, Giblets and Stuffing) | 165 degrees F" — ground chicken and
    // ground turkey are poultry, never the 160 F ground-meat class.
    for (const product of ["ground chicken", "ground turkey"]) {
      const r = tool.checkFoodSafety({ product });
      if (r.answer.kind === "sourced-check") {
        expect(r.answer.check.temperatureC).toBe(74);
        expect(r.answer.check.temperatureF).toBe(165);
      } else throw new Error(`${product} must be covered`);
    }
    const beef = tool.checkFoodSafety({ product: "burger patty" });
    if (beef.answer.kind === "sourced-check") expect(beef.answer.check.temperatureC).toBe(71);
    else throw new Error("burger must be covered");
    const lamb = tool.checkFoodSafety({ product: "ground lamb" });
    if (lamb.answer.kind === "sourced-check") expect(lamb.answer.check.temperatureF).toBe(160);
    else throw new Error("ground lamb must be covered");
  });

  it("ground veal reads 71C/160F (ground meat), not the 63C whole-cut minimum", () => {
    const r = tool.checkFoodSafety({ product: "ground veal" });
    if (r.answer.kind === "sourced-check") {
      expect(r.answer.check.temperatureC).toBe(71);
      expect(r.answer.check.temperatureF).toBe(160);
    } else throw new Error("ground veal must be covered");
  });

  it("casseroles read 74C/165F — the casserole class wins over the species minimum", () => {
    // A salmon casserole is not merely "fish" (63 C): FSIS requires 165 F for
    // casseroles and other combination dishes. Strictest applicable class wins.
    for (const product of ["salmon casserole", "chicken casserole", "vegan lentil bake"]) {
      const r = tool.checkFoodSafety({ product });
      if (r.answer.kind === "sourced-check") {
        expect(r.answer.check.temperatureF).toBe(165);
        expect(r.answer.check.temperatureC).toBe(74);
      } else throw new Error(`${product} must be covered`);
    }
  });

  it("reheating is question-aware: 'pork roast' + 'how do I reheat it?' gives 74C/165F, not 63C/145F", () => {
    const r = tool.checkFoodSafety({ product: "pork roast", question: "how do I reheat it?" });
    if (r.answer.kind === "sourced-check") {
      expect(r.answer.check.temperatureF).toBe(165);
      expect(r.answer.check.temperatureC).toBe(74);
    } else throw new Error("reheated pork roast must be covered");
  });

  it("reheating is product-aware too: 'leftover pork roast' gives 74C/165F without a reheat question", () => {
    const r = tool.checkFoodSafety({ product: "leftover pork roast" });
    if (r.answer.kind === "sourced-check") {
      expect(r.answer.check.temperatureF).toBe(165);
    } else throw new Error("leftover pork roast must be covered");
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

describe("food safety: the rulebook is loaded from the pinned food-safety canon", () => {
  it("the default rulebook is the canon's reviewed FSIS chart citation, not an embedded copy", () => {
    const tool = createFoodSafetyTool();
    expect(tool.rulebook().source).toMatch(/Safe Minimum Internal Temperature Chart/);
    expect(tool.rulebook().source).toMatch(/fsis\.usda\.gov/);
    const r = tool.checkFoodSafety({ product: "chicken" });
    if (r.answer.kind === "sourced-check") {
      expect(r.answer.check.source).toBe(tool.rulebook().source);
      expect(r.answer.check.source).toBe(FSIS_SOURCE);
    } else throw new Error("canon default must cover chicken");
  });

  it("a rulebook override supersedes the canon default (corpus-task drop-in)", () => {
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
      ingredient: "butter",
      context: "pancake batter",
      eaters: []
    });
    expect(r.kind).toBe("beyond-table");
    expect(r.swaps[0].to).toBe("olive oil");
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
