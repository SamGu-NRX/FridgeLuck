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
 * Both packages carry provenance (PR #104 review blockers 2 and 3): the
 * reviewed branch, commit and file hash the data was copied or derived from,
 * plus a `copiedBlobHash` over the copied data that the loader recomputes at
 * load — a drifted local copy never loads at all. The facts file encodes a
 * review boundary: an ingredient absent from it has UNKNOWN composition, and
 * the gate must treat unknown composition as a screening failure, never as
 * allowed.
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
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const FOOD_SAFETY_CANON_SCHEMA = "fridgeluck/food-safety-canon@v1";
export const INGREDIENT_FACTS_SCHEMA = "fridgeluck/ingredient-facts@v1";

/**
 * The closed food-class vocabulary of the canonical rulebook
 * (overhaul/food-safety-canon, data/food-safety/rules.json): the FSIS class
 * names its doneness rules and per-class cooking-temperature minimums use.
 * A class outside this set is bad data and fails closed.
 */
export const FOOD_SAFETY_CLASSES = [
  "meat_poultry",
  "meat_ground",
  "meat_whole_cut_pork",
  "meat_whole_cut_red",
  "flesh_fish",
  "flesh_shellfish",
  "egg",
  "leftovers",
] as const;

export type FoodSafetyClass = (typeof FOOD_SAFETY_CLASSES)[number];

/** Lineage of the numeric cooking-temperature data copied from the canonical rulebook. */
export interface MinCookingTempProvenance {
  /** The reviewed branch the numbers were copied from. */
  readonly sourceBranch: string;
  /** The data file inside that branch. */
  readonly sourceFile: string;
  /** The commit of that branch the copy was made at. */
  readonly sourceCommit: string;
  /** sha256 of the source file at that commit (`sha256:<hex>`). */
  readonly sourceFileHash: string;
  /** sha256 over the copied minimums+keywords blob (stableCookingTempString), rechecked at load. */
  readonly copiedBlobHash: string;
  /** What was copied, in prose. */
  readonly extracted: string;
}

/**
 * The reviewed per-class cooking-temperature floors (PR #104 review blocker
 * 2). The numbers and the food→class keywords are copied from the canonical
 * rulebook, never a looser local guess; `provenance.copiedBlobHash` is
 * rechecked at load, so a drifted local copy cannot load at all.
 */
export interface MinCookingTempRule {
  readonly kind: "min-cooking-temp";
  readonly id: string;
  readonly message: string;
  /** Minimum internal cooking temperature per food class, °F. */
  readonly minimumsF: Readonly<Record<FoodSafetyClass, number>>;
  /** Reviewed food → class attribution keywords; a longer keyword that contains a shorter one wins. */
  readonly classKeywords: Readonly<Record<FoodSafetyClass, readonly string[]>>;
  readonly provenance: MinCookingTempProvenance;
}

/** Lineage of the ingredient → allergen facts derived from the canonical dataset (blocker 3). */
export interface IngredientFactsProvenance {
  /** The reviewed branch the facts were derived from. */
  readonly sourceBranch: string;
  /** The data file inside that branch the facts were derived from. */
  readonly sourceFile: string;
  /** The commit of that branch the copy was made at. */
  readonly sourceCommit: string;
  /** sha256 of the source file at that commit (`sha256:<hex>`). */
  readonly sourceFileHash: string;
  /** sha256 over the copied entries blob (stableIngredientFactsString), rechecked at load. */
  readonly copiedBlobHash: string;
  /** What was copied — and what was deliberately left unknown — in prose. */
  readonly extracted: string;
}

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
    }
  | MinCookingTempRule;

/**
 * The canonical serialization the provenance hash is computed over: keys
 * sorted, arrays in copied order, no whitespace. The loader recomputes it
 * and refuses data whose hash differs from `provenance.copiedBlobHash`.
 */
export function stableCookingTempString(parts: {
  readonly minimumsF: Readonly<Record<FoodSafetyClass, number>>;
  readonly classKeywords: Readonly<Record<FoodSafetyClass, readonly string[]>>;
}): string {
  const sorted = FOOD_SAFETY_CLASSES.slice().sort();
  return JSON.stringify({
    classKeywords: Object.fromEntries(sorted.map((cls) => [cls, parts.classKeywords[cls]])),
    minimumsF: Object.fromEntries(sorted.map((cls) => [cls, parts.minimumsF[cls]])),
  });
}

/** sha256 hex of a string. */
export function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

/**
 * The canonical serialization the facts provenance hash is computed over
 * (blocker 3): entries in file order, per-entry keys in a fixed order, no
 * whitespace. The loader recomputes it and refuses facts whose hash differs
 * from `provenance.copiedBlobHash`.
 */
export function stableIngredientFactsString(entries: readonly IngredientFactsEntry[]): string {
  return JSON.stringify(entries.map((entry) => ({ id: entry.id, match: [...entry.match], allergens: [...entry.allergens] })));
}

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
  /**
   * Allergen slugs (from the file's own vocabulary), already including
   * compound contributions. EMPTY means the reviewed dataset established the
   * ingredient allergen-free — a known-free ingredient, not an unknown one.
   * An ingredient with no entry here at all is UNKNOWN (never allowed).
   */
  readonly allergens: readonly string[];
}

export interface IngredientFacts {
  readonly schema: string;
  readonly source: string;
  /** The closed allergen vocabulary every entry must draw from. */
  readonly allergens: readonly string[];
  readonly ingredients: readonly IngredientFactsEntry[];
  /** Where these facts came from; the blob hash is rechecked at load (blocker 3). */
  readonly provenance: IngredientFactsProvenance;
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

/** Pattern for a recorded sha256 hash (`sha256:<hex>`). */
const SHA256_HASH = /^sha256:[0-9a-f]{64}$/;

/**
 * Parses a class-keyed map whose keys are exactly the canonical classes —
 * an unknown class or a missing floor both fail closed.
 */
function parseClassMap(value: unknown, what: string, problems: string[]): Record<string, unknown> | null {
  if (!isRecord(value)) {
    problems.push(`${what} must be a JSON object keyed by food class`);
    return null;
  }
  const keys = Object.keys(value).sort();
  const expected = FOOD_SAFETY_CLASSES.slice().map(String).sort();
  if (keys.length !== expected.length || keys.some((k, i) => k !== expected[i])) {
    problems.push(`${what} must carry exactly the canonical classes (${FOOD_SAFETY_CLASSES.join(", ")})`);
    return null;
  }
  return value;
}

/** One provenance field: non-empty string, optionally hash-shaped. */
function provenanceField(provenance: Record<string, unknown>, name: string, what: string, pattern: RegExp | null, problems: string[]): string | null {
  const value = provenance[name];
  if (typeof value !== "string" || value.trim().length === 0 || (pattern !== null && !pattern.test(value))) {
    problems.push(`${what}.provenance.${name} must be a non-empty string${pattern === null ? "" : ` matching ${pattern.source}`}`);
    return null;
  }
  return value;
}

/**
 * The six-field provenance block both packages carry (blockers 2 and 3):
 * the reviewed branch/commit/file the data was copied or derived from, plus
 * a copiedBlobHash the caller rechecks over the copied data at load.
 */
function parseProvenanceBlock(entry: Record<string, unknown>, what: string, problems: string[]): IngredientFactsProvenance | null {
  const provRaw = entry["provenance"];
  if (!isRecord(provRaw)) {
    problems.push(`${what}.provenance must record where the data was copied from`);
    return null;
  }
  const sourceBranch = provenanceField(provRaw, "sourceBranch", what, null, problems);
  const sourceFile = provenanceField(provRaw, "sourceFile", what, null, problems);
  const sourceCommit = provenanceField(provRaw, "sourceCommit", what, null, problems);
  const sourceFileHash = provenanceField(provRaw, "sourceFileHash", what, SHA256_HASH, problems);
  const copiedBlobHash = provenanceField(provRaw, "copiedBlobHash", what, SHA256_HASH, problems);
  const extracted = provenanceField(provRaw, "extracted", what, null, problems);
  if (sourceBranch === null || sourceFile === null || sourceCommit === null || sourceFileHash === null || copiedBlobHash === null || extracted === null) {
    return null;
  }
  return { sourceBranch, sourceFile, sourceCommit, sourceFileHash, copiedBlobHash, extracted };
}

function parseMinCookingTempRule(entry: Record<string, unknown>, id: string, message: string, index: number, problems: string[]): MinCookingTempRule | null {
  const what = `rulebook.rules[${index}]`;
  const minimumsRaw = parseClassMap(entry["minimumsF"], `${what}.minimumsF`, problems);
  if (minimumsRaw === null) {
    return null;
  }
  const minimumsF = {} as Record<FoodSafetyClass, number>;
  for (const cls of FOOD_SAFETY_CLASSES) {
    const value = minimumsRaw[cls];
    if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
      problems.push(`${what}.minimumsF.${cls} must be a positive temperature in °F`);
      return null;
    }
    minimumsF[cls] = value;
  }
  const keywordsRaw = parseClassMap(entry["classKeywords"], `${what}.classKeywords`, problems);
  if (keywordsRaw === null) {
    return null;
  }
  const classKeywords = {} as Record<FoodSafetyClass, string[]>;
  for (const cls of FOOD_SAFETY_CLASSES) {
    const keywords = readNonEmptyStrings(keywordsRaw[cls], `${what}.classKeywords.${cls}`, problems);
    if (keywords.length === 0) {
      return null;
    }
    classKeywords[cls] = keywords;
  }
  const provenance = parseProvenanceBlock(entry, what, problems);
  if (provenance === null) {
    return null;
  }
  // Load-time integrity: the copied numbers must hash to the recorded blob
  // hash. A loosened or drifted local copy never loads — the gate fails
  // closed instead of enforcing looser floors (blocker 2).
  const actualHash = `sha256:${sha256Hex(stableCookingTempString({ classKeywords, minimumsF }))}`;
  if (actualHash !== provenance.copiedBlobHash) {
    problems.push(`${what}.minimumsF/classKeywords do not match the recorded provenance hash — a drifted local copy must not load; re-copy from ${provenance.sourceBranch} at ${provenance.sourceCommit}`);
    return null;
  }
  return { kind: "min-cooking-temp", id, message, minimumsF, classKeywords, provenance };
}

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
      case "min-cooking-temp": {
        const rule = parseMinCookingTempRule(entry, id, message, i, problems);
        if (rule === null) {
          return null;
        }
        rules.push(rule);
        break;
      }
      default:
        problems.push(`rulebook.rules[${i}].kind must be one of forbidden-terms, claim-requires-evidence, allergen-claim, min-cooking-temp`);
        return null;
    }
  }
  // The reviewed per-class cooking-temperature floors are mandatory data,
  // not optional enrichment: a rulebook without them is not the canonical
  // rulebook, and the gate fails closed rather than enforce no floors.
  if (!rules.some((rule) => rule.kind === "min-cooking-temp")) {
    problems.push("rulebook.rules must include a min-cooking-temp rule carrying the reviewed per-class cooking-temperature floors");
    return null;
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
    // allergens may be EMPTY — a reviewed, known allergen-free ingredient.
    // It may not be missing, malformed, or draw outside the vocabulary.
    const allergensRaw = entryRaw["allergens"];
    const allergens = Array.isArray(allergensRaw) ? [...(allergensRaw as string[])] : null;
    if (typeof id !== "string" || id.trim().length === 0 || match.length === 0 || allergens === null || allergens.some((a) => typeof a !== "string" || a.trim().length === 0 || !known.has(a))) {
      problems.push(`ingredient facts ingredients[${i}] must carry an id, a non-empty match list, and an allergens array (possibly empty) drawn from the file's own vocabulary`);
      return null;
    }
    entries.push({ id, match, allergens });
  }
  // Provenance + load-time integrity (blocker 3, mirroring blocker 2): the
  // copied entries must hash to the recorded blob hash, so a drifted local
  // copy never loads — the gate cannot tag from data nobody reviewed.
  const provenance = parseProvenanceBlock(raw, "ingredient facts", problems);
  if (provenance === null) {
    return null;
  }
  const actualHash = `sha256:${sha256Hex(stableIngredientFactsString(entries))}`;
  if (actualHash !== provenance.copiedBlobHash) {
    problems.push(`ingredient facts ingredients do not match the recorded provenance hash — a drifted local copy must not load; re-derive from ${provenance.sourceBranch} at ${provenance.sourceCommit}`);
    return null;
  }
  return { schema: INGREDIENT_FACTS_SCHEMA, source: raw["source"] as string, allergens: vocabulary, ingredients: entries, provenance };
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
