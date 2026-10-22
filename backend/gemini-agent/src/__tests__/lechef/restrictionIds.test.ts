/**
 * The app's household restriction ids must reach the reviewed facts.
 *
 * The ids are the raw values of HouseholdAllergenGroup and HouseholdDiet
 * (apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift, read here as text).
 * Every id must map either to a reviewed check or to the explicit
 * asks-by-design list — a new Swift case that arrives without a mapping fails
 * CI. Each mapped id must also adjudicate every reviewed fact exactly like
 * the canon tokens it maps to, and the mapping keys must be FOLDED, so the
 * pre-burst14 alias bug (keys written unfolded, lookups folded — "tree nut"
 * could never match) cannot recur.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  allergenViolations,
  resolveRestriction,
  APP_RESTRICTION_CHECKS,
  fold,
  PHONE_RESTRICTION_IDS
} from "../../lechef/allergens.js";
import { parseCookSession, WireParseError } from "../../lechef/wire.js";

const swift = readFileSync(
  new URL("../../../../../apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift", import.meta.url),
  "utf8"
);

/** The raw case values of a Swift enum with implicit and explicit raw values. */
function enumRawValues(enumName: string): readonly string[] {
  const start = swift.indexOf(`enum ${enumName}`);
  if (start < 0) throw new Error(`enum ${enumName} not found in HouseholdSafetyGate.swift`);
  const end = swift.indexOf("\n}", start);
  const body = swift.slice(start, end);
  return [...body.matchAll(/case\s+([A-Za-z_]\w*)\s*(?:=\s*"([^"]+)")?\s*\n/g)].map((m) => m[2] ?? m[1]);
}

const ALLERGEN_IDS = enumRawValues("HouseholdAllergenGroup");
const DIET_IDS = enumRawValues("HouseholdDiet");
const APP_IDS = [...ALLERGEN_IDS, ...DIET_IDS];

const canonDir = "../../lechef/canon/ingredient-facts";
const factKeys = Object.keys(
  (JSON.parse(readFileSync(new URL(`${canonDir}/facts.json`, import.meta.url), "utf8")) as { facts: Record<string, unknown> }).facts
);

/** clear | violate | ask, read off the violation lines' reviewed verdicts. */
function classify(ingredient: string, restrictions: readonly string[]): "clear" | "violate" | "ask" {
  const violations = allergenViolations(ingredient, [{ name: "probe", restrictions }]);
  if (violations.length === 0) return "clear";
  return violations.some((v) => /carries /.test(v) || /not compatible with/.test(v)) ? "violate" : "ask";
}

/** The pinned app-id → canon-token table (HouseholdSafetyGate raw values). */
const CANON_EQUIVALENT: Readonly<Record<string, readonly string[]>> = {
  milk: ["milk"],
  egg: ["egg"],
  peanut: ["peanuts"],
  tree_nut: ["treeNuts"],
  soy: ["soy"],
  wheat_gluten: ["wheat", "glutenFree"],
  fish: ["fish"],
  shellfish: ["crustaceanShellfish", "molluscanShellfish"],
  sesame: ["sesame"],
  vegetarian: ["vegetarian"],
  pescatarian: ["pescatarian"],
  vegan: ["vegan"]
};



describe("app restriction ids reach the reviewed facts", () => {
  test("every HouseholdSafetyGate case value maps to a reviewed check or the asks-by-design list", () => {
    expect(APP_IDS.length).toBeGreaterThanOrEqual(14);
    const unmapped = APP_IDS.filter((id) => resolveRestriction(id) === null);
    expect(unmapped).toEqual([]);
  });

  test("mustard and keto ask by design — no reviewed facts exist, so nothing can clear them", () => {
    const asksByDesign = APP_IDS.filter((id) => resolveRestriction(id)?.kind === "asksByDesign");
    expect(asksByDesign.sort()).toEqual(["keto", "mustard"]);
    for (const id of asksByDesign) {
      const violations = allergenViolations("water", [{ name: "probe", restrictions: [id] }]);
      expect(violations.length, id).toBe(1);
      expect(violations[0]).toMatch(/asks by design/);
      expect(violations[0]).toMatch(/confirmation required/);
    }
  });

  test("mapping keys are folded, so an unfolded alias spelling can never silently miss", () => {
    for (const key of Object.keys(APP_RESTRICTION_CHECKS)) {
      expect(fold(key), `alias key "${key}"`).toBe(key);
    }
  });

  test("each mapped id adjudicates every fact exactly like its canon tokens", () => {
    const wrong: string[] = [];
    for (const [id, canon] of Object.entries(CANON_EQUIVALENT)) {
      for (const key of factKeys) {
        const viaApp = classify(key, [id]);
        // One eater carrying every canon token — exactly the check the app
        // id resolves to (resolveRestriction(id) → allergens + diets).
        const viaCanon = classify(key, canon);
        if (viaApp !== viaCanon) wrong.push(`${key} × ${id}: app=${viaApp} canon=${viaCanon}`);
      }
    }
    expect(wrong).toEqual([]);
  });

  test("the human spellings that missed the vocabulary before resolve like their app ids", () => {
    const spellings: Readonly<Record<string, string>> = {
      "tree nut": "tree_nut",
      "tree nuts": "tree_nut",
      "tree-nuts": "tree_nut",
      peanut: "peanut",
      eggs: "egg",
      dairy: "milk",
      gluten: "wheat_gluten"
    };
    for (const [spelling, equivalent] of Object.entries(spellings)) {
      expect(resolveRestriction(spelling), spelling).not.toBeNull();
      for (const key of factKeys) {
        expect(classify(key, [spelling]), `${key} × ${spelling}`).toBe(classify(key, [equivalent]));
      }
    }
  });

  test("a mapped id no longer asks where its canon token clears (evidence-1 regression)", () => {
    // Pre-burst14, "tree nuts" (with the space) folded to "tree-nuts", missed
    // the unfolded alias keys, and asked on all 434 facts.
    expect(classify("water", ["tree nuts"])).toBe("clear");
    expect(classify("almonds", ["tree_nut"])).toBe("violate");
    expect(classify("water", ["peanut"])).toBe("clear");
  });
});

describe("the gateway accepts exactly the phone's restriction ids", () => {
  const session = (restrictions: readonly unknown[]) => ({
    state: "cooking",
    currentStepIndex: 0,
    eaters: [{ name: "probe", restrictions }],
    activeTimers: [],
    cameraMode: "push-to-look"
  });

  test("PHONE_RESTRICTION_IDS is the HouseholdAllergenGroup + HouseholdDiet raw values", () => {
    expect([...PHONE_RESTRICTION_IDS].sort()).toEqual([...APP_IDS].sort());
  });

  test("every phone id parses", () => {
    expect(parseCookSession(session(APP_IDS)).eaters[0].restrictions).toEqual(APP_IDS);
  });

  test("aliases the allergen check resolves are still refused on the wire", () => {
    for (const alias of ["gluten", "wheat", "Peanut", "tree nut", "tree-nut", "dairy", "peanuts", ""]) {
      expect(() => parseCookSession(session([alias])), alias).toThrow(WireParseError);
    }
  });
});
