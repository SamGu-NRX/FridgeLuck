/**
 * The food-safety data seam (SPEC 3.1, 3.5, 6; PR #104 review blocker 1).
 *
 * Publishing is gated on TWO data packages, both mandatory:
 *
 *   - the canonical food-safety rulebook (`overhaul/food-safety-canon`),
 *     loaded from `canon.json` — the mechanical rules a recipe text must
 *     satisfy (doneness evidence, advisory-sourcing, allergen-claim rules);
 *   - the ingredient facts (`overhaul/ingredient-facts`, the FLIngredientFacts
 *     lineage), loaded from `ingredient-facts.json` — the ingredient →
 *     allergen knowledge (including compound ingredients: soy sauce carries
 *     wheat, pesto carries nuts) that allergen tagging derives from.
 *
 * The gate is FAIL-CLOSED: absence, emptiness, unparsable JSON, or a schema
 * violation is never a warning — the catalog reports itself not loaded and
 * publishing is refused outright (error envelope, nothing persisted). A
 * publication is never created on absent safety data.
 *
 * Locations, in precedence order (documented contract for the packages when
 * they land):
 *   1. explicit paths passed to the loader;
 *   2. `FOOD_SAFETY_CANON_PATH` / `FOOD_SAFETY_FACTS_PATH` env vars;
 *   3. `<data root>/data/food-safety/{canon,ingredient-facts}.json`, where the
 *      data root is `FOOD_SAFETY_DATA_ROOT` or the nearest ancestor of the
 *      working directory that has a `data` directory (the repo root when run
 *      from `backend/gemini-agent`).
 */
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const FOOD_SAFETY_CANON_SCHEMA = "fridgeluck/food-safety-canon@v1";
export const INGREDIENT_FACTS_SCHEMA = "fridgeluck/ingredient-facts@v1";

/** A rulebook rule: forbid terms outright, or require evidence when a trigger appears. */
export type FoodSafetyRule =
  | { readonly kind: "forbidden-terms"; readonly id: string; readonly terms: readonly string[]; readonly message: string }
  | {
      readonly kind: "claim-requires-evidence";
      readonly id: string;
      readonly triggers: readonly string[];
      /** RegExp sources (case-insensitive); each must match somewhere in the recipe. */
      readonly requireAny: readonly string[];
      readonly message: string;
    }
  | {
      readonly kind: "allergen-claim";
      readonly id: string;
      readonly claims: ReadonlyArray<{ readonly phrases: readonly string[]; readonly allergen: string }>;
      readonly message: string;
    };

export interface FoodSafetyRulebook {
  readonly schema: string;
  /** Where the rulebook came from (the package should name its reviewed source). */
  readonly source: string;
  readonly rules: readonly FoodSafetyRule[];
}

export interface IngredientFactsEntry {
  readonly id: string;
  /** Lowercase names/phrases this ingredient goes by; multi-word phrases are matched as such. */
  readonly match: readonly string[];
  /** Allergen slugs (from the file's own vocabulary), already including compound contributions. */
  readonly allergens: readonly string[];
}

export interface IngredientFacts {
  readonly schema: string;
  readonly source: string;
  /** The closed allergen vocabulary every entry must draw from. */
  readonly allergens: readonly string[];
  readonly ingredients: readonly IngredientFactsEntry[];
}

/**
 * The loaded state of the two packages. `loaded: false` is the fail-closed
 * state — `reason` is a stable, log-worthy explanation, never a warning.
 */
export type FoodSafetyCatalog =
  | { readonly loaded: true; readonly rulebook: FoodSafetyRulebook; readonly facts: IngredientFacts }
  | { readonly loaded: false; readonly reason: string };

export interface FoodSafetyCatalogPaths {
  readonly canon: string;
  readonly facts: string;
}

export interface ResolveFoodSafetyPathsOptions {
  readonly env?: Record<string, string | undefined>;
  readonly cwd?: string;
  readonly dataRoot?: string;
}

/** Nearest ancestor (inclusive) of `from` holding a `data` directory; `from` itself as fallback. */
function defaultDataRoot(from: string): string {
  let dir = resolve(from);
  for (;;) {
    try {
      if (statSync(join(dir, "data")).isDirectory()) {
        return dir;
      }
    } catch {
      // no data directory here — keep walking
    }
    const parent = dirname(dir);
    if (parent === dir) {
      return resolve(from);
    }
    dir = parent;
  }
}

/**
 * Where the loader reads the two packages from, per the documented precedence.
 * Falls back to the working-directory root so a missing tree surfaces as a
 * closed catalog ("absent data") rather than a resolution error.
 */
export function resolveFoodSafetyCatalogPaths(options: ResolveFoodSafetyPathsOptions = {}): FoodSafetyCatalogPaths {
  const env = options.env ?? process.env;
  const root = options.dataRoot ?? env["FOOD_SAFETY_DATA_ROOT"] ?? defaultDataRoot(options.cwd ?? process.cwd());
  const foodSafetyDir = join(root, "data", "food-safety");
  return {
    canon: env["FOOD_SAFETY_CANON_PATH"] ?? join(foodSafetyDir, "canon.json"),
    facts: env["FOOD_SAFETY_FACTS_PATH"] ?? join(foodSafetyDir, "ingredient-facts.json"),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function closed(reason: string): FoodSafetyCatalog {
  return { loaded: false, reason };
}

/** Slug pattern for allergen vocabulary and rule references. */
const ALLERGEN_SLUG = /^[a-z][a-z0-9-]{0,31}$/;

function readNonEmptyStrings(value: unknown, what: string, problems: string[]): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.some((v) => typeof v !== "string" || v.trim().length === 0)) {
    problems.push(`${what} must be a non-empty array of non-empty strings`);
    return [];
  }
  return value as string[];
}

function validateRulebook(raw: unknown, factsVocabulary: ReadonlySet<string>, problems: string[]): FoodSafetyRulebook | null {
  if (!isRecord(raw)) {
    problems.push("rulebook must be a JSON object");
    return null;
  }
  if (raw["schema"] !== FOOD_SAFETY_CANON_SCHEMA) {
    problems.push(`rulebook schema must be ${FOOD_SAFETY_CANON_SCHEMA}`);
    return null;
  }
  if (typeof raw["source"] !== "string" || raw["source"].trim().length === 0) {
    problems.push("rulebook.source must name its reviewed source");
    return null;
  }
  if (!Array.isArray(raw["rules"]) || raw["rules"].length === 0) {
    problems.push("rulebook.rules must be a non-empty array (an empty canon is not a canon)");
    return null;
  }
  const rules: FoodSafetyRule[] = [];
  for (const [i, entry] of (raw["rules"] as unknown[]).entries()) {
    if (!isRecord(entry)) {
      problems.push(`rulebook.rules[${i}] must be an object`);
      return null;
    }
    const id = entry["id"];
    if (typeof id !== "string" || id.trim().length === 0) {
      problems.push(`rulebook.rules[${i}].id must be a non-empty string`);
      return null;
    }
    const message = entry["message"];
    if (typeof message !== "string" || message.trim().length === 0) {
      problems.push(`rulebook.rules[${i}].message must be a non-empty string`);
      return null;
    }
    switch (entry["kind"]) {
      case "forbidden-terms": {
          const terms = readNonEmptyStrings(entry["terms"], `rulebook.rules[${i}].terms`, problems);
          if (terms.length === 0) {
            return null;
          }
          rules.push({ kind: "forbidden-terms", id, terms, message });
        }
        break;
      case "claim-requires-evidence": {
        const triggers = readNonEmptyStrings(entry["triggers"], `rulebook.rules[${i}].triggers`, problems);
        const requireAny = readNonEmptyStrings(entry["requireAny"], `rulebook.rules[${i}].requireAny`, problems);
        if (triggers.length === 0 || requireAny.length === 0) {
          return null;
        }
        // Evidence entries are regular expressions; an unparsable one is bad
        // data, and bad data closes the gate rather than weakening it.
        for (const source of requireAny) {
          try {
            new RegExp(source, "i");
          } catch (error) {
            problems.push(`rulebook.rules[${i}].requireAny contains an invalid regular expression (${source}): ${error instanceof Error ? error.message : String(error)}`);
            return null;
          }
        }
        rules.push({ kind: "claim-requires-evidence", id, triggers, requireAny, message });
        break;
      }
      case "allergen-claim": {
        if (!Array.isArray(entry["claims"]) || entry["claims"].length === 0) {
          problems.push(`rulebook.rules[${i}].claims must be a non-empty array`);
          return null;
        }
        const claims: Array<{ phrases: string[]; allergen: string }> = [];
        for (const [j, claimRaw] of (entry["claims"] as unknown[]).entries()) {
          if (!isRecord(claimRaw)) {
            problems.push(`rulebook.rules[${i}].claims[${j}] must be an object`);
            return null;
          }
          const phrases = readNonEmptyStrings(claimRaw["phrases"], `rulebook.rules[${i}].claims[${j}].phrases`, problems);
          const allergen = claimRaw["allergen"];
          if (phrases.length === 0) {
            return null;
          }
          if (typeof allergen !== "string" || !ALLERGEN_SLUG.test(allergen) || !factsVocabulary.has(allergen)) {
            problems.push(`rulebook.rules[${i}].claims[${j}].allergen must be an allergen from the ingredient-facts vocabulary`);
            return null;
          }
          claims.push({ phrases, allergen });
        }
        rules.push({ kind: "allergen-claim", id, claims, message });
        break;
      }
      default:
        problems.push(`rulebook.rules[${i}].kind must be one of forbidden-terms, claim-requires-evidence, allergen-claim`);
        return null;
    }
  }
  return { schema: FOOD_SAFETY_CANON_SCHEMA, source: raw["source"] as string, rules };
}

function validateFacts(raw: unknown, problems: string[]): IngredientFacts | null {
  if (!isRecord(raw)) {
    problems.push("ingredient facts must be a JSON object");
    return null;
  }
  if (raw["schema"] !== INGREDIENT_FACTS_SCHEMA) {
    problems.push(`ingredient facts schema must be ${INGREDIENT_FACTS_SCHEMA}`);
    return null;
  }
  if (typeof raw["source"] !== "string" || raw["source"].trim().length === 0) {
    problems.push("ingredient facts source must name its reviewed source");
    return null;
  }
  const vocabulary = readNonEmptyStrings(raw["allergens"], "ingredient facts allergens", problems);
  if (vocabulary.length === 0 || vocabulary.some((a) => !ALLERGEN_SLUG.test(a))) {
    problems.push("ingredient facts allergens must be lowercase slugs");
    return null;
  }
  if (!Array.isArray(raw["ingredients"]) || raw["ingredients"].length === 0) {
    problems.push("ingredient facts ingredients must be a non-empty array");
    return null;
  }
  const known = new Set(vocabulary);
  const entries: IngredientFactsEntry[] = [];
  for (const [i, entryRaw] of (raw["ingredients"] as unknown[]).entries()) {
    if (!isRecord(entryRaw)) {
      problems.push(`ingredient facts ingredients[${i}] must be an object`);
      return null;
    }
    const id = entryRaw["id"];
    const match = readNonEmptyStrings(entryRaw["match"], `ingredient facts ingredients[${i}].match`, problems);
    const allergens = readNonEmptyStrings(entryRaw["allergens"], `ingredient facts ingredients[${i}].allergens`, problems);
    if (typeof id !== "string" || id.trim().length === 0 || match.length === 0 || allergens.length === 0) {
      return null;
    }
    if (allergens.some((a) => !known.has(a))) {
      problems.push(`ingredient facts ingredients[${i}].allergens must draw from the file's own allergens vocabulary`);
      return null;
    }
    entries.push({ id, match, allergens });
  }
  return { schema: INGREDIENT_FACTS_SCHEMA, source: raw["source"] as string, allergens: vocabulary, ingredients: entries };
}

function readJsonFile(path: string): { ok: true; value: unknown } | { ok: false; reason: string } {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code ?? "unknown";
    return { ok: false, reason: `cannot read ${path} (${code})` };
  }
  if (raw.trim().length === 0) {
    return { ok: false, reason: `${path} is empty` };
  }
  try {
    return { ok: true, value: JSON.parse(raw) };
  } catch (error) {
    return { ok: false, reason: `${path} is not parsable JSON: ${error instanceof Error ? error.message : String(error)}` };
  }
}

/**
 * Loads and validates both packages. Anything less than two valid, non-empty,
 * on-schema documents is `loaded: false` — the caller must fail closed.
 */
export function loadFoodSafetyCatalog(paths: FoodSafetyCatalogPaths): FoodSafetyCatalog {
  const canonFile = readJsonFile(paths.canon);
  if (!canonFile.ok) {
    return closed(`food-safety canon not loaded: ${canonFile.reason}`);
  }
  const factsFile = readJsonFile(paths.facts);
  if (!factsFile.ok) {
    return closed(`ingredient facts not loaded: ${factsFile.reason}`);
  }
  const problems: string[] = [];
  const facts = validateFacts(factsFile.value, problems);
  if (facts === null) {
    return closed(`ingredient facts invalid: ${problems.join("; ")}`);
  }
  const rulebook = validateRulebook(canonFile.value, new Set(facts.allergens), problems);
  if (rulebook === null) {
    return closed(`food-safety canon invalid: ${problems.join("; ")}`);
  }
  return { loaded: true, rulebook, facts };
}
