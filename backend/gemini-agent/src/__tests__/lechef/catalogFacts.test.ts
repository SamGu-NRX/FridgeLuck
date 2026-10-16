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
 * certain/typical components (the composition half of resolveCarries).
 */
function carries(fact: Fact, token: string): "contains" | "unknown" | "free" {
  const stack = [fact];
  const seen = new Set<string>();
  while (stack.length > 0) {
    const f = stack.pop()!;
    if (seen.has(f.key)) continue;
    seen.add(f.key);
    const state = f.allergens?.[token]?.state;
    if (state === "contains") return "contains";
    if (state === "unknown" && f === fact) return "unknown";
    for (const component of f.components ?? []) {
      if (component.certainty === "unknown") continue;
      const cf = facts[component.key];
      if (cf) stack.push(cf);
    }
  }
  return "free";
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

/** Bundle class → reviewed allergen token. Only classes with a reviewed token. */
const CLASS_TOKEN: Readonly<Record<string, string>> = {
  gluten: "wheat",
  tree_nut: "treeNuts",
  fish: "fish",
  soy: "soy",
  dairy: "milk",
  shellfish: "crustaceanShellfish",
  egg: "egg",
  sesame: "sesame",
  mustard: "mustard",
  peanut: "peanuts"
};

/** Classes the reviewed diet verdicts read as animal flesh. */
const FLESH_CLASSES = new Set(["meat", "fish", "shellfish", "animal"]);
/** Classes the reviewed vegan verdict reads as animal-derived. */
const ANIMAL_CLASSES = new Set([...FLESH_CLASSES, "egg", "dairy", "honey"]);

/**
 * Documented, deliberate disagreements (bundle key + class → token) where the
 * bundle claims a carry and the reviewed fact says free:
 *
 * - gnocchi (dairy → milk): fresh gnocchi recipes vary; the bundle is
 *   conservative, the reviewed fact (potato/wheat/water base) carries no milk.
 * - gochujang (gluten → wheat): traditional gochujang carries no wheat; some
 *   brands add wheat-based sweeteners. Reviewed as brand-dependent, not a
 *   definite contains.
 * - miso (gluten → wheat): barley (mugi) miso exists; the reviewed fact keeps
 *   wheat brand-dependent instead of contains.
 * - mustard (mustard → mustard): "mustard" is outside the reviewed FDA-major-9
 *   vocabulary entirely — no reviewed fact carries that token, so a mustard
 *   restriction fails closed (confirmation required) at runtime rather than
 *   being adjudicated. The bundle's class claim is stricter than the reviewed
 *   vocabulary, which is safe.
 * - squid (shellfish → crustaceanShellfish): squid is a MOLLUSK, not a
 *   crustacean. The reviewed fact deliberately says free for
 *   crustaceanShellfish with the FDA mollusk note; the bundle's shellfish
 *   class is the coarse app-level claim.
 */
const BUNDLE_CARRY_LECHEF_FREE: ReadonlySet<string> = new Set([
  "gnocchi: dairy→milk",
  "gochujang: gluten→wheat",
  "miso: gluten→wheat",
  "mustard: mustard→mustard",
  "squid: shellfish→crustaceanShellfish"
]);

/**
 * Documented disagreements in the other direction (LeChef contains, bundle
 * class absent):
 *
 * - breadcrumbs carries milk: the reviewed fact has milk and wheat (some
 *   breadcrumbs contain milk powder); the bundle classes it gluten+plant only.
 * - squid carries fish: cephalopod allergens are reviewed under the fish token;
 *   the bundle's shellfish class does not claim fish.
 */
const LECHEF_CONTAINS_BUNDLE_LACKS: ReadonlySet<string> = new Set([
  "breadcrumbs: milk",
  "squid: fish"
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
    const disagreements: string[] = [];
    for (const ing of bundle) {
      const fact = factFor(ing.key);
      if (!fact) continue;
      for (const cls of ing.classes ?? []) {
        const token = CLASS_TOKEN[cls];
        if (!token) continue;
        if (carries(fact, token) === "free") {
          const entry = `${ing.key}: ${cls}→${token}`;
          if (!BUNDLE_CARRY_LECHEF_FREE.has(entry)) disagreements.push(entry);
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
        if ([...classes].some((cls) => CLASS_TOKEN[cls] === token)) continue;
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
});
