/**
 * Automated screening (SPEC §6.5): three deterministic checks run on every
 * publish. No LLM anywhere in the moderation path; every stage is a function
 * of text. A blocking result sends the publication to the human queue —
 * overridable only by an operator, never by resubmission spam.
 *
 * Ported in spirit from PR #104 `explore/screening.ts` (personal-data
 * patterns, fail-closed pipeline shape). The food-safety lint runs a
 * self-contained rule set; the compound-allergens stage tags through LeChef's
 * reviewed ingredient-facts canon (backend/gemini-agent/src/lechef/allergens.ts
 * and the canon beside it) — no lookup is re-implemented here. The pipeline
 * stays fail-closed: when `screeningPackagesLoaded` is false the publish
 * route refuses with 503 rather than publishing unscreened (SPEC §2.3, PR
 * #104 behaviour kept), and an ingredient line the reviewed canon cannot
 * adjudicate flags "unknown-contents" instead of passing clean.
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import type { AllergenTag, RecipeContent, ScreeningCheck, ScreeningVerdictKind } from "./contract.js";

/**
 * LeChef's own allergen lookup (backend/gemini-agent/src/lechef/allergens.ts),
 * loaded at runtime through createRequire rather than a static import:
 * community's tsconfig is stricter (noUncheckedIndexedAccess) than
 * gemini-agent's, and a static import would drag LeChef's sources into this
 * package's type-check. The lookup is never re-implemented here — these are
 * the exported functions over the reviewed canon, verified by gemini-agent's
 * own suite.
 */
interface LeChefAllergens {
  restrictionTokensFor(ingredientId: string): readonly string[];
  allergenViolations(
    ingredientId: string,
    eaters: readonly { readonly name?: string; readonly restrictions: readonly string[] }[],
  ): readonly string[];
}

let leChefAllergens: LeChefAllergens | null = null;
function leChef(): LeChefAllergens {
  if (leChefAllergens === null) {
    leChefAllergens = createRequire(import.meta.url)("../../../gemini-agent/src/lechef/allergens.js") as LeChefAllergens;
  }
  return leChefAllergens;
}

export interface ScreeningOutcomeResult {
  readonly check: ScreeningCheck;
  readonly verdict: ScreeningVerdictKind;
  readonly detail: string | null;
}

export interface ScreeningResult {
  /** Any blocking verdict → publication goes to the human queue. */
  readonly blocked: boolean;
  /** A non-blocking note pending confirmation (e.g. unresolved allergen). */
  readonly flagged: boolean;
  readonly flaggedTag: AllergenTag | null;
  readonly outcomes: readonly ScreeningOutcomeResult[];
  readonly allergenTags: readonly AllergenTag[];
}

/** A stable hash of the exact content a pipeline run judged; approval consults it (PR #104's content-hash-bound approvals). */
export function contentHashOf(content: RecipeContent): string {
  return createHash("sha256").update(JSON.stringify(content)).digest("hex");
}

/** Stage names the spec lists (contracts/moderation-case.schema.json). */
export const SCREENING_CHECKS = ["food-safety-lint", "compound-allergens", "personal-data"] as const;

/**
 * The mandatory stages no human decision may overrule (the food-safety gate
 * is fail-closed, SPEC §2.3). Approval of a queued publication requires a
 * passing lint at the exact content hash.
 */
export const MANDATORY_STAGES: readonly ScreeningCheck[] = ["food-safety-lint"];

interface IngredientFact {
  readonly allergens: readonly AllergenTag[];
}

interface IngredientFact {
  readonly allergens: readonly AllergenTag[];
}

interface CanonTagMapping {
  /** The community AllergenTag this mapping produces. */
  readonly tag: AllergenTag;
  /** The reviewed vocabulary spelling passed to LeChef's lookup. */
  readonly restriction: string;
  /** The reviewed allergen token(s) the community tag covers. */
  readonly tokens: readonly string[];
}

/**
 * Community AllergenTag → reviewed canon token(s). "shellfish" covers both
 * reviewed shellfish tokens (the canon's crustaceanShellfish stays
 * crustacean-only; molluscs carry molluscanShellfish — the app's shellfish
 * class includes both); every other tag maps to one token. Kept in step with
 * the canon vocabulary; the mapping is spelling only — the allergen states
 * themselves always come from LeChef's lookup of the reviewed facts.
 */
const CANON_TOKENS: Readonly<Record<Exclude<AllergenTag, "unknown-contents" | "mustard" | "sulphites">, CanonTagMapping>> = {
  milk: { tag: "milk", restriction: "milk", tokens: ["milk"] },
  eggs: { tag: "eggs", restriction: "egg", tokens: ["egg"] },
  fish: { tag: "fish", restriction: "fish", tokens: ["fish"] },
  shellfish: { tag: "shellfish", restriction: "shellfish", tokens: ["crustaceanShellfish", "molluscanShellfish"] },
  "tree-nuts": { tag: "tree-nuts", restriction: "treeNuts", tokens: ["treeNuts"] },
  peanuts: { tag: "peanuts", restriction: "peanuts", tokens: ["peanuts"] },
  wheat: { tag: "wheat", restriction: "wheat", tokens: ["wheat"] },
  soy: { tag: "soy", restriction: "soy", tokens: ["soy"] },
  sesame: { tag: "sesame", restriction: "sesame", tokens: ["sesame"] },
};

/**
 * mustard and sulphites have no reviewed canon token: the facts do not
 * adjudicate them. This table is NOT reviewed — it is the burst5 stand-in,
 * kept only for these two tags (every other tag comes from the canon).
 */
const UNREVIEWED_TAG_FACTS: Readonly<Record<string, IngredientFact>> = {
  mustard: { allergens: ["mustard"] },
  wine: { allergens: ["sulphites"] },
  "dried apricot": { allergens: ["sulphites"] },
};

/**
 * Startup readiness measurement (SPEC §2.3): read the reviewed canon from its
 * configured location and force LeChef's lazy facts load, so a missing or
 * malformed canon fails the boot loudly with the path named — never at first
 * publish. The tagging itself goes through LeChef's own lookup, which reads
 * the canon shipped beside allergens.ts (the same directory at the default
 * path); a deployment that relocates the canon points
 * COMMUNITY_INGREDIENT_FACTS_PATH at the new directory.
 */
export function loadIngredientFactsCanon(canonPath: string): void {
  for (const file of ["facts.json", "identities.json"]) {
    const full = join(canonPath, file);
    try {
      JSON.parse(readFileSync(full, "utf8"));
    } catch (error) {
      const cause = error instanceof Error ? error.message : String(error);
      throw new Error(
        `the reviewed ingredient-facts canon is missing or unreadable at ${full} (${cause}); set COMMUNITY_INGREDIENT_FACTS_PATH to the canon directory`,
      );
    }
  }
  try {
    // LeChef's own canon read, end to end: resolves the identity index and
    // the facts table (cached after this) before the app can serve traffic.
    leChef().restrictionTokensFor("water");
  } catch (error) {
    const cause = error instanceof Error ? error.message : String(error);
    throw new Error(`the reviewed ingredient-facts canon at ${canonPath} could not be loaded for screening: ${cause}`);
  }
}

/** Animal proteins that must show a cooking step (burst5 stand-in for PR #126's rulebook). */
const RAW_PROTEIN_TERMS = ["chicken", "pork", "beef", "lamb", "turkey", "salmon", "tuna", "shrimp", "prawn", "fish", "egg"];
const COOKING_TERMS = ["cook", "bake", "fry", "sauté", "saute", "simmer", "grill", "roast", "boil", "poach", "sear", "steam"];
const COOKING_TEMPERATURE = /(1[5-9]\d|2\d\d|[6-9]\d)\s*°?\s*[cf]\b/i;

export class ScreeningPipeline {
  constructor(private readonly packagesLoaded: boolean) {}

  run(content: RecipeContent): ScreeningResult {
    if (!this.packagesLoaded) {
      // Fail closed: the caller turns this into 503; nothing was screened, so
      // nothing may be published.
      throw new Error("screening packages are unloaded");
    }
    const outcomes: ScreeningOutcomeResult[] = [];
    const allergenTags = this.allergenStage(content, outcomes);
    this.foodSafetyStage(content, outcomes);
    const personalDataBlocked = this.personalDataStage(content, outcomes);
    const blocked = personalDataBlocked || outcomes.some((o) => o.check === "food-safety-lint" && o.verdict === "block");
    const flaggedTag: AllergenTag | null = allergenTags.includes("unknown-contents") ? "unknown-contents" : null;
    return {
      blocked,
      flagged: flaggedTag !== null,
      flaggedTag,
      outcomes,
      allergenTags,
    };
  }

  /**
   * Tags every line through LeChef's reviewed facts. A canon token the line
   * certainly carries becomes a tag; a token the canon cannot clear (an
   * unknown or uncertain state anywhere in the composition) marks the line
   * unresolved, which adds "unknown-contents" and the flag. A name with no
   * reviewed fact is unresolved whatever its fdcId — an FDC id says what food
   * a line is, nothing about its allergens.
   */
  private allergenStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): AllergenTag[] {
    const tags = new Set<AllergenTag>();
    let unresolved = 0;
    for (const line of content.ingredientLines) {
      const name = line.name.trim().toLowerCase();
      const carried = leChef().restrictionTokensFor(name);
      let resolved = true;
      for (const mapping of Object.values(CANON_TOKENS)) {
        if (mapping.tokens.some((t) => carried.includes(t))) {
          tags.add(mapping.tag);
          continue;
        }
        // Not certainly carried: cleared only when the reviewed facts answer
        // free for every token the tag covers — any violation (missing fact,
        // unknown or uncertain state) leaves the tag unresolved.
        const cleared = leChef().allergenViolations(name, [{ restrictions: [mapping.restriction] }]).length === 0;
        if (!cleared) {
          resolved = false;
        }
      }
      const unreviewed = UNREVIEWED_TAG_FACTS[name];
      if (unreviewed !== undefined) {
        for (const a of unreviewed.allergens) {
          tags.add(a);
        }
      }
      if (!resolved) {
        unresolved += 1;
      }
    }
    if (unresolved > 0) {
      // Fail closed: any line that cannot resolve tags as unknown-contents
      // rather than passing clean (SPEC §6.5).
      tags.add("unknown-contents");
    }
    const sorted = [...tags].sort();
    outcomes.push({
      check: "compound-allergens",
      verdict: unresolved > 0 ? "flag" : "pass",
      detail:
        unresolved > 0
          ? `${unresolved} of ${content.ingredientLines.length} lines could not resolve an allergen.`
          : null,
    });
    return sorted;
  }

  private foodSafetyStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): void {
    const haystack = `${content.title} ${content.description ?? ""} ${content.ingredientLines.map((l) => l.name).join(" ")} ${content.steps.map((s) => s.text).join(" ")}`.toLowerCase();
    const mentionsRawProtein = RAW_PROTEIN_TERMS.some((t) => haystack.includes(t));
    const stepsText = content.steps.map((s) => s.text.toLowerCase()).join(" ");
    const hasCookingStep = COOKING_TERMS.some((t) => stepsText.includes(t)) || COOKING_TEMPERATURE.test(stepsText);
    // A rule the linter cannot evaluate is a block (fail-closed): an empty
    // recipe — no steps — cannot be evaluated, so it blocks too.
    const unevaluable = content.steps.length === 0;
    if (unevaluable) {
      outcomes.push({
        check: "food-safety-lint",
        verdict: "block",
        detail: "the recipe has no steps, so the food-safety lint cannot evaluate it.",
      });
      return;
    }
    if (mentionsRawProtein && !hasCookingStep) {
      outcomes.push({
        check: "food-safety-lint",
        verdict: "block",
        detail: "a raw animal protein appears without any cooking step or temperature.",
      });
      return;
    }
    outcomes.push({ check: "food-safety-lint", verdict: "pass", detail: null });
  }

  private personalDataStage(content: RecipeContent, outcomes: ScreeningOutcomeResult[]): boolean {
    const fields: Array<readonly [string, string]> = [
      ["title", content.title],
      ...(content.description !== null ? ([["description", content.description]] as const) : []),
      ...content.ingredientLines.map((line, i) => [`ingredient line ${i + 1}`, line.name] as const),
      ...content.steps.map((step, i) => [`step ${i + 1}`, step.text] as const),
      // Client-authored strings that ride the publication verbatim (review
      // finding 4): an email or @handle in equipment must block too.
      ...content.equipment.map((item, i) => [`equipment ${i + 1}`, item] as const),
      ...content.dietaryTags.map((tag, i) => [`dietary tag ${i + 1}`, tag] as const),
    ];
    const reasons: string[] = [];
    for (const [field, text] of fields) {
      for (const finding of findPersonalData(text)) {
        reasons.push(`${finding} in ${field}`);
      }
    }
    if (reasons.length > 0) {
      outcomes.push({
        check: "personal-data",
        verdict: "block",
        detail: reasons.join("; "),
      });
      return true;
    }
    outcomes.push({ check: "personal-data", verdict: "pass", detail: null });
    return false;
  }
}

/** Deterministic personal-data heuristics — ported from PR #104 `findPersonalData`. */
export function findPersonalData(text: string): readonly string[] {
  const findings: string[] = [];
  if (/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("an email address");
  }
  if (/https?:\/\//i.test(text) || /\bwww\.[A-Za-z0-9-]+\.[A-Za-z]{2,}/.test(text)) {
    findings.push("a link");
  }
  if (/@[A-Za-z0-9_]{3,}/.test(text)) {
    findings.push("an @handle");
  }
  for (const run of text.matchAll(/\d[\d\s().-]{5,}\d/g)) {
    if ((run[0]?.match(/\d/g) ?? []).length >= 7) {
      findings.push("a phone number");
      break;
    }
  }
  return findings;
}
