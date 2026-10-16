/**
 * Catalog-agreement tests: every ingredient in the shipped recipe bundle must
 * resolve to a LeChef reviewed fact, and the bundle's class claims must agree
 * with the reviewed allergen states — so the app's screens and LeChef's safety
 * checks never contradict each other.
 *
 * Resolution mirrors src/lechef/allergens.ts exactly: canonical identities
 * (case/spaces/hyphens/underscores fold to one identity, synonyms map to the
 * reviewed key), then a fallback to the folded key itself.
 *
 * Expected disagreements are pinned and documented. Each one is a position the
 * reviewed canon takes deliberately; a change on either side moves these lists
 * and must be a conscious canon decision, not silent drift.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { allergenViolations } from "../../lechef/allergens.js";

function fold(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

interface AllergenState {
  readonly state: "contains" | "free" | "unknown";
}

interface Fact {
  readonly key: string;
  readonly allergens?: Readonly<Record<string, AllergenState>>;
  readonly diets?: Readonly<Record<string, AllergenState>>;
  readonly components?: readonly {
    readonly key: string;
    readonly certainty: "certain" | "typical" | "unknown";
  }[];
}

interface BundleIngredient {
  readonly key: string;
  readonly classes?: readonly string[];
}

const canonDir = "../../lechef/canon/ingredient-facts";
const facts = (JSON.parse(readFileSync(new URL(`${canonDir}/facts.json`, import.meta.url), "utf8")) as {
  facts: Readonly<Record<string, Fact>>;
}).facts;
const identities = (JSON.parse(readFileSync(new URL(`${canonDir}/identities.json`, import.meta.url), "utf8")) as {
  ingredients: readonly { key: string; synonyms?: readonly string[] }[];
}).ingredients;

const bundle = (JSON.parse(
  readFileSync(new URL("../../../../../data/recipes/build/recipes-v2.json", import.meta.url), "utf8")
) as { ingredients: readonly BundleIngredient[] }).ingredients;

/** Identity index, last-write-wins exactly like allergens.ts. */
const identityIndex = new Map<string, string>();
for (const entry of identities) {
  identityIndex.set(fold(entry.key), entry.key);
  for (const synonym of entry.synonyms ?? []) identityIndex.set(fold(synonym), entry.key);
}

function factFor(bundleKey: string): Fact | null {
  const f = fold(bundleKey);
  const key = identityIndex.get(f) ?? f;
  return facts[key] ?? null;
}

/**
 * Whether the reviewed facts carry `token` for the resolved fact, recursing
 * every component — mirroring allergens.ts: a contains state on a
 * certain/typical path flags hard; a reviewed unknown state, a missing key, a
 * component with no fact, or a contains state below an unknown-certainty
 * component is uncertain and never clears; only free on every fact resolves free.
 */
function carries(fact: Fact, token: string): "contains" | "unknown" | "free" {
  const stack: { fact: Fact | undefined; certain: boolean }[] = [{ fact, certain: true }];
  const seen = new Set<string>();
  let sawContains = false;
  let sawUnknown = false;
  while (stack.length > 0) {
    const { fact: f, certain } = stack.pop()!;
    if (!f) {
      sawUnknown = true;
      continue;
    }
    const visit = `${f.key}:${certain}`;
    if (seen.has(visit)) continue;
    seen.add(visit);
    const state = f.allergens?.[token]?.state;
    if (state === "contains" && certain) sawContains = true;
    else if (state !== "free") sawUnknown = true;
    for (const component of f.components ?? []) {
      stack.push({ fact: facts[component.key], certain: certain && component.certainty !== "unknown" });
    }
  }
  return sawContains ? "contains" : sawUnknown ? "unknown" : "free";
}

/** Diet verdict through composition, mirroring allergens.ts dietState. */
function dietState(fact: Fact, diet: string, seen: ReadonlySet<string> = new Set()): "allowed" | "violated" | undefined {
  if (seen.has(fact.key)) return undefined;
  const own = fact.diets?.[diet]?.state;
  if (own && own !== "unknown") return own;
  const next = new Set(seen).add(fact.key);
  let sawViolated = false;
  for (const component of fact.components ?? []) {
    if (component.certainty === "unknown") return undefined;
    const cf = facts[component.key];
    if (!cf) continue;
    const state = dietState(cf, diet, next);
    if (state === undefined) return undefined;
    if (state === "violated") sawViolated = true;
  }
  return sawViolated ? "violated" : "allowed";
}

/** Bundle class → reviewed allergen tokens. Shellfish spans both tokens: the
 * app's shellfish class covers molluscs as well as crustaceans (allergens.ts
 * RESTRICTION_TOKEN_GROUPS), so the class agrees unless BOTH tokens are free. */
const CLASS_TOKENS: Readonly<Record<string, readonly string[]>> = {
  gluten: ["wheat"],
  tree_nut: ["treeNuts"],
  fish: ["fish"],
  soy: ["soy"],
  dairy: ["milk"],
  shellfish: ["crustaceanShellfish", "molluscanShellfish"],
  egg: ["egg"],
  sesame: ["sesame"],
  mustard: ["mustard"],
  peanut: ["peanuts"]
};

/** The runtime verdict for a restriction group: contains > unknown > free. */
function classVerdict(fact: Fact, tokens: readonly string[]): "contains" | "unknown" | "free" {
  const verdicts = tokens.map((t) => carries(fact, t));
  if (verdicts.some((v) => v === "contains")) return "contains";
  if (verdicts.some((v) => v === "unknown")) return "unknown";
  return "free";
}

/** Classes the reviewed diet verdicts read as animal flesh. */
const FLESH_CLASSES = new Set(["meat", "fish", "shellfish", "animal"]);
/** Classes the reviewed vegan verdict reads as animal-derived. */
const ANIMAL_CLASSES = new Set([...FLESH_CLASSES, "egg", "dairy", "honey"]);

/**
 * Documented disagreements in the other direction (LeChef contains, bundle
 * class absent):
 *
 * - breadcrumbs carries milk: the reviewed fact has milk and wheat (some
 *   breadcrumbs contain milk powder); the bundle classes it gluten+plant only.
 * - squid carries fish: cephalopod allergens are reviewed under the fish token;
 *   the bundle's shellfish class does not claim fish.
 * - hao_you carries molluscanShellfish: reviewed as oyster-derived (molluscs
 *   count as shellfish), but the bundle does not class it shellfish — the
 *   reviewed claim is stricter, the safe direction.
 */
const LECHEF_CONTAINS_BUNDLE_LACKS: ReadonlySet<string> = new Set([
  "breadcrumbs: milk",
  "squid: fish",
  "hao_you: molluscanShellfish"
]);

/**
 * Documented diet disagreements (bundle key + diet): the bundle's animal class
 * over-claims for foods that are genuinely vegetarian (no flesh).
 */
const DIET_DISAGREEMENTS: ReadonlySet<string> = new Set([
  "ghee: vegetarian",
  "honey: vegetarian",
  "mayonnaise: vegetarian"
]);

describe("catalog facts agreement", () => {
  test("every catalog ingredient resolves to a reviewed LeChef fact", () => {
    const unresolved: string[] = [];
    for (const ing of bundle) {
      if (!factFor(ing.key)) unresolved.push(ing.key);
    }
    expect(unresolved).toEqual([]);
    expect(bundle.length).toBe(328);
  });

  test("bundle allergen classes agree with reviewed contains/unknown verdicts", () => {
    // No exceptions: the former ones (gnocchi milk, gochujang and miso wheat,
    // mustard) were all missing keys, which now ask instead of clearing.
    const disagreements: string[] = [];
    for (const ing of bundle) {
      const fact = factFor(ing.key);
      if (!fact) continue;
      for (const cls of ing.classes ?? []) {
        const tokens = CLASS_TOKENS[cls];
        if (!tokens) continue;
        if (classVerdict(fact, tokens) === "free") {
          disagreements.push(`${ing.key}: ${cls}→${tokens.join("/")}`);
        }
      }
    }
    expect(disagreements).toEqual([]);
  });

  test("reviewed contains verdicts are claimed by the bundle (documented exceptions only)", () => {
    const disagreements: string[] = [];
    for (const ing of bundle) {
      const fact = factFor(ing.key);
      if (!fact) continue;
      const classes = new Set(ing.classes ?? []);
      for (const [token, state] of Object.entries(fact.allergens ?? {})) {
        if (state.state !== "contains") continue;
        if ([...classes].some((cls) => (CLASS_TOKENS[cls] ?? []).includes(token))) continue;
        const entry = `${ing.key}: ${token}`;
        if (!LECHEF_CONTAINS_BUNDLE_LACKS.has(entry)) disagreements.push(entry);
      }
    }
    expect(disagreements).toEqual([]);
  });

  test("diet verdicts never clear a restriction the bundle classes as violated", () => {
    const disagreements: string[] = [];
    for (const ing of bundle) {
      const fact = factFor(ing.key);
      if (!fact) continue;
      const classes = new Set(ing.classes ?? []);
      const check = (diet: string, applicable: boolean) => {
        if (!applicable) return;
        if (dietState(fact, diet) !== "allowed") return;
        const entry = `${ing.key}: ${diet}`;
        if (!DIET_DISAGREEMENTS.has(entry)) disagreements.push(entry);
      };
      check("vegetarian", [...classes].some((cls) => FLESH_CLASSES.has(cls)));
      check("vegan", [...classes].some((cls) => ANIMAL_CLASSES.has(cls)));
    }
    expect(disagreements).toEqual([]);
  });

  test("review-round-2 probe: a reviewed unknown allergen state flags (confirmation required), never clears", () => {
    // Exactly the review probe: on the pre-fix head every case below was
    // silently cleared by allergenViolations; on alpha each ingredient sits
    // outside the reviewed facts and is refused. Restrictions use the reviewed
    // vocabulary spellings the runtime consumes.
    const flag = (ingredient: string, restrictions: readonly string[]): string =>
      allergenViolations(ingredient, [{ name: "probe", restrictions }]).join("\n");
    for (const [ingredient, restriction] of [
      ["stock", "wheat"],
      ["stock", "milk"],
      ["broth", "soy"],
      ["beef-vegetable-stock", "wheat"],
      ["baking-powder", "wheat"],
      ["massaman-curry-paste", "peanuts"]
    ] as const) {
      expect(flag(ingredient, [restriction]), `${ingredient} × ${restriction}`).toMatch(/confirmation required/);
    }
  });

  test("review-round-2 probe: molluscs count as shellfish — squid and oyster sauce hard-flag the app's shellfish class", () => {
    for (const ingredient of ["squid", "oyster-sauce", "hao-you"]) {
      const violations = allergenViolations(ingredient, [{ name: "probe", restrictions: ["shellfish"] }]);
      expect(violations.length, `${ingredient} × shellfish`).toBeGreaterThan(0);
      expect(violations.join("\n")).toMatch(/carries/);
    }
  });
});
