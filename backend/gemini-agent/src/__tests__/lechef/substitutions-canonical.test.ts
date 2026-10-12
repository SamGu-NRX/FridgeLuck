import { describe, it, expect } from "bun:test";
import { createSubstitutionTool } from "../../lechef/substitutions.js";

describe("substitutions: the reviewed substitution table is installed from the canon", () => {
  it("a covered ingredient gets reviewed table rows by default (no loader needed)", () => {
    const tool = createSubstitutionTool();
    const r = tool.lookupSubstitution({ ingredient: "soy sauce", context: "stir fry", eaters: [] });
    expect(r.kind).toBe("table");
    expect(r.swaps[0]?.to).toBe("tamari");
  });

  it("a covered pair serves the reviewed substitute and describes the difference", () => {
    const tool = createSubstitutionTool();
    const r = tool.lookupSubstitution({ ingredient: "salmon", context: "fillet", eaters: [] });
    expect(r.kind).toBe("table");
    expect(r.swaps[0]?.to).toBe("trout");
    expect(r.differenceStatements.length).toBeGreaterThan(0);
    for (const d of r.differenceStatements) {
      expect(d.toLowerCase()).not.toMatch(/no change|identical result/);
    }
  });

  it("table swaps still pass the fail-closed recheck: every butter row is blocked for a milk eater", () => {
    const tool = createSubstitutionTool();
    const r = tool.lookupSubstitution({
      ingredient: "butter",
      context: "sauce",
      eaters: [{ name: "Ada", restrictions: ["milk"] }]
    });
    expect(r.kind).toBe("table");
    expect(r.swaps).toHaveLength(0);
    expect(r.violations.length).toBeGreaterThan(0);
  });
});
