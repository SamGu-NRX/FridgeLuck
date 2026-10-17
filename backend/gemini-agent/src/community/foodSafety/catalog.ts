/**
 * The food-safety data seam (SPEC 3.1, 3.5, 6; PR #104 review blocker 1).
 *
 * Publishing is gated on TWO data packages, both mandatory:
 *
 *   - the canonical food-safety rulebook (`overhaul/food-safety-canon`),
 *     loaded from `canon.json` — the mechanical rules a recipe text must
 *     satisfy (doneness evidence, advisory-sourcing, allergen-claim rules);
 *   - the ingredient facts: the PUBLISHED FLIngredientFacts dataset
 *     (`overhaul/ingredient-facts`, PR #127), vendored BYTE-FOR-BYTE under
 *     `data/ingredient-facts/` by scripts/vendor-ingredient-facts.ts — the
 *     backend does not re-derive it.
 *
 * The gate is FAIL-CLOSED: absence, emptiness, unparsable JSON, a schema
 * violation, or vendored bytes that fail their provenance pins is never a
 * warning — the catalog reports itself not loaded and publishing is refused
 * outright (error envelope, nothing persisted). A publication is never
 * created on absent safety data.
 *
 * Round-three rescope of PR #104 review blocker 3 — the fact semantics below
 * are the dataset's own (the ones its conformance runner enforces, replayed
 * against the vendored conformance cases in the suite):
 *
 *   - A missing axis stays UNKNOWN. It is never an empty known set, so
 *     barley (no reviewed allergen axes) and beef stock (no reviewed
 *     allergen axes, violated diet facts) cannot masquerade as
 *     allergen-free.
 *   - UNKNOWN blocks every free-from claim AND every diet claim: an
 *     ingredient reaches the gate-facing list only when every axis in the
 *     tag namespace (the nine FDA allergens plus the gluten property,
 *     asserted directly) is reviewed in the published data; anything less
 *     stays out, and the gate fails closed on its lines. Diet facts ride the
 *     dataset and evaluate through the same published semantics — an
 *     unknown diet axis is never a pass.
 *
 * Locations, in precedence order (documented contract for the packages when
 * they land):
 *   1. explicit paths passed to the loader;
 *   2. `FOOD_SAFETY_CANON_PATH` / `FOOD_SAFETY_FACTS_PATH` env vars;
 *   3. `<data root>/data/food-safety/canon.json` and
 *      `<data root>/data/ingredient-facts/facts.json`, where the data root
 *      is `FOOD_SAFETY_DATA_ROOT` or the nearest ancestor of the working
 *      directory that has a `data` directory (the repo root when run from
 *      `backend/gemini-agent`).
 */
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const FOOD_SAFETY_CANON_SCHEMA = "fridgeluck/food-safety-canon@v1";

/**
 * The ingredient-facts seam version. @v2 is the PUBLISHED dataset vendored
 * byte-for-byte (round-three rescope of blocker 3); @v1 was the derived
 * allergen-presence projection that turned missing axes into empty known
 * sets and dropped the gluten and diet axes.
 */
export const INGREDIENT_FACTS_SCHEMA = "fridgeluck/ingredient-facts@v2";

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

// ————————————————————————————————————————————————————————————————————————————————————————————————
// The published FLIngredientFacts dataset (vendored byte-for-byte; PR #104
// review blocker 3, round three). The backend consumes the data AS PUBLISHED:
// the evaluation semantics below mirror the dataset's own conformance runner
// (data/ingredient-facts/conformance/runners/typescript, on the source
// branch) and the vendored conformance cases replay against them in the
// suite.
// ————————————————————————————————————————————————————————————————————————————————————————————————

/** The nine FDA major allergens, as the dataset's canonical axis keys. */
const ALLERGEN_AXES = [
  "milk",
  "egg",
  "fish",
  "crustaceanShellfish",
  "treeNuts",
  "peanuts",
  "wheat",
  "soy",
  "sesame",
] as const;

/**
 * The dataset's diet axes, as its canonical keys. Diet facts ride the
 * dataset and evaluate through the published semantics; they are not part
 * of the gate's tag namespace (the canon's claim rules reference allergens).
 */
const DIET_AXES = ["vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree"] as const;

export type AllergenAxis = (typeof ALLERGEN_AXES)[number];
export type DietAxis = (typeof DIET_AXES)[number];

const ALLERGEN_AXIS_SET: ReadonlySet<string> = new Set(ALLERGEN_AXES);
const DIET_AXIS_SET: ReadonlySet<string> = new Set(DIET_AXES);

/** Dataset axis key → backend tag slug. */
const ALLERGEN_AXIS_SLUGS: Readonly<Record<AllergenAxis, string>> = {
  milk: "milk",
  egg: "egg",
  fish: "fish",
  crustaceanShellfish: "crustacean-shellfish",
  treeNuts: "tree-nuts",
  peanuts: "peanuts",
  wheat: "wheat",
  soy: "soy",
  sesame: "sesame",
};

/** The gluten property sits beside the nine FDA axes in the same tag namespace. */
const GLUTEN_AXIS_SLUG = "gluten";

/** The closed tag vocabulary the canon's allergen-claim rules may reference. */
export const INGREDIENT_FACTS_TAG_VOCABULARY: readonly string[] = [
  ...Object.values(ALLERGEN_AXIS_SLUGS),
  GLUTEN_AXIS_SLUG,
].sort();

/** A reviewed fact's state, as published. */
export type FactState = "contains" | "free" | "unknown" | "allowed" | "violated";

export interface FactEvidence {
  readonly kind: string;
  readonly ref: string;
  readonly note: string;
}

export interface FactObject {
  readonly state: FactState;
  readonly evidence?: FactEvidence;
}

export interface FactComponent {
  readonly key: string;
  readonly certainty: "certain" | "typical" | "variable" | "unknown";
  readonly evidence?: FactEvidence;
}

export interface FactFormOverride {
  readonly key?: string;
  readonly allergens?: Readonly<Record<string, FactObject>>;
  readonly gluten?: FactObject;
  readonly diets?: Readonly<Record<string, FactObject>>;
}

/** A published fact entry, verbatim in shape. */
export interface FactEntry {
  readonly key: string;
  readonly class?: string;
  readonly note?: string;
  readonly components?: readonly FactComponent[];
  readonly compositionComplete?: boolean;
  readonly allergens?: Readonly<Record<string, FactObject>>;
  readonly gluten?: FactObject;
  readonly diets?: Readonly<Record<string, FactObject>>;
  readonly forms?: Readonly<Record<string, FactFormOverride>>;
}

export interface FactForm {
  readonly key: string;
  readonly display: string;
  readonly synonyms?: readonly string[];
}

export interface FactIdentity {
  readonly key: string;
  readonly display: string;
  readonly kind?: string;
  readonly synonyms?: readonly string[];
  readonly forms?: readonly FactForm[];
}

/** One claim axis to evaluate: one allergen axis or one diet axis. */
export type FactRestriction = { readonly allergen: AllergenAxis } | { readonly diet: DietAxis };

/** The restriction set the evaluator takes, mirroring the published runner. */
export interface FactRestrictions {
  readonly allergens: ReadonlySet<AllergenAxis>;
  readonly diets: ReadonlySet<DietAxis>;
}

/**
 * The published evaluation contract, mirrored from the dataset's conformance
 * runner: an evaluation is allowed (with the evidence that supports it),
 * violated (with the first violation and its evidence), or UNKNOWN — and an
 * unknown axis never reads as a pass.
 */
export type FactEvaluation =
  | { readonly result: "allowed"; readonly evidence: readonly FactEvidence[] }
  | {
      readonly result: "violated";
      readonly violation: {
        readonly ingredient: string;
        readonly restriction: FactRestriction;
        readonly reason: string;
        readonly evidence: readonly FactEvidence[];
      };
    }
  | {
      readonly result: "unknown";
      readonly unknown: {
        readonly ingredient: string;
        readonly restriction: FactRestriction;
        readonly missing: readonly string[];
        readonly reason: string;
      };
    };

/** The validated published dataset plus its name indexes. */
export interface IngredientFactsDataset {
  readonly facts: Readonly<Record<string, FactEntry>>;
  readonly identities: readonly FactIdentity[];
  readonly displayName: Readonly<Record<string, string>>;
  readonly nameIndex: Readonly<Record<string, string>>;
  readonly formIndex: Readonly<Record<string, { readonly identity: string; readonly form: string }>>;
}

/** One vendored file's pin: its published relative path and exact-byte hash. */
export interface IngredientFactsSourceFile {
  readonly path: string;
  readonly sha256: string;
}

/**
 * Provenance of the vendored facts package (blocker 3, round three): the
 * published branch and commit the bytes were vendored from plus a
 * `sha256:<hex>` pin per vendored file, recorded by
 * scripts/vendor-ingredient-facts.ts and re-verified at load. A missing,
 * unparsable, or mismatched manifest fails the gate closed.
 */
export interface IngredientFactsProvenance {
  readonly sourceBranch: string;
  readonly sourceCommit: string;
  readonly files: readonly IngredientFactsSourceFile[];
  /** What was vendored, in prose. */
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

/** sha256 hex over raw bytes — the vendored-facts pins are over exact bytes. */
function sha256HexBytes(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

export interface FoodSafetyRulebook {
  readonly schema: string;
  /** Where the rulebook came from (the package should name its reviewed source). */
  readonly source: string;
  readonly rules: readonly FoodSafetyRule[];
}

/**
 * One gate-facing entry: the ingredient resolves by `match`, and `allergens`
 * lists — PRESENCE ONLY — the reviewed allergens it contains, as slugs from
 * the tag vocabulary. An entry exists ONLY when every axis in the tag
 * namespace is reviewed in the published data (a missing axis stays unknown
 * and can never read as an empty known set), so an entry with an empty
 * `allergens` is a reviewed, known allergen-free ingredient. An ingredient
 * with no entry here at all is UNKNOWN (never allowed).
 */
export interface IngredientFactsEntry {
  readonly id: string;
  /** Lowercase names/phrases this ingredient goes by; multi-word phrases are matched as such. */
  readonly match: readonly string[];
  readonly allergens: readonly string[];
}

export interface IngredientFacts {
  readonly schema: string;
  readonly source: string;
  /** The closed allergen vocabulary every entry must draw from. */
  readonly allergens: readonly string[];
  readonly ingredients: readonly IngredientFactsEntry[];
  /** Where these facts came from; the vendored bytes are reverified at load (blocker 3). */
  readonly provenance: IngredientFactsProvenance;
  /** The validated published dataset the projection was resolved from. */
  readonly dataset: IngredientFactsDataset;
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
 * closed catalog ("absent data") rather than a resolution error. The facts
 * path points at the vendored published package's facts.json.
 */
export function resolveFoodSafetyCatalogPaths(options: ResolveFoodSafetyPathsOptions = {}): FoodSafetyCatalogPaths {
  const env = options.env ?? process.env;
  const root = options.dataRoot ?? env["FOOD_SAFETY_DATA_ROOT"] ?? defaultDataRoot(options.cwd ?? process.cwd());
  return {
    canon: env["FOOD_SAFETY_CANON_PATH"] ?? join(root, "data", "food-safety", "canon.json"),
    facts: env["FOOD_SAFETY_FACTS_PATH"] ?? join(root, "data", "ingredient-facts", "facts.json"),
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
 * The six-field provenance block the min-cooking-temp rule carries
 * (blocker 2): the reviewed branch/commit/file the numbers were copied
 * from, plus a copiedBlobHash the loader rechecks over the copied data at
 * load. (The ingredient facts carry their own vendored-package manifest;
 * see IngredientFactsProvenance.)
 */
function parseProvenanceBlock(entry: Record<string, unknown>, what: string, problems: string[]): MinCookingTempProvenance | null {
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

// ————— vendored package loading: manifest verification + published-format validation —————

/** The files the vendored package must pin and load (cases.json is the published conformance suite the suite replays). */
const REQUIRED_VENDORED_FILES = ["facts.json", "identities.json"] as const;

const FACT_EVIDENCE_KINDS = new Set(["usda", "label", "reference", "recipe", "standard"]);
const FACT_CERTAINTIES = new Set(["certain", "typical", "variable", "unknown"]);
const FACT_STATES = new Set(["contains", "free", "unknown", "allowed", "violated"]);
/** The dataset package publishes this identity without a fact entry (its own load-time exemption). */
const FACTLESS_IDENTITY_EXEMPTIONS = new Set(["artisan-granola-bar"]);
/** The dataset's conformance runner recursion cap for compound composition. */
const FACT_EVALUATION_DEPTH_LIMIT = 8;

function checkFactEvidence(evidence: FactEvidence, where: string, problems: string[]): void {
  if (!FACT_EVIDENCE_KINDS.has(evidence.kind)) {
    problems.push(`${where}: bad evidence kind '${evidence.kind}'`);
  }
  if (evidence.ref.trim().length === 0) {
    problems.push(`${where}: evidence ref must be a non-empty string`);
  }
  if (evidence.note.trim().length === 0) {
    problems.push(`${where}: evidence note must be a non-empty string`);
  }
}

/**
 * Parses one reviewed fact. Evidence discipline as published: unknown facts
 * carry no evidence obligation (and may carry an optional note via evidence);
 * every settled state needs complete evidence; an absence state may never
 * lean on usda or recipe evidence.
 */
function parseFactObject(value: unknown, where: string, problems: string[]): FactObject | null {
  if (!isRecord(value)) {
    problems.push(`${where}: fact must be an object`);
    return null;
  }
  const rawState = value["state"];
  if (typeof rawState !== "string" || !FACT_STATES.has(rawState)) {
    problems.push(`${where}: bad state '${String(rawState)}'`);
    return null;
  }
  const state = rawState as FactState;
  if (state === "unknown" && value["evidence"] === undefined) {
    return { state };
  }
  if (value["evidence"] === undefined) {
    problems.push(`${where}: ${state} fact lacks evidence`);
    return null;
  }
  const rawEvidence = value["evidence"];
  if (!isRecord(rawEvidence)) {
    problems.push(`${where}: evidence must be an object`);
    return null;
  }
  const kind = rawEvidence["kind"];
  const ref = rawEvidence["ref"];
  const note = rawEvidence["note"];
  if (typeof kind !== "string" || typeof ref !== "string" || typeof note !== "string") {
    problems.push(`${where}: incomplete evidence`);
    return null;
  }
  const evidence: FactEvidence = { kind, ref, note };
  checkFactEvidence(evidence, where, problems);
  if ((state === "free" || state === "allowed") && (kind === "usda" || kind === "recipe")) {
    problems.push(`${where}: absence state '${state}' may not use '${kind}' evidence`);
  }
  return { state, evidence };
}

/** Parses an axis-keyed fact map (allergens or diets), or undefined when absent. */
function parseFactAxisMap(value: unknown, axes: ReadonlySet<string>, where: string, problems: string[]): Record<string, FactObject> | null | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!isRecord(value)) {
    problems.push(`${where} must be an object`);
    return null;
  }
  const out: Record<string, FactObject> = {};
  for (const [axis, factRaw] of Object.entries(value)) {
    if (!axes.has(axis)) {
      problems.push(`${where}: unknown axis '${axis}'`);
      return null;
    }
    const fact = parseFactObject(factRaw, `${where}.${axis}`, problems);
    if (fact === null) {
      return null;
    }
    out[axis] = fact;
  }
  return out;
}

function parseFactEntry(key: string, value: unknown, problems: string[]): FactEntry | null {
  const where = `facts.${key}`;
  if (!isRecord(value)) {
    problems.push(`${where}: entry must be an object`);
    return null;
  }
  if (value["key"] !== key) {
    problems.push(`fact entry key mismatch: ${key} vs ${String(value["key"])}`);
    return null;
  }
  const allergens = parseFactAxisMap(value["allergens"], ALLERGEN_AXIS_SET, `${where}.allergens`, problems);
  if (allergens === null) {
    return null;
  }
  const diets = parseFactAxisMap(value["diets"], DIET_AXIS_SET, `${where}.diets`, problems);
  if (diets === null) {
    return null;
  }
  let gluten: FactObject | undefined;
  if (value["gluten"] !== undefined) {
    const parsed = parseFactObject(value["gluten"], `${where}.gluten`, problems);
    if (parsed === null) {
      return null;
    }
    gluten = parsed;
  }
  const forms: Record<string, FactFormOverride> = {};
  if (value["forms"] !== undefined) {
    if (!isRecord(value["forms"])) {
      problems.push(`${where}.forms must be an object`);
      return null;
    }
    for (const [formName, overrideRaw] of Object.entries(value["forms"])) {
      if (!isRecord(overrideRaw)) {
        problems.push(`${where}.forms.${formName}: override must be an object`);
        return null;
      }
      const overrideAllergens = parseFactAxisMap(overrideRaw["allergens"], ALLERGEN_AXIS_SET, `${where}.forms.${formName}.allergens`, problems);
      if (overrideAllergens === null) {
        return null;
      }
      const overrideDiets = parseFactAxisMap(overrideRaw["diets"], DIET_AXIS_SET, `${where}.forms.${formName}.diets`, problems);
      if (overrideDiets === null) {
        return null;
      }
      let overrideGluten: FactObject | undefined;
      if (overrideRaw["gluten"] !== undefined) {
        const parsed = parseFactObject(overrideRaw["gluten"], `${where}.forms.${formName}.gluten`, problems);
        if (parsed === null) {
          return null;
        }
        overrideGluten = parsed;
      }
      forms[formName] = {
        key: typeof overrideRaw["key"] === "string" ? overrideRaw["key"] : undefined,
        allergens: overrideAllergens === undefined ? undefined : overrideAllergens,
        gluten: overrideGluten,
        diets: overrideDiets === undefined ? undefined : overrideDiets,
      };
    }
  }
  const components: FactComponent[] = [];
  if (value["components"] !== undefined) {
    if (!Array.isArray(value["components"])) {
      problems.push(`${where}.components must be an array`);
      return null;
    }
    for (const [i, componentRaw] of (value["components"] as unknown[]).entries()) {
      if (!isRecord(componentRaw)) {
        problems.push(`${where}.components[${i}] must be an object`);
        return null;
      }
      const componentKey = componentRaw["key"];
      if (typeof componentKey !== "string" || componentKey.trim().length === 0) {
        problems.push(`${where}.components[${i}].key must be a non-empty string`);
        return null;
      }
      const certainty = componentRaw["certainty"];
      if (typeof certainty !== "string" || !FACT_CERTAINTIES.has(certainty)) {
        problems.push(`${where}: bad certainty '${String(certainty)}'`);
        return null;
      }
      let componentEvidence: FactEvidence | undefined;
      if (componentRaw["evidence"] !== undefined) {
        if (!isRecord(componentRaw["evidence"])) {
          problems.push(`${where}.components[${i}].evidence must be an object`);
          return null;
        }
        const kind = componentRaw["evidence"]["kind"];
        const ref = componentRaw["evidence"]["ref"];
        const note = componentRaw["evidence"]["note"];
        if (typeof kind !== "string" || typeof ref !== "string" || typeof note !== "string") {
          problems.push(`${where}.components[${i}]: incomplete evidence`);
          return null;
        }
        componentEvidence = { kind, ref, note };
        checkFactEvidence(componentEvidence, `${where}.components.${componentKey}`, problems);
      }
      if (certainty !== "unknown" && componentEvidence === undefined) {
        problems.push(`${where}: component '${componentKey}' lacks evidence`);
        return null;
      }
      components.push({ key: componentKey, certainty: certainty as FactComponent["certainty"], evidence: componentEvidence });
    }
  }
  const compositionComplete = value["compositionComplete"];
  if (compositionComplete !== undefined && typeof compositionComplete !== "boolean") {
    problems.push(`${where}.compositionComplete must be a boolean`);
    return null;
  }
  return {
    key,
    class: typeof value["class"] === "string" ? value["class"] : undefined,
    note: typeof value["note"] === "string" ? value["note"] : undefined,
    components: components.length > 0 ? components : undefined,
    compositionComplete: typeof compositionComplete === "boolean" ? compositionComplete : undefined,
    allergens: allergens === undefined ? undefined : allergens,
    gluten,
    diets: diets === undefined ? undefined : diets,
    forms: Object.keys(forms).length > 0 ? forms : undefined,
  };
}

function parsePublishedFactsDoc(doc: unknown, problems: string[]): Record<string, FactEntry> | null {
  if (!isRecord(doc)) {
    problems.push("facts.json must be a JSON object");
    return null;
  }
  if (doc["version"] !== 1) {
    problems.push("facts.json version must be 1");
    return null;
  }
  const factsRaw = doc["facts"];
  if (!isRecord(factsRaw) || Object.keys(factsRaw).length === 0) {
    problems.push("facts.json is empty");
    return null;
  }
  const facts: Record<string, FactEntry> = {};
  for (const [key, entryRaw] of Object.entries(factsRaw)) {
    const entry = parseFactEntry(key, entryRaw, problems);
    if (entry === null) {
      return null;
    }
    facts[key] = entry;
  }
  return facts;
}

/**
 * Parses identities.json and builds the name indexes exactly as the
 * published runner does: identity keys, displays and synonyms resolve to
 * the identity; form synonyms resolve to (identity, form) and must not
 * collide with any identity name.
 */
function parsePublishedIdentitiesDoc(value: unknown, facts: Record<string, FactEntry>, problems: string[]): Omit<IngredientFactsDataset, "facts"> | null {
  if (!isRecord(value)) {
    problems.push("identities.json must be a JSON object");
    return null;
  }
  if (value["version"] !== 1) {
    problems.push("identities.json version must be 1");
    return null;
  }
  if (!Array.isArray(value["ingredients"]) || (value["ingredients"] as unknown[]).length === 0) {
    problems.push("identities.json is empty");
    return null;
  }
  const identities: FactIdentity[] = [];
  const displayName: Record<string, string> = {};
  const nameIndex: Record<string, string> = {};
  const formIndex: Record<string, { identity: string; form: string }> = {};
  const seenKeys = new Set<string>();
  const indexName = (raw: unknown, key: string, where: string): boolean => {
    if (typeof raw !== "string") {
      problems.push(`${where}: name must be a string`);
      return false;
    }
    const name = raw.trim().toLowerCase();
    if (name.length === 0) {
      problems.push(`${where}: blank name`);
      return false;
    }
    const existing = nameIndex[name];
    if (existing !== undefined) {
      if (existing !== key) {
        problems.push(`name '${raw}' maps to both ${existing} and ${key}`);
        return false;
      }
      return true;
    }
    nameIndex[name] = key;
    return true;
  };
  const indexFormName = (raw: unknown, identity: string, form: string, where: string): boolean => {
    if (typeof raw !== "string") {
      problems.push(`${where}: name must be a string`);
      return false;
    }
    const name = raw.trim().toLowerCase();
    if (name.length === 0) {
      problems.push(`${where}: blank name`);
      return false;
    }
    if (formIndex[name] !== undefined || nameIndex[name] !== undefined) {
      problems.push(`match name '${raw}' is not unique (identity ${identity}, form ${form})`);
      return false;
    }
    formIndex[name] = { identity, form };
    nameIndex[name] = identity;
    return true;
  };
  for (const [i, raw] of (value["ingredients"] as unknown[]).entries()) {
    if (!isRecord(raw)) {
      problems.push(`identities[${i}] must be an object`);
      return null;
    }
    const key = raw["key"];
    if (typeof key !== "string" || key.trim().length === 0) {
      problems.push(`identities[${i}]: missing key`);
      return null;
    }
    if (seenKeys.has(key)) {
      problems.push(`duplicate identity key '${key}'`);
      return null;
    }
    seenKeys.add(key);
    if (facts[key] === undefined && !FACTLESS_IDENTITY_EXEMPTIONS.has(key)) {
      problems.push(`identity '${key}' has no fact entry`);
      return null;
    }
    const display = raw["display"];
    if (typeof display !== "string" || display.trim().length === 0) {
      problems.push(`identities[${i}].display must be a non-empty string`);
      return null;
    }
    displayName[key] = display;
    if (!indexName(key, key, `identities[${i}].key`)) {
      return null;
    }
    if (!indexName(display, key, `identities[${i}].display`)) {
      return null;
    }
    const synonyms = raw["synonyms"];
    if (synonyms !== undefined) {
      if (!Array.isArray(synonyms)) {
        problems.push(`identities[${i}].synonyms must be an array`);
        return null;
      }
      for (const [j, synonym] of synonyms.entries()) {
        if (!indexName(synonym, key, `identities[${i}].synonyms[${j}]`)) {
          return null;
        }
      }
    }
    const parsedForms: FactForm[] = [];
    const forms = raw["forms"];
    if (forms !== undefined) {
      if (!Array.isArray(forms)) {
        problems.push(`identities[${i}].forms must be an array`);
        return null;
      }
      for (const [j, formRaw] of forms.entries()) {
        if (!isRecord(formRaw)) {
          problems.push(`identities[${i}].forms[${j}] must be an object`);
          return null;
        }
        const formKey = formRaw["key"];
        if (typeof formKey !== "string" || formKey.trim().length === 0) {
          problems.push(`identities[${i}].forms[${j}]: missing key`);
          return null;
        }
        const formDisplay = formRaw["display"];
        if (typeof formDisplay !== "string" || formDisplay.trim().length === 0) {
          problems.push(`identities[${i}].forms[${j}].display must be a non-empty string`);
          return null;
        }
        const formSynonyms = formRaw["synonyms"];
        if (formSynonyms !== undefined) {
          if (!Array.isArray(formSynonyms)) {
            problems.push(`identities[${i}].forms[${j}].synonyms must be an array`);
            return null;
          }
          for (const [k, synonym] of formSynonyms.entries()) {
            if (!indexFormName(synonym, key, formKey, `identities[${i}].forms[${j}].synonyms[${k}]`)) {
              return null;
            }
          }
        }
        if (facts[key]?.forms?.[formKey] === undefined) {
          problems.push(`identity '${key}' form '${formKey}' has no fact override`);
          return null;
        }
        parsedForms.push({ key: formKey, display: formDisplay, synonyms: Array.isArray(formSynonyms) ? (formSynonyms as string[]) : undefined });
      }
    }
    identities.push({
      key,
      display,
      kind: typeof raw["kind"] === "string" ? raw["kind"] : undefined,
      synonyms: Array.isArray(synonyms) ? (synonyms as string[]) : undefined,
      forms: parsedForms.length > 0 ? parsedForms : undefined,
    });
  }
  // Every compound's component keys must resolve (the runner checks this).
  for (const [key, entry] of Object.entries(facts)) {
    for (const component of entry.components ?? []) {
      if (facts[component.key] === undefined) {
        problems.push(`${key}: component key '${component.key}' does not resolve`);
        return null;
      }
    }
  }
  return { identities, displayName, nameIndex, formIndex };
}

// ————— the published evaluator (a faithful port of the dataset's conformance runner) —————

function orderedFactRestrictions(restrictions: FactRestrictions): FactRestriction[] {
  return ALLERGEN_AXES.filter((axis) => restrictions.allergens.has(axis))
    .map((axis) => ({ allergen: axis }) as FactRestriction)
    .concat(DIET_AXES.filter((diet) => restrictions.diets.has(diet)).map((diet) => ({ diet }) as FactRestriction));
}

function evaluateFactEntry(dataset: IngredientFactsDataset, entry: FactEntry, form: string | null, restrictions: FactRestrictions, ingredientLabel: string, depth: number): FactEvaluation {
  const violations: Array<{ ingredient: string; restriction: FactRestriction; reason: string; evidence: FactEvidence[] }> = [];
  const unknownMissing: string[] = [];
  const unknownAllergens = new Set<AllergenAxis>();
  const unknownDiets = new Set<DietAxis>();
  const allowedEvidence: FactEvidence[] = [];
  let unknownRestriction: FactRestriction | null = null;

  const factFor = (restriction: FactRestriction): FactObject | undefined => {
    const override = form === null ? undefined : entry.forms?.[form];
    if ("allergen" in restriction) {
      return override?.allergens?.[restriction.allergen] ?? entry.allergens?.[restriction.allergen];
    }
    return override?.diets?.[restriction.diet] ?? entry.diets?.[restriction.diet];
  };

  const recordUnknown = (restriction: FactRestriction, note?: string): void => {
    if (unknownRestriction === null) {
      unknownRestriction = restriction;
    }
    const what =
      "allergen" in restriction
        ? `allergen '${restriction.allergen}' fact for '${entry.key}' is missing or unknown`
        : `diet '${restriction.diet}' fact for '${entry.key}' is missing or unknown`;
    unknownMissing.push(note === undefined ? what : `${what} — ${note}`);
    if ("allergen" in restriction) {
      unknownAllergens.add(restriction.allergen);
    } else {
      unknownDiets.add(restriction.diet);
    }
  };

  const violationReason = (restriction: FactRestriction): string =>
    "allergen" in restriction
      ? `'${ingredientLabel}' contains the allergen '${restriction.allergen}'`
      : `'${ingredientLabel}' is not compatible with the ${restriction.diet} diet`;

  for (const restriction of orderedFactRestrictions(restrictions)) {
    const fact = factFor(restriction);
    const state = fact?.state;
    if (state === "contains" || state === "violated") {
      if (fact?.evidence !== undefined) {
        violations.push({ ingredient: ingredientLabel, restriction, reason: violationReason(restriction), evidence: [fact.evidence] });
      }
    } else if (state === "free" || state === "allowed") {
      if (fact?.evidence !== undefined) {
        allowedEvidence.push(fact.evidence);
      }
    } else if (state === "unknown") {
      recordUnknown(restriction, fact?.evidence?.note);
    } else {
      recordUnknown(restriction);
    }
  }

  if (violations.length > 0) {
    return { result: "violated", violation: violations[0] as { ingredient: string; restriction: FactRestriction; reason: string; evidence: FactEvidence[] } };
  }

  const components = entry.components ?? [];
  if (unknownMissing.length > 0 && depth < FACT_EVALUATION_DEPTH_LIMIT && components.length > 0) {
    const componentUnknowns: string[] = [];
    for (const component of components) {
      const componentLabel = `'${component.key}' in '${entry.key}'`;
      const componentEntry = dataset.facts[component.key];
      if (componentEntry === undefined) {
        componentUnknowns.push(`composition of ${componentLabel} is unrecorded`);
        continue;
      }
      if (component.certainty === "certain" || component.certainty === "typical") {
        const sub = evaluateFactEntry(dataset, componentEntry, null, restrictions, component.key, depth + 1);
        if (sub.result === "violated") {
          const evidence = [...sub.violation.evidence];
          if (component.evidence !== undefined) {
            evidence.push(component.evidence);
          }
          return {
            result: "violated",
            violation: {
              ingredient: ingredientLabel,
              restriction: sub.violation.restriction,
              reason: `component ${sub.violation.reason}`,
              evidence,
            },
          };
        }
        if (sub.result === "unknown") {
          componentUnknowns.push(`component ${component.key}: ${sub.unknown.missing.join("; ")}`);
        } else {
          allowedEvidence.push(...sub.evidence);
        }
      } else if (component.certainty === "variable") {
        // Presence varies: a violation only means SOME products carry it,
        // which is unknown, not violated.
        const sub = evaluateFactEntry(dataset, componentEntry, null, restrictions, component.key, depth + 1);
        if (sub.result === "violated") {
          componentUnknowns.push(`whether ${componentLabel} is present varies by product; when present it ${sub.violation.reason}`);
        } else if (sub.result === "unknown") {
          componentUnknowns.push(`component ${component.key} (presence varies): ${sub.unknown.missing.join("; ")}`);
        } else {
          allowedEvidence.push(...sub.evidence);
        }
      } else {
        componentUnknowns.push(`composition of ${componentLabel} is unverified (certainty unknown)`);
      }
    }
    const fallbackRestriction: FactRestriction = unknownRestriction ?? orderedFactRestrictions(restrictions)[0] ?? { allergen: "milk" };
    if (componentUnknowns.length > 0) {
      return {
        result: "unknown",
        unknown: {
          ingredient: ingredientLabel,
          restriction: fallbackRestriction,
          missing: [...unknownMissing, ...componentUnknowns],
          reason: "compound composition leaves restrictions undecided",
        },
      };
    }
    if (unknownAllergens.size === 0 || entry.compositionComplete === true) {
      return { result: "allowed", evidence: allowedEvidence };
    }
    return {
      result: "unknown",
      unknown: {
        ingredient: ingredientLabel,
        restriction: fallbackRestriction,
        missing: [...unknownMissing, `composition of '${entry.key}' is incomplete`],
        reason: "composition is not known to be complete",
      },
    };
  }

  if (unknownMissing.length === 0) {
    return { result: "allowed", evidence: allowedEvidence };
  }
  return {
    result: "unknown",
    unknown: {
      ingredient: ingredientLabel,
      restriction: unknownRestriction ?? orderedFactRestrictions(restrictions)[0] ?? { allergen: "milk" },
      missing: unknownMissing,
      reason: "facts do not settle the restricted properties",
    },
  };
}

/**
 * Evaluates named restrictions on an ingredient by name, exactly as the
 * published runner does: an unresolved name and an unfactored identity both
 * fail closed as unknown — never as allowed.
 */
export function evaluateIngredient(dataset: IngredientFactsDataset, name: string, restrictions: FactRestrictions): FactEvaluation {
  const folded = name.trim().toLowerCase();
  const resolvedKey = dataset.nameIndex[folded];
  const formRecord = dataset.formIndex[folded];
  const fallbackRestriction: FactRestriction = orderedFactRestrictions(restrictions)[0] ?? { allergen: "milk" };
  if (resolvedKey === undefined) {
    return {
      result: "unknown",
      unknown: {
        ingredient: name,
        restriction: fallbackRestriction,
        missing: [`ingredient '${name}' is not in the dataset`],
        reason: "unresolved ingredient: evaluation fails closed",
      },
    };
  }
  const entry = dataset.facts[resolvedKey];
  if (entry === undefined) {
    return {
      result: "unknown",
      unknown: {
        ingredient: name,
        restriction: fallbackRestriction,
        missing: [`no facts exist for '${resolvedKey}'`],
        reason: "unfactored ingredient: evaluation fails closed",
      },
    };
  }
  const label = dataset.displayName[resolvedKey] ?? name;
  return evaluateFactEntry(dataset, entry, formRecord?.form ?? null, restrictions, label, 0);
}

// ————— the gate-facing projection —————

/**
 * The gluten property, resolved by direct published assertion only (with the
 * form override): the published runners define no gluten restriction, so
 * nothing may be inferred into it — an unasserted gluten axis stays unknown
 * and excludes the ingredient from the gate-facing list.
 */
function resolveGlutenFact(entry: FactEntry, form: string | null): FactObject | undefined {
  const override = form === null ? undefined : entry.forms?.[form];
  return override?.gluten ?? entry.gluten;
}

function collectNames(key: string | undefined, display: string | undefined, synonyms: readonly string[] | undefined): string[] {
  const names = new Set<string>();
  for (const raw of [key, display, ...(synonyms ?? [])]) {
    if (typeof raw === "string") {
      const name = raw.trim().toLowerCase();
      if (name.length > 0) {
        names.add(name);
      }
    }
  }
  return [...names];
}

/**
 * Projects one identity (or one form) into the gate's tag namespace, or
 * null when it may not surface as covered. The gate's model is binary per
 * ingredient line (covered ⟹ the entry's tags are the whole truth), so an
 * ingredient may surface as covered ONLY when every axis in the tag
 * namespace is reviewed in the published data: each allergen axis through
 * the published evaluator (which resolves compound composition and per-form
 * overrides), and the gluten property by direct assertion. Anything less
 * stays absent — unknown composition fails closed, and never reads as an
 * empty known set.
 */
function projectFactAxes(dataset: IngredientFactsDataset, entry: FactEntry, form: string | null): string[] | null {
  const tags = new Set<string>();
  for (const axis of ALLERGEN_AXES) {
    const evaluation = evaluateFactEntry(dataset, entry, form, { allergens: new Set([axis]), diets: new Set() }, entry.key, 0);
    if (evaluation.result === "unknown") {
      return null;
    }
    if (evaluation.result === "violated") {
      tags.add(ALLERGEN_AXIS_SLUGS[axis]);
    }
  }
  const gluten = resolveGlutenFact(entry, form);
  if (gluten === undefined || gluten.state === "unknown") {
    return null;
  }
  if (gluten.state === "contains" || gluten.state === "violated") {
    tags.add(GLUTEN_AXIS_SLUG);
  }
  return [...tags].sort();
}

function projectIngredientFacts(dataset: IngredientFactsDataset): IngredientFactsEntry[] {
  const projected: IngredientFactsEntry[] = [];
  for (const identity of dataset.identities) {
    const entry = dataset.facts[identity.key];
    if (entry === undefined) {
      // The dataset's own factless identity: unknown at the gate (fail
      // closed), never a known-free entry.
      continue;
    }
    const tags = projectFactAxes(dataset, entry, null);
    if (tags !== null) {
      projected.push({ id: identity.key, match: collectNames(identity.key, identity.display, identity.synonyms), allergens: tags });
    }
    for (const form of identity.forms ?? []) {
      const formNames = collectNames(undefined, undefined, form.synonyms);
      if (formNames.length === 0) {
        // The published runner indexes form synonyms only: without one the
        // form is unreachable by name.
        continue;
      }
      const formTags = projectFactAxes(dataset, entry, form.key);
      if (formTags !== null) {
        projected.push({ id: `${identity.key}#${form.key}`, match: formNames, allergens: formTags });
      }
    }
  }
  projected.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return projected;
}

// ————— the vendored-package loader —————

/**
 * Loads the vendored ingredient-facts package (blocker 3, round three).
 *
 * The vendored bytes ARE the published dataset — no re-derivation. Load-time
 * integrity: provenance.json pins each vendored file's sha256; every pin
 * must match the bytes on disk or the package does not load and the gate
 * fails closed. Interpretation is the published evaluator's, mirrored
 * above; the projection into the gate-facing list is deliberately lossless
 * about UNKNOWN — a missing axis excludes the ingredient rather than
 * reading as reviewed-free.
 */
function loadIngredientFactsPackage(factsPath: string, problems: string[]): IngredientFacts | null {
  const packageDir = dirname(factsPath);

  // The manifest: recorded at vendor time, verified at load time.
  const manifestFile = readJsonFile(join(packageDir, "provenance.json"));
  if (!manifestFile.ok) {
    problems.push(`cannot read ${join(packageDir, "provenance.json")} (${manifestFile.reason}) — vendored facts must carry their pinned source`);
    return null;
  }
  const manifest = manifestFile.value;
  if (!isRecord(manifest)) {
    problems.push("provenance.json must be a JSON object");
    return null;
  }
  const sourceBranch = provenanceField(manifest, "sourceBranch", "ingredient facts", null, problems);
  const sourceCommit = provenanceField(manifest, "sourceCommit", "ingredient facts", null, problems);
  const extracted = provenanceField(manifest, "extracted", "ingredient facts", null, problems);
  const filesRaw = manifest["files"];
  if (sourceBranch === null || sourceCommit === null || extracted === null || !Array.isArray(filesRaw) || filesRaw.length === 0) {
    problems.push("provenance.json must carry sourceBranch, sourceCommit, extracted and a non-empty files pin list");
    return null;
  }
  const pins = new Map<string, string>();
  for (const [i, fileRaw] of filesRaw.entries()) {
    if (!isRecord(fileRaw)) {
      problems.push(`provenance.json files[${i}] must be an object`);
      return null;
    }
    const path = fileRaw["path"];
    const hash = fileRaw["sha256"];
    if (typeof path !== "string" || path.length === 0 || typeof hash !== "string" || !SHA256_HASH.test(hash)) {
      problems.push(`provenance.json files[${i}] must carry a path and a sha256 pin`);
      return null;
    }
    pins.set(path, hash);
  }
  for (const required of REQUIRED_VENDORED_FILES) {
    if (!pins.has(required)) {
      problems.push(`provenance.json does not pin ${required}`);
      return null;
    }
  }

  // Byte-for-byte integrity: every pinned file must hash to its pin.
  const vendoredBytes = new Map<string, Buffer>();
  for (const [relativePath, pin] of pins) {
    const vendoredPath = join(packageDir, relativePath);
    let bytes: Buffer;
    try {
      bytes = readFileSync(vendoredPath);
    } catch (error) {
      problems.push(`vendored ${relativePath} is missing (${error instanceof Error ? error.message : String(error)}) — the package must be complete; re-vendor from ${sourceBranch} at ${sourceCommit}`);
      return null;
    }
    const actual = `sha256:${sha256HexBytes(bytes)}`;
    if (actual !== pin) {
      problems.push(`vendored ${relativePath} does not match the pinned ${pin} — a drifted vendored copy must not load; re-vendor from ${sourceBranch} at ${sourceCommit}`);
      return null;
    }
    vendoredBytes.set(relativePath, bytes);
  }

  const factsBytes = vendoredBytes.get("facts.json");
  const identitiesBytes = vendoredBytes.get("identities.json");
  if (factsBytes === undefined || identitiesBytes === undefined) {
    return null; // pinned above — unreachable
  }
  let factsDoc: unknown;
  let identitiesDoc: unknown;
  try {
    factsDoc = JSON.parse(factsBytes.toString("utf8"));
  } catch (error) {
    problems.push(`facts.json is not parsable JSON: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
  try {
    identitiesDoc = JSON.parse(identitiesBytes.toString("utf8"));
  } catch (error) {
    problems.push(`identities.json is not parsable JSON: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
  const facts = parsePublishedFactsDoc(factsDoc, problems);
  if (facts === null) {
    return null;
  }
  const identityPieces = parsePublishedIdentitiesDoc(identitiesDoc, facts, problems);
  if (identityPieces === null) {
    return null;
  }
  const dataset: IngredientFactsDataset = {
    facts,
    identities: identityPieces.identities,
    displayName: identityPieces.displayName,
    nameIndex: identityPieces.nameIndex,
    formIndex: identityPieces.formIndex,
  };
  const ingredients = projectIngredientFacts(dataset);
  if (ingredients.length === 0) {
    problems.push("the published dataset projects no gate-facing entries — refusing to serve an empty facts list");
    return null;
  }
  return {
    schema: INGREDIENT_FACTS_SCHEMA,
    source: `the published FLIngredientFacts dataset vendored byte-for-byte from ${sourceBranch} at ${sourceCommit} (PR #127); interpretation mirrors its conformance runner`,
    allergens: INGREDIENT_FACTS_TAG_VOCABULARY,
    ingredients,
    provenance: {
      sourceBranch,
      sourceCommit,
      files: [...pins].map(([path, sha256]) => ({ path, sha256 })),
      extracted,
    },
    dataset,
  };
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
 * Loads and validates both packages. Anything less than a valid rulebook and
 * a verified vendored facts package is `loaded: false` — the caller must
 * fail closed.
 */
export function loadFoodSafetyCatalog(paths: FoodSafetyCatalogPaths): FoodSafetyCatalog {
  const canonFile = readJsonFile(paths.canon);
  if (!canonFile.ok) {
    return closed(`food-safety canon not loaded: ${canonFile.reason}`);
  }
  const problems: string[] = [];
  const facts = loadIngredientFactsPackage(paths.facts, problems);
  if (facts === null) {
    return closed(`ingredient facts invalid: ${problems.join("; ")}`);
  }
  const rulebook = validateRulebook(canonFile.value, new Set(facts.allergens), problems);
  if (rulebook === null) {
    return closed(`food-safety canon invalid: ${problems.join("; ")}`);
  }
  return { loaded: true, rulebook, facts };
}
