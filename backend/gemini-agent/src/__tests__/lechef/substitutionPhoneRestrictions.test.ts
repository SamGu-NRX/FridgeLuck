import { describe, expect, test } from "bun:test";
import { PHONE_RESTRICTION_IDS } from "../../lechef/allergens.js";
import { createSubstitutionTool, substitutionsCanonLoader } from "../../lechef/substitutions.js";

const phoneIdsByLabel: Readonly<Record<string, readonly string[]>> = {
  "dairy-free": ["milk"],
  "gluten-free": ["wheat_gluten"],
  "nut-free": ["peanut", "tree_nut"],
  "peanut-free": ["peanut"],
  "tree-nut-free": ["tree_nut"]
};

describe("reviewed substitution refusals for phone restrictions", () => {
  test("wheat_gluten gets the reviewed gluten-free refusal before the generic recheck", () => {
    const tool = createSubstitutionTool({ loader: () => ({
      source: "reviewed fixture",
      rows: [{ from: "wheat flour", to: "rice flour", ratio: "1:1", notes: "Different structure",
        conditionalFor: ["gluten-free"], conditionalWhy: "Reviewed gluten-free refusal" }]
    }) });
    const result = tool.lookupSubstitution({ ingredient: "wheat flour", eaters: [{ restrictions: ["wheat_gluten"] }] });
    expect(result.violations).toEqual([
      "substitutions: wheat flour → rice flour refused for gluten-free: Reviewed gluten-free refusal"
    ]);
    expect(result.swaps).toEqual([]);
  });

  test("every shipped conditional label refuses every corresponding known phone id with its reviewed reason", () => {
    const table = substitutionsCanonLoader();
    if (!table) throw new Error("Shipped substitution table is missing");
    const labels = [...new Set(table.rows.flatMap((row) => row.conditionalFor ?? []))];
    const unmapped = labels.filter((label) => !phoneIdsByLabel[label]?.length);
    expect(unmapped).toEqual([]);
    for (const row of table.rows) {
      for (const label of row.conditionalFor ?? []) {
        for (const phoneId of phoneIdsByLabel[label] ?? []) {
          expect(PHONE_RESTRICTION_IDS).toContain(phoneId);
          const tool = createSubstitutionTool({ loader: () => ({ source: table.source, rows: [{ ...row, conditionalFor: [label] }] }) });
          const result = tool.lookupSubstitution({ ingredient: row.from, eaters: [{ restrictions: [phoneId] }] });
          expect(result.violations).toEqual([
            `substitutions: ${row.from} → ${row.to} refused for ${label}: ${row.conditionalWhy}`
          ]);
          expect(result.swaps).toEqual([]);
        }
      }
    }
  });
});
