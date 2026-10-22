/**
 * Allergen recheck for substitutions (SPEC 3.1).
 *
 * Every substitution rechecks ALL eaters' restrictions, including compound
 * ingredients — soy sauce contains wheat, pesto carries nuts. The facts are
 * NOT embedded here: they come from the PINNED ingredient-facts canon at
 * ./canon/ingredient-facts/ (verbatim from overhaul/ingredient-facts; see
 * canon/PROVENANCE.md), with canonical identities — case, spaces, hyphens
 * and underscores all fold to one identity ("SOY SAUCE", "soy_sauce" and
 * "soy-sauce" are the same reviewed fact) — and compound composition
 * resolved through the facts graph with its certainty levels.
 *
 * Fail closed (SPEC 3.1: unresolved safety-relevant composition fails
 * closed): an ingredient outside the reviewed facts, an ingredient or
 * component whose allergen state for a restriction is unresolved (unknown) or
 * absent (no entry for that allergen), or an
 * ingredient whose composition is incomplete, produces a CONFIRMATION-REQUIRED
 * line — never a silent "no violation". A restriction outside the reviewed vocabulary
 * (anything the reviewed facts cannot adjudicate) also requires
 * confirmation instead of clearing. Only reviewed contains/violated states
 * can produce a hard violation, and only a reviewed free/allowed state
 * clears — a reviewed unknown state never clears (review round 2).
 */

import { readFileSync } from "node:fs";
import type { Eater } from "./types.js";

interface FactEvidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}

interface AllergenState {
  readonly state: "contains" | "free" | "unknown";
  readonly evidence: FactEvidence;
}

interface DietState {
  readonly state: "allowed" | "violated" | "unknown";
  readonly evidence: FactEvidence;
}

interface IngredientFact {
  readonly key: string;
  readonly class?: string;
  readonly allergens?: Readonly<Record<string, AllergenState>>;
  readonly diets?: Readonly<Record<string, DietState>>;
  readonly components?: readonly {
    readonly key: string;
    readonly certainty: "certain" | "typical" | "unknown";
    readonly evidence: FactEvidence;
  }[];
  readonly compositionComplete?: boolean;
  readonly note?: string;
}

interface CanonIdentities {
  readonly version: number;
  readonly ingredients: readonly {
    readonly key: string;
    readonly display: string;
    readonly kind: string;
    readonly synonyms?: readonly string[];
  }[];
}

interface CanonFacts {
  readonly version: number;
  readonly facts: Readonly<Record<string, IngredientFact>>;
}

/** Canonical identity fold: case, spaces, hyphens and underscores are one identity. */
export function fold(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function readCanonFile(relative: string): string {
  return readFileSync(new URL(relative, import.meta.url), "utf8");
}

let identityIndex: ReadonlyMap<string, string> | null = null;
function identities(): ReadonlyMap<string, string> {
  if (!identityIndex) {
    const canon: CanonIdentities = JSON.parse(readCanonFile("./canon/ingredient-facts/identities.json"));
    const map = new Map<string, string>();
    for (const entry of canon.ingredients) {
      map.set(fold(entry.key), entry.key);
      for (const synonym of entry.synonyms ?? []) map.set(fold(synonym), entry.key);
    }
    identityIndex = map;
  }
  return identityIndex;
}

let factTable: Readonly<Record<string, IngredientFact>> | null = null;
function facts(): Readonly<Record<string, IngredientFact>> {
  if (!factTable) {
    const canon: CanonFacts = JSON.parse(readCanonFile("./canon/ingredient-facts/facts.json"));
    factTable = canon.facts;
  }
  return factTable;
}

/** The reviewed fact for a name in any spelling, or null when unknown. */
function factFor(name: string): IngredientFact | null {
  const f = fold(name);
  const key = identities().get(f) ?? f;
  return facts()[key] ?? null;
}

export interface Carries {
  /** Allergen tokens the ingredient certainly/typically carries (contains). */
  readonly tokens: readonly string[];
  /**
   * Allergen tokens without a reviewed free state somewhere in the composition:
   * a reviewed unknown state, a missing key, a component with no fact, or a
   * contains state reached through an unknown-certainty component.
   */
  readonly uncertainTokens: readonly string[];
  /** The resolved reviewed fact, when one exists. */
  readonly fact: IngredientFact | null;
}

const ALLERGEN_CACHE = new Map<string, Carries>();

/**
 * Resolve carried allergen tokens from the reviewed facts, recursing
 * composition. Every allergen token in the reviewed vocabulary is checked on
 * every fact reached: only an explicit free state is silent. A missing key is
 * treated like a reviewed unknown, because the canon has facts that review a
 * single token (almonds lists only treeNuts) and components with no allergen
 * entries at all (stock-additives), and reading those gaps as free cleared
 * beef stock for a wheat-free eater.
 */
function resolveCarries(ingredient: string): Carries {
  const key = fold(identities().get(fold(ingredient)) ?? ingredient);
  const cached = ALLERGEN_CACHE.get(key);
  if (cached) return cached;
  const fact = factFor(key);
  const result = (() => {
    if (!fact) return { tokens: [], uncertainTokens: [], fact: null } satisfies Carries;
    const vocabularyTokens = allergenTokens();
    const tokens = new Set<string>();
    const uncertainTokens = new Set<string>();
    // `certain` is false below an unknown-certainty component: a contains
    // state there is only a possibility, but a gap there is still a gap.
    const visit = (factKey: string, certain: boolean, stack: ReadonlySet<string>): void => {
      if (stack.has(factKey)) return; // composition cycles: reviewed facts are acyclic; guard anyway
      const next = new Set(stack).add(factKey);
      const f = facts()[factKey];
      for (const token of vocabularyTokens) {
        const state = f?.allergens?.[token]?.state;
        if (state === "free") continue;
        if (state === "contains" && certain) tokens.add(token);
        else uncertainTokens.add(token); // unknown, missing key, or no fact for this component: never clears
      }
      for (const component of f?.components ?? []) {
        visit(component.key, certain && component.certainty !== "unknown", next);
      }
    };
    visit(fact.key, true, new Set());
    return { tokens: [...tokens].sort(), uncertainTokens: [...uncertainTokens].sort(), fact } satisfies Carries;
  })();
  ALLERGEN_CACHE.set(key, result);
  return result;
}

/** The reviewed diet verdict for an ingredient, deriving through composition. */
function dietState(fact: IngredientFact, diet: string, seen: ReadonlySet<string> = new Set()): "allowed" | "violated" | undefined {
  if (seen.has(fact.key)) return undefined;
  const own = fact.diets?.[diet]?.state;
  if (own && own !== "unknown") return own;
  const next = new Set(seen).add(fact.key);
  const components = fact.components ?? [];
  // Only a reviewed "allowed" clears. A component-less fact with no reviewed
  // diet state (or an unknown one) has nothing to derive from: it asks, like
  // the allergen rule (#211) — it must not fall through to a vacuous
  // "allowed". Facts with components still derive from them.
  if (components.length === 0) return undefined;
  let sawViolated = false;
  for (const component of components) {
    if (component.certainty === "unknown") return undefined; // uncertain composition: no diet verdict
    const cf = facts()[component.key];
    if (!cf) return undefined; // a component with no reviewed fact is a gap, never silence
    const state = dietState(cf, diet, next);
    if (state === undefined) return undefined;
    if (state === "violated") sawViolated = true;
  }
  return sawViolated ? "violated" : "allowed";
}

/**
 * Human spellings and the app's household restriction ids → reviewed
 * vocabulary checks (HouseholdAllergenGroup / HouseholdDiet raw values,
 * apps/ios/FeatureLogic/Safety/HouseholdSafetyGate.swift — read as text by
 * restrictionIds.test.ts, which fails CI when a Swift case arrives without a
 * mapping here).
 *
 * KEYS ARE FOLDED (fold()): the pre-burst14 alias table folded the lookup but
 * not its keys, so "tree nut" folded to "tree-nuts" and never matched the
 * "tree nut" key — every alias was dead. Writing keys pre-folded makes that
 * recurrence impossible, and the test pins every key === fold(key).
 *
 * wheat_gluten maps to BOTH the wheat allergen and the glutenFree diet — both
 * must clear before the restriction clears. shellfish covers both reviewed
 * shellfish tokens (crustaceanShellfish + molluscanShellfish); dairy folds to
 * the milk allergen; gluten covers wheat + glutenFree.
 */
export interface RestrictionCheck {
  /** Reviewed allergen tokens (canon camelCase) the restriction screens. */
  readonly allergens: readonly string[];
  /** Reviewed diet names the restriction screens. */
  readonly diets: readonly string[];
}

export const APP_RESTRICTION_CHECKS: Readonly<Record<string, RestrictionCheck>> = {
  milk: { allergens: ["milk"], diets: [] },
  dairy: { allergens: ["milk"], diets: [] },
  egg: { allergens: ["egg"], diets: [] },
  eggs: { allergens: ["egg"], diets: [] },
  peanut: { allergens: ["peanuts"], diets: [] },
  "tree-nut": { allergens: ["treeNuts"], diets: [] },
  "tree-nuts": { allergens: ["treeNuts"], diets: [] },
  soy: { allergens: ["soy"], diets: [] },
  soya: { allergens: ["soy"], diets: [] },
  "wheat-gluten": { allergens: ["wheat"], diets: ["glutenFree"] },
  gluten: { allergens: ["wheat"], diets: ["glutenFree"] },
  fish: { allergens: ["fish"], diets: [] },
  shellfish: { allergens: ["crustaceanShellfish", "molluscanShellfish"], diets: [] },
  sesame: { allergens: ["sesame"], diets: [] },
  vegetarian: { allergens: [], diets: ["vegetarian"] },
  pescatarian: { allergens: [], diets: ["pescatarian"] },
  vegan: { allergens: [], diets: ["vegan"] }
};

/**
 * Restrictions with NO reviewed facts in the canon: nothing can adjudicate
 * them, so they keep asking — explicitly, with the reason named in the
 * confirmation text, instead of silently clearing or reading as a vocabulary
 * miss. mustard and keto are today's reviewed canon gaps; the facts-review
 * bands may review them later, at which point they move to the table above.
 */
const ASKS_BY_DESIGN: Readonly<Record<string, string>> = {
  mustard: "the reviewed facts cover no mustard facts",
  keto: "the reviewed facts cover no keto facts"
};

/**
 * The restriction ids the phone may send in `cookSession.eaters`: exactly the
 * HouseholdAllergenGroup and HouseholdDiet raw values. The live gateway
 * rejects any other string, including spellings resolveRestriction would
 * accept ("gluten", "wheat"), so a phone-side rename fails loudly instead of
 * relying on an alias. restrictionIds.test.ts pins this list to the Swift enums.
 */
export const PHONE_RESTRICTION_IDS: readonly string[] = [
  "milk",
  "egg",
  "peanut",
  "tree_nut",
  "soy",
  "wheat_gluten",
  "fish",
  "shellfish",
  "sesame",
  "mustard",
  "vegetarian",
  "pescatarian",
  "vegan",
  "keto"
];

export type RestrictionResolution =
  | ({ readonly kind: "check" } & RestrictionCheck)
  | { readonly kind: "asksByDesign"; readonly reason: string };

/**
 * Resolve a restriction (any human spelling, app id, or reviewed token) to
 * what should be checked, or null when nothing reviewed can adjudicate it —
 * null fails closed (asks), never clears.
 */
export function resolveRestriction(restriction: string): RestrictionResolution | null {
  const f = fold(restriction);
  const app = APP_RESTRICTION_CHECKS[f];
  if (app) return { kind: "check", allergens: app.allergens, diets: app.diets };
  const asks = ASKS_BY_DESIGN[f];
  if (asks) return { kind: "asksByDesign", reason: asks };
  const entry = restrictionVocabulary()[f];
  if (!entry) return null;
  return entry.kind === "allergen"
    ? { kind: "check", allergens: [entry.token], diets: [] }
    : { kind: "check", allergens: [], diets: [entry.token] };
}

/**
 * App-level restriction groups: the app's "shellfish" class covers molluscs
 * (bivalves, cephalopods) as well as crustaceans, while the reviewed
 * crustaceanShellfish token stays crustacean-only (FDA major-9). A shellfish
 * restriction therefore matches both tokens; mollusk facts carry
 * molluscanShellfish. Keys are folded tokens.
 */
const RESTRICTION_TOKEN_GROUPS: Readonly<Record<string, readonly string[]>> = {
  crustaceanshellfish: ["crustaceanShellfish", "molluscanShellfish"]
};

interface VocabularyEntry {
  readonly kind: "allergen" | "diet";
  /** The canon's exact token (camelCase as reviewed). */
  readonly token: string;
}

let vocabulary: Readonly<Record<string, VocabularyEntry>> | null = null;
/** The reviewed restriction vocabulary: every allergen token and diet name in the canon. */
function restrictionVocabulary(): Readonly<Record<string, VocabularyEntry>> {
  if (!vocabulary) {
    const v: Record<string, VocabularyEntry> = {};
    for (const fact of Object.values(facts())) {
      for (const token of Object.keys(fact.allergens ?? {})) v[fold(token)] = { kind: "allergen", token };
      for (const diet of Object.keys(fact.diets ?? {})) v[fold(diet)] = { kind: "diet", token: diet };
    }
    vocabulary = v;
  }
  return vocabulary;
}

/** Every allergen token in the reviewed vocabulary, in the canon's spelling. */
function allergenTokens(): readonly string[] {
  return Object.values(restrictionVocabulary())
    .filter((entry) => entry.kind === "allergen")
    .map((entry) => entry.token);
}

/** The restriction tokens an ingredient carries from the reviewed facts (direct + composition). */
export function restrictionTokensFor(ingredientId: string): readonly string[] {
  return resolveCarries(ingredientId).tokens;
}

/**
 * Recheck one ingredient against all eaters' explicit restrictions.
 * Only reviewed facts can clear: an unknown ingredient, an uncertain
 * composition relevant to a restriction, or a restriction outside the
 * reviewed vocabulary produces a confirmation-required line, never silence.
 */
export function allergenViolations(
  ingredientId: string,
  eaters: readonly Eater[]
): readonly string[] {
  const carries = resolveCarries(ingredientId);
  if (!carries.fact) {
    // Fail closed: no reviewed facts at all — confirmation required even
    // when no eater restricts anything.
    return [
      `"${ingredientId}" is not in the reviewed ingredient facts — confirmation required before serving; this check never assumes a food is safe by default`
    ];
  }
  const violations: string[] = [];
  for (const eater of eaters) {
    for (const restriction of eater.restrictions) {
      const resolution = resolveRestriction(restriction);
      if (!resolution) {
        // Fail closed: the reviewed facts cannot adjudicate this restriction.
        violations.push(
          `${eater.name ?? "eater"}: restriction "${restriction}" is not in the reviewed restriction vocabulary — confirmation required, this check never assumes such a restriction is satisfied`
        );
        continue;
      }
      if (resolution.kind === "asksByDesign") {
        // No reviewed facts exist for this restriction: it keeps asking, by
        // design, with the reason named — never a silent clear.
        violations.push(
          `${eater.name ?? "eater"}: ${restriction} — asks by design: ${resolution.reason} — confirmation required before serving`
        );
        continue;
      }
      for (const token of resolution.allergens) {
        const group = RESTRICTION_TOKEN_GROUPS[fold(token)] ?? [token];
        const carried = group.some((t) => carries.tokens.includes(t));
        const uncertain = group.some((t) => carries.uncertainTokens.includes(t));
        if (carried) {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} carries ${carries.tokens.join(", ")}`
          );
        } else if (uncertain) {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} may carry ${token} (presence unresolved in the reviewed facts) — confirmation required before serving`
          );
        }
        // Only a reviewed free state on every fact in the composition clears.
      }
      for (const diet of resolution.diets) {
        const state = dietState(carries.fact, diet);
        if (state === "violated") {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} is not compatible with ${restriction} (reviewed diet fact)`
          );
        } else if (state === undefined) {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} diet status is unresolved in the reviewed facts — confirmation required before serving`
          );
        }
      }
    }
  }
  return violations;
}

/**
 * Recheck a swap (from → to) against all eaters. BOTH sides are rechecked:
 * dropping the original can matter as much as adding the substitute when a
 * restriction relies on its absence.
 */
export function recheckSwapAllergens(
  from: string,
  to: string,
  eaters: readonly Eater[]
): readonly string[] {
  return [...allergenViolations(to, eaters), ...allergenViolations(from, eaters)];
}
