import { describe, it, expect } from "bun:test";
import { restrictionTokensFor, allergenViolations } from "../../lechef/allergens.js";

describe("allergens: canonical identities (case, spaces, hyphens fold to one identity)", () => {
  it("soy sauce in every spelling carries wheat + soy — a wheat eater is never cleared", () => {
    for (const form of ["soy sauce", "soy-sauce", "SOY SAUCE", "Soy Sauce", "soy_sauce"]) {
      const v = allergenViolations(form, [{ name: "Kai", restrictions: ["wheat"] }]);
      expect(v.length).toBeGreaterThan(0);
      expect(v.join(" ")).toMatch(/wheat/);
    }
  });

  it("cream cheese carries milk via compound composition", () => {
    const v = allergenViolations("cream cheese", [{ name: "Ada", restrictions: ["milk"] }]);
    expect(v.length).toBeGreaterThan(0);
    expect(v.join(" ")).toMatch(/milk/);
  });

  it("restrictionTokensFor reads carried tokens from the reviewed facts in every spelling", () => {
    expect(restrictionTokensFor("soy sauce")).toContain("wheat");
    expect(restrictionTokensFor("SOY-SAUCE")).toContain("soy");
    expect(restrictionTokensFor("cream-cheese")).toContain("milk");
  });
});

describe("allergens: unknown composition fails closed", () => {
  it("tamari's wheat status is uncertain — confirmation required, never silently wheat-free", () => {
    const v = allergenViolations("tamari", [{ name: "Kai", restrictions: ["wheat"] }]);
    expect(v.length).toBeGreaterThan(0);
    expect(v.join(" ")).toMatch(/confirm/i);
    expect(v.join(" ").toLowerCase()).not.toMatch(/^no violation/);
  });

  it("an ingredient outside the reviewed facts requires confirmation even with no restrictions", () => {
    const v = allergenViolations("grits", [{ name: "Ada", restrictions: [] }]);
    expect(v.length).toBeGreaterThan(0);
    expect(v.join(" ")).toMatch(/confirm/i);
  });

  it("unknown composition never reads as 'no violations' when a restriction is in play", () => {
    const v = allergenViolations("mystery-blend-xj", [{ name: "Ada", restrictions: ["milk"] }]);
    expect(v.length).toBeGreaterThan(0);
    expect(v.join(" ")).toMatch(/confirm/i);
  });

  it("diet restrictions bind: lard and beef violate a vegetarian eater", () => {
    for (const ingredient of ["lard", "beef"]) {
      const v = allergenViolations(ingredient, [{ name: "Sam", restrictions: ["vegetarian"] }]);
      expect(v.length).toBeGreaterThan(0);
      expect(v.join(" ")).toMatch(/vegetarian/);
    }
  });

  it("a restriction outside the reviewed vocabulary fails closed instead of clearing", () => {
    const v = allergenViolations("rice", [{ name: "Ada", restrictions: ["sulfite-free"] }]);
    expect(v.length).toBeGreaterThan(0);
    expect(v.join(" ")).toMatch(/confirm|not in the reviewed vocabulary/i);
  });

  it("verified allergens still report violations (the map did not lose its teeth)", () => {
    const shellfish = allergenViolations("shrimp", [{ name: "Ada", restrictions: ["shellfish"] }]);
    expect(shellfish.length).toBeGreaterThan(0);
    const pasta = allergenViolations("pasta", [{ name: "Kai", restrictions: ["wheat"] }]);
    expect(pasta.length).toBeGreaterThan(0);
  });
});
