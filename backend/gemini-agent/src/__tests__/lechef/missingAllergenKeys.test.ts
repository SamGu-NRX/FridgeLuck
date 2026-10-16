/**
 * An allergen restriction clears only when every fact in the ingredient's
 * composition graph reviews that allergen as free. A missing key, a reviewed
 * unknown, or a component with no fact asks for confirmation instead.
 *
 * The sweep compares allergenViolations with an independent walk over the
 * canon, so a regression in either the resolver or the canon shows up as the
 * exact fact × restriction pair that changed.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { allergenViolations } from "../../lechef/allergens.js";

interface Fact {
  readonly key: string;
  readonly allergens?: Readonly<Record<string, { readonly state: string }>>;
  readonly components?: readonly { readonly key: string }[];
}

const canonDir = "../../lechef/canon/ingredient-facts";
const facts = (JSON.parse(readFileSync(new URL(`${canonDir}/facts.json`, import.meta.url), "utf8")) as {
  facts: Readonly<Record<string, Fact>>;
}).facts;
const identities = (JSON.parse(readFileSync(new URL(`${canonDir}/identities.json`, import.meta.url), "utf8")) as {
  ingredients: readonly { key: string; synonyms?: readonly string[] }[];
}).ingredients;

function fold(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

/**
 * The fact key allergens.ts reads for a name: identities win, last write
 * first. Three fact keys (chicken, palm-oil, sunflower-oil) are synonyms of
 * other facts, so the runtime never reads them by their own key.
 */
const identityIndex = new Map<string, string>();
for (const entry of identities) {
  identityIndex.set(fold(entry.key), entry.key);
  for (const synonym of entry.synonyms ?? []) identityIndex.set(fold(synonym), entry.key);
}
const resolve = (name: string): string => identityIndex.get(fold(name)) ?? fold(name);

/** The nine FDA major allergens as restrictions, with the canon tokens each one covers. */
const RESTRICTIONS: Readonly<Record<string, readonly string[]>> = {
  milk: ["milk"],
  egg: ["egg"],
  fish: ["fish"],
  shellfish: ["crustaceanShellfish", "molluscanShellfish"],
  treeNuts: ["treeNuts"],
  peanuts: ["peanuts"],
  wheat: ["wheat"],
  soy: ["soy"],
  sesame: ["sesame"]
};

const check = (ingredient: string, restriction: string) =>
  allergenViolations(ingredient, [{ name: "probe", restrictions: [restriction] }]);

/** True when every fact reachable from `key`, through any component, reviews every token as free. */
function everyPathFree(key: string, tokens: readonly string[], seen: Set<string> = new Set()): boolean {
  if (seen.has(key)) return true;
  seen.add(key);
  const fact = facts[key];
  if (!fact) return false;
  if (!tokens.every((t) => fact.allergens?.[t]?.state === "free")) return false;
  return (fact.components ?? []).every((c) => everyPathFree(c.key, tokens, seen));
}

describe("missing allergen keys never clear", () => {
  test("commercial stocks ask wheat-, milk- and soy-free eaters to confirm", () => {
    for (const stock of ["beef-stock", "chicken-stock", "vegetable-stock"]) {
      for (const restriction of ["wheat", "milk", "soy"]) {
        const violations = check(stock, restriction);
        expect(violations.length, `${stock} × ${restriction}`).toBe(1);
        expect(violations[0]).toMatch(/confirmation required/);
      }
    }
  });

  test("a fact that reviews every allergen as free clears every restriction", () => {
    for (const restriction of Object.keys(RESTRICTIONS)) {
      expect(check("water", restriction), `water × ${restriction}`).toEqual([]);
    }
  });

  test("a component-less fact with a missing or unknown diet state asks instead of clearing", () => {
    // flatbread reviews glutenFree as unknown and has no vegan state at all
    // (naan-style flatbreads can carry milk) — neither may clear silently.
    for (const fact of ["flatbread", "tortilla"]) {
      for (const restriction of ["glutenFree", "vegan"]) {
        const violations = check(fact, restriction);
        expect(violations.length, `${fact} × ${restriction}`).toBe(1);
        expect(violations[0]).toMatch(/confirmation required/);
      }
    }
    // A reviewed allowed state still clears, and a reviewed violated state
    // still violates — the fix only removes the silent fall-through.
    expect(check("rice-flour", "glutenFree")).toEqual([]);
    expect(check("bulgur", "glutenFree").join(" ")).toMatch(/not compatible with/);
  });

  test("a reviewed contains state still violates", () => {
    const violations = check("soy-sauce", "wheat");
    expect(violations.length).toBe(1);
    expect(violations[0]).toMatch(/carries/);
    expect(violations[0]).not.toMatch(/confirmation required/);
  });

  test("sweep: a result clears exactly when every path rests on an explicit free state", () => {
    const wrong: string[] = [];
    for (const key of Object.keys(facts)) {
      for (const [restriction, tokens] of Object.entries(RESTRICTIONS)) {
        const cleared = check(key, restriction).length === 0;
        if (cleared !== everyPathFree(resolve(key), tokens)) wrong.push(`${key} × ${restriction}: cleared=${cleared}`);
      }
    }
    expect(wrong).toEqual([]);
  });
});
