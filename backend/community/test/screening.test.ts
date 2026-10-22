/**
 * The compound-allergens stage against the real reviewed canon
 * (backend/gemini-agent/src/lechef/canon/ingredient-facts) and the startup
 * readiness loader.
 *
 * Pins hold across facts packets: a reviewed contains state stays contains, a
 * name the canon does not know stays flagged — never exact tag counts, since
 * the facts review rewrites facts.json underneath these tests.
 */

import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ScreeningPipeline, loadIngredientFactsCanon } from "../src/core/screening.js";
import { configFromEnv } from "../src/config.js";
import type { RecipeContent } from "../src/core/contract.js";

function content(overrides?: Partial<RecipeContent>): RecipeContent {
  return {
    title: "Test recipe",
    description: null,
    servings: 2,
    timeMinutes: 20,
    ingredientLines: [{ name: "water", quantity: 200, unit: "ml", preparation: null, fdcId: null }],
    steps: [{ text: "Boil everything, then simmer for ten minutes.", timerMinutes: 10 }],
    equipment: ["pan"],
    dietaryTags: [],
    ...overrides,
  };
}

function allergenStageOf(lines: RecipeContent["ingredientLines"]) {
  const result = new ScreeningPipeline(true).run(content({ ingredientLines: lines }));
  return {
    tags: result.allergenTags,
    flagged: result.flagged,
    verdict: result.outcomes.find((o) => o.check === "compound-allergens")?.verdict ?? null,
  };
}

describe("compound-allergens through the reviewed canon", () => {
  test("water — a fully reviewed ingredient — carries no tags and no flag", () => {
    const { tags, flagged, verdict } = allergenStageOf([{ name: "water", quantity: 200, unit: "ml", preparation: null, fdcId: null }]);
    expect(tags).toEqual([]);
    expect(flagged).toBe(false);
    expect(verdict).toBe("pass");
  });

  test("breadcrumbs are tagged wheat (reviewed contains stays contains)", () => {
    const { tags } = allergenStageOf([{ name: "breadcrumbs", quantity: 60, unit: "g", preparation: null, fdcId: null }]);
    expect(tags).toContain("wheat");
  });

  test("a cheese is tagged milk", () => {
    const { tags } = allergenStageOf([{ name: "cheddar", quantity: 100, unit: "g", preparation: null, fdcId: null }]);
    expect(tags).toContain("milk");
  });

  test("fish sauce is tagged fish", () => {
    const { tags } = allergenStageOf([{ name: "fish sauce", quantity: 15, unit: "ml", preparation: null, fdcId: null }]);
    expect(tags).toContain("fish");
  });

  test("soy sauce is tagged wheat and soy", () => {
    const { tags } = allergenStageOf([{ name: "soy sauce", quantity: 30, unit: "ml", preparation: null, fdcId: null }]);
    expect(tags).toContain("wheat");
    expect(tags).toContain("soy");
  });

  test("an unknown name with an fdcId is flagged — an FDC id says nothing about allergens", () => {
    const { tags, flagged, verdict } = allergenStageOf([
      { name: "grandma's secret blend", quantity: 5, unit: "g", preparation: null, fdcId: 123456 },
    ]);
    expect(tags).toContain("unknown-contents");
    expect(flagged).toBe(true);
    expect(verdict).toBe("flag");
  });

  test("an unknown name without an fdcId is still flagged", () => {
    const { tags, flagged } = allergenStageOf([
      { name: "grandma's secret blend", quantity: 5, unit: "g", preparation: null, fdcId: null },
    ]);
    expect(tags).toContain("unknown-contents");
    expect(flagged).toBe(true);
  });

  test("mustard and sulphites keep the unreviewed stand-in tags", () => {
    const mustard = allergenStageOf([{ name: "mustard", quantity: 5, unit: "g", preparation: null, fdcId: null }]);
    expect(mustard.tags).toContain("mustard");
    const wine = allergenStageOf([{ name: "wine", quantity: 100, unit: "ml", preparation: null, fdcId: null }]);
    expect(wine.tags).toContain("sulphites");
  });

  test("one resolved line does not cancel another line's unknown-contents", () => {
    const { tags, flagged } = allergenStageOf([
      { name: "water", quantity: 200, unit: "ml", preparation: null, fdcId: null },
      { name: "grandma's secret blend", quantity: 5, unit: "g", preparation: null, fdcId: 123456 },
    ]);
    expect(flagged).toBe(true);
    expect(tags).toContain("unknown-contents");
  });
});

describe("screening readiness is measured at startup", () => {
  test("the bundled canon loads", () => {
    // The default resolves to the canon beside LeChef's lookup — the only
    // source (PR #219 review).
    expect(() => loadIngredientFactsCanon()).not.toThrow();
  });

  test("a missing canon fails loudly, naming the path", () => {
    const missing = "/nonexistent/canon-path/ingredient-facts";
    try {
      loadIngredientFactsCanon(missing);
      expect.unreachable();
    } catch (error) {
      expect((error as Error).message).toContain(missing);
    }
  });

  /** Writes a canon-shaped directory with the given parsed documents. */
  function canonDir(facts: unknown, identities: unknown): string {
    const dir = mkdtempSync(join(tmpdir(), "canon-readiness-"));
    writeFileSync(join(dir, "facts.json"), JSON.stringify(facts));
    writeFileSync(join(dir, "identities.json"), JSON.stringify(identities));
    return dir;
  }

  test("an empty facts table fails readiness — valid JSON alone is not readiness (PR #219 Codex round)", () => {
    const dir = canonDir({ version: 1, facts: {} }, { version: 1, ingredients: {} });
    try {
      loadIngredientFactsCanon(dir);
      expect.unreachable();
    } catch (error) {
      const message = (error as Error).message;
      expect(message).toContain("holds 0 entries");
      expect(message).toContain(dir);
    }
  });

  test("a facts table holding entries without the reviewed shape fails readiness", () => {
    const dir = canonDir(
      { version: 1, facts: { mystery: { key: "mystery", note: "no allergens object" } } },
      { version: 1, ingredients: {} },
    );
    try {
      loadIngredientFactsCanon(dir);
      expect.unreachable();
    } catch (error) {
      expect((error as Error).message).toContain("not shaped like a reviewed fact");
    }
  });

  test("a truncated facts table fails readiness", () => {
    const facts = Object.fromEntries(
      Array.from({ length: 5 }, (_, i) => [`ingredient-${i}`, { key: `ingredient-${i}`, allergens: {} }]),
    );
    const dir = canonDir({ version: 1, facts }, { version: 1, ingredients: {} });
    try {
      loadIngredientFactsCanon(dir);
      expect.unreachable();
    } catch (error) {
      expect((error as Error).message).toContain("at least 400");
    }
  });

  test("identities.json without an identity index fails readiness", () => {
    const facts = Object.fromEntries(
      Array.from({ length: 400 }, (_, i) => [`ingredient-${i}`, { key: `ingredient-${i}`, allergens: {} }]),
    );
    const dir = canonDir({ version: 1, facts }, { version: 1 });
    try {
      loadIngredientFactsCanon(dir);
      expect.unreachable();
    } catch (error) {
      expect((error as Error).message).toContain("no identity index");
    }
  });
});
