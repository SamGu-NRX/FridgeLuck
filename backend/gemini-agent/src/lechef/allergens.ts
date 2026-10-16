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
 * closed): an ingredient outside the reviewed facts, an ingredient whose
 * reviewed allergen state for a restriction is unresolved (unknown), or an
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
function fold(name: string): string {
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
  /** Allergen tokens whose presence is uncertain: an own reviewed unknown state, or unknown-certainty components. */
  readonly uncertainTokens: readonly string[];
  /** The resolved reviewed fact, when one exists. */
  readonly fact: IngredientFact | null;
}

const ALLERGEN_CACHE = new Map<string, Carries>();

/** Resolve carried allergen tokens from the reviewed facts, recursing composition. */
function resolveCarries(ingredient: string): Carries {
  const key = fold(identities().get(fold(ingredient)) ?? ingredient);
  const cached = ALLERGEN_CACHE.get(key);
  if (cached) return cached;
  const fact = factFor(key);
  const result = (() => {
    if (!fact) return { tokens: [], uncertainTokens: [], fact: null } satisfies Carries;
    const tokens = new Set<string>();
    const uncertainTokens = new Set<string>();
    const visit = (factKey: string, stack: ReadonlySet<string>): void => {
      if (stack.has(factKey)) return; // composition cycles: reviewed facts are acyclic; guard anyway
      const next = new Set(stack).add(factKey);
      const f = facts()[factKey];
      if (!f) return;
      for (const [token, state] of Object.entries(f.allergens ?? {})) {
        if (state.state === "contains") tokens.add(token);
        else if (state.state === "unknown") uncertainTokens.add(token); // reviewed as unresolved: never clears
      }
      for (const component of f.components ?? []) {
        const componentAllergens = Object.entries(facts()[component.key]?.allergens ?? {});
        if (component.certainty === "unknown") {
          for (const [token, state] of componentAllergens) {
            if (state.state === "contains") uncertainTokens.add(token);
          }
        } else {
          visit(component.key, next);
        }
      }
    };
    visit(fact.key, new Set());
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
  let sawViolated = false;
  for (const component of fact.components ?? []) {
    if (component.certainty === "unknown") return undefined; // uncertain composition: no diet verdict
    const cf = facts()[component.key];
    if (!cf) continue;
    const state = dietState(cf, diet, next);
    if (state === undefined) return undefined;
    if (state === "violated") sawViolated = true;
  }
  return sawViolated ? "violated" : "allowed";
}

/**
 * Human spellings of reviewed tokens the vocabulary would otherwise miss
 * (the canon's token for shellfish is "crustaceanShellfish"). Alias targets
 * are folded keys. Matching is otherwise exact on the reviewed vocabulary —
 * anything else fails closed.
 */
const RESTRICTION_ALIASES: Readonly<Record<string, string>> = {
  shellfish: "crustaceanshellfish",
  "tree nut": "treenuts",
  "tree nuts": "treenuts",
  soya: "soy"
};

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

/** Restriction → reviewed vocabulary entry, or null when outside the vocabulary. */
function restrictionEntry(restriction: string): VocabularyEntry | null {
  const f = fold(restriction);
  const key = RESTRICTION_ALIASES[f] ?? f;
  return restrictionVocabulary()[key] ?? null;
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
      const entry = restrictionEntry(restriction);
      if (!entry) {
        // Fail closed: the reviewed facts cannot adjudicate this restriction.
        violations.push(
          `${eater.name ?? "eater"}: restriction "${restriction}" is not in the reviewed restriction vocabulary — confirmation required, this check never assumes such a restriction is satisfied`
        );
        continue;
      }
      if (entry.kind === "allergen") {
        const group = RESTRICTION_TOKEN_GROUPS[fold(entry.token)] ?? [entry.token];
        const carried = group.some((t) => carries.tokens.includes(t));
        const uncertain = group.some((t) => carries.uncertainTokens.includes(t));
        if (carried) {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} carries ${carries.tokens.join(", ")}`
          );
        } else if (uncertain) {
          violations.push(
            `${eater.name ?? "eater"}: ${restriction} — ${ingredientId} may carry ${entry.token} (presence unresolved in the reviewed facts) — confirmation required before serving`
          );
        }
        // A reviewed free/absent state is the one thing that clears.
      } else {
        const state = dietState(carries.fact, entry.token);
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
